#import "ProcessMonitor.h"
#import <libproc.h>
#import <mach/mach_time.h>
#import <signal.h>
#import <sys/proc_info.h>

@implementation AppSuspect
@end

@interface PidSample : NSObject
@property (nonatomic, assign) uint64_t cpuTimeNs;
@property (nonatomic, assign) uint64_t startTimeSec;
@end

@implementation PidSample
@end

@interface GroupAccumulator : NSObject
@property (nonatomic, copy) NSString *groupKey;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy, nullable) NSString *bundlePath;
@property (nonatomic, assign) double totalCPU;
@property (nonatomic, assign) double totalMemoryMB;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *pids;
@property (nonatomic, assign) BOOL canTerminate;
@end

@implementation GroupAccumulator
- (instancetype)init {
    self = [super init];
    if (self) {
        _pids = [NSMutableArray array];
        _canTerminate = YES;
    }
    return self;
}
@end

@interface ProcessMonitor ()
@property (nonatomic, assign) mach_timebase_info_data_t timebase;
@property (nonatomic, assign) uint64_t lastSampleWallNs;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, PidSample *> *prevPidSamples;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *groupCPUHistory;
@property (nonatomic, strong) NSCache<NSString *, NSImage *> *iconCache;
@property (nonatomic, strong) NSSet<NSString *> *protectedNames;
@end

@implementation ProcessMonitor

- (instancetype)init {
    self = [super init];
    if (self) {
        mach_timebase_info(&_timebase);
        _lastSampleWallNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        _prevPidSamples = [NSMutableDictionary dictionary];
        _groupCPUHistory = [NSMutableDictionary dictionary];
        _iconCache = [[NSCache alloc] init];
        _protectedNames = [NSSet setWithArray:@[
            @"kernel_task", @"launchd", @"WindowServer", @"loginwindow",
            @"UserEventAgent", @"distnoted", @"cfprefsd", @"coreaudiod",
            @"bluetoothd", @"airportd", @"opendirectoryd", @"securityd"
        ]];
    }
    return self;
}

- (NSString *)outerAppBundlePathFromExecutable:(NSString *)execPath {
    if (execPath.length == 0) return nil;
    NSRange range = [execPath rangeOfString:@".app/"];
    if (range.location == NSNotFound) {
        if ([execPath hasSuffix:@".app"]) return execPath;
        return nil;
    }
    return [execPath substringToIndex:range.location + 4];
}

- (NSString *)displayNameForAppPath:(NSString *)appPath {
    NSBundle *bundle = [NSBundle bundleWithPath:appPath];
    NSString *name = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"];
    if (name.length == 0) name = [bundle objectForInfoDictionaryKey:@"CFBundleName"];
    if (name.length == 0) name = [[appPath lastPathComponent] stringByDeletingPathExtension];
    return name;
}

- (NSImage *)iconForPath:(NSString *)path isProtected:(BOOL)isProtected {
    NSString *cacheKey = path.length > 0 ? path : (isProtected ? @"__sys__" : @"__cli__");
    NSImage *cached = [self.iconCache objectForKey:cacheKey];
    if (cached) return cached;

    NSImage *img = nil;
    if (path.length > 0) {
        img = [[NSWorkspace sharedWorkspace] iconForFile:path];
    }
    if (!img) {
        img = [NSImage imageWithSystemSymbolName:(isProtected ? @"gearshape.2.fill" : @"terminal.fill")
                        accessibilityDescription:nil];
    }
    if (img) {
        [self.iconCache setObject:img forKey:cacheKey];
    }
    return img;
}

- (NSArray<AppSuspect *> *)sampleAndTopSuspects:(NSInteger)limit {
    uint64_t nowNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    uint64_t elapsedNs = (nowNs > self.lastSampleWallNs) ? (nowNs - self.lastSampleWallNs) : 1;
    self.lastSampleWallNs = nowNs;

    int byteCount = proc_listallpids(NULL, 0);
    if (byteCount <= 0) return @[];

    int estimatedCount = byteCount / (int)sizeof(pid_t) + 64;
    pid_t *pids = calloc((size_t)estimatedCount, sizeof(pid_t));
    if (!pids) return @[];

    int actualBytes = proc_listallpids(pids, estimatedCount * (int)sizeof(pid_t));
    int pidCount = actualBytes / (int)sizeof(pid_t);
    pid_t selfPid = getpid();

    NSMutableDictionary<NSNumber *, PidSample *> *nextPidSamples = [NSMutableDictionary dictionaryWithCapacity:pidCount];
    NSMutableDictionary<NSString *, GroupAccumulator *> *groups = [NSMutableDictionary dictionary];

    // Map running applications for quick lookup
    NSMutableDictionary<NSNumber *, NSRunningApplication *> *runningApps = [NSMutableDictionary dictionary];
    for (NSRunningApplication *app in [NSWorkspace sharedWorkspace].runningApplications) {
        runningApps[@(app.processIdentifier)] = app;
    }

    for (int i = 0; i < pidCount; i++) {
        pid_t pid = pids[i];
        if (pid <= 0 || pid == selfPid) continue;

        struct proc_taskinfo taskInfo;
        int ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, sizeof(taskInfo));
        if (ret != sizeof(taskInfo)) continue;

        struct proc_bsdinfo bsdInfo;
        uint64_t startSec = 0;
        NSString *commName = nil;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, sizeof(bsdInfo)) == sizeof(bsdInfo)) {
            startSec = bsdInfo.pbi_start_tvsec;
            if (bsdInfo.pbi_comm[0] != '\0') {
                commName = [NSString stringWithUTF8String:bsdInfo.pbi_comm];
            }
        }

        uint64_t totalTicks = taskInfo.pti_total_user + taskInfo.pti_total_system;
        uint64_t cpuNs = (totalTicks * self.timebase.numer) / self.timebase.denom;

        PidSample *curSample = [[PidSample alloc] init];
        curSample.cpuTimeNs = cpuNs;
        curSample.startTimeSec = startSec;
        nextPidSamples[@(pid)] = curSample;

        double cpuPercent = 0.0;
        PidSample *prev = self.prevPidSamples[@(pid)];
        if (prev && prev.startTimeSec == startSec && cpuNs >= prev.cpuTimeNs && elapsedNs > 1000000ULL) {
            cpuPercent = ((double)(cpuNs - prev.cpuTimeNs) / (double)elapsedNs) * 100.0;
        }

        double memMB = (double)taskInfo.pti_resident_size / (1024.0 * 1024.0);
        struct rusage_info_v4 rusage;
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&rusage) == 0 && rusage.ri_phys_footprint > 0) {
            memMB = (double)rusage.ri_phys_footprint / (1024.0 * 1024.0);
        }

        char pathBuf[PROC_PIDPATHINFO_MAXSIZE];
        NSString *execPath = nil;
        if (proc_pidpath(pid, pathBuf, sizeof(pathBuf)) > 0) {
            execPath = [NSString stringWithUTF8String:pathBuf];
        }

        NSString *appBundlePath = [self outerAppBundlePathFromExecutable:execPath];
        NSRunningApplication *runApp = runningApps[@(pid)];
        if (!appBundlePath && runApp.bundleURL.path) {
            appBundlePath = runApp.bundleURL.path;
        }

        NSString *groupKey = nil;
        NSString *displayName = nil;
        BOOL isProtected = NO;

        if (appBundlePath.length > 0) {
            groupKey = appBundlePath;
            displayName = runApp.localizedName.length > 0 ? runApp.localizedName : [self displayNameForAppPath:appBundlePath];
        } else {
            NSString *procName = execPath.length > 0 ? [execPath lastPathComponent] : (commName.length > 0 ? commName : [NSString stringWithFormat:@"PID %d", pid]);
            groupKey = [NSString stringWithFormat:@"bin:%@", procName];
            displayName = procName;
            if ([self.protectedNames containsObject:procName] || pid == 0 || pid == 1) {
                isProtected = YES;
            }
        }

        GroupAccumulator *acc = groups[groupKey];
        if (!acc) {
            acc = [[GroupAccumulator alloc] init];
            acc.groupKey = groupKey;
            acc.displayName = displayName;
            acc.bundlePath = appBundlePath ?: execPath;
            acc.canTerminate = !isProtected;
            groups[groupKey] = acc;
        }
        acc.totalCPU += cpuPercent;
        acc.totalMemoryMB += memMB;
        [acc.pids addObject:@(pid)];
    }

    free(pids);
    self.prevPidSamples = nextPidSamples;

    // Update 60s rolling history (30 samples at 2s interval)
    NSMutableSet<NSString *> *activeKeys = [NSMutableSet setWithArray:groups.allKeys];
    for (NSString *oldKey in [self.groupCPUHistory.allKeys copy]) {
        if (![activeKeys containsObject:oldKey]) {
            [self.groupCPUHistory removeObjectForKey:oldKey];
        }
    }

    NSMutableArray<AppSuspect *> *suspects = [NSMutableArray arrayWithCapacity:groups.count];
    for (GroupAccumulator *acc in groups.allValues) {
        NSMutableArray<NSNumber *> *hist = self.groupCPUHistory[acc.groupKey];
        if (!hist) {
            hist = [NSMutableArray array];
            self.groupCPUHistory[acc.groupKey] = hist;
        }
        [hist addObject:@(acc.totalCPU)];
        if (hist.count > 30) {
            [hist removeObjectAtIndex:0];
        }

        NSInteger windowCount = MIN((NSInteger)hist.count, 15); // ~30s
        double sum30s = 0;
        double peak30s = 0;
        for (NSInteger j = hist.count - windowCount; j < (NSInteger)hist.count; j++) {
            double v = hist[j].doubleValue;
            sum30s += v;
            if (v > peak30s) peak30s = v;
        }
        double avg30s = windowCount > 0 ? (sum30s / windowCount) : acc.totalCPU;

        AppSuspect *s = [[AppSuspect alloc] init];
        s.groupKey = acc.groupKey;
        s.displayName = acc.displayName;
        s.bundlePath = acc.bundlePath;
        s.icon = [self iconForPath:acc.bundlePath isProtected:!acc.canTerminate];
        s.currentCPU = acc.totalCPU;
        s.avgCPU30s = avg30s;
        s.peakCPU30s = peak30s;
        s.memoryMB = acc.totalMemoryMB;
        s.processCount = acc.pids.count;
        s.pids = [acc.pids copy];
        s.canTerminate = acc.canTerminate;
        s.suspicionScore = 0.65 * avg30s + 0.35 * acc.totalCPU;

        if (!s.canTerminate) {
            s.reasonText = [NSString stringWithFormat:@"系统进程负载（当前 %.0f%% CPU）", s.currentCPU];
        } else if (s.avgCPU30s >= 80.0) {
            s.reasonText = [NSString stringWithFormat:@"持续高 CPU 占用（近30秒均值 %.0f%%）", s.avgCPU30s];
        } else if (s.processCount >= 4 && s.currentCPU >= 40.0) {
            s.reasonText = [NSString stringWithFormat:@"多子进程合计高负载（%ld 个进程 · %.0f%%）", (long)s.processCount, s.currentCPU];
        } else if (s.peakCPU30s >= 100.0) {
            s.reasonText = [NSString stringWithFormat:@"近期 CPU 突发冲高（峰值 %.0f%%）", s.peakCPU30s];
        } else {
            s.reasonText = [NSString stringWithFormat:@"当前 CPU %.1f%% · 内存 %.0f MB", s.currentCPU, s.memoryMB];
        }

        [suspects addObject:s];
    }

    [suspects sortUsingComparator:^NSComparisonResult(AppSuspect *a, AppSuspect *b) {
        if (a.suspicionScore > b.suspicionScore) return NSOrderedAscending;
        if (a.suspicionScore < b.suspicionScore) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    if (limit > 0 && (NSInteger)suspects.count > limit) {
        return [suspects subarrayWithRange:NSMakeRange(0, (NSUInteger)limit)];
    }
    return suspects;
}

- (BOOL)terminateSuspect:(AppSuspect *)suspect force:(BOOL)force {
    if (!suspect.canTerminate) return NO;

    // Try graceful NSRunningApplication terminate first when not forcing
    if (!force && suspect.bundlePath.length > 0) {
        BOOL handled = NO;
        for (NSRunningApplication *app in [NSWorkspace sharedWorkspace].runningApplications) {
            if ([app.bundleURL.path isEqualToString:suspect.bundlePath]) {
                [app terminate];
                handled = YES;
            }
        }
        if (handled) return YES;
    }

    BOOL anySent = NO;
    int sig = force ? SIGKILL : SIGTERM;
    for (NSNumber *pidNum in suspect.pids) {
        pid_t pid = (pid_t)pidNum.intValue;
        if (pid > 1) {
            if (kill(pid, sig) == 0) {
                anySent = YES;
            }
        }
    }
    return anySent;
}

- (void)revealSuspectInFinder:(AppSuspect *)suspect {
    if (suspect.bundlePath.length > 0) {
        NSURL *url = [NSURL fileURLWithPath:suspect.bundlePath];
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
    }
}

@end
