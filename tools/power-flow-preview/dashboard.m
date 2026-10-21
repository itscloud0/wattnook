#import "../../pkg/gui/native_internal.h"
#include <assert.h>
#include <math.h>
#include <stdlib.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

static void AssertSameBatteryPixels(NSImage *actual, NSImage *expected) {
    assert(actual && expected && NSEqualSizes(actual.size,expected.size));
    NSBitmapImageRep *a = [NSBitmapImageRep imageRepWithData:actual.TIFFRepresentation];
    NSBitmapImageRep *b = [NSBitmapImageRep imageRepWithData:expected.TIFFRepresentation];
    assert(a.pixelsWide == b.pixelsWide && a.pixelsHigh == b.pixelsHigh);
    for (NSInteger y=0;y<a.pixelsHigh;y++) for (NSInteger x=0;x<a.pixelsWide;x++) {
        NSColor *ca = [[a colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
        NSColor *cb = [[b colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
        assert(fabs(ca.alphaComponent-cb.alphaComponent) < 0.001);
        if (ca.alphaComponent > 0) {
            assert(fabs(ca.redComponent-cb.redComponent) < 0.001);
            assert(fabs(ca.greenComponent-cb.greenComponent) < 0.001);
            assert(fabs(ca.blueComponent-cb.blueComponent) < 0.001);
        }
    }
}

static void CheckNativeBatteryArtwork(void) {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27) return;
    assert(WattNativeBatteryRendererAvailable());
    Class cls = NSClassFromString(@"BUIImage");
    id cache = ((id(*)(id,SEL))objc_msgSend)(cls,NSSelectorFromString(@"sharedBUIImageCache"));
    SEL selector = NSSelectorFromString(@"_modernBatteryImageForLevel:charging:pluggedIn:noBattery:needsReplacement:lowPowerMode:showPercentage:useRed:");
    for (NSNumber *charge in @[@0,@1,@10,@20,@21,@50,@80,@99,@100]) {
        for (NSArray *flags in @[@[@NO,@NO,@YES,@NO,@NO],@[@YES,@YES,@YES,@NO,@NO],
                @[@YES,@NO,@YES,@NO,@NO],@[@NO,@NO,@YES,@NO,@YES],
                @[@NO,@NO,@NO,@NO,@NO],@[@NO,@NO,@YES,@YES,@NO]]) {
            BOOL plugged=[flags[0] boolValue], charging=[flags[1] boolValue], present=[flags[2] boolValue];
            BOOL service=[flags[3] boolValue], low=[flags[4] boolValue];
            NSImage *expected = ((id(*)(id,SEL,double,BOOL,BOOL,BOOL,BOOL,BOOL,BOOL,BOOL))objc_msgSend)(
                cache,selector,charge.doubleValue/100.0,present&&plugged&&charging,present&&plugged,
                !present,present&&service,low,NO,present&&!plugged&&charge.integerValue<=20);
            AssertSameBatteryPixels(WattSystemMenuBattery(charge.integerValue,plugged,charging,present,service,low),expected);
        }
    }
    assert(WattSystemMenuBattery(-1,NO,NO,YES,NO,NO) == nil);
}

// Isolated native render + behavior checks. No daemon callbacks or process quits.
void battMenuWillOpen(uintptr_t handle) { (void)handle; }
void battMenuTimerFired(uintptr_t handle) { (void)handle; }
void battMenuAction(uintptr_t handle, int item, bool checked) { (void)handle; (void)item; (void)checked; }
static int requestedLimit = -1;
static int mainCallbacks;
void battMainCallback(uintptr_t handle) { assert(handle == 123); assert(NSThread.isMainThread); mainCallbacks++; }
void battStorageAction(uintptr_t handle,uint64_t generation,int action) {}
bool battMenuSetLimit(uintptr_t handle, int limit) { (void)handle; requestedLimit = limit; return true; }

static NSButton *FindButton(NSView *view, NSString *title) {
    for (NSView *child in view.subviews) {
        if ([child isKindOfClass:NSButton.class] && [((NSButton *)child).title isEqual:title])
            return (NSButton *)child;
        NSButton *found = FindButton(child,title);
        if (found) return found;
    }
    return nil;
}
static NSButton *FindAccessibleButton(NSView *view, NSString *label) {
    for (NSView *child in view.subviews) {
        if ([child isKindOfClass:NSButton.class] && [child.accessibilityLabel isEqual:label])
            return (NSButton *)child;
        NSButton *found = FindAccessibleButton(child,label);
        if (found) return found;
    }
    return nil;
}
static NSUInteger CountGlassViews(NSView *view) {
    NSUInteger count = [NSStringFromClass(view.class) isEqual:@"NSGlassEffectContainerView"] ? 1 : 0;
    for (NSView *child in view.subviews) count += CountGlassViews(child);
    return count;
}
static void Capture(NSView *view, NSString *directory, NSString *name) {
    if (getenv("WATTNOOK_CHECKS_ONLY")) return;
    const char *prefix = getenv("WATTNOOK_CAPTURE_PREFIX");
    if (prefix && strcmp(prefix,"compact") == 0) {
        if (![@[@"polish-battery",@"charging",@"hybrid",@"native-heat-unavailable",@"native-heat-settings",@"monitoring-settings",@"polish-system",@"monitoring-history"] containsObject:name]) return;
    } else if (prefix && strcmp(prefix,"redesign") == 0) {
        if (![@[@"polish-battery",@"polish-system",@"polish-glass-system",@"polish-glass-battery",@"monitoring-settings",@"monitoring-history",@"native-heat-unavailable"] containsObject:name]) return;
    } else if (prefix && ![name hasPrefix:[NSString stringWithUTF8String:prefix]]) return;
    [view displayIfNeeded];
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:[directory stringByAppendingPathComponent:[name stringByAppendingString:@".png"]]
        atomically:YES];
}
int main(int argc, const char *argv[]) {
    if (argc != 2) return 2;
    @autoreleasepool {
        assert(WattKeepLidGuard(nil,YES)); // failed status read must not restore a closed display
        assert(!WattKeepLidGuard(nil,NO));
        assert(!WattKeepLidGuard(@NO,YES));
        assert(WattKeepLidGuard(@YES,NO));
        assert([WattMemoryPressureLabel(DISPATCH_MEMORYPRESSURE_NORMAL) isEqual:@"Normal"]);
        assert([WattMemoryPressureLabel(99) isEqual:@"Unavailable"]);
        WattMetricHistory *history = [[[WattMetricHistory alloc] init] autorelease];
        for (NSUInteger i=0;i<1000;i++) [history append:(WattMetricSample){i*10,25,80,12,3}];
        assert(history.count == WattHistoryCapacity);
        assert([history sampleAtIndex:0].time == 9100);
        assert([history sampleAtIndex:89].time == 9990);
        [history append:(WattMetricSample){9991,30,85,20,4}];
        assert([history sampleAtIndex:89].time == 9990); // rate limited, no growth
        [history append:(WattMetricSample){10000,-1,120,NAN,INFINITY}];
        WattMetricSample missing = [history sampleAtIndex:89];
        assert(isnan(missing.cpu) && isnan(missing.memory) && isnan(missing.watts) && isnan(missing.disk));
        [history append:(WattMetricSample){5,30,50,12,2}]; // backwards clock clears stale timeline
        assert(history.count == 1 && [history sampleAtIndex:0].time == 5);
        assert([WattCPUUsageLabel(234,10) isEqual:@"23.4% CPU"]);
        assert([WattCPUUsageLabel(234,8) isEqual:@"29.2% CPU"]);
        assert([WattCPUUsageLabel(100,1) isEqual:@"100.0% CPU"]);
        assert([WattCPUUsageLabel(0,8) isEqual:@"0.0% CPU"]);
        assert([WattCPUUsageLabel(234,0) isEqual:@"—"]);
        assert([WattCPUUsageLabel(NAN,8) isEqual:@"—"]);
        assert(fabs(BattProcessCPUPercent(0,24000000,1,125,3)-100)<0.001);
        assert(fabs(BattProcessCPUPercent(0,1000000000,1,1,1)-100)<0.001);
        assert(BattProcessCPUPercent(200,100,1,125,3) == 0);
        assert(BattProcessCPUPercent(0,100,0,125,3) == 0);
        assert([WattCompactBytes(-1,YES) isEqual:@"—"]);
        assert([WattCompactBytes(NAN,YES) isEqual:@"—"]);
        assert([WattCompactBytes(0,YES) isEqual:@"0 B"]);
        assert([WattCompactBytes(1024,YES) isEqual:@"1 KB"]);
        assert([WattCompactBytes(1500000,NO) isEqual:@"1.5 MB"]);
        assert([WattCompactBytes(3.0*1024*1024*1024*1024,YES) isEqual:@"3 TB"]);
        assert([WattCompactBytes(999999999,NO) isEqual:@"1 GB"]);
        assert(BattCounterRate(100,300,2) == 100);
        assert(BattCounterRate(300,100,2) == -1);
        assert(BattCounterRate(100,100,2) == 0);
        assert(BattCounterRate(0,100,0) == -1);
        assert(BattCounterRate(0,100,NAN) == -1);
        [NSApplication sharedApplication];
        batt_dispatch_main(123);
        assert(mainCallbacks == 0);
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        assert(mainCallbacks == 1);
        // This executable has no app bundle: preferences are isolated from WattNook.
        assert(NSBundle.mainBundle.bundleIdentifier == nil);
        for (NSString *key in @[@"WattNookMonitoringEnabled",@"WattNookHistoryEnabled",@"WattNookAwakeEvents"])
            [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        for (NSInteger i=0;i<80;i++) WattRecordAwakeEvent([NSString stringWithFormat:@"Test event %ld",(long)i]);
        NSArray *awakeEvents = [NSUserDefaults.standardUserDefaults arrayForKey:@"WattNookAwakeEvents"];
        assert(awakeEvents.count == 64 && [awakeEvents.firstObject hasSuffix:@"Test event 16"]);
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WattNookAwakeEvents"];
        for (NSString *key in @[@"WattNookPalette",@"WattNookMenuMetrics",@"WattNookMenuBatteryIcon",@"WattNookCPUUnits",@"WattNookMemoryUnits",@"WattNookDiskUnits"])
            [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        NSString *directory = [NSString stringWithUTF8String:argv[1]];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
            withIntermediateDirectories:YES attributes:nil error:nil];
        BattMenuController *c = [[BattMenuController alloc] init];
        c.items = [NSMutableDictionary dictionary];
        c.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
        c.powerFlowView = [[[BattPowerFlowView alloc] initWithFrame:NSMakeRect(0,0,360,220)] autorelease];
        CheckNativeBatteryArtwork();
        {
            // Keep Apple's natural 26x14 footprint, not a resized reconstruction.
            BOOL modern = WattNativeBatteryRendererAvailable();
            [c setLiveStatusCharge:0 pluggedIn:NO charging:NO heatPaused:NO];
            assert(c.batteryIcon.size.width == (modern ? 26 : 25));
            NSBitmapImageRep *empty = [NSBitmapImageRep imageRepWithData:c.batteryIcon.TIFFRepresentation];
            CGFloat emptyAlpha = [[empty colorAtX:empty.pixelsWide/2 y:empty.pixelsHigh/2] alphaComponent];
            assert(modern ? (emptyAlpha > 0 && emptyAlpha < 0.95) : emptyAlpha < 0.05);
            [c setLiveStatusCharge:100 pluggedIn:NO charging:NO heatPaused:NO];
            NSBitmapImageRep *full = [NSBitmapImageRep imageRepWithData:c.batteryIcon.TIFFRepresentation];
            CGFloat fullAlpha = [[full colorAtX:full.pixelsWide/2 y:full.pixelsHigh/2] alphaComponent];
            // Apple uses semantic foreground alpha, not our old opaque white.
            // Exact native pixels for all levels/states are checked above.
            assert(modern ? fullAlpha > emptyAlpha : fullAlpha > 0.95);
            for (NSNumber *charge in @[@0,@1,@20,@80,@100]) {
                for (NSNumber *charging in @[@NO,@YES]) {
                    [c setLiveStatusCharge:charge.integerValue pluggedIn:YES charging:charging.boolValue heatPaused:NO];
                    assert(c.batteryIcon.size.width == (modern ? 26 : 25) && c.batteryIcon.size.height == 14);
                    assert(c.statusItem.button.image.isTemplate);
                }
            }
            // A changed percentage must be composed in the same update, not one poll later.
            [NSUserDefaults.standardUserDefaults setObject:@[@"Battery"] forKey:@"WattNookMenuMetrics"];
            [c setLiveStatusCharge:9 pluggedIn:NO charging:NO heatPaused:NO];
            NSData *nine = c.statusItem.button.image.TIFFRepresentation;
            [c setLiveStatusCharge:88 pluggedIn:NO charging:NO heatPaused:NO];
            NSData *first88 = c.statusItem.button.image.TIFFRepresentation;
            [c refreshStatusImage];
            assert(![nine isEqual:first88]);
            assert([first88 isEqual:c.statusItem.button.image.TIFFRepresentation]);
            if (modern) {
                [c setLiveStatusCharge:10 pluggedIn:NO charging:NO heatPaused:NO];
                assert(c.batteryIconHasColor && !c.batteryColorView.hidden);
                assert([c.batteryColorView hitTest:NSMakePoint(2,2)] == nil);
                assert(c.batteryColorView.allowsVibrancy);
                assert(NSEqualSizes(c.batteryColorView.frame.size,c.batteryIcon.size));
                assert([c.batteryColorView.image.TIFFRepresentation isEqual:c.batteryIcon.TIFFRepresentation]);
                [c setLiveStatusCharge:80 pluggedIn:YES charging:NO heatPaused:NO];
                assert(c.batteryColorView.hidden && c.batteryColorView.image == nil);
                [c setLiveStatusCharge:80 pluggedIn:NO charging:NO heatPaused:NO present:NO needsService:NO];
                assert([c.statusItem.button.toolTip containsString:@"not detected"]);
                BattApplyBatterySnapshot(c,@{});
                assert(c.powerFlowView.chargePercent == -1 && !c.powerFlowView.chargingStateKnown);
                assert([c.statusItem.button.toolTip containsString:@"unavailable"]);
                BattApplyBatterySnapshot(c,@{@"CurrentCapacity":@80,@"ExternalConnected":@YES,
                    @"BatteryHealthCondition":@"Check Battery",@"IsCharging":@NO});
                assert([c.statusItem.button.toolTip containsString:@"service recommended"]);
                [c refreshStatusImage]; // System sampling must not erase VoiceOver state.
                assert([c.statusItem.button.accessibilityLabel containsString:@"service recommended"]);
                assert([c.statusItem.button.accessibilityLabel componentsSeparatedByString:@"Battery 80%"].count == 2);
                [c setLiveStatusCharge:80 pluggedIn:YES charging:YES heatPaused:NO];
                [c refreshStatusImage];
                assert([c.statusItem.button.accessibilityLabel containsString:@"charging"]);
            }
        }
        // The final composed status image must delegate contrast to NSStatusBar,
        // including text-only, icon-only and mixed layouts in Aqua/Dark Aqua.
        for (NSString *appearance in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
            c.statusItem.button.appearance = [NSAppearance appearanceNamed:appearance];
            for (NSArray *metrics in @[@[], @[@"CPU"], @[@"Battery"], @[@"CPU",@"RAM",@"SSD",@"Battery"]]) {
                [NSUserDefaults.standardUserDefaults setObject:metrics forKey:@"WattNookMenuMetrics"];
                for (NSNumber *showIcon in @[@NO,@YES]) {
                    [NSUserDefaults.standardUserDefaults setBool:showIcon.boolValue forKey:@"WattNookMenuBatteryIcon"];
                    [c setLiveStatusCharge:48 pluggedIn:NO charging:NO heatPaused:NO];
                    assert(c.statusItem.button.image.isTemplate);
                    assert(c.statusItem.button.contentTintColor == nil);
                    assert(c.statusItem.button.image.size.width > 0);
                    if (WattNativeBatteryRendererAvailable()) {
                        [c setLiveStatusCharge:10 pluggedIn:NO charging:NO heatPaused:NO];
                        BOOL visible = showIcon.boolValue || metrics.count == 0;
                        assert(c.batteryColorView.hidden == !visible);
                        if (visible) {
                            assert(NSContainsRect(c.statusItem.button.bounds,c.batteryColorView.frame));
                            assert(fabs(NSMidY(c.batteryColorView.frame)-NSMidY(c.statusItem.button.bounds)) < 1);
                        }
                    }
                }
            }
        }
        c.statusItem.button.appearance = nil;
        if (getenv("WATTNOOK_MENU_ICON_PREVIEW")) {
            NSArray *states = @[@"On battery",@"Charging",@"AC, not charging",@"Low battery",@"Low Power Mode",@"Service",@"No battery",@"Unknown"];
            [NSUserDefaults.standardUserDefaults setObject:@[@"CPU",@"RAM",@"SSD",@"Battery"] forKey:@"WattNookMenuMetrics"];
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"WattNookMenuBatteryIcon"];
            for (NSString *appearance in @[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]) {
                c.statusItem.button.appearance = [NSAppearance appearanceNamed:appearance];
                for (NSInteger state=0;state<states.count;state++) {
                    [c setLiveStatusCharge:state==3?10:(state==7?-1:48)
                        pluggedIn:state==1||state==2 charging:state==1 heatPaused:NO
                        present:state!=6 needsService:state==5];
                    if (state == 4) {
                        // Fixture only: do not toggle the host's Low Power Mode.
                        c.batteryIcon = WattSystemMenuBattery(48,NO,NO,YES,NO,YES);
                        c.batteryIconHasColor = YES;
                        [c refreshStatusImage];
                    }
                    Capture(c.statusItem.button,directory,[NSString stringWithFormat:@"menu-icon-%@-%ld",appearance,(long)state]);
                }
            }
            c.statusItem.button.appearance = nil;
            [c setLiveStatusCharge:48 pluggedIn:NO charging:NO heatPaused:NO];
        }
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WattNookMenuMetrics"];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WattNookMenuBatteryIcon"];
        c.diskReadRate = 12400000; c.diskWriteRate = 2100000;
        c.diskSpacePercent = 73; c.diskTotalBytes = 500000000000; c.diskFreeBytes = 135000000000;
        c.swapUsedBytes = 1.5*1024*1024*1024;
        c.appStats = @[
            @{@"pid":@123, @"name":@"ChatGPT", @"path":@"/Applications/ChatGPT.app", @"cpu":@9, @"memory":@780000000},
            @{@"pid":@124, @"name":@"Warp", @"path":@"/Applications/Warp.app", @"cpu":@6, @"memory":@1370000000},
            @{@"pid":@125, @"name":@"Safari", @"path":@"/Applications/Safari.app", @"cpu":@4, @"memory":@500000000},
            @{@"pid":@126, @"name":@"Finder", @"path":@"/System/Library/CoreServices/Finder.app", @"cpu":@1, @"memory":@180000000},
            @{@"pid":@127, @"name":@"An application with a very long name", @"path":@"/System/Applications/Utilities/Terminal.app", @"cpu":@0, @"memory":@180000000},
            @{@"pid":@128, @"name":@"WattNook", @"path":@"", @"cpu":@0.2, @"memory":@42000000, @"canQuit":@NO}];
        NSMutableDictionary *previewProcesses = [NSMutableDictionary dictionary];
        for (NSDictionary *app in c.appStats) previewProcesses[app[@"pid"]] = @[@0,@0];
        c.previousProcessCPU = previewProcesses;
        // Build inside its own pool and refresh after draining it: views that
        // nothing retains crash here instead of only in the shipped app.
        @autoreleasepool { BattBuildPopover(c); }
        @autoreleasepool { BattRefreshPopover(c,63,81); [c.powerFlowView setLimitPercent:-1]; BattRefreshPopover(c,63,81); }
        NSView *view = c.popover.contentViewController.view;
        // The approved full redesign gives both destinations equal, usable lanes.
        assert(NSWidth(view.bounds) == 400 && NSHeight(view.bounds) == 502);
        assert(NSHeight(c.powerFlowView.frame) == 252);
        assert(NSEqualRects(c.powerFlowView.frame,NSMakeRect(0,198,400,252)));
        assert(NSMaxY(FindButton(view,@"History").frame) + 6 <= 446);
        // Keyboard: ⌘2/⌘3/⌘1 switch tabs, ⌘, toggles Settings.
        NSEvent *(^command)(NSString *) = ^NSEvent *(NSString *key) {
            return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand
                timestamp:0 windowNumber:0 context:nil characters:key charactersIgnoringModifiers:key isARepeat:NO keyCode:0];
        };
        assert([view performKeyEquivalent:command(@"2")] && ((NSButton *)FindButton(view,@"System")).state == NSControlStateValueOn);
        assert([view performKeyEquivalent:command(@"3")] && ((NSButton *)FindButton(view,@"Storage")).state == NSControlStateValueOn);
        assert([view performKeyEquivalent:command(@",")] && !((NSView *)[view valueForKey:@"_settingsPage"]).hidden);
        assert([view performKeyEquivalent:command(@",")] && [view performKeyEquivalent:command(@"1")]);
        assert(((NSButton *)FindButton(view,@"Battery")).state == NSControlStateValueOn && NSHeight(view.bounds) == 502);
        NSButton *historyBack = FindButton([view valueForKey:@"_historyPage"],@"System");
        assert(historyBack && NSMaxY(historyBack.frame) + 6 <= 446 && historyBack.image != nil);
        assert(NSWidth(FindButton(view,@"Battery").frame) >= 112);
        assert(NSWidth(FindButton(view,@"System").frame) >= 112);
        assert(FindButton(view,@"Storage") != nil);
        assert(NSWidth(FindButton(view,@"Storage").frame) >= 112);
        assert(NSMaxX(FindButton(view,@"Battery").frame) + 8 <= NSMinX(FindButton(view,@"System").frame));
        assert(NSMaxX(FindButton(view,@"System").frame) + 8 <= NSMinX(FindButton(view,@"Storage").frame));
        // Page navigation is a selected surface; sorting alone uses an underline.
        assert(![[FindButton(view,@"Battery") valueForKey:@"tab"] boolValue]);
        assert(![[FindButton(view,@"System") valueForKey:@"tab"] boolValue]);
        assert([[FindButton(view,@"CPU") valueForKey:@"tab"] boolValue]);
        NSArray *contexts = @[[view valueForKey:@"_processCount"],
            [view valueForKey:@"_swap"], [view valueForKey:@"_availableSpace"]];
        // Column captions identify values before reading the measurements.
        NSArray *orderedDetails = [view valueForKey:@"_details"];
        NSArray *orderedCaptions = [view valueForKey:@"_detailCaptions"];
        for (NSUInteger i=0;i<orderedDetails.count;i++) {
            assert(NSMaxY(((NSView *)orderedDetails[i]).frame) <= NSMinY(((NSView *)orderedCaptions[i]).frame));
            NSTextField *context = contexts[i];
            assert(context.alignment == NSTextAlignmentCenter);
            assert(fabs(NSMidX(context.frame)-NSMidX(((NSView *)orderedDetails[i]).frame)) < 0.5);
        }
        // Quiet consumer actions retain their hit area and readable second line.
        NSArray *polishRows = [view valueForKey:@"_rows"];
        NSButton *quietQuit = [polishRows[0] valueForKey:@"_quit"];
        assert([[quietQuit valueForKey:@"plain"] boolValue]);
        assert(NSHeight(quietQuit.frame) >= 24);
        assert(((NSTextField *)[polishRows[0] valueForKey:@"_relative"]).font.pointSize >= 10.5);
        assert([((NSTextField *)[polishRows[0] valueForKey:@"_amount"]).textColor isEqual:NSColor.labelColor]);
        assert(polishRows.count == 6);
        for (NSButton *sort in @[FindButton(view,@"CPU"),FindButton(view,@"Memory"),FindButton(view,@"Disk")])
            assert(NSWidth(sort.frame) >= 56 && NSHeight(sort.frame) >= 28);
        for (NSTextField *caption in [view valueForKey:@"_detailCaptions"])
            assert(caption.alignment == NSTextAlignmentCenter);
        // Keep Awake diagnostics live in Settings; Battery keeps one aligned action pair.
        NSButton *awakeInfo = FindButton(view,@"Keep Awake details…");
        if (!awakeInfo) { fprintf(stderr,"FAIL: Settings has a Keep Awake details button\n"); return 1; }
        assert(awakeInfo.target == c && awakeInfo.action == @selector(showKeepAwakeDiagnostics:));
        assert(c.darkButton.action == @selector(toggleKeepAwakeFromPopover:));
        assert(!FindAccessibleButton(view,@"Keep Awake details"));
        NSWindow *window = [[NSWindow alloc] initWithContentRect:view.bounds
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        [window.contentView addSubview:view];
        NSArray *states = @[
            @{@"name":@"battery", @"charge":@48, @"plug":@NO, @"adapter":@0, @"battery":@-9.4, @"system":@9.4, @"heat":@NO},
            @{@"name":@"charging", @"charge":@57, @"plug":@YES, @"adapter":@36, @"battery":@15.8, @"system":@20.2, @"heat":@NO},
            @{@"name":@"limit-held", @"charge":@80, @"plug":@YES, @"adapter":@21, @"battery":@0, @"system":@21, @"heat":@NO},
            @{@"name":@"heat-held", @"charge":@64, @"plug":@YES, @"adapter":@18.9, @"battery":@0, @"system":@18.9, @"heat":@YES},
            @{@"name":@"hybrid", @"charge":@70, @"plug":@YES, @"adapter":@11.1, @"battery":@-5.5, @"system":@16.6, @"heat":@NO},
            @{@"name":@"unavailable", @"charge":@70, @"plug":@NO, @"adapter":@0, @"battery":@0, @"system":@0, @"heat":@NO},
            @{@"name":@"inconsistent", @"charge":@57, @"plug":@YES, @"adapter":@14, @"battery":@14.3, @"system":@0, @"heat":@NO}];
        for (NSDictionary *state in states) {
            BattPowerFlowView *power = c.powerFlowView;
            power.chargePercent = [state[@"charge"] integerValue]; power.limitPercent = 80;
            power.pluggedIn = [state[@"plug"] boolValue]; power.adapterWatts = [state[@"adapter"] doubleValue];
            power.batteryWatts = [state[@"battery"] doubleValue]; power.systemWatts = [state[@"system"] doubleValue];
            power.chargingStateKnown = YES; power.batteryCharging = power.batteryWatts > 0.25;
            power.heatPaused = [state[@"heat"] boolValue]; power.temperatureCelsius = 36.5; power.processorTemperatureCelsius = 88.4;
            power.healthPercent = 85; power.cycleCount = 358;
            power.hasTelemetry = ![state[@"name"] isEqual:@"unavailable"];
            BattRefreshPopover(c,63,81);
            Capture(view,directory,state[@"name"]);
            if ([state[@"name"] isEqual:@"battery"]) Capture(view,directory,@"polish-battery");
        }
        if (getenv("WATTNOOK_README")) {
            // Marketing captures with live-looking control states; restored after.
            c.keepAwakeStatusTime = NSProcessInfo.processInfo.systemUptime; c.keepAwakeStatus = @YES;
            c.powerFlowView.supportedLimits = @[@50,@55,@60,@65,@70,@75,@80,@85,@90,@95,@100];
            [c item:BattItemQuickLimits].hidden = NO; [c item:BattItemLimit80].enabled = YES;
            c.powerFlowView.limitEditable = YES;
            NSArray *readme = @[
                @{@"name":@"readme-charging", @"charge":@62, @"plug":@YES, @"adapter":@38.4, @"battery":@19.6, @"system":@18.8, @"heat":@NO, @"cpu":@64, @"detail":@"Watching · pauses at 33°"},
                @{@"name":@"readme-heat", @"charge":@64, @"plug":@YES, @"adapter":@21.3, @"battery":@0, @"system":@21.3, @"heat":@YES, @"cpu":@91, @"detail":@"Paused · resumes at 30°"},
                @{@"name":@"readme-hybrid", @"charge":@71, @"plug":@YES, @"adapter":@11.7, @"battery":@-6.2, @"system":@17.9, @"heat":@NO, @"cpu":@78, @"detail":@"Watching · pauses at 33°"}];
            for (NSDictionary *state in readme) {
                BattPowerFlowView *power = c.powerFlowView;
                power.chargePercent = [state[@"charge"] integerValue]; power.limitPercent = 80;
                power.pluggedIn = YES; power.adapterWatts = [state[@"adapter"] doubleValue];
                power.batteryWatts = [state[@"battery"] doubleValue]; power.systemWatts = [state[@"system"] doubleValue];
                power.chargingStateKnown = YES; power.batteryCharging = power.batteryWatts > 0.25;
                power.heatPaused = [state[@"heat"] boolValue]; power.temperatureCelsius = [state[@"heat"] boolValue] ? 34.2 : 31.4;
                power.processorTemperatureCelsius = [state[@"cpu"] doubleValue]; power.hasTelemetry = YES;
                c.heatDetail = state[@"detail"];
                BattRefreshPopover(c,38,62);
                power.limitEditable = YES; [power setNeedsDisplay:YES];
                Capture(view,directory,state[@"name"]);
            }
            c.heatDetail = nil; c.keepAwakeStatus = nil; c.powerFlowView.limitEditable = NO;
            c.powerFlowView.supportedLimits = nil;
        }
        NSButton *system = FindButton(view,@"System"); assert(system);
        // Cached system telemetry drives the real button; pending authorization blocks repeats.
        c.keepAwakeStatusTime = NSProcessInfo.processInfo.systemUptime;
        c.keepAwakeStatus = @YES;
        BattRefreshPopover(c,63,81);
        assert([c.darkButton.title isEqual:@"Keep Awake · On"] && c.darkButton.enabled);
        CGFloat awakeTitleWidth = [c.darkButton.title sizeWithAttributes:@{NSFontAttributeName:c.darkButton.font}].width;
        assert(awakeTitleWidth + (c.darkButton.image ? 27 : 0) + 12 <= NSWidth(c.darkButton.bounds));
        Capture(view,directory,@"awake-controls");
        NSMenuItem *heatFixture = [[[NSMenuItem alloc] initWithTitle:
            @"Custom heat protection unavailable with Apple's native charge limit"
            action:nil keyEquivalent:@""] autorelease];
        [c rememberItem:heatFixture as:BattItemHeatProtection];
        heatFixture.hidden = YES;
        c.powerFlowView.supportedLimits = @[@80,@85,@90,@95,@100];
        c.powerFlowView.pluggedIn = YES;
        c.powerFlowView.adapterWatts = 18.9;
        c.powerFlowView.batteryWatts = 0;
        c.powerFlowView.systemWatts = 18.9;
        c.powerFlowView.hasTelemetry = YES;
        BattRefreshPopover(c,63,81);
        assert(!c.heatButton.enabled && [c.heatButton.title isEqual:@"Heat unavailable"]);
        assert(c.heatButton.hidden);
        assert(NSMinX(c.darkButton.frame) == 16 && NSMaxX(c.darkButton.frame) == 384);
        NSTextField *heatNotice = [view valueForKey:@"_heatNotice"];
        assert(!heatNotice.hidden && [heatNotice.stringValue containsString:@"unavailable"]);
        assert([heatNotice.stringValue sizeWithAttributes:@{NSFontAttributeName:heatNotice.font}].width <= NSWidth(heatNotice.frame));
        assert([c.heatButton.accessibilityLabel isEqual:@"Heat unavailable. Native limit only"]);
        assert([c.heatButton.toolTip containsString:@"unavailable"]);
        Capture(view,directory,@"native-heat-unavailable");
        NSButton *heatSettings = FindAccessibleButton(view,@"Settings");
        [heatSettings performClick:nil];
        Capture(view,directory,@"native-heat-settings");
        [FindButton(view,@"Battery") performClick:nil];
        heatFixture.hidden = NO;
        c.powerFlowView.supportedLimits = nil;
        BattRefreshPopover(c,63,81);
        assert(c.heatButton.enabled && [c.heatButton.accessibilityLabel isEqual:@"Heat protection. Checking…"]);
        assert(!c.heatButton.hidden && heatNotice.hidden);
        assert(NSMinX(c.darkButton.frame) == 204 && NSMaxX(c.darkButton.frame) == 384);
        assert(NSWidth(c.heatButton.frame) == NSWidth(c.darkButton.frame) && NSMinX(c.heatButton.frame) == 16);
        c.keepAwakeChanging = YES;
        BattRefreshPopover(c,63,81);
        assert([c.darkButton.title isEqual:@"Changing…"] && !c.darkButton.enabled);
        assert(![c item:BattItemKeepAwake].enabled);
        c.keepAwakeChanging = NO;
        c.keepAwakeStatus = @NO;
        BattRefreshPopover(c,63,81);
        assert([c.darkButton.title isEqual:@"Keep Awake"] && c.darkButton.enabled);
        c.keepAwakeStatus = nil;
        BattRefreshPopover(c,63,81);
        assert([c.darkButton.title isEqual:@"Keep Awake"]);
        assert([[c.darkButton valueForKey:@"subtitle"] isEqual:@"Status unavailable"]);
        c.powerFlowView.limitEditable = YES;
        Capture(view,directory,@"editable-limit");
        [c.powerFlowView keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown
            location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil
            characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:124]];
        assert(requestedLimit == 85);
        assert(c.powerFlowView.displayedLimitPercent == 85);
        // Native mode snaps to advertised choices, never unsupported SMC values.
        for (NSNumber *identifier in @[@(BattItemQuickLimits),@(BattItemLimit80)]) {
            NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:@"Fixture" action:nil keyEquivalent:@""] autorelease];
            [c rememberItem:item as:identifier.integerValue];
        }
        [c item:BattItemQuickLimits].hidden = NO;
        [c item:BattItemLimit80].enabled = YES;
        c.powerFlowView.limitEditable = YES;
        c.powerFlowView.supportedLimits = @[@80,@85,@90,@95,@100];
        c.powerFlowView.limitPercent = 85;
        [c.powerFlowView accessibilitySetValue:@35];
        assert(requestedLimit == 80);
        [c.powerFlowView accessibilitySetValue:@92];
        assert(requestedLimit == 90);
        [c.powerFlowView accessibilitySetValue:@100];
        assert(requestedLimit == 100);
        c.powerFlowView.limitPercent = -1;
        BattRefreshPopover(c,63,81);
        assert(!c.powerFlowView.limitEditable);
        assert(c.powerFlowView.displayedLimitPercent == -1);
        c.powerFlowView.supportedLimits = nil;
        c.powerFlowView.limitPercent = 80;
        c.powerFlowView.limitPercent = 20;
        assert([view hitTest:NSMakePoint(84,308-(532-NSHeight(view.bounds)))] == c.powerFlowView);
        c.powerFlowView.limitPercent = 80;
        assert([view hitTest:NSMakePoint(276,308-(532-NSHeight(view.bounds)))] == c.powerFlowView);
        [c refreshStatusImage];
        assert([c.statusItem.button.accessibilityLabel containsString:@"SSD space used 73%"]);
        CGFloat withoutPercent = c.statusItem.button.image.size.width;
        // A compatibility refresh on a healthy install must not collapse the
        // live metrics image to the generic batteryblock symbol.
        [c setStatusIconInstalled:YES capable:YES needsUpgrade:NO];
        assert(c.statusItem.button.image.size.width == withoutPercent);
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"WattNookMenuBatteryIcon"];
        [c refreshStatusImage];
        assert(withoutPercent-c.statusItem.button.image.size.width >= 34);
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WattNookMenuBatteryIcon"];
        [NSUserDefaults.standardUserDefaults setObject:@[@"CPU",@"RAM",@"SSD",@"Battery"] forKey:@"WattNookMenuMetrics"];
        [c refreshStatusImage];
        assert(c.statusItem.button.image.size.width-withoutPercent >= 14);
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WattNookMenuMetrics"];
        BattRefreshPopover(c,63,81);
        [system performClick:nil]; assert(c.powerFlowView.hiddenOrHasHiddenAncestor);
        NSArray *consumerRows = [view valueForKey:@"_rows"];
        assert(consumerRows.count == 6);
        assert(((NSTextField *)[view valueForKey:@"_swap"]).font.pointSize == 12);
        assert([((NSTextField *)[view valueForKey:@"_swap"]).stringValue isEqual:@"Swap 1.5 GB"]);
        for(NSUInteger i=0;i<3;i++) assert(fabs(NSMidX(((NSView *)contexts[i]).frame)-NSMidX(((NSView *)orderedDetails[i]).frame))<0.5);
        assert([((NSTextField *)[view valueForKey:@"_availableSpace"]).stringValue isEqual:@""]);
        // Regress the actual NSRangeException: CPU's default NSButton tag was -1.
        [FindButton(view,@"Memory") performClick:nil];
        [FindButton(view,@"CPU") performClick:nil];
        assert([[view valueForKey:@"_sortMetric"] integerValue] == 0);
        for (NSInteger i=0; i<100; i++) {
            [FindButton(view,@"Memory") performClick:nil];
            [FindButton(view,@"Disk") performClick:nil];
            [FindButton(view,@"CPU") performClick:nil];
        }
        NSButton *invalidSort = [[[NSButton alloc] init] autorelease]; invalidSort.tag = -1;
        [view performSelector:@selector(sort:) withObject:invalidSort];
        assert([[view valueForKey:@"_sortMetric"] integerValue] == 0);
        [view setValue:@-1 forKey:@"_sortMetric"];
        BattRefreshPopover(c,63,81);
        assert([[view valueForKey:@"_sortMetric"] integerValue] == 0);
        Capture(view,directory,@"system-cpu");
        Capture(view,directory,@"polish-system");
        NSArray *cpuApps = c.appStats;
        NSMutableDictionary *busyApp = [[cpuApps[0] mutableCopy] autorelease]; busyApp[@"cpu"] = @234;
        c.appStats = @[busyApp]; BattRefreshPopover(c,35,81);
        NSView *busyRow = consumerRows[0];
        assert([((NSTextField *)[busyRow valueForKey:@"_amount"]).stringValue isEqual:
            WattCPUUsageLabel(234,NSProcessInfo.processInfo.processorCount)]);
        // CPU rows show one centered value; the core-equivalent line was noise.
        assert([((NSTextField *)[busyRow valueForKey:@"_relative"]).stringValue isEqual:@""]);
        c.appStats = cpuApps; BattRefreshPopover(c,63,81);
        [FindButton(view,@"Memory") performClick:nil];
        Capture(view,directory,@"system-memory");
        NSArray *details = [view valueForKey:@"_details"];
        NSArray *captions = [view valueForKey:@"_detailCaptions"];
        for (NSUInteger i=0;i<details.count;i++) {
            for (NSUInteger mode=0;mode<(i == 2 ? 3 : 2);mode++) {
                [(NSButton *)details[i] performClick:nil];
                assert(![((NSTextField *)captions[i]).stringValue containsString:@"↔"]);
                assert([((NSButton *)details[i]).toolTip isEqual:@"Change units"]);
            }
        }
        [(NSButton *)details[1] performClick:nil];
        assert([NSUserDefaults.standardUserDefaults integerForKey:@"WattNookMemoryUnits"] == 1);
        assert([((NSButton *)details[1]).title containsString:@"GB"]);
        assert([((NSButton *)details[0]).title containsString:@"%"]);
        [(NSButton *)details[0] performClick:nil];
        assert(![((NSButton *)details[0]).title containsString:@"%"]);
        [(NSButton *)details[2] performClick:nil];
        assert([((NSButton *)details[2]).title isEqual:@"73%"]);
        [(NSButton *)details[2] performClick:nil];
        assert([((NSButton *)details[2]).title isEqual:@"365 GB"]);
        Capture(view,directory,@"system-absolute");
        c.diskTotalBytes = 4000000000000; c.diskFreeBytes = 1000000000000;
        c.diskSpacePercent = 75;
        BattRefreshPopover(c,100,100);
        assert([((NSButton *)details[2]).title isEqual:@"3 TB"]);
        assert([((NSTextField *)[view valueForKey:@"_availableSpace"]).stringValue isEqual:@""]);
        Capture(view,directory,@"system-terabytes");
        NSArray *originalApps = c.appStats;
        NSMutableDictionary *largeApp = [[c.appStats[0] mutableCopy] autorelease];
        largeApp[@"memory"] = @(3.0*1024*1024*1024*1024);
        c.appStats = @[largeApp];
        BattRefreshPopover(c,100,100);
        NSArray *rows = [view valueForKey:@"_rows"];
        assert([((NSTextField *)[rows[0] valueForKey:@"_amount"]).stringValue isEqual:@"3 TB"]);
        for (NSString *key in @[@"_amount",@"_relative"]) {
            NSTextField *field = [rows[0] valueForKey:key];
            assert([field.stringValue sizeWithAttributes:@{NSFontAttributeName:field.font}].width <= field.frame.size.width);
        }
        Capture(view,directory,@"app-terabytes");
        c.appStats = originalApps;
        for (NSButton *detail in details)
            assert([detail.title sizeWithAttributes:@{NSFontAttributeName:detail.font}].width <= detail.frame.size.width-6);
        [(NSButton *)details[0] performClick:nil]; [(NSButton *)details[1] performClick:nil];
        [(NSButton *)details[2] performClick:nil];
        c.diskTotalBytes = 500000000000; c.diskFreeBytes = 135000000000;
        c.diskSpacePercent = 73;
        BattRefreshPopover(c,63,81);
        NSMutableArray *diskApps = [NSMutableArray array];
        for (NSDictionary *app in c.appStats) {
            NSMutableDictionary *sample = [[app mutableCopy] autorelease];
            sample[@"disk"] = @([sample[@"cpu"] doubleValue]*1000000);
            sample[@"diskRead"] = sample[@"disk"]; sample[@"diskWrite"] = @0;
            [diskApps addObject:sample];
        }
        c.appStats = diskApps;
        [FindButton(view,@"Disk") performClick:nil]; Capture(view,directory,@"system-disk");
        NSButton *gear = FindButton(view,@""); assert(gear);
        [gear performClick:nil]; assert(FindButton(view,@"SSD used")); Capture(view,directory,@"settings");
        NSButton *glass = FindButton(view,@"Glass"); assert(glass);
        assert(glass.hidden == !WattGlassAvailable());
        [NSUserDefaults.standardUserDefaults setObject:@"Glass" forKey:@"WattNookPalette"];
        assert(WattGlassTheme() == WattGlassAvailable());
        [FindButton(view,@"Blue") performClick:nil];
        assert(!WattGlassTheme());
        assert(CountGlassViews(view) == 0);
        if (WattGlassAvailable()) {
            [glass performClick:nil]; assert(WattGlassTheme());
            assert(CountGlassViews(view) == 2);
            // Availability changes rebuild actual Glass shapes, not just button frames.
            for (NSNumber *unavailable in @[@YES,@NO,@YES,@NO]) {
                heatFixture.hidden = unavailable.boolValue;
                BattRefreshPopover(c,63,81);
                assert(c.heatButton.hidden == unavailable.boolValue);
                NSView *batteryPage = [view valueForKey:@"_batteryPage"];
                NSView *actionGlass = nil;
                for (NSView *container in [view valueForKey:@"_glassViews"])
                    if (container.superview == batteryPage) actionGlass = container;
                assert(actionGlass && NSEqualRects(actionGlass.frame,NSMakeRect(16,46,368,56)));
                NSView *glassContent = [actionGlass valueForKey:@"contentView"];
                assert(glassContent.subviews.count == (unavailable.boolValue ? 1 : 2));
                if (unavailable.boolValue)
                    assert(NSEqualRects(((NSView *)glassContent.subviews.firstObject).frame,NSMakeRect(0,0,368,56)));
                assert(CountGlassViews(view) == 2);
            }
            [FindButton(view,@"System") performClick:nil];
            Capture(view,directory,@"polish-glass-system");
            [FindButton(view,@"Battery") performClick:nil];
            Capture(view,directory,@"polish-glass-battery");
            assert(c.darkButton.action == @selector(toggleKeepAwakeFromPopover:));
            assert(!c.darkButton.hidden);
            assert(!FindButton(view,@"Screen off"));
            [gear performClick:nil];
            [FindButton(view,@"Blue") performClick:nil]; assert(!WattGlassTheme());
            assert(CountGlassViews(view) == 0);
            [glass performClick:nil]; assert(WattGlassTheme());
            assert(CountGlassViews(view) == 2);
        }
        [FindButton(view,@"Mint") performClick:nil];
        assert([[NSUserDefaults.standardUserDefaults stringForKey:@"WattNookPalette"] isEqual:@"Mint"]);
        [FindButton(view,@"Memory used") performClick:nil];
        [FindButton(view,@"SSD used") performClick:nil];
        [FindButton(view,@"Battery icon") performClick:nil];
        assert([WattMenuMetrics() isEqual:@[@"CPU"]] && !WattMenuBatteryIcon());
        [FindButton(view,@"CPU load") performClick:nil];
        assert(WattMenuMetrics().count == 0 && WattMenuBatteryIcon());
        [FindButton(view,@"Battery percentage") performClick:nil];
        [FindButton(view,@"Battery icon") performClick:nil];
        assert([WattMenuMetrics() isEqual:@[@"Battery"]] && !WattMenuBatteryIcon());
        [FindButton(view,@"Battery") performClick:nil];
        Capture(view,directory,@"palette-mint");
        [gear performClick:nil]; [FindButton(view,@"Blue") performClick:nil];
        [FindButton(view,@"Battery") performClick:nil];
        c.powerFlowView.pluggedIn = YES; c.powerFlowView.adapterWatts = 18.9;
        c.powerFlowView.batteryWatts = 0; c.powerFlowView.systemWatts = 18.9;
        c.powerFlowView.heatPaused = YES; c.powerFlowView.hasTelemetry = YES;
        [gear performClick:nil]; [FindButton(view,@"Mint") performClick:nil];
        [FindButton(view,@"Battery") performClick:nil]; Capture(view,directory,@"palette-mint");
        [gear performClick:nil]; [FindButton(view,@"Violet") performClick:nil];
        [FindButton(view,@"Battery") performClick:nil]; Capture(view,directory,@"palette-violet");
        [gear performClick:nil]; [FindButton(view,@"Amber") performClick:nil];
        [FindButton(view,@"Battery") performClick:nil]; Capture(view,directory,@"palette-amber");
        [gear performClick:nil]; [FindButton(view,@"Blue") performClick:nil];
        [FindButton(view,@"Battery") performClick:nil];
        c.powerFlowView.heatPaused = NO;
        BattApplyBatterySnapshot(c,@{@"ExternalConnected":@YES,@"IsCharging":@NO,
            @"InstantAmperage":@736,@"Voltage":@12000,@"CurrentCapacity":@22,
            @"PowerTelemetryData":@{@"SystemPowerIn":@15000}});
        assert([c.statusItem.button.accessibilityLabel containsString:@"not charging"]);
        assert(c.powerFlowView.chargingStateKnown && !c.powerFlowView.batteryCharging);
        BattApplyBatterySnapshot(c,@{@"ExternalConnected":@YES,@"IsCharging":@YES,
            @"InstantAmperage":@0,@"Voltage":@12000,@"CurrentCapacity":@22,
            @"PowerTelemetryData":@{@"SystemPowerIn":@15000}});
        assert([c.statusItem.button.accessibilityLabel hasSuffix:@", charging"]);
        assert(c.powerFlowView.batteryCharging);
        BattApplyBatterySnapshot(c,@{@"ExternalConnected":@NO,@"InstantAmperage":@-900,
            @"Voltage":@12000,@"CurrentCapacity":@64,@"AppleRawMaxCapacity":@4003,@"DesignCapacity":@4629,
            @"CycleCount":@330,@"PowerTelemetryData":@{@"SystemPowerIn":@22000}});
        assert(!c.powerFlowView.pluggedIn && c.powerFlowView.adapterWatts == 0);
        assert(fabs(c.powerFlowView.batteryWatts+10.8)<0.0001);
        assert(fabs(c.powerFlowView.systemWatts-10.8)<0.0001);
        Capture(view,directory,@"unplug-transition");
        BattApplyBatterySnapshot(c,@{@"ExternalConnected":@NO,@"InstantAmperage":@0,
            @"Voltage":@12000,@"CurrentCapacity":@64});
        Capture(view,directory,@"transition-waiting");
        [FindButton(view,@"Battery") performClick:nil]; assert(!c.powerFlowView.hiddenOrHasHiddenAncestor);
        c.appStats = @[]; c.diskReadRate = -1; c.diskWriteRate = -1; c.swapUsedBytes = -1;
        BattRefreshPopover(c,-1,-1);
        [system performClick:nil]; Capture(view,directory,@"system-empty");
        BattUpdateStorage(c); assert(c.diskReadRate == -1);
        c.previousDiskSampleTime -= 1;
        BattUpdateStorage(c);
        assert(c.previousDiskCounters.count == 0 || (c.diskReadRate >= 0 && c.diskWriteRate >= 0));
        [c updateAppStats];
        CFAbsoluteTime busyUntil = CFAbsoluteTimeGetCurrent()+0.25;
        while (CFAbsoluteTimeGetCurrent() < busyUntil) { }
        [c updateAppStats];
        NSDictionary *selfSample = nil;
        for (NSDictionary *app in c.appStats)
            if ([app[@"pid"] intValue] == getpid()) selfSample = app;
        assert(selfSample != nil && ![selfSample[@"canQuit"] boolValue]);
        assert([selfSample[@"cpu"] doubleValue] > 50 && [selfSample[@"cpu"] doubleValue] < 250);
        NSLog(@"Live CPU sanity: one busy thread = %.1f%%; %lu readable processes",[selfSample[@"cpu"] doubleValue],(unsigned long)c.previousProcessCPU.count);
        [c updateSystemStats:nil]; assert(c.swapUsedBytes >= 0);
        [FindButton(view,@"Battery") performClick:nil];
        c.powerFlowView.hasTelemetry = YES;
        c.powerFlowView.pluggedIn = YES;
        c.powerFlowView.adapterWatts = 18.9;
        c.powerFlowView.batteryWatts = 0;
        c.powerFlowView.systemWatts = 18.9;
        [window orderFront:nil];
        c.powerFlowView.flowAnimationEnabled = YES;
        [c.powerFlowView display];
        [CATransaction flush];
        BOOL animated = NO;
        for (CALayer *layer in c.powerFlowView.layer.sublayers)
            animated |= [layer animationForKey:@"flow"] != nil;
        assert(animated == !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion);
        if (animated) {
            for (BOOL merge = NO; ; merge = YES) {
                c.powerFlowView.adapterWatts = merge ? 8.3 : 56.2;
                c.powerFlowView.batteryWatts = merge ? -13.9 : 31.2;
                c.powerFlowView.systemWatts = merge ? 22.2 : 25.0;
                [c.powerFlowView setNeedsDisplay:YES];
                [c.powerFlowView display];
                [CATransaction flush];
                for (CALayer *layer in c.powerFlowView.layer.sublayers) {
                    CABasicAnimation *pulse = (CABasicAnimation *)[layer animationForKey:@"flow"];
                    if (!pulse) continue;
                    assert(fabs(pulse.duration - 3.2) < 0.001);
                    __block NSInteger starts = 0, closes = 0;
                    CGPathRef outline = ((CAShapeLayer *)layer.mask).path;
                    CGPathApplyWithBlock(outline, ^(const CGPathElement *element) {
                        starts += element->type == kCGPathElementMoveToPoint;
                        closes += element->type == kCGPathElementCloseSubpath;
                    });
                    // Two Sankey bands (AppKit may append empty moves after closes).
                    assert(starts >= 3 && starts <= 6 && closes == 3);
                    CGFloat center = NSMidX(c.powerFlowView.bounds), width = NSWidth(c.powerFlowView.bounds);
                    // Solid shared trunk at the common node, a gap between branches mid-way.
                    assert(CGPathContainsPoint(outline, NULL, CGPointMake(merge ? width-66-8 : 66+8, 49), NO));
                    assert(!CGPathContainsPoint(outline, NULL, CGPointMake(center, 49), NO));
                }
                if (merge) break;
            }
        }
        c.powerFlowView.flowAnimationEnabled = NO;
        for (CALayer *layer in c.powerFlowView.layer.sublayers)
            assert([layer animationForKey:@"flow"] == nil);
        [gear performClick:nil];
        [FindButton(view,@"Keep 15-minute history") performClick:nil];
        assert(c.metricHistory && c.statsTimer.valid);
        Capture(view,directory,@"monitoring-settings");
        [FindButton(view,@"System") performClick:nil];
        NSTextField *pressure = [view valueForKey:@"_pressure"];
        assert(NSMaxY(pressure.frame) <= NSHeight(pressure.superview.bounds));
        assert(!NSIntersectsRect(pressure.frame,FindButton(view,@"History").frame));
        // Illustrative graph fixture covers all four series and a missing sample.
        c.metricHistory = [[[WattMetricHistory alloc] init] autorelease];
        NSTimeInterval historyNow = NSDate.timeIntervalSinceReferenceDate;
        for (NSInteger i=0;i<90;i++)
            [c.metricHistory append:(WattMetricSample){historyNow-890+i*10,
                30+20*sin(i/8.0),65+8*sin(i/17.0),i == 50 ? NAN : 20+12*sin(i/10.0),15+10*cos(i/7.0)}];
        [FindButton(view,@"History") performClick:nil];
        assert(!c.systemPageVisible && !((NSView *)[view valueForKey:@"_historyPage"]).hidden);
        // Cover real graph drawing without generating screenshots.
        [[view valueForKey:@"_historyChart"] display];
        Capture(view,directory,@"monitoring-history");
        [gear performClick:nil];
        [FindButton(view,@"System monitoring") performClick:nil];
        assert(!WattMonitoringEnabled() && !c.statsTimer && !c.metricHistory && !c.appStats);
        assert(!c.previousProcessCPU && !c.previousDiskCounters && c.memoryPressure == 0);
        [c updateSystemStats:nil]; [c updateAppStats];
        assert(!c.previousProcessCPU && !c.previousDiskCounters && c.memoryPressure == 0);
        [FindButton(view,@"System monitoring") performClick:nil];
        assert(c.statsTimer.valid && c.metricHistory);
        [FindButton(view,@"Keep 15-minute history") performClick:nil];
        assert(!c.metricHistory && c.statsTimer.valid);
        [FindButton(view,@"System monitoring") performClick:nil];
        assert(!c.statsTimer);
        [window orderOut:nil];
        NSLog(@"Native checks passed; internal disks: %lu, read %.1f B/s, write %.1f B/s",
            (unsigned long)c.previousDiskCounters.count,c.diskReadRate,c.diskWriteRate);
        [window release]; [c release];
        for (NSString *key in @[@"WattNookMonitoringEnabled",@"WattNookHistoryEnabled",@"WattNookAwakeEvents"])
            [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        for (NSString *key in @[@"WattNookPalette",@"WattNookMenuMetrics",@"WattNookMenuBatteryIcon",@"WattNookCPUUnits",@"WattNookMemoryUnits",@"WattNookDiskUnits"])
            [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
    }
    return 0;
}
