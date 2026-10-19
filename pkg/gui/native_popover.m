#import "native_internal.h"
#import <malloc/malloc.h>

// One AppKit surface: the battery overview and a deeper, sortable System page.
// All frames are points (not image pixels); text never sits on a power ribbon.
static NSTextField *Label(NSView *parent, NSRect frame, NSString *text,
                         CGFloat size, BOOL prominent) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.frame = frame;
    label.font = [NSFont systemFontOfSize:size weight:prominent ?
        NSFontWeightSemibold : NSFontWeightRegular];
    label.textColor = prominent ? NSColor.labelColor : NSColor.secondaryLabelColor;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [parent addSubview:label];
    return label;
}

static const CGFloat WattFullPopoverHeight = 532;
static const CGFloat WattBatteryPopoverHeight = 532 - 142;

@interface WattButton : NSButton
@property(nonatomic, assign) BOOL selected;
@property(nonatomic, assign) BOOL plain;
@property(nonatomic, assign) BOOL onGlass; // sits on an NSGlassEffectView in the Glass theme
@property(nonatomic, assign) BOOL grouped;
@property(nonatomic, assign) BOOL tab;
@property(nonatomic, copy) NSString *subtitle;
// Trailing chevron for buttons that open a menu instead of acting at once.
@property(nonatomic, assign) BOOL opensMenu;
@property(nonatomic, retain) NSColor *swatch;
@end
@implementation WattButton {
    NSTrackingArea *_tracking;
    BOOL _hover;
}
- (void)dealloc { [_tracking release]; [_subtitle release]; [_swatch release]; [super dealloc]; }
- (void)updateTrackingAreas {
    if (_tracking) [self removeTrackingArea:_tracking];
    [_tracking release];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
                NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
    [super updateTrackingAreas];
}
- (void)mouseEntered:(NSEvent *)event { (void)event; _hover = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)event { (void)event; _hover = NO; self.needsDisplay = YES; }
- (void)setSelected:(BOOL)value {
    _selected = value; self.state = value ? NSControlStateValueOn : NSControlStateValueOff;
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)rect {
    (void)rect;
    NSRect surface = NSInsetRect(self.bounds, 0.5, 0.5);
    BOOL glass = WattGlassTheme();
    // Glass uses capsules, concentric with the glass shapes behind the controls.
    CGFloat radius = glass || _grouped ? NSHeight(surface) / 2 : 10;
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:surface xRadius:radius yRadius:radius];
    BOOL bare = (_grouped || (glass && _onGlass)) && !_selected && !_hover && !self.highlighted;
    if ((!_plain || _hover || _selected) && !bare && (!_tab || _hover || self.highlighted)) {
        NSColor *color = _selected && _grouped ?
            [NSColor.whiteColor colorWithAlphaComponent:self.highlighted ? 0.22 : 0.14] :
            _selected ? (glass ? [WattAccentColor() colorWithAlphaComponent:0.85] :
            [WattAccentColor() blendedColorWithFraction:0.40 ofColor:NSColor.blackColor]) :
            [NSColor.whiteColor colorWithAlphaComponent:self.highlighted ? 0.14 :
                (_hover ? 0.10 : 0.045)];
        [color setFill]; [path fill];
    }
    if (_tab && _selected) {
        [NSColor.labelColor setFill];
        CGFloat indicatorY = self.isFlipped ? NSHeight(self.bounds)-3 : 1;
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(12, indicatorY, NSWidth(self.bounds)-24, 2)
            xRadius:1 yRadius:1] fill];
    }
    if (self.window.firstResponder == self) {
        [NSColor.keyboardFocusIndicatorColor setStroke]; path.lineWidth = 2; [path stroke];
    }
    NSColor *ink = !self.enabled ? NSColor.disabledControlTextColor :
        _grouped && !_selected ? NSColor.secondaryLabelColor : NSColor.labelColor;
    CGFloat iconWidth = self.image ? 17 : (_swatch ? 10 : 0);
    NSDictionary *style = @{NSFontAttributeName:self.font,
        NSForegroundColorAttributeName:ink};
    NSSize textSize = [self.title sizeWithAttributes:style];
    CGFloat start = (NSWidth(self.bounds) - textSize.width -
        (iconWidth > 0 && self.title.length > 0 ? iconWidth + 10 : iconWidth)) / 2;
    if (self.image) {
        NSSize intrinsic = self.image.size;
        CGFloat scale = MIN(17 / MAX(1, intrinsic.width), 19 / MAX(1, intrinsic.height));
        NSRect icon = NSMakeRect(start, (NSHeight(self.bounds) - intrinsic.height * scale)/2,
            intrinsic.width * scale, intrinsic.height * scale);
        NSImage *tinted = [[[NSImage alloc] initWithSize:self.image.size] autorelease];
        [tinted lockFocus];
        [self.image drawAtPoint:NSZeroPoint fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver fraction:1];
        [ink setFill]; NSRectFillUsingOperation(NSMakeRect(0,0,self.image.size.width,self.image.size.height),
            NSCompositingOperationSourceAtop);
        [tinted unlockFocus];
        [tinted drawInRect:icon fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver fraction:self.enabled ? 1 : 0.4
            respectFlipped:YES hints:nil];
        start += iconWidth + (self.title.length ? 10 : 0);
    } else if (_swatch) {
        // A palette pill shows its color, not just its name.
        NSRect dot = NSMakeRect(start, (NSHeight(self.bounds)-10)/2, 10, 10);
        [_swatch setFill]; [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
        start += iconWidth + 8;
    }
    CGFloat titleOffset = _subtitle.length ? (self.isFlipped ? -7 : 7) : 0;
    [self.title drawAtPoint:NSMakePoint(start, (NSHeight(self.bounds)-textSize.height)/2 + titleOffset)
        withAttributes:style];
    if (_opensMenu) {
        NSImage *chevron = [NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:nil];
        chevron = [chevron imageWithSymbolConfiguration:
            [NSImageSymbolConfiguration configurationWithPointSize:9 weight:NSFontWeightSemibold]];
        NSSize size = chevron.size;
        NSImage *tinted = [[[NSImage alloc] initWithSize:size] autorelease];
        [tinted lockFocus];
        [chevron drawAtPoint:NSZeroPoint fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        [NSColor.secondaryLabelColor setFill];
        NSRectFillUsingOperation(NSMakeRect(0,0,size.width,size.height), NSCompositingOperationSourceAtop);
        [tinted unlockFocus];
        [tinted drawInRect:NSMakeRect(NSWidth(self.bounds)-14-size.width,(NSHeight(self.bounds)-size.height)/2,size.width,size.height)
            fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    }
    if (_subtitle.length) {
        NSDictionary *secondary = @{NSFontAttributeName:[NSFont systemFontOfSize:10.5],
            NSForegroundColorAttributeName:NSColor.secondaryLabelColor};
        NSSize size = [_subtitle sizeWithAttributes:secondary];
        CGFloat subtitleY = self.isFlipped ? NSHeight(self.bounds)-5-size.height : 5;
        [_subtitle drawAtPoint:NSMakePoint((NSWidth(self.bounds)-size.width)/2,subtitleY) withAttributes:secondary];
    }
}
@end

static NSColor *WattPaletteSwatch(NSString *name) {
    // Same values as WattAccentColor, so the dot previews the real accent.
    NSDictionary *colors = @{@"Blue":NSColor.systemBlueColor,
        @"Mint":[NSColor colorWithCalibratedRed:0.20 green:0.78 blue:0.64 alpha:1],
        @"Violet":[NSColor colorWithCalibratedRed:0.64 green:0.46 blue:0.96 alpha:1],
        @"Amber":[NSColor colorWithCalibratedRed:0.94 green:0.63 blue:0.23 alpha:1]};
    return colors[name] ?: [NSColor.whiteColor colorWithAlphaComponent:0.55]; // Glass
}

static WattButton *Button(NSView *parent, NSRect frame, NSString *title,
                          NSString *symbol, id target, SEL action) {
    WattButton *button = [[[WattButton alloc] initWithFrame:frame] autorelease];
    button.title = title; button.target = target; button.action = action;
    button.bordered = NO;
    button.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    if (symbol.length) button.image = [NSImage imageWithSystemSymbolName:symbol
        accessibilityDescription:nil];
    button.imagePosition = NSImageLeft;
    button.accessibilityLabel = title.length ? title : @"Settings";
    [parent addSubview:button];
    return button;
}

NSString *WattCompactBytes(double bytes, BOOL binary) {
    if (!isfinite(bytes) || bytes < 0) return @"—";
    NSArray *units = @[@"B",@"KB",@"MB",@"GB",@"TB",@"PB",@"EB"];
    double base = binary ? 1024 : 1000;
    NSInteger unit = 0;
    while (bytes >= base && unit < units.count-1) { bytes /= base; unit++; }
    double rounded = round(bytes*10)/10;
    if (rounded >= base && unit < units.count-1) { rounded /= base; unit++; }
    return [NSString stringWithFormat:rounded == floor(rounded) ? @"%.0f %@" : @"%.1f %@",
        rounded,units[unit]];
}

@interface WattAppRow : NSView
@property(nonatomic, retain) NSDictionary *sample;
@property(nonatomic, assign) BattMenuController *controller;
- (void)update:(NSDictionary *)sample metric:(NSInteger)metric;
@end

@interface WattLimitLabel : NSTextField
@end
@implementation WattLimitLabel
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
@end
@implementation WattAppRow {
    NSTrackingArea *_rowTracking;
    NSImageView *_icon;
    NSTextField *_name, *_amount, *_relative;
    WattButton *_quit;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _icon = [[[NSImageView alloc] initWithFrame:NSMakeRect(0, 4, 26, 26)] autorelease];
        _icon.imageScaling = NSImageScaleProportionallyUpOrDown;
        [self addSubview:_icon];
        _name = Label(self, NSMakeRect(36, 8, 143, 19), @"Sampling…", 13, YES);
        _name.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        _amount = Label(self, NSMakeRect(180, 17, 172, 15), @"", 11.5, NO);
        _amount.textColor = NSColor.labelColor;
        _amount.alignment = NSTextAlignmentRight;
        _amount.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
        _relative = Label(self, NSMakeRect(180, 2, 172, 14), @"", 10.5, NO);
        _relative.alignment = NSTextAlignmentRight;
        _relative.font = [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightRegular];
        _quit = Button(self, NSMakeRect(306, 4, 46, 27), @"Quit", @"", self, @selector(quit:));
        _quit.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        _quit.plain = YES;
        _quit.toolTip = @"Request a normal Quit after confirmation";
        _quit.alphaValue = 0;
    }
    return self;
}
- (void)dealloc { [_rowTracking release]; [_sample release]; [super dealloc]; }
- (void)updateTrackingAreas {
    if (_rowTracking) [self removeTrackingArea:_rowTracking];
    [_rowTracking release];
    _rowTracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:_rowTracking];
    [super updateTrackingAreas];
}
// Quit is a destructive-ish action; show it for the row under the pointer
// instead of repeating it on every line.
- (void)setHover:(BOOL)hover {
    if (_quit.hidden) return;
    CGFloat width = hover ? 112 : 172;
    for (NSTextField *field in @[_amount,_relative]) {
        NSRect frame = field.frame; frame.size.width = width; field.animator.frame = frame;
    }
    _quit.animator.alphaValue = hover ? 1 : 0;
}
- (void)mouseEntered:(NSEvent *)event { (void)event; [self setHover:YES]; }
- (void)mouseExited:(NSEvent *)event { (void)event; [self setHover:NO]; }
- (void)update:(NSDictionary *)sample metric:(NSInteger)metric {
    BOOL changed = ![sample[@"path"] isEqual:self.sample[@"path"]];
    self.sample = sample;
    self.hidden = sample == nil;
    if (!sample) return;
    if (changed) _icon.image = [sample[@"path"] length] ?
        [NSWorkspace.sharedWorkspace iconForFile:sample[@"path"]] :
        [NSImage imageWithSystemSymbolName:@"gearshape.2" accessibilityDescription:@"Background process"];
    _quit.hidden = sample[@"canQuit"] && ![sample[@"canQuit"] boolValue];
    _name.stringValue = sample[@"name"] ?: @"Application";
    _name.toolTip = _name.stringValue;
    BOOL diskValid = sample[@"disk"] && [sample[@"disk"] doubleValue] >= 0;
    _amount.stringValue = metric == 2 ? (diskValid ?
        [NSString stringWithFormat:@"Read %@/s",WattCompactBytes([sample[@"diskRead"] doubleValue],NO)] : @"—") :
        metric == 1 ? WattCompactBytes([sample[@"memory"] doubleValue],YES) :
        WattCPUUsageLabel([sample[@"cpu"] doubleValue],NSProcessInfo.processInfo.processorCount);
    uint64_t physical = NSProcessInfo.processInfo.physicalMemory;
    _relative.stringValue = metric == 2 ? (diskValid ?
        [NSString stringWithFormat:@"Write %@/s",WattCompactBytes([sample[@"diskWrite"] doubleValue],NO)] : @"Sampling…") :
        metric == 1 ? (physical ? [NSString stringWithFormat:@"%.1f%% RAM",
            100*[sample[@"memory"] doubleValue]/physical] : @"—") : @"";
    // CPU has one value; center it instead of leaving an empty second line.
    NSRect amountFrame = _amount.frame;
    amountFrame.origin.y = metric == 0 ? 9.5 : 17;
    _amount.frame = amountFrame;
    _amount.toolTip = metric == 2 ? @"Read/write throughput; includes helpers, all volumes. Not disk utilization percent." :
        metric == 1 ? @"Resident memory, including helper processes" :
        @"Percentage of total CPU capacity, on the same scale as CPU load; helpers included";
    _relative.toolTip = _amount.toolTip;
    for (NSTextField *field in @[_amount,_relative]) {
        CGFloat size = field == _amount ? 11 : 10.5;
        field.font = [NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightRegular];
        while ([field.stringValue sizeWithAttributes:@{NSFontAttributeName:field.font}].width > field.frame.size.width && size > 8) {
            size -= 0.5;
            field.font = [NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightRegular];
        }
    }
    _quit.accessibilityLabel = [@"Quit " stringByAppendingString:_name.stringValue];
}
- (void)quit:(id)sender {
    (void)sender;
    if (!self.sample) return;
    NSMenuItem *request = [[[NSMenuItem alloc] initWithTitle:@"Quit"
        action:nil keyEquivalent:@""] autorelease];
    request.representedObject = self.sample;
    [self.controller quitDiagnosedApp:request];
    [self.controller updateAppStats];
    [self.controller refreshPopoverControls];
}
@end

@interface WattStorageBar : NSView
@property(nonatomic, assign) double fraction;
@end
@implementation WattStorageBar
- (void)drawRect:(NSRect)rect {
    (void)rect;
    [[NSColor.whiteColor colorWithAlphaComponent:0.13] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:3 yRadius:3] fill];
    if (self.fraction >= 0 && isfinite(self.fraction)) {
        NSRect fill = self.bounds; fill.size.width *= MAX(0,MIN(1,self.fraction));
        [WattAccentColor() setFill];
        [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:3 yRadius:3] fill];
    }
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityProgressIndicatorRole; }
- (NSString *)accessibilityLabel { return @"SSD space used"; }
- (id)accessibilityValue { return self.fraction < 0 ? nil : @(self.fraction*100); }
@end

// Public macOS 26 properties; runtime lookup keeps older SDK builds compatible.
@protocol WattGlassContainerAPI
@property(nonatomic, retain) NSView *contentView;
@end
@protocol WattGlassEffectAPI
@property(nonatomic) CGFloat cornerRadius;
@end
@interface WattDashboard : NSView
@property(nonatomic, assign) BattMenuController *controller;
- (void)refreshCPU:(double)cpu memory:(double)memory;
@end
@implementation WattDashboard {
    NSView *_batteryPage, *_systemPage, *_settingsPage, *_historyPage, *_storagePage;
    WattHistoryView *_historyChart;
    NSButton *_monitoringCheck, *_historyCheck;
    NSTextField *_pressure, *_heatNotice;
    WattButton *_batteryTab, *_systemTab, *_storageTab, *_cpuSort, *_memorySort, *_diskSort;
    NSMutableArray *_summary, *_details, *_detailCaptions, *_rows, *_paletteButtons, *_metricChecks, *_glassViews;
    NSTextField *_processCount, *_swap, *_availableSpace, *_footer, *_empty, *_limitLabel;
    BOOL _system, _settings, _history, _storage;
    NSInteger _sortMetric;
    double _cpu, _memory;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _summary = [[NSMutableArray alloc] init]; _details = [[NSMutableArray alloc] init];
        _detailCaptions = [[NSMutableArray alloc] init];
        _rows = [[NSMutableArray alloc] init];
        _paletteButtons = [[NSMutableArray alloc] init]; _metricChecks = [[NSMutableArray alloc] init];
        _glassViews = [[NSMutableArray alloc] init];
    }
    return self;
}
- (void)dealloc {
    [_summary release]; [_details release]; [_rows release];
    [_detailCaptions release];
    [_paletteButtons release]; [_metricChecks release]; [_glassViews release];
    [super dealloc];
}
- (void)drawRect:(NSRect)rect {
    (void)rect;
    // Glass: no backdrop, so the popover's own Liquid Glass stays visible.
    if (WattGlassTheme()) return;
    NSGradient *surface = [[[NSGradient alloc] initWithStartingColor:WattSurfaceColor(YES)
        endingColor:WattSurfaceColor(NO)] autorelease];
    [surface drawInRect:self.bounds angle:90];
}
// Puts system Liquid Glass shapes behind the given controls, grouped in one
// container as Apple recommends. They only show in the Glass theme.
- (void)glass:(NSArray *)rects behind:(NSArray *)buttons in:(NSView *)parent {
    if (WattGlassAvailable()) {
        NSRect bounds = NSZeroRect;
        for (NSValue *rect in rects) bounds = NSUnionRect(bounds, rect.rectValue);
        NSView<WattGlassContainerAPI> *container =
            [[[NSClassFromString(@"NSGlassEffectContainerView") alloc] initWithFrame:bounds] autorelease];
        NSView *content = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(bounds), NSHeight(bounds))] autorelease];
        container.contentView = content;
        for (NSValue *value in rects) {
            NSRect rect = NSOffsetRect(value.rectValue, -NSMinX(bounds), -NSMinY(bounds));
            NSView<WattGlassEffectAPI> *glass = [[[NSClassFromString(@"NSGlassEffectView") alloc] initWithFrame:rect] autorelease];
            glass.cornerRadius = NSHeight(rect) / 2;
            [content addSubview:glass];
        }
        container.autoresizingMask = NSViewMinYMargin;
        [parent addSubview:container positioned:NSWindowBelow relativeTo:buttons.firstObject];
        [_glassViews addObject:container];
        for (WattButton *button in buttons) button.onGlass = YES;
    }
}
static void Redisplay(NSView *view) {
    view.needsDisplay = YES;
    for (NSView *subview in view.subviews) Redisplay(subview);
}
- (void)clearGlass {
    for (NSView *view in _glassViews) [view removeFromSuperview];
    [_glassViews removeAllObjects];
    for (WattButton *button in @[_batteryTab, _systemTab, _storageTab,
            self.controller.heatButton, self.controller.darkButton]) button.onGlass = NO;
}
- (void)applyTheme {
    if (WattGlassTheme() && !_glassViews.count) {
        [self glass:@[[NSValue valueWithRect:NSMakeRect(20, 446, 360, 36)]]
            behind:@[_batteryTab, _systemTab, _storageTab] in:self];
        NSMutableArray *buttons = [NSMutableArray array];
        NSMutableArray *rects = [NSMutableArray array];
        for (NSButton *button in @[self.controller.heatButton,self.controller.darkButton]) {
            if (button.hidden) continue;
            [buttons addObject:button]; [rects addObject:[NSValue valueWithRect:button.frame]];
        }
        [self glass:rects behind:buttons in:_batteryPage];
    } else if (!WattGlassTheme()) {
        [self clearGlass];
    }
    Redisplay(self);
}
- (void)line:(NSView *)parent y:(CGFloat)y {
    NSBox *line = [[[NSBox alloc] initWithFrame:NSMakeRect(24, y, 352, 1)] autorelease];
    line.boxType = NSBoxSeparator; [parent addSubview:line];
    line.alphaValue = 0.45;
}
- (void)build {
    Label(self, NSMakeRect(24, 498, 230, 20), @"WattNook", 13, YES);
    WattButton *settings = Button(self, NSMakeRect(348, 490, 28, 32), @"", @"gearshape",
        self, @selector(settings:)); settings.plain = YES;
    _batteryTab = Button(self, NSMakeRect(24, 450, 112, 28), @"Battery", @"battery.100percent",
        self, @selector(battery:));
    _systemTab = Button(self, NSMakeRect(144, 450, 112, 28), @"System", @"chart.bar.fill",
        self, @selector(system:)); _batteryTab.selected = YES;
    _storageTab = Button(self, NSMakeRect(264,450,112,28), @"Storage", @"internaldrive", self, @selector(storage:));
    _batteryTab.grouped = _systemTab.grouped = _storageTab.grouped = YES;
    _batteryTab.toolTip = @"Battery  ⌘1"; _systemTab.toolTip = @"System  ⌘2"; _storageTab.toolTip = @"Storage  ⌘3";
    settings.toolTip = @"Settings  ⌘,";
    // A filled selection identifies the page; underlines are reserved for sorting.
    _batteryTab.tab = _systemTab.tab = _storageTab.tab = NO;
    _batteryPage = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 450)] autorelease];
    _systemPage = [[[NSView alloc] initWithFrame:_batteryPage.frame] autorelease];
    [self addSubview:_batteryPage]; [self addSubview:_systemPage]; _systemPage.hidden = YES;
    _settingsPage = [[[NSView alloc] initWithFrame:_batteryPage.frame] autorelease];
    [self addSubview:_settingsPage]; _settingsPage.hidden = YES;
    _historyPage = [[[NSView alloc] initWithFrame:_batteryPage.frame] autorelease];
    [self addSubview:_historyPage]; _historyPage.hidden = YES;
    BattMenuController *c = self.controller;
    _storagePage = WattCreateStorageReview(c);
    [self addSubview:_storagePage]; _storagePage.hidden = YES;
    c.powerFlowView.frame = NSMakeRect(0, 214, 400, 220);
    c.powerFlowView.limitTarget = c; c.powerFlowView.limitAction = @selector(commitLimitFromRail:);
    [_batteryPage addSubview:c.powerFlowView];
    _limitLabel = [[[WattLimitLabel alloc] initWithFrame:NSMakeRect(24,322,240,18)] autorelease];
    _limitLabel.editable = NO; _limitLabel.selectable = NO; _limitLabel.bezeled = NO;
    _limitLabel.drawsBackground = NO; _limitLabel.textColor = [NSColor.whiteColor colorWithAlphaComponent:0.7];
    _limitLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    [_batteryPage addSubview:_limitLabel];
    c.heatButton = Button(_batteryPage, NSMakeRect(24, 158, 172, 44),
        @"Heat protection", @"", c, @selector(showHeatOptions:));
    c.darkButton = Button(_batteryPage, NSMakeRect(204, 158, 172, 44),
        @"Keep Awake", @"", c, @selector(toggleKeepAwakeFromPopover:));
    c.heatButton.font = c.darkButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    ((WattButton *)c.heatButton).opensMenu = YES;
    // Battery ends at its controls; System and Storage are one tab away and
    // are no longer echoed here. Summary values stay detached for the menu.
    for (NSInteger i = 0; i < 3; i++) {
        CGFloat column = 24+i*122;
        WattButton *metric = Button(nil, NSMakeRect(column, 94, 108, 24),
            @"—", @"", self, @selector(metric:));
        metric.plain = YES; metric.tag = i;
        metric.font = [NSFont monospacedDigitSystemFontOfSize:16 weight:NSFontWeightSemibold];
        [_summary addObject:metric];
        WattButton *detail = Button(_systemPage, NSMakeRect(column, 358, 108, 36),
            @"—", @"", self, @selector(units:));
        detail.plain = YES; detail.tag = i;
        detail.font = [NSFont monospacedDigitSystemFontOfSize:22 weight:NSFontWeightSemibold];
        [_details addObject:detail];
        NSTextField *detailCaption = Label(_systemPage, NSMakeRect(column, 398, 108, 16),
            @[@"CPU load", @"Memory used", @"Disk MB/s"][i], 11, NO);
        detailCaption.alignment = NSTextAlignmentCenter;
        [_detailCaptions addObject:detailCaption];
        detail.toolTip = @"Change units";
    }
    _swap = Label(_systemPage, NSMakeRect(146,334,108,20), @"Swap —", 12, NO);
    _pressure = Label(_systemPage,NSMakeRect(24,419,260,18),@"Memory pressure: —",11,NO);
    _pressure.toolTip = @"macOS memory pressure, separate from the percentage of RAM used";
    WattButton *history = Button(_systemPage,NSMakeRect(307,415,80,25),@"History ›",@"",self,@selector(history:));
    history.plain = YES;
    _swap.toolTip = @"Current system swap used, not swap-file capacity or RAM usage";
    _processCount = Label(_systemPage, NSMakeRect(24,334,108,20), @"", 12, NO);
    _processCount.toolTip = @"Processes accessible to this monitor; app helpers are grouped in the list";
    _availableSpace = Label(_systemPage, NSMakeRect(268,334,108,20), @"Free —", 12, NO);
    for (NSTextField *context in @[_processCount,_swap,_availableSpace])
        context.alignment = NSTextAlignmentCenter;
    _availableSpace.toolTip = @"Free storage space on the startup volume";
    [self line:_systemPage y:332];
    Label(_systemPage,NSMakeRect(24,306,180,20),@"Top consumers",13,YES);
    _cpuSort = Button(_systemPage, NSMakeRect(24,270,112,30), @"CPU", @"", self, @selector(sort:));
    _memorySort = Button(_systemPage, NSMakeRect(144,270,112,30), @"Memory", @"", self, @selector(sort:));
    _diskSort = Button(_systemPage,NSMakeRect(264,270,112,30),@"Disk",@"",self,@selector(sort:));
    for (WattButton *sort in @[_cpuSort,_memorySort,_diskSort])
        sort.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    _diskSort.tag = 2;
    _cpuSort.tag = 0; _cpuSort.selected = YES; _memorySort.tag = 1;
    _cpuSort.grouped = _memorySort.grouped = _diskSort.grouped = YES;
    _cpuSort.tab = _memorySort.tab = _diskSort.tab = NO;
    for (NSInteger i = 0; i < 6; i++) {
        WattAppRow *row = [[[WattAppRow alloc] initWithFrame:NSMakeRect(24, 226-i*34, 352, 34)] autorelease];
        [_systemPage addSubview:row]; row.controller = c; [_rows addObject:row];
    }
    _empty = Label(_systemPage, NSMakeRect(24, 181, 352, 32), @"Collecting app samples…", 12, NO);
    WattButton *activity = Button(_systemPage, NSMakeRect(24, 14, 352, 28),
        @"Open Activity Monitor ↗", @"waveform.path.ecg", self, @selector(activity:)); activity.plain = YES;
    _footer = Label(_systemPage, NSMakeRect(24, 4, 352, 16), @"", 10, NO);
    _footer.alignment = NSTextAlignmentCenter;
    WattButton *back = Button(_historyPage,NSMakeRect(14,408,100,30),@"System",@"chevron.left",self,@selector(system:)); back.plain = YES;
    NSTextField *window = Label(_historyPage,NSMakeRect(226,414,150,18),@"Last 15 minutes",11,NO);
    window.alignment = NSTextAlignmentRight;
    _historyChart = [[[WattHistoryView alloc] initWithFrame:NSMakeRect(24,40,352,360)] autorelease];
    [_historyPage addSubview:_historyChart];
    Label(_historyPage,NSMakeRect(24,12,352,18),@"10-second samples · kept in memory only",11,NO);
    Label(_settingsPage,NSMakeRect(24,410,352,20),@"Appearance",13,YES);
    Label(_settingsPage,NSMakeRect(24,382,352,18),@"Palette",12,NO);
    NSArray *palettes = @[@"Blue",@"Mint",@"Violet",@"Amber",@"Glass"];
    for (NSInteger i=0;i<palettes.count;i++) {
        WattButton *palette = Button(_settingsPage,NSMakeRect(24+i*72,344,64,30),
            palettes[i],@"",self,@selector(palette:));
        palette.tag = i; palette.grouped = YES; [_paletteButtons addObject:palette];
        palette.swatch = WattPaletteSwatch(palettes[i]);
        palette.hidden = [palettes[i] isEqual:@"Glass"] && !WattGlassAvailable();
    }
    [self line:_settingsPage y:326];
    Label(_settingsPage,NSMakeRect(24,296,352,20),@"Menu bar",13,YES);
    NSArray *titles = @[@"CPU load",@"Memory used",@"SSD used",@"Battery percentage",@"Battery icon"];
    for (NSInteger i=0;i<titles.count;i++) {
        NSButton *check = [NSButton checkboxWithTitle:titles[i] target:self action:@selector(menuMetric:)];
        check.frame = NSMakeRect(24+(i%2)*184,260-(i/2)*28,168,24); check.tag = i;
        check.font = [NSFont systemFontOfSize:12];
        [_settingsPage addSubview:check]; [_metricChecks addObject:check];
    }
    [self line:_settingsPage y:188];
    Label(_settingsPage,NSMakeRect(24,158,352,20),@"Monitoring",13,YES);
    _monitoringCheck = [NSButton checkboxWithTitle:@"System monitoring" target:self action:@selector(monitoring:)];
    _monitoringCheck.frame = NSMakeRect(24,128,352,24); [_settingsPage addSubview:_monitoringCheck];
    _monitoringCheck.toolTip = @"Off stops CPU, memory, disk and process sampling and clears history. Battery controls remain available.";
    _historyCheck = [NSButton checkboxWithTitle:@"Keep 15-minute history" target:self action:@selector(monitoring:)];
    _historyCheck.frame = NSMakeRect(24,100,352,24); [_settingsPage addSubview:_historyCheck];
    _historyCheck.toolTip = @"90 samples in memory. Off releases the history buffer; nothing is written to disk.";
    _heatNotice = Label(_settingsPage,NSMakeRect(24,80,352,16),
        @"Heat protection unavailable on this Mac",10.5,NO);
    _heatNotice.hidden = YES;
    _heatNotice.toolTip = @"This Mac exposes no charge-only control WattNook can use while staying on adapter power.";
    WattButton *awakeDetails = Button(_settingsPage,NSMakeRect(24,48,352,30),@"Keep Awake details…",@"moon.zzz",
        c,@selector(showKeepAwakeDiagnostics:));
    awakeDetails.toolTip = @"Sleep prevention, closed-lid display and apps keeping your Mac awake";
    Button(_settingsPage,NSMakeRect(24,12,352,30),@"Advanced controls…",@"slider.horizontal.3",
        c,@selector(showMoreMenu:));
    // Pin everything to the top edge so the popover can be shorter on Battery.
    for (NSView *view in self.subviews) view.autoresizingMask = NSViewMinYMargin;
    [self applyTheme];
}
- (void)battery:(id)sender { (void)sender; _system = NO; _storage = NO; _settings = NO; _history = NO; [self selectPage]; }
- (void)system:(id)sender { (void)sender; _system = YES; _storage = NO; _settings = NO; _history = NO; [self selectPage]; }
- (void)storage:(id)sender { (void)sender; _system = NO; _storage = YES; _settings = NO; _history = NO; [self selectPage]; }
- (void)history:(id)sender { (void)sender; _system = YES; _storage = NO; _settings = NO; _history = YES; [self selectPage]; }
- (void)monitoring:(id)sender {
    (void)sender;
    [NSUserDefaults.standardUserDefaults setBool:_monitoringCheck.state == NSControlStateValueOn forKey:@"WattNookMonitoringEnabled"];
    [NSUserDefaults.standardUserDefaults setBool:_historyCheck.state == NSControlStateValueOn forKey:@"WattNookHistoryEnabled"];
    [self.controller applyMonitoringPreferences];
}
- (void)settings:(id)sender { (void)sender; _settings = !_settings; [self selectPage]; }
// ⌘1/⌘2/⌘3 switch tabs and ⌘, toggles Settings while the popover has focus.
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if ((event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) != NSEventModifierFlagCommand)
        return [super performKeyEquivalent:event];
    NSString *key = event.charactersIgnoringModifiers;
    if ([key isEqual:@"1"]) { [self battery:nil]; return YES; }
    if ([key isEqual:@"2"]) { [self system:nil]; return YES; }
    if ([key isEqual:@"3"]) { [self storage:nil]; return YES; }
    if ([key isEqual:@","]) { [self settings:nil]; return YES; }
    return [super performKeyEquivalent:event];
}
- (void)palette:(NSButton *)sender {
    [NSUserDefaults.standardUserDefaults setObject:@[@"Blue",@"Mint",@"Violet",@"Amber",@"Glass"][sender.tag]
        forKey:@"WattNookPalette"];
    [self applyTheme];
    [self refreshCPU:_cpu memory:_memory]; [self setNeedsDisplay:YES];
    for (NSView *view in self.subviews) [view setNeedsDisplay:YES];
}
- (void)menuMetric:(NSButton *)sender {
    (void)sender;
    NSMutableArray *metrics = [NSMutableArray array];
    NSArray *names = @[@"CPU",@"RAM",@"SSD",@"Battery"];
    for (NSInteger i=0;i<4;i++)
        if (((NSButton *)_metricChecks[i]).state == NSControlStateValueOn) [metrics addObject:names[i]];
    BOOL icon = ((NSButton *)_metricChecks[4]).state == NSControlStateValueOn;
    if (metrics.count == 0 && !icon) icon = YES; // Keep a way back into the app.
    [NSUserDefaults.standardUserDefaults setObject:metrics forKey:@"WattNookMenuMetrics"];
    [NSUserDefaults.standardUserDefaults setBool:icon forKey:@"WattNookMenuBatteryIcon"];
    [self.controller refreshStatusImage]; [self refreshCPU:_cpu memory:_memory];
}
- (void)selectPage {
    BOOL wasShowingApps = self.controller.systemPageVisible;
    _batteryPage.hidden = _system || _storage || _settings; _systemPage.hidden = !_system || _settings || _history;
    _storagePage.hidden = !_storage || _settings;
    WattSetStorageReviewActive(self.controller,!_storagePage.hidden);
    _settingsPage.hidden = !_settings;
    _historyPage.hidden = !_system || _settings || !_history;
    self.controller.systemPageVisible = _system && !_settings && !_history;
    if (wasShowingApps && !self.controller.systemPageVisible) {
        self.controller.previousProcessCPU = nil; self.controller.previousProcessDisk = nil;
    }
    if (!wasShowingApps && self.controller.systemPageVisible && self.controller.popover.isShown)
        [self.controller updateAppStats];
    _batteryTab.selected = !_system && !_storage && !_settings; _systemTab.selected = _system && !_settings;
    _storageTab.selected = _storage && !_settings;
    self.controller.powerFlowView.flowAnimationEnabled = !_system && !_storage && !_settings && self.window.visible;
    // Battery stops at its action row (y 158 within a 450 pt page); trim the
    // unused band below it instead of leaving empty space.
    BOOL battery = !_system && !_storage && !_settings;
    NSSize size = NSMakeSize(400, battery ? WattBatteryPopoverHeight : WattFullPopoverHeight);
    if (!NSEqualSizes(self.frame.size, size)) {
        [self setFrameSize:size];
        self.controller.popover.contentSize = size;
    }
    [self refreshCPU:_cpu memory:_memory];
}
- (void)metric:(NSButton *)sender {
    if (sender.tag < 0 || sender.tag > 2) return;
    _sortMetric = sender.tag;
    [self system:sender];
}
- (void)units:(NSButton *)sender {
    if (sender.tag < 0 || sender.tag > 2) return;
    NSString *key = @[@"WattNookCPUUnits",@"WattNookMemoryUnits",@"WattNookDiskUnits"][sender.tag];
    NSInteger count = sender.tag == 2 ? 3 : 2;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setInteger:([defaults integerForKey:key]+1)%count forKey:key];
    [self refreshCPU:_cpu memory:_memory];
}
- (void)sort:(NSButton *)sender {
    if (sender.tag < 0 || sender.tag > 2) return;
    _sortMetric = sender.tag; [self refreshCPU:_cpu memory:_memory];
}
- (void)activity:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:
        @"/System/Applications/Utilities/Activity Monitor.app"]];
}
- (void)refreshCPU:(double)cpu memory:(double)memory {
    if (_sortMetric < 0 || _sortMetric > 2) _sortMetric = 0;
    _cpu = cpu; _memory = memory;
    BattMenuController *c = self.controller;
    BOOL monitoring = WattMonitoringEnabled();
    if (!monitoring) cpu = memory = -1;
    _monitoringCheck.state = monitoring ? NSControlStateValueOn : NSControlStateValueOff;
    _historyCheck.state = [NSUserDefaults.standardUserDefaults boolForKey:@"WattNookHistoryEnabled"] ? NSControlStateValueOn : NSControlStateValueOff;
    _historyCheck.enabled = monitoring;
    _historyChart.history = c.metricHistory;
    if (!_historyPage.hidden) _historyChart.needsDisplay = YES;
    NSString *pressure = WattMemoryPressureLabel(c.memoryPressure);
    _pressure.stringValue = monitoring ? [@"Memory pressure: " stringByAppendingString:pressure] : @"System monitoring is off";
    _pressure.hidden = monitoring && [pressure isEqual:@"Unavailable"];
    _pressure.textColor = monitoring && (c.memoryPressure == DISPATCH_MEMORYPRESSURE_WARN || c.memoryPressure == DISPATCH_MEMORYPRESSURE_CRITICAL) ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
    _pressure.toolTip = @"macOS memory pressure, separate from the percentage of RAM used";
    if (monitoring && c.memoryPressureSince > 0 && c.memoryPressure > DISPATCH_MEMORYPRESSURE_NORMAL)
        _pressure.toolTip = [NSString stringWithFormat:@"%@ for %.0f seconds. Inspect Memory consumers below.",WattMemoryPressureLabel(c.memoryPressure),MAX(0,NSDate.timeIntervalSinceReferenceDate-c.memoryPressureSince)];
    double io = c.diskReadRate < 0 || c.diskWriteRate < 0 ? -1 :
        (c.diskReadRate + c.diskWriteRate)/1000000;
    NSArray *values = @[cpu < 0 ? @"—" : [NSString stringWithFormat:@"%.0f%%",cpu],
        memory < 0 ? @"—" : [NSString stringWithFormat:@"%.0f%%",memory],
        io < 0 ? @"—" : [NSString stringWithFormat:io >= 100 ? @"%.0f" : @"%.1f",io]];
    for (NSInteger i = 0; i < 3; i++) {
        ((NSButton *)_summary[i]).title = values[i];
        NSInteger mode = [NSUserDefaults.standardUserDefaults integerForKey:
            @[@"WattNookCPUUnits",@"WattNookMemoryUnits",@"WattNookDiskUnits"][i]];
        NSString *value = values[i], *caption = @[@"CPU load",@"Memory used",@"Disk MB/s"][i];
        if (i == 0 && mode == 1) {
            value = cpu < 0 ? @"—" : [NSString stringWithFormat:@"%.2f",cpu*NSProcessInfo.processInfo.processorCount/100];
            caption = @"CPU cores";
        } else if (i == 1 && mode == 1) {
            value = memory < 0 ? @"—" : WattCompactBytes(memory*NSProcessInfo.processInfo.physicalMemory/100,YES);
        } else if (i == 2 && mode == 1) {
            value = c.diskSpacePercent < 0 ? @"—" : [NSString stringWithFormat:@"%.0f%%",c.diskSpacePercent];
            caption = @"SSD used";
        } else if (i == 2 && mode == 2) {
            value = c.diskTotalBytes == 0 ? @"—" : WattCompactBytes(c.diskTotalBytes-MIN(c.diskFreeBytes,c.diskTotalBytes),NO);
            caption = @"SSD used";
        } else if (i == 2) {
            value = io < 0 ? @"—" : [WattCompactBytes(io*1000000,NO) stringByAppendingString:@"/s"];
            caption = @"Disk activity";
        }
        NSButton *detail = _details[i]; detail.title = value;
        CGFloat size = 22;
        while ([value sizeWithAttributes:@{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightSemibold]}].width > detail.frame.size.width-6 && size > 12) size--;
        detail.font = [NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightSemibold];
        ((NSTextField *)_detailCaptions[i]).stringValue = caption;
        detail.accessibilityLabel = [NSString stringWithFormat:@"%@ %@; activate to change units",caption,value];
        ((NSButton *)_summary[i]).needsDisplay = YES; ((NSButton *)_details[i]).needsDisplay = YES;
        NSString *description = [NSString stringWithFormat:@"%@ %@",
            @[@"CPU load", @"Memory used", @"Disk throughput MB/s"][i], values[i]];
        ((NSButton *)_summary[i]).accessibilityLabel = description;
    }
    _swap.stringValue = [@"Swap " stringByAppendingString:WattCompactBytes(c.swapUsedBytes,YES)];
    double socTemperature = c.powerFlowView.processorTemperatureCelsius;
    _processCount.stringValue = socTemperature > 0 ? [NSString stringWithFormat:@"%.0f°C",socTemperature] : @"";
    _processCount.textColor = socTemperature >= 85 ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
    _processCount.toolTip = @"Hottest CPU/GPU die sensor";
    // Free space is Storage's job; throughput needs no second number here.
    _availableSpace.stringValue = @"";
    for (NSTextField *field in @[_processCount,_swap,_availableSpace]) {
        CGFloat size = 12;
        field.font = [NSFont systemFontOfSize:size];
        while ([field.stringValue sizeWithAttributes:@{NSFontAttributeName:field.font}].width > field.frame.size.width && size > 10) {
            size -= 0.5; field.font = [NSFont systemFontOfSize:size];
        }
    }
    _limitLabel.stringValue = c.powerFlowView.displayedLimitPercent < 0 ? @"Limit unavailable" :
        [NSString stringWithFormat:@"%@ %ld%%", c.powerFlowView.supportedLimits.count ? @"Charge limit" : @"Limit", (long)c.powerFlowView.displayedLimitPercent];
    c.heatButton.title = [c item:BattItemHeatProtection].hidden ? @"Heat unavailable" : @"Heat protection";
    ((WattButton *)c.heatButton).subtitle = [c item:BattItemHeatProtection].hidden ? @"Native limit only" : c.heatDetail ?: @"Checking…";
    c.heatButton.accessibilityLabel = [NSString stringWithFormat:@"%@. %@",c.heatButton.title,((WattButton *)c.heatButton).subtitle];
    ((WattButton *)c.darkButton).subtitle = c.keepAwakeStatus == nil ? @"Status unavailable" : @"Prevent system sleep";
    c.heatButton.toolTip = [c item:BattItemHeatProtection].title;
    BOOL awake = [c isKeepAwakeActive];
    BOOL awaitingStatus = c.keepAwakeTogglePending || (!c.keepAwakeStatus && c.keepAwakeStatusReading);
    c.darkButton.title = c.keepAwakeChanging ? @"Changing…" :
        awaitingStatus ? @"Checking…" :
        c.lidGuardError ? @"Keep Awake · Issue" : awake ? @"Keep Awake · On" : @"Keep Awake";
    c.darkButton.enabled = !c.keepAwakeChanging && !awaitingStatus;
    c.darkButton.toolTip = awaitingStatus ? @"Reading macOS sleep setting…" : c.keepAwakeError ?: c.lidGuardError ?: @"Prevents system sleep. Remote access still requires a working connection. Details are in Settings.";
    [c item:BattItemKeepAwake].enabled = c.darkButton.enabled;
    [c item:BattItemKeepAwake].title = c.keepAwakeStatus == nil ? @"Keep Awake: status unavailable" : awake ? @"Keep Awake: On — turn off" : @"Keep Awake: closed-lid work";
    c.darkButton.accessibilityLabel = c.darkButton.title;
    c.heatButton.enabled = ![c item:BattItemHeatProtection].hidden;
    BOOL heatUnavailable = !c.heatButton.enabled;
    NSRect awakeFrame = NSMakeRect(heatUnavailable ? 24 : 204,158,heatUnavailable ? 352 : 172,44);
    BOOL actionsChanged = c.heatButton.hidden != heatUnavailable || !NSEqualRects(c.darkButton.frame,awakeFrame);
    c.heatButton.hidden = heatUnavailable;
    c.darkButton.frame = awakeFrame;
    _heatNotice.hidden = !heatUnavailable;
    if (actionsChanged) { [self clearGlass]; [self applyTheme]; }
    c.powerFlowView.limitEditable = c.powerFlowView.limitPercent >= 0 && ![c item:BattItemQuickLimits].hidden && [c item:BattItemLimit80].enabled;
    _cpuSort.selected = _sortMetric == 0; _memorySort.selected = _sortMetric == 1;
    _diskSort.selected = _sortMetric == 2;
    NSArray *apps = [c.appStats sortedArrayUsingDescriptors:@[
        [NSSortDescriptor sortDescriptorWithKey:@[@"cpu",@"memory",@"disk"][_sortMetric] ascending:NO],
        [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES]]];
    for (NSInteger i = 0; i < _rows.count; i++)
        [(WattAppRow *)_rows[i] update:i < apps.count ? apps[i] : nil metric:_sortMetric];
    _empty.stringValue = monitoring ? @"Collecting app samples…" : @"Enable System monitoring in Settings.";
    _empty.hidden = apps.count > 0;
    _footer.stringValue = @"";
    _footer.hidden = YES; // Battery state lives on Battery.
    [c.powerFlowView setNeedsDisplay:YES];
    NSString *palette = [NSUserDefaults.standardUserDefaults stringForKey:@"WattNookPalette"] ?: @"Blue";
    for (WattButton *button in _paletteButtons) button.selected = [button.title isEqual:palette];
    NSArray *metrics = WattMenuMetrics();
    for (NSInteger i=0;i<4;i++) ((NSButton *)_metricChecks[i]).state =
        [metrics containsObject:@[@"CPU",@"RAM",@"SSD",@"Battery"][i]] ? NSControlStateValueOn : NSControlStateValueOff;
    ((NSButton *)_metricChecks[4]).state = WattMenuBatteryIcon() ? NSControlStateValueOn : NSControlStateValueOff;
    ((NSButton *)_metricChecks[2]).toolTip = @"SSD storage space used as a percentage; read/write activity is available in System";
}
@end

NSButton *WattActionButton(NSView *parent, NSRect frame, NSString *title, NSString *symbol, id target, SEL action) {
    return Button(parent, frame, title, symbol, target, action);
}
void WattSetButtonSelected(NSButton *button, BOOL selected) {
    if (![button isKindOfClass:WattButton.class]) return;
    ((WattButton *)button).selected = selected; [button setNeedsDisplay:YES];
}
void WattSetButtonGrouped(NSButton *button, BOOL grouped) {
    if ([button isKindOfClass:WattButton.class]) ((WattButton *)button).grouped = grouped;
}
void WattSetButtonPlain(NSButton *button, BOOL plain) {
    if ([button isKindOfClass:WattButton.class]) ((WattButton *)button).plain = plain;
}

void BattBuildPopover(BattMenuController *controller) {
    WattDashboard *content = [[[WattDashboard alloc] initWithFrame:NSMakeRect(0,0,400,532)] autorelease];
    content.controller = controller;
    content.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [content build];
    [content setFrameSize:NSMakeSize(400, WattBatteryPopoverHeight)]; // Battery opens first.
    NSViewController *viewController = [[[NSViewController alloc] init] autorelease];
    viewController.view = content;
    controller.popover = [[[NSPopover alloc] init] autorelease];
    controller.popover.behavior = NSPopoverBehaviorTransient;
    controller.popover.delegate = controller;
    controller.popover.contentSize = content.frame.size;
    controller.popover.contentViewController = viewController;
}
// NSPopover keeps its window and compositor buffers (tens of MB with Glass)
// alive after closing. A fresh popover around the same content frees them
// while the menu bar item stays idle; the content and its state are reused.
void BattRecyclePopover(BattMenuController *controller) {
    NSPopover *old = controller.popover;
    if (old == nil || old.isShown) return;
    NSViewController *viewController = [[old.contentViewController retain] autorelease];
    old.delegate = nil;
    old.contentViewController = nil;
    NSPopover *popover = [[[NSPopover alloc] init] autorelease];
    popover.behavior = NSPopoverBehaviorTransient;
    popover.delegate = controller;
    popover.contentSize = viewController.view.frame.size;
    popover.contentViewController = viewController;
    controller.popover = popover;
    // Opening the popover peaks well above 100 MB; once its buffers and
    // samples are released, hand the freed malloc pages back to the system
    // so an idle menu-bar app returns to its launch footprint.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!controller.popover.isShown) malloc_zone_pressure_relief(NULL, 0);
    });
}
void BattRefreshPopover(BattMenuController *controller, double cpu, double memory) {
    WattDashboard *view = (WattDashboard *)controller.popover.contentViewController.view;
    [view refreshCPU:cpu memory:memory];
}
void BattShowStoragePage(BattMenuController *controller) {
    WattDashboard *view = (WattDashboard *)controller.popover.contentViewController.view;
    [view storage:nil];
}
