#import "AlertPanelController.h"

@interface SuspectRowView : NSView
@property (nonatomic, strong) AppSuspect *suspect;
@property (nonatomic, copy) void (^onTerminate)(AppSuspect *s, BOOL force);
@property (nonatomic, copy) void (^onSnooze)(AppSuspect *s);
@property (nonatomic, copy) void (^onReveal)(AppSuspect *s);
@property (nonatomic, copy) void (^onHoverChanged)(AppSuspect *s, SuspectRowView *row, BOOL entered);
@property (nonatomic, strong) NSTrackingArea *hoverTrackingArea;
@end

@implementation SuspectRowView

- (instancetype)initWithSuspect:(AppSuspect *)suspect
                          frame:(NSRect)frame
                    onTerminate:(void (^)(AppSuspect *, BOOL))onTerminate
                       onSnooze:(void (^)(AppSuspect *))onSnooze
                       onReveal:(void (^)(AppSuspect *))onReveal
                 onHoverChanged:(void (^)(AppSuspect *, SuspectRowView *, BOOL))onHoverChanged {
    self = [super initWithFrame:frame];
    if (self) {
        _suspect = suspect;
        _onTerminate = [onTerminate copy];
        _onSnooze = [onSnooze copy];
        _onReveal = [onReveal copy];
        _onHoverChanged = [onHoverChanged copy];
        [self buildUI];
    }
    return self;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.hoverTrackingArea) {
        [self removeTrackingArea:self.hoverTrackingArea];
    }
    NSTrackingAreaOptions opts = NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect;
    self.hoverTrackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds options:opts owner:self userInfo:nil];
    [self addTrackingArea:self.hoverTrackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    if (self.onHoverChanged) self.onHoverChanged(self.suspect, self, YES);
}

- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    if (self.onHoverChanged) self.onHoverChanged(self.suspect, self, NO);
}

- (NSImage *)templateSymbol:(NSString *)symbolName {
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:11.5 weight:NSFontWeightMedium];
    NSImage *img = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
    img = [img imageWithSymbolConfiguration:cfg];
    img.template = YES;
    return img;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    NSAppearanceName best = [self.effectiveAppearance bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameAqua,
        NSAppearanceNameDarkAqua
    ]];
    BOOL isDark = [best isEqualToString:NSAppearanceNameDarkAqua];
    if (isDark) {
        self.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.075].CGColor;
        self.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.12].CGColor;
    } else {
        self.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.035].CGColor;
        self.layer.borderColor = [NSColor colorWithWhite:0.0 alpha:0.08].CGColor;
    }
    self.layer.borderWidth = 1.0;
}

- (void)buildUI {
    self.wantsLayer = YES;
    self.layer.cornerRadius = 8.0;

    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(12, 10, 28, 28)];
    iconView.image = self.suspect.icon;
    iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [self addSubview:iconView];

    // Process icon + count
    NSImageView *procIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(50, 17, 14, 14)];
    procIcon.image = [self templateSymbol:@"square.stack.3d.up"];
    procIcon.contentTintColor = [NSColor.labelColor colorWithAlphaComponent:0.72];
    procIcon.toolTip = @"进程数量";
    [self addSubview:procIcon];

    NSTextField *procLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"%ld", (long)self.suspect.processCount]];
    procLabel.font = [NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightMedium];
    procLabel.textColor = [NSColor.labelColor colorWithAlphaComponent:0.90];
    procLabel.frame = NSMakeRect(67, 15, 32, 18);
    [self addSubview:procLabel];

    // CPU icon + %
    BOOL isHotCPU = (self.suspect.currentCPU >= 80.0 || self.suspect.avgCPU30s >= 80.0);
    NSColor *cpuColor = isHotCPU ? NSColor.systemOrangeColor : NSColor.labelColor;

    NSImageView *cpuIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(104, 17, 14, 14)];
    cpuIcon.image = [self templateSymbol:@"cpu"];
    cpuIcon.contentTintColor = isHotCPU ? NSColor.systemOrangeColor : [NSColor.labelColor colorWithAlphaComponent:0.72];
    cpuIcon.toolTip = @"CPU 占用";
    [self addSubview:cpuIcon];

    NSTextField *cpuLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"%.0f%%", self.suspect.currentCPU]];
    cpuLabel.font = [NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightMedium];
    cpuLabel.textColor = cpuColor;
    cpuLabel.frame = NSMakeRect(121, 15, 48, 18);
    [self addSubview:cpuLabel];

    // Memory icon + size (M / G)
    NSImageView *memIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(172, 17, 14, 14)];
    memIcon.image = [self templateSymbol:@"memorychip"];
    memIcon.contentTintColor = [NSColor.labelColor colorWithAlphaComponent:0.72];
    memIcon.toolTip = @"内存占用";
    [self addSubview:memIcon];

    NSString *memText = (self.suspect.memoryMB >= 1024.0)
        ? [NSString stringWithFormat:@"%.1fG", self.suspect.memoryMB / 1024.0]
        : [NSString stringWithFormat:@"%.0fM", self.suspect.memoryMB];
    NSTextField *memLabel = [NSTextField labelWithString:memText];
    memLabel.font = [NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightMedium];
    memLabel.textColor = [NSColor.labelColor colorWithAlphaComponent:0.90];
    memLabel.frame = NSMakeRect(189, 15, 58, 18);
    [self addSubview:memLabel];

    CGFloat btnY = 13;
    if (self.suspect.bundlePath.length > 0) {
        NSButton *revealBtn = [NSButton buttonWithImage:[self templateSymbol:@"folder"]
                                                 target:self
                                                 action:@selector(handleReveal:)];
        revealBtn.bezelStyle = NSBezelStyleInline;
        revealBtn.bordered = NO;
        revealBtn.contentTintColor = [NSColor.labelColor colorWithAlphaComponent:0.72];
        revealBtn.toolTip = @"在访达中显示";
        revealBtn.frame = NSMakeRect(252, btnY + 1, 20, 20);
        [self addSubview:revealBtn];
    }

    if (self.suspect.canTerminate) {
        NSButton *snoozeBtn = [NSButton buttonWithTitle:@"忽略" target:self action:@selector(handleSnooze:)];
        snoozeBtn.bezelStyle = NSBezelStyleRounded;
        snoozeBtn.controlSize = NSControlSizeSmall;
        snoozeBtn.toolTip = @"30分钟内不再提醒";
        snoozeBtn.frame = NSMakeRect(278, btnY, 58, 22);
        [self addSubview:snoozeBtn];

        NSButton *killBtn = [NSButton buttonWithTitle:@"结束" target:self action:@selector(handleTerminate:)];
        killBtn.bezelStyle = NSBezelStyleRounded;
        killBtn.controlSize = NSControlSizeSmall;
        killBtn.toolTip = @"温和退出（按住 Option 点击强制结束）";
        killBtn.frame = NSMakeRect(340, btnY, 56, 22);
        [self addSubview:killBtn];
    } else {
        NSTextField *sysTag = [NSTextField labelWithString:@"系统进程"];
        sysTag.font = [NSFont systemFontOfSize:11];
        sysTag.textColor = NSColor.tertiaryLabelColor;
        sysTag.alignment = NSTextAlignmentRight;
        sysTag.frame = NSMakeRect(320, 16, 76, 16);
        [self addSubview:sysTag];
    }
}

- (void)handleTerminate:(id)sender {
    NSEvent *ev = NSApp.currentEvent;
    BOOL force = (ev.modifierFlags & NSEventModifierFlagOption) != 0;
    if (self.onTerminate) self.onTerminate(self.suspect, force);
}

- (void)handleSnooze:(id)sender {
    if (self.onSnooze) self.onSnooze(self.suspect);
}

- (void)handleReveal:(id)sender {
    if (self.onReveal) self.onReveal(self.suspect);
}

@end

@interface AlertPanelController () <NSWindowDelegate>
@property (nonatomic, strong) NSTextField *bannerTitleLabel;
@property (nonatomic, strong) NSTextField *tempBadgeLabel;
@property (nonatomic, strong) NSTextField *fanSummaryLabel;
@property (nonatomic, strong) NSView *bannerBox;
@property (nonatomic, strong) NSView *listContainer;
@property (nonatomic, strong) NSPopUpButton *sensitivityPopup;
@property (nonatomic, strong) NSPanel *hoverPanel;
@property (nonatomic, strong) NSTextField *hoverTitleLabel;
@property (nonatomic, strong) NSTextField *hoverSubLabel;
@property (nonatomic, strong) NSView *hoverCardView;
@property (nonatomic, copy, nullable) NSString *hoveredGroupKey;
@property (nonatomic, strong, nullable) NSTimer *hoverHideTimer;
@end

@implementation AlertPanelController

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 440, 356);
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:frame
                                                styleMask:(NSWindowStyleMaskTitled |
                                                           NSWindowStyleMaskClosable |
                                                           NSWindowStyleMaskNonactivatingPanel)
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    panel.title = @"FanGuard";
    panel.level = NSFloatingWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.releasedWhenClosed = NO;

    self = [super initWithWindow:panel];
    if (self) {
        panel.delegate = self;
        [self setupUI];
        [self setupHoverPanel];
        [panel center];
    }
    return self;
}

- (void)setupHoverPanel {
    self.hoverPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 240, 44)
                                                 styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
    self.hoverPanel.opaque = NO;
    self.hoverPanel.backgroundColor = NSColor.clearColor;
    self.hoverPanel.hasShadow = YES;
    self.hoverPanel.ignoresMouseEvents = YES;
    self.hoverPanel.level = NSPopUpMenuWindowLevel;
    self.hoverPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;

    NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 240, 44)];
    bg.material = NSVisualEffectMaterialPopover;
    bg.state = NSVisualEffectStateActive;
    bg.wantsLayer = YES;
    bg.layer.cornerRadius = 8.0;
    bg.layer.borderWidth = 1.0;
    bg.layer.borderColor = [NSColor.separatorColor colorWithAlphaComponent:0.5].CGColor;
    bg.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.hoverPanel.contentView = bg;
    self.hoverCardView = bg;

    self.hoverTitleLabel = [NSTextField labelWithString:@""];
    self.hoverTitleLabel.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold];
    self.hoverTitleLabel.textColor = NSColor.labelColor;
    self.hoverTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [bg addSubview:self.hoverTitleLabel];

    self.hoverSubLabel = [NSTextField labelWithString:@""];
    self.hoverSubLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    self.hoverSubLabel.textColor = NSColor.secondaryLabelColor;
    self.hoverSubLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [bg addSubview:self.hoverSubLabel];
}

- (void)showHoverForSuspect:(AppSuspect *)suspect row:(SuspectRowView *)row {
    [self.hoverHideTimer invalidate];
    self.hoverHideTimer = nil;
    self.hoveredGroupKey = suspect.groupKey;

    self.hoverTitleLabel.stringValue = suspect.displayName ?: @"";
    self.hoverSubLabel.stringValue = suspect.reasonText ?: @"";

    NSSize titleSize = [self.hoverTitleLabel.stringValue sizeWithAttributes:@{NSFontAttributeName: self.hoverTitleLabel.font}];
    NSSize subSize = [self.hoverSubLabel.stringValue sizeWithAttributes:@{NSFontAttributeName: self.hoverSubLabel.font}];
    CGFloat contentW = MAX(titleSize.width, subSize.width);
    CGFloat panelW = MIN(340.0, MAX(140.0, ceil(contentW) + 24.0));
    CGFloat panelH = 44.0;

    self.hoverTitleLabel.frame = NSMakeRect(12, 22, panelW - 24, 16);
    self.hoverSubLabel.frame = NSMakeRect(12, 6, panelW - 24, 14);

    NSRect rowInWindow = [row convertRect:row.bounds toView:nil];
    NSRect rowOnScreen = [self.window convertRectToScreen:rowInWindow];
    NSPoint origin = NSMakePoint(rowOnScreen.origin.x + 10.0, rowOnScreen.origin.y + rowOnScreen.size.height + 4.0);

    [self.hoverPanel setFrame:NSMakeRect(origin.x, origin.y, panelW, panelH) display:YES];
    if (!self.hoverPanel.isVisible) {
        [self.hoverPanel orderFrontRegardless];
    }
}

- (void)scheduleHideHoverForGroupKey:(NSString *)groupKey {
    if (![self.hoveredGroupKey isEqualToString:groupKey]) return;
    [self.hoverHideTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.hoverHideTimer = [NSTimer scheduledTimerWithTimeInterval:0.08 repeats:NO block:^(NSTimer * _Nonnull timer) {
        weakSelf.hoveredGroupKey = nil;
        [weakSelf.hoverPanel orderOut:nil];
    }];
}

- (void)windowWillClose:(NSNotification *)notification {
    [self.hoverHideTimer invalidate];
    self.hoverHideTimer = nil;
    self.hoveredGroupKey = nil;
    [self.hoverPanel orderOut:nil];
}

- (void)setupUI {
    NSView *root = self.window.contentView;

    // Top thermal banner
    self.bannerBox = [[NSView alloc] initWithFrame:NSMakeRect(16, 278, 408, 62)];
    self.bannerBox.wantsLayer = YES;
    self.bannerBox.layer.cornerRadius = 10.0;
    self.bannerBox.layer.backgroundColor = [NSColor.systemBlueColor colorWithAlphaComponent:0.12].CGColor;
    [root addSubview:self.bannerBox];

    self.bannerTitleLabel = [NSTextField labelWithString:@"风扇运转正常"];
    self.bannerTitleLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightBold];
    self.bannerTitleLabel.frame = NSMakeRect(14, 34, 240, 20);
    [self.bannerBox addSubview:self.bannerTitleLabel];

    self.tempBadgeLabel = [NSTextField labelWithString:@"-- °C"];
    self.tempBadgeLabel.font = [NSFont monospacedDigitSystemFontOfSize:13.5 weight:NSFontWeightBold];
    self.tempBadgeLabel.alignment = NSTextAlignmentRight;
    self.tempBadgeLabel.frame = NSMakeRect(256, 34, 138, 20);
    [self.bannerBox addSubview:self.tempBadgeLabel];

    self.fanSummaryLabel = [NSTextField labelWithString:@"正在读取风扇与温度…"];
    self.fanSummaryLabel.font = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    self.fanSummaryLabel.textColor = NSColor.secondaryLabelColor;
    self.fanSummaryLabel.frame = NSMakeRect(14, 12, 380, 16);
    [self.bannerBox addSubview:self.fanSummaryLabel];

    // Suspect list container (4 compact rows: 4*48 + 3*8 = 216)
    self.listContainer = [[NSView alloc] initWithFrame:NSMakeRect(16, 50, 408, 216)];
    [root addSubview:self.listContainer];

    // Bottom toolbar
    NSTextField *sensLabel = [NSTextField labelWithString:@"阈值:"];
    sensLabel.font = [NSFont systemFontOfSize:11.5];
    sensLabel.textColor = NSColor.secondaryLabelColor;
    sensLabel.frame = NSMakeRect(16, 16, 36, 18);
    [root addSubview:sensLabel];

    self.sensitivityPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(54, 13, 196, 24) pullsDown:NO];
    [self.sensitivityPopup addItemsWithTitles:@[
        @"敏感 (>2600 RPM / 78°C)",
        @"标准 (>3200 RPM / 85°C)",
        @"高负载 (>4200 RPM / 92°C)"
    ]];
    self.sensitivityPopup.font = [NSFont systemFontOfSize:11.5];
    self.sensitivityPopup.target = self;
    self.sensitivityPopup.action = @selector(sensitivityChanged:);
    [root addSubview:self.sensitivityPopup];

    NSButton *testBtn = [NSButton buttonWithTitle:@"模拟" target:self action:@selector(testAlertClicked:)];
    testBtn.bezelStyle = NSBezelStyleRounded;
    testBtn.controlSize = NSControlSizeSmall;
    testBtn.frame = NSMakeRect(306, 14, 56, 22);
    [root addSubview:testBtn];

    NSButton *quitBtn = [NSButton buttonWithTitle:@"退出" target:self action:@selector(quitClicked:)];
    quitBtn.bezelStyle = NSBezelStyleRounded;
    quitBtn.controlSize = NSControlSizeSmall;
    quitBtn.frame = NSMakeRect(368, 14, 56, 22);
    [root addSubview:quitBtn];
}

- (void)updateWithThermal:(ThermalSnapshot *)thermal
                 suspects:(NSArray<AppSuspect *> *)suspects
              isAlertMode:(BOOL)isAlertMode
              sensitivity:(FanSensitivity)sensitivity {
    [self.sensitivityPopup selectItemAtIndex:sensitivity];

    if (isAlertMode) {
        self.bannerBox.layer.backgroundColor = [NSColor.systemRedColor colorWithAlphaComponent:0.18].CGColor;
        self.bannerBox.layer.borderColor = [NSColor.systemRedColor colorWithAlphaComponent:0.35].CGColor;
        self.bannerBox.layer.borderWidth = 1.0;
        self.bannerTitleLabel.textColor = NSColor.systemRedColor;
        self.bannerTitleLabel.stringValue = (thermal.maxRPM >= 2000)
            ? @"检测到风扇高速运转，已定位高负载源头"
            : @"检测到芯片温度异常升高，已定位高负载源头";
    } else if (thermal.maxRPM >= 2000 || thermal.maxSocTempC >= 75.0) {
        self.bannerBox.layer.backgroundColor = [NSColor.systemOrangeColor colorWithAlphaComponent:0.16].CGColor;
        self.bannerBox.layer.borderColor = [NSColor.systemOrangeColor colorWithAlphaComponent:0.32].CGColor;
        self.bannerBox.layer.borderWidth = 1.0;
        self.bannerTitleLabel.textColor = NSColor.systemOrangeColor;
        self.bannerTitleLabel.stringValue = (thermal.maxRPM >= 2000) ? @"风扇正在运转" : @"设备温度略高";
    } else {
        self.bannerBox.layer.backgroundColor = [NSColor.systemGreenColor colorWithAlphaComponent:0.14].CGColor;
        self.bannerBox.layer.borderColor = [NSColor.systemGreenColor colorWithAlphaComponent:0.28].CGColor;
        self.bannerBox.layer.borderWidth = 1.0;
        self.bannerTitleLabel.textColor = NSColor.labelColor;
        self.bannerTitleLabel.stringValue = @"风扇静默 / 温度正常";
    }

    if (thermal.tempAvailable) {
        self.tempBadgeLabel.stringValue = [NSString stringWithFormat:@"%.0f°C (峰值 %.0f°C)",
                                           thermal.socTempC, thermal.maxSocTempC];
        if (thermal.maxSocTempC >= 85.0) {
            self.tempBadgeLabel.textColor = NSColor.systemRedColor;
        } else if (thermal.maxSocTempC >= 70.0) {
            self.tempBadgeLabel.textColor = NSColor.systemOrangeColor;
        } else {
            self.tempBadgeLabel.textColor = NSColor.systemGreenColor;
        }
    } else {
        self.tempBadgeLabel.stringValue = @"温度不可用";
        self.tempBadgeLabel.textColor = NSColor.tertiaryLabelColor;
    }

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (thermal.smcAvailable && thermal.fans.count > 0) {
        for (FanInfo *f in thermal.fans) {
            [parts addObject:[NSString stringWithFormat:@"风扇%ld: %.0f RPM", (long)(f.index + 1), f.currentRPM]];
        }
    }
    if (thermal.batteryTempC > 0) {
        [parts addObject:[NSString stringWithFormat:@"电池: %.0f°C", thermal.batteryTempC]];
    }
    [parts addObject:[NSString stringWithFormat:@"热状态: %@", thermal.thermalStateText]];
    self.fanSummaryLabel.stringValue = [parts componentsJoinedByString:@"  ·  "];

    for (NSView *sub in [self.listContainer.subviews copy]) {
        [sub removeFromSuperview];
    }

    NSInteger count = MIN((NSInteger)suspects.count, 4);
    CGFloat rowHeight = 48.0;
    CGFloat gap = 8.0;
    CGFloat topY = self.listContainer.bounds.size.height - rowHeight;

    __weak typeof(self) weakSelf = self;
    BOOL hoveredStillPresent = NO;
    for (NSInteger i = 0; i < count; i++) {
        AppSuspect *s = suspects[i];
        NSRect rowFrame = NSMakeRect(0, topY - i * (rowHeight + gap), self.listContainer.bounds.size.width, rowHeight);
        SuspectRowView *row = [[SuspectRowView alloc] initWithSuspect:s
                                                                frame:rowFrame
                                                          onTerminate:^(AppSuspect *target, BOOL force) {
            [weakSelf.delegate alertPanelDidRequestTerminateSuspect:target force:force];
        } onSnooze:^(AppSuspect *target) {
            [weakSelf.delegate alertPanelDidRequestSnoozeSuspect:target minutes:30];
        } onReveal:^(AppSuspect *target) {
            [weakSelf.delegate alertPanelDidRequestRevealSuspect:target];
        } onHoverChanged:^(AppSuspect *target, SuspectRowView *hoveredRow, BOOL entered) {
            if (entered) {
                [weakSelf showHoverForSuspect:target row:hoveredRow];
            } else {
                [weakSelf scheduleHideHoverForGroupKey:target.groupKey];
            }
        }];
        [self.listContainer addSubview:row];

        if (self.hoveredGroupKey && [s.groupKey isEqualToString:self.hoveredGroupKey]) {
            hoveredStillPresent = YES;
            [self showHoverForSuspect:s row:row];
        }
    }
    if (!hoveredStillPresent && self.hoverPanel.isVisible) {
        self.hoveredGroupKey = nil;
        [self.hoverPanel orderOut:nil];
    }
}

- (void)showPanelAndActivate:(BOOL)activate {
    if (activate) {
        [NSApp activateIgnoringOtherApps:YES];
    }
    [self.window makeKeyAndOrderFront:nil];
}

- (void)sensitivityChanged:(NSPopUpButton *)sender {
    [self.delegate alertPanelDidChangeSensitivity:(FanSensitivity)sender.indexOfSelectedItem];
}

- (void)testAlertClicked:(id)sender {
    [self.delegate alertPanelDidRequestTestAlert];
}

- (void)quitClicked:(id)sender {
    [self.delegate alertPanelDidRequestQuit];
}

@end
