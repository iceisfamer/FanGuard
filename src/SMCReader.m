#import "SMCReader.h"
#import <IOKit/IOKitLib.h>

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timeout);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kIOHIDEventTypeTemperature 15
#define IOHIDEventFieldBase(type) ((type) << 16)

typedef struct {
    uint32_t key;
    struct {
        uint8_t major;
        uint8_t minor;
        uint8_t build;
        uint8_t reserved;
        uint16_t release;
    } vers;
    struct {
        uint16_t version;
        uint16_t length;
        uint32_t cpuPLimit;
        uint32_t gpuPLimit;
        uint32_t memPLimit;
    } pLimitData;
    struct {
        uint32_t dataSize;
        uint32_t dataType;
        uint8_t dataAttributes;
    } keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData_t;

static uint32_t smcStrToKey(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) |
           ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8)  |
           ((uint32_t)(uint8_t)s[3]);
}

static void smcKeyToStr(uint32_t k, char *out) {
    out[0] = (k >> 24) & 0xFF;
    out[1] = (k >> 16) & 0xFF;
    out[2] = (k >> 8) & 0xFF;
    out[3] = k & 0xFF;
    out[4] = '\0';
}

@implementation FanInfo
@end

@implementation ThermalSnapshot
@end

@interface SMCReader ()
@property (nonatomic, assign) io_connect_t conn;
@property (nonatomic, assign) IOHIDEventSystemClientRef hidClient;
@end

@implementation SMCReader

- (instancetype)init {
    self = [super init];
    if (self) {
        [self openSMC];
        [self openHIDTempClient];
    }
    return self;
}

- (void)dealloc {
    if (_conn != IO_OBJECT_NULL) {
        IOServiceClose(_conn);
        _conn = IO_OBJECT_NULL;
    }
    if (_hidClient != NULL) {
        CFRelease(_hidClient);
        _hidClient = NULL;
    }
}

- (void)openHIDTempClient {
    _hidClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (_hidClient) {
        NSDictionary *match = @{@"PrimaryUsagePage": @(0xff00), @"PrimaryUsage": @(5)};
        IOHIDEventSystemClientSetMatching(_hidClient, (__bridge CFDictionaryRef)match);
    }
}

- (BOOL)openSMC {
    if (_conn != IO_OBJECT_NULL) return YES;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) return NO;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &_conn);
    IOObjectRelease(service);
    if (kr != kIOReturnSuccess) {
        _conn = IO_OBJECT_NULL;
        return NO;
    }
    return YES;
}

- (BOOL)readKey:(const char *)keyStr value:(double *)outValue {
    if (_conn == IO_OBJECT_NULL && ![self openSMC]) return NO;

    SMCKeyData_t input = {0};
    SMCKeyData_t output = {0};
    size_t outputSize = sizeof(SMCKeyData_t);

    input.key = smcStrToKey(keyStr);
    input.data8 = 9; // kSMCGetKeyInfo
    kern_return_t kr = IOConnectCallStructMethod(_conn, 2, &input, sizeof(SMCKeyData_t), &output, &outputSize);
    if (kr != kIOReturnSuccess || output.result != 0) return NO;

    uint32_t dataSize = output.keyInfo.dataSize;
    uint32_t dataType = output.keyInfo.dataType;

    memset(&input, 0, sizeof(SMCKeyData_t));
    memset(&output, 0, sizeof(SMCKeyData_t));
    outputSize = sizeof(SMCKeyData_t);

    input.key = smcStrToKey(keyStr);
    input.keyInfo.dataSize = dataSize;
    input.data8 = 5; // kSMCReadKey
    kr = IOConnectCallStructMethod(_conn, 2, &input, sizeof(SMCKeyData_t), &output, &outputSize);
    if (kr != kIOReturnSuccess || output.result != 0) return NO;

    char typeStr[5];
    smcKeyToStr(dataType, typeStr);

    if (strcmp(typeStr, "flt ") == 0 && dataSize == 4) {
        float f = 0;
        memcpy(&f, output.bytes, 4);
        *outValue = (double)f;
        return YES;
    }
    if (strcmp(typeStr, "fpe2") == 0 && dataSize == 2) {
        *outValue = ((output.bytes[0] << 8) | output.bytes[1]) / 4.0;
        return YES;
    }
    if (strcmp(typeStr, "ui8 ") == 0 && dataSize == 1) {
        *outValue = (double)output.bytes[0];
        return YES;
    }
    if (strcmp(typeStr, "ui16") == 0 && dataSize == 2) {
        *outValue = (double)((output.bytes[0] << 8) | output.bytes[1]);
        return YES;
    }
    if (strcmp(typeStr, "sp78") == 0 && dataSize == 2) {
        int16_t raw = (int16_t)((output.bytes[0] << 8) | output.bytes[1]);
        *outValue = raw / 256.0;
        return YES;
    }
    return NO;
}

- (NSString *)labelForThermalState:(NSProcessInfoThermalState)state {
    switch (state) {
        case NSProcessInfoThermalStateNominal:  return @"正常";
        case NSProcessInfoThermalStateFair:     return @"轻度发热";
        case NSProcessInfoThermalStateSerious:  return @"明显发热";
        case NSProcessInfoThermalStateCritical: return @"严重过热";
    }
    return @"未知";
}

- (void)populateTemperaturesInSnapshot:(ThermalSnapshot *)snap {
    if (!_hidClient) {
        [self openHIDTempClient];
    }
    if (!_hidClient) return;

    CFArrayRef services = IOHIDEventSystemClientCopyServices(_hidClient);
    if (!services) return;

    double dieSum = 0.0;
    NSInteger dieCount = 0;
    double dieMax = 0.0;
    double fallbackSum = 0.0;
    NSInteger fallbackCount = 0;
    double fallbackMax = 0.0;
    double battSum = 0.0;
    NSInteger battCount = 0;

    CFIndex count = CFArrayGetCount(services);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFStringRef nameRef = IOHIDServiceClientCopyProperty(svc, CFSTR("Product"));
        NSString *name = nameRef ? (__bridge_transfer NSString *)nameRef : @"";

        if ([name containsString:@"tcal"]) continue;

        IOHIDEventRef ev = IOHIDServiceClientCopyEvent(svc, kIOHIDEventTypeTemperature, 0, 0);
        if (!ev) continue;

        double temp = IOHIDEventGetFloatValue(ev, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
        CFRelease(ev);

        if (temp <= 5.0 || temp >= 130.0) continue;

        if ([name containsString:@"tdie"] || [name containsString:@"SOC MTR"]) {
            dieSum += temp;
            dieCount++;
            if (temp > dieMax) dieMax = temp;
        } else if ([name containsString:@"battery"]) {
            battSum += temp;
            battCount++;
        } else if ([name containsString:@"tdev"]) {
            fallbackSum += temp;
            fallbackCount++;
            if (temp > fallbackMax) fallbackMax = temp;
        }
    }
    CFRelease(services);

    if (dieCount > 0) {
        snap.tempAvailable = YES;
        snap.socTempC = dieSum / dieCount;
        snap.maxSocTempC = dieMax;
    } else if (fallbackCount > 0) {
        snap.tempAvailable = YES;
        snap.socTempC = fallbackSum / fallbackCount;
        snap.maxSocTempC = fallbackMax;
    }
    if (battCount > 0) {
        snap.batteryTempC = battSum / battCount;
    }
}

- (ThermalSnapshot *)readThermalSnapshot {
    ThermalSnapshot *snap = [[ThermalSnapshot alloc] init];
    snap.thermalState = NSProcessInfo.processInfo.thermalState;
    snap.thermalStateText = [self labelForThermalState:snap.thermalState];
    [self populateTemperaturesInSnapshot:snap];

    double fanCountD = 0;
    if (![self readKey:"FNum" value:&fanCountD]) {
        snap.smcAvailable = NO;
        snap.fans = @[];
        return snap;
    }

    snap.smcAvailable = YES;
    NSInteger fanCount = MAX(0, MIN(8, (NSInteger)llround(fanCountD)));
    NSMutableArray<FanInfo *> *fans = [NSMutableArray arrayWithCapacity:fanCount];
    double maxRPM = 0;
    double maxPercent = 0;

    for (NSInteger i = 0; i < fanCount; i++) {
        char kAc[5], kMn[5], kMx[5];
        snprintf(kAc, sizeof(kAc), "F%ldAc", (long)i);
        snprintf(kMn, sizeof(kMn), "F%ldMn", (long)i);
        snprintf(kMx, sizeof(kMx), "F%ldMx", (long)i);

        double cur = 0, mn = 0, mx = 0;
        [self readKey:kAc value:&cur];
        [self readKey:kMn value:&mn];
        [self readKey:kMx value:&mx];

        FanInfo *f = [[FanInfo alloc] init];
        f.index = i;
        f.currentRPM = MAX(0, cur);
        f.minRPM = mn;
        f.maxRPM = mx;

        if (f.currentRPM < 100.0) {
            f.speedPercent = 0.0;
        } else if (mx > mn) {
            double pct = (f.currentRPM - mn) / (mx - mn) * 100.0;
            f.speedPercent = MAX(0.0, MIN(100.0, pct));
        } else if (mx > 0) {
            f.speedPercent = MAX(0.0, MIN(100.0, f.currentRPM / mx * 100.0));
        }

        if (f.currentRPM > maxRPM) maxRPM = f.currentRPM;
        if (f.speedPercent > maxPercent) maxPercent = f.speedPercent;
        [fans addObject:f];
    }

    snap.fans = fans;
    snap.maxRPM = maxRPM;
    snap.maxPercent = maxPercent;
    return snap;
}

@end
