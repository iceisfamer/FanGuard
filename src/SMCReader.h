#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FanInfo : NSObject
@property (nonatomic, assign) NSInteger index;
@property (nonatomic, assign) double currentRPM;
@property (nonatomic, assign) double minRPM;
@property (nonatomic, assign) double maxRPM;
@property (nonatomic, assign) double speedPercent;
@end

@interface ThermalSnapshot : NSObject
@property (nonatomic, strong) NSArray<FanInfo *> *fans;
@property (nonatomic, assign) double maxRPM;
@property (nonatomic, assign) double maxPercent;
@property (nonatomic, assign) double socTempC;
@property (nonatomic, assign) double maxSocTempC;
@property (nonatomic, assign) double batteryTempC;
@property (nonatomic, assign) BOOL tempAvailable;
@property (nonatomic, assign) NSProcessInfoThermalState thermalState;
@property (nonatomic, copy) NSString *thermalStateText;
@property (nonatomic, assign) BOOL smcAvailable;
@end

@interface SMCReader : NSObject
- (ThermalSnapshot *)readThermalSnapshot;
@end

NS_ASSUME_NONNULL_END
