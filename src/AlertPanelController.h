#import <Cocoa/Cocoa.h>
#import "SMCReader.h"
#import "ProcessMonitor.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FanSensitivity) {
    FanSensitivitySensitive = 0, // > 2600 RPM
    FanSensitivityStandard  = 1, // > 3200 RPM
    FanSensitivityHighOnly  = 2  // > 4200 RPM
};

@protocol AlertPanelDelegate <NSObject>
- (void)alertPanelDidRequestTerminateSuspect:(AppSuspect *)suspect force:(BOOL)force;
- (void)alertPanelDidRequestSnoozeSuspect:(AppSuspect *)suspect minutes:(NSInteger)minutes;
- (void)alertPanelDidRequestRevealSuspect:(AppSuspect *)suspect;
- (void)alertPanelDidChangeSensitivity:(FanSensitivity)sensitivity;
- (void)alertPanelDidRequestTestAlert;
- (void)alertPanelDidRequestQuit;
@end

@interface AlertPanelController : NSWindowController
@property (nonatomic, weak, nullable) id<AlertPanelDelegate> delegate;

- (void)updateWithThermal:(ThermalSnapshot *)thermal
                 suspects:(NSArray<AppSuspect *> *)suspects
              isAlertMode:(BOOL)isAlertMode
              sensitivity:(FanSensitivity)sensitivity;
- (void)showPanelAndActivate:(BOOL)activate;
@end

NS_ASSUME_NONNULL_END
