#import "AppDelegate.h"
#import "SMCReader.h"
#import "ProcessMonitor.h"
#import "AlertPanelController.h"

static NSString *const kPrefSensitivity = @"FanGuardSensitivity";

@interface AppDelegate () <AlertPanelDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) SMCReader *smcReader;
@property (nonatomic, strong) ProcessMonitor *processMonitor;
@property (nonatomic, strong) AlertPanelController *panelController;
@property (nonatomic, strong) NSTimer *sampleTimer;

@property (nonatomic, strong) ThermalSnapshot *latestThermal;
@property (nonatomic, strong) NSArray<AppSuspect *> *latestSuspects;
@property (nonatomic, assign) FanSensitivity sensitivity;
@property (nonatomic, assign) NSInteger highFanStreak;
@property (nonatomic, strong) NSDate *lastAlertDate;
@property (nonatomic, assign) double lastAlertRPM;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *snoozedUntil;
@property (nonatomic, assign) BOOL notificationAuthorized;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSInteger savedSens = [[NSUserDefaults standardUserDefaults] integerForKey:kPrefSensitivity];
    if (savedSens >= FanSensitivitySensitive && savedSens <= FanSensitivityHighOnly) {
        self.sensitivity = (FanSensitivity)savedSens;
    } else {
        self.sensitivity = FanSensitivityStandard;
    }

    self.smcReader = [[SMCReader alloc] init];
    self.processMonitor = [[ProcessMonitor alloc] init];
    self.snoozedUntil = [NSMutableDictionary dictionary];

    [self setupStatusItem];
    [self setupNotifications];

    // Initial baseline sample (so CPU deltas are ready on the next tick)
    self.latestThermal = [self.smcReader readThermalSnapshot];
    self.latestSuspects = [self.processMonitor sampleAndTopSuspects:6];

    self.sampleTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                        target:self
                                                      selector:@selector(onSampleTick:)
                                                      userInfo:nil
                                                       repeats:YES];
    self.sampleTimer.tolerance = 0.5;
}

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSStatusBarButton *btn = self.statusItem.button;
    btn.image = [NSImage imageWithSystemSymbolName:@"fan" accessibilityDescription:@"FanGuard"];
    btn.imagePosition = NSImageLeading;
    btn.target = self;
    btn.action = @selector(statusBarClicked:);
    btn.toolTip = @"FanGuard：静默监测风扇异常";
}

- (void)setupNotifications {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.notificationAuthorized = granted;
        });
    }];
}

- (double)rpmThresholdForSensitivity:(FanSensitivity)sens {
    switch (sens) {
        case FanSensitivitySensitive: return 2600.0;
        case FanSensitivityStandard:  return 3200.0;
        case FanSensitivityHighOnly:  return 4200.0;
    }
    return 3200.0;
}

- (double)tempThresholdForSensitivity:(FanSensitivity)sens {
    switch (sens) {
        case FanSensitivitySensitive: return 78.0;
        case FanSensitivityStandard:  return 85.0;
        case FanSensitivityHighOnly:  return 92.0;
    }
    return 85.0;
}

- (BOOL)isThermalAbnormal:(ThermalSnapshot *)thermal {
    double rpmThreshold = [self rpmThresholdForSensitivity:self.sensitivity];
    double tempThreshold = [self tempThresholdForSensitivity:self.sensitivity];
    return (thermal.maxRPM >= rpmThreshold)
        || (thermal.tempAvailable && thermal.maxSocTempC >= tempThreshold)
        || (thermal.thermalState >= NSProcessInfoThermalStateSerious);
}

- (void)onSampleTick:(NSTimer *)timer {
    ThermalSnapshot *thermal = [self.smcReader readThermalSnapshot];
    NSArray<AppSuspect *> *suspects = [self.processMonitor sampleAndTopSuspects:6];

    self.latestThermal = thermal;
    self.latestSuspects = suspects;

    BOOL isAbnormal = [self isThermalAbnormal:thermal];

    [self updateStatusIconWithThermal:thermal isHigh:isAbnormal];

    if (self.panelController.window.isVisible) {
        [self.panelController updateWithThermal:thermal
                                       suspects:suspects
                                    isAlertMode:isAbnormal
                                    sensitivity:self.sensitivity];
    }

    if (isAbnormal) {
        self.highFanStreak += 1;
        if (self.highFanStreak >= 3) { // Sustained for ~6 seconds
            [self evaluateAndTriggerAlertWithThermal:thermal suspects:suspects];
        }
    } else {
        self.highFanStreak = 0;
    }
}

- (void)updateStatusIconWithThermal:(ThermalSnapshot *)thermal isHigh:(BOOL)isHigh {
    NSStatusBarButton *btn = self.statusItem.button;
    NSImageSymbolConfiguration *cfg = nil;
    if (isHigh) {
        cfg = [NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.systemOrangeColor];
        if (thermal.maxRPM >= 2000 && thermal.tempAvailable) {
            btn.title = [NSString stringWithFormat:@" %.0f · %.0f°C", thermal.maxRPM, thermal.maxSocTempC];
        } else if (thermal.tempAvailable) {
            btn.title = [NSString stringWithFormat:@" %.0f°C", thermal.maxSocTempC];
        } else {
            btn.title = [NSString stringWithFormat:@" %.0f", thermal.maxRPM];
        }
    } else {
        cfg = [NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.labelColor];
        btn.title = @"";
    }
    if (thermal.tempAvailable) {
        btn.toolTip = [NSString stringWithFormat:@"FanGuard · 芯片 %.0f°C · 风扇 %.0f RPM",
                       thermal.socTempC, thermal.maxRPM];
    } else {
        btn.toolTip = @"FanGuard：静默监测风扇与温度异常";
    }
    NSImage *img = [[NSImage imageWithSystemSymbolName:(isHigh ? @"fan.fill" : @"fan")
                              accessibilityDescription:@"FanGuard"] imageWithSymbolConfiguration:cfg];
    btn.image = img;
}

- (BOOL)isSuspectSnoozed:(AppSuspect *)suspect {
    NSDate *until = self.snoozedUntil[suspect.groupKey];
    if (!until) return NO;
    if ([until timeIntervalSinceNow] > 0) return YES;
    [self.snoozedUntil removeObjectForKey:suspect.groupKey];
    return NO;
}

- (void)evaluateAndTriggerAlertWithThermal:(ThermalSnapshot *)thermal suspects:(NSArray<AppSuspect *> *)suspects {
    AppSuspect *top = nil;
    for (AppSuspect *s in suspects) {
        if (![self isSuspectSnoozed:s]) {
            top = s;
            break;
        }
    }
    if (!top) return;

    NSTimeInterval sinceLast = self.lastAlertDate ? [[NSDate date] timeIntervalSinceDate:self.lastAlertDate] : 99999.0;
    BOOL bigSpike = (thermal.maxRPM - self.lastAlertRPM) >= 1000.0;
    if (sinceLast < 300.0 && !bigSpike) {
        return;
    }

    self.lastAlertDate = [NSDate date];
    self.lastAlertRPM = thermal.maxRPM;
    [self dispatchAlertWithThermal:thermal suspects:suspects topSuspect:top isTest:NO];
}

- (void)dispatchAlertWithThermal:(ThermalSnapshot *)thermal
                        suspects:(NSArray<AppSuspect *> *)suspects
                      topSuspect:(nullable AppSuspect *)top
                          isTest:(BOOL)isTest {
    NSString *title = nil;
    if (isTest) {
        title = thermal.tempAvailable
            ? [NSString stringWithFormat:@"FanGuard 测试提醒 (%.0f°C · %.0f RPM)", thermal.maxSocTempC, thermal.maxRPM]
            : @"FanGuard 测试提醒：检测到风扇/温度异常";
    } else if (thermal.maxRPM >= 2000 && thermal.tempAvailable) {
        title = [NSString stringWithFormat:@"风扇高速运转 (%.0f RPM · %.0f°C)", thermal.maxRPM, thermal.maxSocTempC];
    } else if (thermal.tempAvailable) {
        title = [NSString stringWithFormat:@"芯片温度异常升高 (%.0f°C · %.0f RPM)", thermal.maxSocTempC, thermal.maxRPM];
    } else {
        title = [NSString stringWithFormat:@"风扇高速运转 (%.0f RPM)", thermal.maxRPM];
    }

    NSString *body = top
        ? [NSString stringWithFormat:@"源头可能是「%@」：%@。点击查看详情并决定是否处理。", top.displayName, top.reasonText]
        : @"检测到设备明显发热，点击查看当前高负载应用。";

    if (self.notificationAuthorized) {
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = title;
        content.body = body;
        content.sound = [UNNotificationSound defaultSound];

        UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:[[NSUUID UUID] UUIDString]
                                                                           content:content
                                                                           trigger:nil];
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:req withCompletionHandler:nil];
    }

    // Ensure panel is updated and shown when notification isn't authorized or during test
    if (!self.notificationAuthorized || isTest) {
        [self ensurePanelController];
        [self.panelController updateWithThermal:thermal
                                       suspects:suspects
                                    isAlertMode:YES
                                    sensitivity:self.sensitivity];
        [self.panelController showPanelAndActivate:isTest];
    }
}

- (void)ensurePanelController {
    if (!self.panelController) {
        self.panelController = [[AlertPanelController alloc] init];
        self.panelController.delegate = self;
    }
}

- (void)statusBarClicked:(id)sender {
    [self ensurePanelController];
    if (self.panelController.window.isVisible) {
        [self.panelController.window orderOut:nil];
        return;
    }
    BOOL isHigh = [self isThermalAbnormal:self.latestThermal];
    [self.panelController updateWithThermal:self.latestThermal
                                   suspects:self.latestSuspects
                                isAlertMode:isHigh
                                sensitivity:self.sensitivity];
    [self.panelController showPanelAndActivate:YES];
}

#pragma mark - UNUserNotificationCenterDelegate

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ensurePanelController];
        [self.panelController updateWithThermal:self.latestThermal
                                       suspects:self.latestSuspects
                                    isAlertMode:YES
                                    sensitivity:self.sensitivity];
        [self.panelController showPanelAndActivate:YES];
    });
    completionHandler();
}

#pragma mark - AlertPanelDelegate

- (void)alertPanelDidRequestTerminateSuspect:(AppSuspect *)suspect force:(BOOL)force {
    [self.processMonitor terminateSuspect:suspect force:force];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self onSampleTick:nil];
    });
}

- (void)alertPanelDidRequestSnoozeSuspect:(AppSuspect *)suspect minutes:(NSInteger)minutes {
    self.snoozedUntil[suspect.groupKey] = [NSDate dateWithTimeIntervalSinceNow:(NSTimeInterval)(minutes * 60)];
    [self.panelController.window orderOut:nil];
}

- (void)alertPanelDidRequestRevealSuspect:(AppSuspect *)suspect {
    [self.processMonitor revealSuspectInFinder:suspect];
}

- (void)alertPanelDidChangeSensitivity:(FanSensitivity)sensitivity {
    self.sensitivity = sensitivity;
    [[NSUserDefaults standardUserDefaults] setInteger:sensitivity forKey:kPrefSensitivity];
}

- (void)alertPanelDidRequestTestAlert {
    AppSuspect *top = self.latestSuspects.firstObject;
    [self dispatchAlertWithThermal:self.latestThermal
                          suspects:self.latestSuspects
                        topSuspect:top
                            isTest:YES];
}

- (void)alertPanelDidRequestQuit {
    [NSApp terminate:nil];
}

@end
