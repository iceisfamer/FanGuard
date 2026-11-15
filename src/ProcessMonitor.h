#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppSuspect : NSObject
@property (nonatomic, copy) NSString *groupKey;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy, nullable) NSString *bundlePath;
@property (nonatomic, strong, nullable) NSImage *icon;
@property (nonatomic, assign) double currentCPU;
@property (nonatomic, assign) double avgCPU30s;
@property (nonatomic, assign) double peakCPU30s;
@property (nonatomic, assign) double memoryMB;
@property (nonatomic, assign) NSInteger processCount;
@property (nonatomic, strong) NSArray<NSNumber *> *pids;
@property (nonatomic, assign) BOOL canTerminate;
@property (nonatomic, assign) double suspicionScore;
@property (nonatomic, copy) NSString *reasonText;
@end

@interface ProcessMonitor : NSObject
- (NSArray<AppSuspect *> *)sampleAndTopSuspects:(NSInteger)limit;
- (BOOL)terminateSuspect:(AppSuspect *)suspect force:(BOOL)force;
- (void)revealSuspectInFinder:(AppSuspect *)suspect;
@end

NS_ASSUME_NONNULL_END
