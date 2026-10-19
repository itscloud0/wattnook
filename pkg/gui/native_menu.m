#import "native_internal.h"
#import <mach/mach.h>
#import <sys/mount.h>
#import <sys/sysctl.h>

static const NSTimeInterval BattMenuUpdateInterval = 10.0;

static NSMenuItem *ActionItem(BattMenuController *controller,
                              NSString *title,
                              NSString *key,
                              BattMenuItem identifier) {
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title
                                                  action:@selector(menuAction:)
                                           keyEquivalent:key] autorelease];
    item.target = controller;
    item.tag = identifier;
    [controller rememberItem:item as:identifier];
    return item;
}

static NSMenuItem *DisplayItem(BattMenuController *controller,
                               NSString *title,
                               BattMenuItem identifier,
                               BOOL enabled) {
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title
                                                  action:@selector(noop:)
                                           keyEquivalent:@""] autorelease];
    item.target = controller;
    item.tag = identifier;
    item.enabled = enabled;
    [controller rememberItem:item as:identifier];
    return item;
}

static NSMenu *AddSubmenu(BattMenuController *controller,
                          NSMenu *parent,
                          NSString *title,
                          BattMenuItem identifier) {
    NSMenu *submenu = [[[NSMenu alloc] initWithTitle:title] autorelease];
    submenu.autoenablesItems = NO;
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title
                                                  action:nil
                                           keyEquivalent:@""] autorelease];
    item.submenu = submenu;
    [controller rememberItem:item as:identifier];
    [parent addItem:item];
    return submenu;
}

@implementation BattMenuController

- (instancetype)initWithHandle:(uintptr_t)handle version:(NSString *)version {
    self = [super init];
    if (self) {
        _handle = handle;
        _items = [[NSMutableDictionary alloc] init];
        _menu = [[NSMenu alloc] initWithTitle:@"batt"];
        _menu.autoenablesItems = NO;
        _menu.delegate = self;
        _statusItem = [[[NSStatusBar systemStatusBar]
            statusItemWithLength:NSVariableStatusItemLength] retain];
        _statusItem.autosaveName = @"BattThermalCombinedStatus";
        _cpuPercent = -1;
        _memoryPercent = -1;
        _swapUsedBytes = -1;
        _diskPercent = -1;
        _diskReadRate = -1;
        _diskWriteRate = -1;
        _diskSpacePercent = -1;
        _powerFlowView = [[BattPowerFlowView alloc] initWithFrame:NSMakeRect(0, 0, 340, 220)];

        BattBuildMenu(self, version);
        BattApplyTooltips(self);
        [self buildPopover];
        _statusItem.button.target = self;
        _statusItem.button.action = @selector(togglePopover:);
        [_statusItem.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
        [self setStatusIconInstalled:NO capable:NO needsUpgrade:NO];
        _timer = [[NSTimer scheduledTimerWithTimeInterval:BattMenuUpdateInterval
                                                   target:self
                                                 selector:@selector(timerTick:)
                                                 userInfo:nil
                                                  repeats:YES] retain];
        _timer.tolerance = 1.0;
        [self applyMonitoringPreferences];
        BattUpdateBattery(self);
    }
    return self;
}

- (void)showStorageReview:(id)sender { WattShowStorageReview(self); }

- (void)dealloc {
    WattSetStorageReviewActive(self,NO);
    [_storageView release];
    [_awakeDetailsWindow close];
    [_awakeDetailsWindow release];
    [_awakeBlockerReport release];
    [_awakeSnapshotDate release];
    [_heatDetail release];
    [_timer invalidate];
    [_timer release];
    [_statsTimer invalidate];
    [_statsTimer release];
    _menu.delegate = nil;
    [[NSStatusBar systemStatusBar] removeStatusItem:_statusItem];
    [_statusItem release];
    [_batteryIcon release];
    [_batteryColorView removeFromSuperview];
    [_batteryColorView release];
    [_powerFlowView release];
    [_popover release];
    [_chargeButton release];
    [_heatButton release];
    [_darkButton release];
    [_keepAwakeStatus release];
    [_lidGuard release];
    [_keepAwakeError release];
    [_lidGuardError release];
    [_metricHistory release];
    [_statsButton release];
    [_memoryButton release];
    [_diskButton release];
    [_cpuTopAppLabel release];
    [_memoryTopAppLabel release];
    [_cpuQuitButton release];
    [_memoryQuitButton release];
    [_cpuFeaturedApp release];
    [_memoryFeaturedApp release];
    [_cpuAppsMenu release];
    [_memoryAppsMenu release];
    [_appStats release];
    [_previousProcessCPU release];
    [_previousProcessDisk release];
    [_previousDiskCounters release];
    [_menu release];
    [_items release];
    [super dealloc];
}

- (NSMenuItem *)item:(BattMenuItem)item {
    return [_items objectForKey:[NSNumber numberWithInteger:item]];
}

- (void)rememberItem:(NSMenuItem *)item as:(BattMenuItem)identifier {
    [_items setObject:item forKey:[NSNumber numberWithInteger:identifier]];
}

- (void)menuAction:(NSMenuItem *)sender {
    BattMenuItem identifier = (BattMenuItem)sender.tag;
    switch (identifier) {
        case BattItemMagSafeEnabled:
        case BattItemMagSafeDisabled:
        case BattItemMagSafeAlwaysOff:
            [self item:BattItemMagSafeEnabled].state = identifier == BattItemMagSafeEnabled
                ? NSControlStateValueOn : NSControlStateValueOff;
            [self item:BattItemMagSafeDisabled].state = identifier == BattItemMagSafeDisabled
                ? NSControlStateValueOn : NSControlStateValueOff;
            [self item:BattItemMagSafeAlwaysOff].state = identifier == BattItemMagSafeAlwaysOff
                ? NSControlStateValueOn : NSControlStateValueOff;
            break;
        case BattItemHeatOff:
        case BattItemHeatStrict:
        case BattItemHeatBalanced:
        case BattItemHeatRelaxed:
            [self item:BattItemHeatOff].state = identifier == BattItemHeatOff
                ? NSControlStateValueOn : NSControlStateValueOff;
            [self item:BattItemHeatStrict].state = identifier == BattItemHeatStrict
                ? NSControlStateValueOn : NSControlStateValueOff;
            [self item:BattItemHeatBalanced].state = identifier == BattItemHeatBalanced
                ? NSControlStateValueOn : NSControlStateValueOff;
            [self item:BattItemHeatRelaxed].state = identifier == BattItemHeatRelaxed
                ? NSControlStateValueOn : NSControlStateValueOff;
            break;
        case BattItemKeepAwake:
            [self toggleKeepAwake];
            return;
        case BattItemHeatCustom:
            [self setCustomHeatProtection];
            return;
        case BattItemPreventIdleSleep:
        case BattItemDisableChargingPreSleep:
        case BattItemPreventSystemSleep:
            sender.state = sender.state == NSControlStateValueOff
                ? NSControlStateValueOn : NSControlStateValueOff;
            break;
        default:
            break;
    }
    battMenuAction(_handle, identifier, sender.state == NSControlStateValueOn);
}

- (void)noop:(NSMenuItem *)sender {
    (void)sender;
}

- (void)menuWillOpen:(NSMenu *)menu {
    if (menu == self.menu) [self updateDiagnosticMenus];
    battMenuWillOpen(_handle);
    BattUpdateBattery(self);
}

- (void)buildPopover {
    BattBuildPopover(self);
    [self refreshPopoverControls];
}


- (void)togglePopover:(id)sender {
    (void)sender;
    NSEvent *event = [NSApp currentEvent];
    if (event.type == NSEventTypeRightMouseUp) {
        [self.popover close];
        battMenuWillOpen(_handle);
        BattUpdateBattery(self);
        [self updateDiagnosticMenus];
        [self showMenu:self.menu fromButton:self.statusItem.button];
        return;
    }
    if (self.popover.isShown) {
        [self.popover close];
        return;
    }
    battMenuWillOpen(_handle);
    if (self.systemPageVisible) [self updateAppStats];
    BattUpdateBattery(self);
    [self refreshPopoverControls];
    [NSApp activateIgnoringOtherApps:YES];
    [self.popover showRelativeToRect:self.statusItem.button.bounds
                             ofView:self.statusItem.button
                      preferredEdge:NSRectEdgeMinY];
}

- (void)popoverDidShow:(NSNotification *)notification {
    (void)notification;
    self.powerFlowView.flowAnimationEnabled = !self.powerFlowView.hiddenOrHasHiddenAncestor;
    WattSetStorageReviewActive(self,!self.storageView.hiddenOrHasHiddenAncestor);
}

- (void)popoverDidClose:(NSNotification *)notification {
    (void)notification;
    self.powerFlowView.flowAnimationEnabled = NO;
    WattSetStorageReviewActive(self,NO);
    self.previousProcessCPU = nil; self.previousProcessDisk = nil;
    _previousProcessSampleTime = 0;
}

- (void)showMenu:(NSMenu *)menu fromButton:(NSButton *)button {
    if (menu == nil) return;
    battMenuWillOpen(_handle);
    [menu popUpMenuPositioningItem:nil
                       atLocation:NSMakePoint(0, NSHeight(button.bounds))
                           inView:button];
    [self refreshPopoverControls];
}

- (void)showChargeLimits:(NSButton *)sender {
    [self showMenu:[self item:BattItemQuickLimits].submenu fromButton:sender];
}

- (void)showHeatOptions:(NSButton *)sender {
    [self showMenu:[self item:BattItemHeatProtection].submenu fromButton:sender];
}

- (void)showDiagnostics:(NSButton *)sender {
    [self updateDiagnosticMenus];
    NSMenu *diagnostics = [self.menu itemWithTitle:@"Diagnostics"].submenu;
    [self showMenu:diagnostics fromButton:sender];
}

- (void)showCPUApps:(NSButton *)sender {
    [self updateDiagnosticMenus];
    [self showMenu:self.cpuAppsMenu fromButton:sender];
}

- (void)showMemoryApps:(NSButton *)sender {
    [self updateDiagnosticMenus];
    [self showMenu:self.memoryAppsMenu fromButton:sender];
}

- (void)showMoreMenu:(NSButton *)sender {
    [self showMenu:self.menu fromButton:sender];
}

- (void)showKeepAwakeDiagnostics:(id)sender {
    (void)sender;
    WattShowAwakeDetails(self);
}

- (void)refreshKeepAwakeDiagnostics:(id)sender {
    (void)sender;
    if (!self.awakeDetailsWindow || self.awakeDiagnosticsLoading) return;
    self.awakeDiagnosticsLoading = YES;
    self.keepAwakeStatusTime = 0;
    [self isKeepAwakeActive];
    WattRefreshAwakeDetails(self);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        @autoreleasepool {
            NSString *blockers = WattSleepBlockerReport();
            NSDate *sampledAt = [NSDate date];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.awakeDiagnosticsLoading = NO;
                // Closing the window drops its process snapshot. A late result must
                // never reopen it; a reopened window may share the in-flight query.
                if (self.awakeDetailsWindow) {
                    self.awakeBlockerReport = blockers;
                    self.awakeSnapshotDate = sampledAt;
                    WattRefreshAwakeDetails(self);
                }
            });
        }
    });
}

- (void)toggleKeepAwakeFromPopover:(NSButton *)sender {
    (void)sender;
    [self toggleKeepAwake];
    [self refreshPopoverControls];
}

- (void)quitFeaturedApp:(NSButton *)sender {
    NSDictionary *sample = sender.tag == 0 ? self.cpuFeaturedApp : self.memoryFeaturedApp;
    if (sample == nil) return;
    NSMenuItem *request = [[[NSMenuItem alloc] initWithTitle:@"Quit"
                                                    action:nil keyEquivalent:@""] autorelease];
    request.representedObject = sample;
    [self quitDiagnosedApp:request];
    [self updateAppStats];
    [self refreshPopoverControls];
}

- (void)commitLimitFromRail:(BattPowerFlowView *)sender {
    NSInteger requested = sender.displayedLimitPercent;
    if (!battMenuSetLimit(_handle, (int)requested)) {
        sender.limitPercent = sender.limitPercent;
    }
    [self refreshPopoverControls];
}

- (void)refreshPopoverControls {
    BattRefreshPopover(self, _cpuPercent, _memoryPercent);
    WattRefreshAwakeDetails(self);
}


- (void)menuDidClose:(NSMenu *)menu {
    (void)menu;
}

- (void)timerTick:(NSTimer *)timer {
    (void)timer;
    battMenuTimerFired(_handle);
    BattUpdateBattery(self);
    [self isKeepAwakeActive];
}

- (void)applyMonitoringPreferences {
    if (WattMonitoringEnabled()) {
        if (!_statsTimer) {
            self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:2 target:self
                selector:@selector(updateSystemStats:) userInfo:nil repeats:YES];
            self.statsTimer.tolerance = 0.25;
        }
        if (WattHistoryEnabled() && !self.metricHistory) self.metricHistory = [[[WattMetricHistory alloc] init] autorelease];
        if (!WattHistoryEnabled()) self.metricHistory = nil;
        [self updateSystemStats:nil];
    } else {
        [self.statsTimer invalidate]; self.statsTimer = nil;
        self.metricHistory = nil; self.appStats = nil;
        self.cpuFeaturedApp = nil; self.memoryFeaturedApp = nil;
        [self.cpuAppsMenu removeAllItems]; [self.memoryAppsMenu removeAllItems];
        self.previousProcessCPU = nil; self.previousProcessDisk = nil;
        self.previousDiskCounters = nil; self.previousDiskSampleTime = 0;
        _hasCPUSample = NO; _previousProcessSampleTime = 0;
        _cpuPercent = _memoryPercent = _diskPercent = -1;
        self.diskReadRate = self.diskWriteRate = self.diskSpacePercent = -1;
        self.diskTotalBytes = self.diskFreeBytes = 0;
        self.swapUsedBytes = -1; self.memoryPressure = 0; self.memoryPressureSince = 0;
    }
    [self refreshStatusImage]; [self refreshPopoverControls];
}

- (void)updateSystemStats:(NSTimer *)timer {
    (void)timer;
    if (!WattMonitoringEnabled()) return;
    _cpuPercent = _memoryPercent = -1;
    host_t host = mach_host_self();
    host_cpu_load_info_data_t cpu;
    mach_msg_type_number_t cpuCount = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(host, HOST_CPU_LOAD_INFO,
                        (host_info_t)&cpu, &cpuCount) == KERN_SUCCESS) {
        uint64_t totalDelta = 0;
        uint64_t busyDelta = 0;
        for (NSInteger i = 0; i < CPU_STATE_MAX; i++) {
            uint64_t tick = cpu.cpu_ticks[i];
            uint64_t delta = tick >= _previousCPUTicks[i] ? tick - _previousCPUTicks[i] : 0;
            totalDelta += delta;
            if (i != CPU_STATE_IDLE) busyDelta += delta;
            _previousCPUTicks[i] = tick;
        }
        if (_hasCPUSample && totalDelta > 0)
            _cpuPercent = 100.0 * busyDelta / totalDelta;
        _hasCPUSample = YES;
    } else _hasCPUSample = NO;

    vm_statistics64_data_t memory;
    mach_msg_type_number_t memoryCount = HOST_VM_INFO64_COUNT;
    if (host_statistics64(host, HOST_VM_INFO64,
                          (host_info64_t)&memory, &memoryCount) == KERN_SUCCESS) {
        uint64_t total = [NSProcessInfo processInfo].physicalMemory;
        uint64_t available = ((uint64_t)memory.free_count +
                              (uint64_t)memory.inactive_count +
                              (uint64_t)memory.speculative_count) * (uint64_t)vm_page_size;
        if (total > 0)
            _memoryPercent = 100.0 * (1.0 - MIN(available, total) / (double)total);
    }
    mach_port_deallocate(mach_task_self(),host);
    NSInteger pressure = WattMemoryPressureLevel();
    if (pressure != self.memoryPressure || !self.memoryPressureSince)
        self.memoryPressureSince = NSDate.timeIntervalSinceReferenceDate;
    self.memoryPressure = pressure;

    struct xsw_usage swap = {0};
    size_t swapSize = sizeof(swap);
    self.swapUsedBytes = sysctlbyname("vm.swapusage", &swap, &swapSize, NULL, 0) == 0 &&
        swapSize == sizeof(swap) ? (double)swap.xsu_used : -1;
    BattUpdateStorage(self);
    _diskPercent = self.diskSpacePercent;
    if (self.metricHistory) {
        double watts = self.powerFlowView.systemWatts;
        BOOL inconsistent = self.powerFlowView.batteryWatts > 0.25 &&
            (self.powerFlowView.adapterWatts < self.powerFlowView.batteryWatts+0.5 || watts < 0.5);
        if (!self.powerFlowView.hasTelemetry || inconsistent || watts <= 0.05) watts = NAN;
        double disk = self.diskReadRate < 0 || self.diskWriteRate < 0 ? NAN : (self.diskReadRate+self.diskWriteRate)/1000000;
        [self.metricHistory append:(WattMetricSample){NSDate.timeIntervalSinceReferenceDate,_cpuPercent,_memoryPercent,watts,disk}];
    }
    [self refreshStatusImage];
    // Per-process scans are only useful while the app list is visible.
    if (self.popover.isShown && self.systemPageVisible)
        [self updateAppStats];
    if (self.popover.isShown) [self refreshPopoverControls];
}

- (void)refreshStatusImage {
    NSArray *metrics = WattMenuMetrics();
    NSMutableArray *labels = [NSMutableArray array], *values = [NSMutableArray array];
    for (NSString *metric in @[@"CPU",@"RAM",@"SSD"]) {
        if (![metrics containsObject:metric]) continue;
        [labels addObject:metric];
        if ([metric isEqual:@"SSD"]) {
            [values addObject:self.diskSpacePercent < 0 ? @"—" :
                [NSString stringWithFormat:@"%.0f%%",self.diskSpacePercent]];
        } else {
            double value = [metric isEqual:@"CPU"] ? _cpuPercent : _memoryPercent;
            [values addObject:value < 0 ? @"—" : [NSString stringWithFormat:@"%.0f%%",value]];
        }
    }
    BOOL percent = [metrics containsObject:@"Battery"];
    BOOL icon = WattMenuBatteryIcon() || (labels.count == 0 && !percent);
    CGFloat fontSize = labels.count > 1 ? 8.5 : 11;
    NSDictionary *attributes = @{
        NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:fontSize weight:NSFontWeightMedium],
        NSForegroundColorAttributeName:NSColor.whiteColor};
    CGFloat labelWidth = 0, valueWidth = 0;
    for (NSString *label in labels) labelWidth = MAX(labelWidth,[label sizeWithAttributes:attributes].width);
    for (NSString *value in values) valueWidth = MAX(valueWidth,[value sizeWithAttributes:attributes].width);
    CGFloat stackWidth = labels.count ? ceil(labelWidth+5+valueWidth)+3 : 0;
    NSString *charge = self.powerFlowView.chargePercent < 0 ? @"—%" :
        [NSString stringWithFormat:@"%ld%%",(long)self.powerFlowView.chargePercent];
    NSDictionary *chargeStyle = @{NSFontAttributeName:
        [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName:NSColor.whiteColor};
    CGFloat percentGap = percent && labels.count ? 10 : 0;
    CGFloat percentWidth = percent ? percentGap+ceil([charge sizeWithAttributes:chargeStyle].width)+4 : 0;
    CGFloat iconGap = icon && (labels.count || percent) ? 8 : 0;
    CGFloat iconWidth = self.batteryIcon ? self.batteryIcon.size.width : 25;
    NSImage *combined = [[[NSImage alloc] initWithSize:
        NSMakeSize(MAX(24,stackWidth+percentWidth+iconGap+(icon ? iconWidth+1 : 0)),24)] autorelease];
    [combined lockFocus];
    CGFloat height = [@"100%" sizeWithAttributes:attributes].height;
    for (NSInteger i=0;i<labels.count;i++) {
        CGFloat y = (24-height)/2 + ((labels.count-1)/2.0-i)*8;
        [labels[i] drawAtPoint:NSMakePoint(1,y) withAttributes:attributes];
        [values[i] drawAtPoint:NSMakePoint(labelWidth+6,y) withAttributes:attributes];
    }
    if (percent) [charge drawAtPoint:NSMakePoint(stackWidth+percentGap,
        (24-[charge sizeWithAttributes:chargeStyle].height)/2) withAttributes:chargeStyle];
    CGFloat iconHeight = self.batteryIcon ? self.batteryIcon.size.height : 14;
    if (icon && !self.batteryIconHasColor) [self.batteryIcon drawInRect:NSMakeRect(stackWidth+percentWidth+iconGap,(24-iconHeight)/2,iconWidth,iconHeight)
        fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    [combined unlockFocus];
    // Template the final composition, not just its battery component: AppKit
    // chooses contrast for the actual menu-bar backdrop and selected state.
    combined.template = YES;
    self.statusItem.button.image = combined;
    self.statusItem.button.contentTintColor = nil;
    self.statusItem.button.title = @"";
    // Keep metrics and neutral glyphs system-template adaptive, while retaining
    // Apple's actual red/yellow warning/Low Power artwork in a passive view.
    if (icon && self.batteryIconHasColor) {
        NSStatusBarButton *button = self.statusItem.button;
        if (!self.batteryColorView) {
            self.batteryColorView = WattCreateBatteryColorView();
            [button addSubview:self.batteryColorView];
        }
        [button layoutSubtreeIfNeeded];
        NSRect imageRect = [(NSButtonCell *)button.cell imageRectForBounds:button.bounds];
        self.batteryColorView.frame = NSMakeRect(NSMinX(imageRect)+stackWidth+percentWidth+iconGap,
            NSMidY(imageRect)-iconHeight/2, iconWidth, iconHeight);
        self.batteryColorView.image = self.batteryIcon;
        self.batteryColorView.hidden = NO;
    } else {
        self.batteryColorView.image = nil;
        self.batteryColorView.hidden = YES;
    }
    NSMutableArray *descriptions = [NSMutableArray arrayWithObject:@"WattNook"];
    for (NSInteger i=0;i<labels.count;i++)
        [descriptions addObject:[NSString stringWithFormat:@"%@ %@",
            [labels[i] isEqual:@"SSD"] ? @"SSD space used" : labels[i],values[i]]];
    if (percent && !self.statusItem.button.toolTip.length)
        [descriptions addObject:[@"Battery " stringByAppendingString:charge]];
    if (self.statusItem.button.toolTip.length)
        [descriptions addObject:self.statusItem.button.toolTip];
    self.statusItem.button.accessibilityLabel = [descriptions componentsJoinedByString:@", "];
}

- (void)setStatusIconInstalled:(BOOL)installed
                       capable:(BOOL)capable
                  needsUpgrade:(BOOL)needsUpgrade {
    self.batteryColorView.hidden = YES;
    NSString *symbol = @"minus.plus.batteryblock";
    NSString *description = @"batt icon";
    if (!installed) {
        symbol = @"batteryblock.slash";
        description = @"batt daemon not installed";
    } else if (!capable) {
        symbol = @"minus.plus.batteryblock.exclamationmark";
        description = @"Your machine cannot run batt";
    } else if (needsUpgrade) {
        symbol = @"fluid.batteryblock";
        description = @"batt needs upgrade";
    }
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:symbol
                                            accessibilityDescription:description];
    self.statusItem.button.title = @"";
    self.statusItem.button.contentTintColor = nil;
}

- (void)setLiveStatusCharge:(NSInteger)charge
                   pluggedIn:(BOOL)pluggedIn
                    charging:(BOOL)charging
                 heatPaused:(BOOL)heatPaused {
    [self setLiveStatusCharge:charge pluggedIn:pluggedIn charging:charging heatPaused:heatPaused
        present:YES needsService:NO];
}

- (void)setLiveStatusCharge:(NSInteger)charge pluggedIn:(BOOL)pluggedIn charging:(BOOL)charging
                heatPaused:(BOOL)heatPaused present:(BOOL)present needsService:(BOOL)needsService {
    BOOL known = charge >= 0 && present;
    charge = known ? MAX(0, MIN(100, charge)) : -1;
    NSBundle *controlCenter = [NSBundle bundleWithPath:@"/System/Library/CoreServices/ControlCenter.app"];
    NSImage *outline = [controlCenter imageForResource:@"battery-outline"];
    NSImage *cap = [controlCenter imageForResource:@"battery-cap"];
    NSString *overlayName = !pluggedIn ? nil : (charging ? @"battery-bolt" : @"battery-plug");
    NSImage *overlay = overlayName == nil ? nil : [controlCenter imageForResource:overlayName];
    NSImage *mask = overlayName == nil ? nil :
        [controlCenter imageForResource:[overlayName stringByAppendingString:@"-mask"]];
    BOOL lowPower = NSProcessInfo.processInfo.lowPowerModeEnabled;
    NSImage *image = WattSystemMenuBattery(charge,pluggedIn,charging,present,needsService,lowPower);
    BOOL nativeImage = image != nil;
    if (!image && known && outline != nil && cap != nil) {
        image = [[[NSImage alloc] initWithSize:NSMakeSize(25, 14)] autorelease];
        [image lockFocus];
        [NSColor.blackColor setFill];
        NSRect fill = NSMakeRect(2, 3, 19.0 * charge / 100.0, 8);
        [NSBezierPath fillRect:fill];
        if (mask != nil) {
            [mask drawInRect:NSMakeRect(7, 0, 11, 14) fromRect:NSZeroRect
                  operation:NSCompositingOperationDestinationOut fraction:1];
        }
        [outline drawInRect:NSMakeRect(0, 1, 23, 12) fromRect:NSZeroRect
                 operation:NSCompositingOperationSourceOver fraction:1];
        [cap drawInRect:NSMakeRect(23, 1, 2, 12) fromRect:NSZeroRect
             operation:NSCompositingOperationSourceOver fraction:1];
        if (overlay != nil) {
            [overlay drawInRect:NSMakeRect(7, 0, 11, 14) fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver fraction:1];
        }
        [image unlockFocus];
    } else if (!image) {
        // Missing artwork must not imply a full battery or fabricate an AC state.
        image = [NSImage imageWithSystemSymbolName:@"questionmark.square.dashed"
                         accessibilityDescription:@"Battery artwork unavailable"];
        image = [image imageWithSymbolConfiguration:[NSImageSymbolConfiguration
            configurationWithPointSize:12 weight:NSFontWeightRegular]];
    }
    // Preserve Control Center's outline alpha in the intermediate glyph.
    // refreshStatusImage templates the entire composition for system contrast.
    NSColor *iconColor = known && !pluggedIn && charge <= 20 ? NSColor.systemRedColor
        : (known && [NSProcessInfo processInfo].lowPowerModeEnabled
            ? NSColor.systemYellowColor : NSColor.whiteColor);
    if (!nativeImage) {
        image = [[image copy] autorelease];
        [image lockFocus];
        [iconColor setFill];
        NSRectFillUsingOperation(NSMakeRect(0, 0, image.size.width, image.size.height),
                                 NSCompositingOperationSourceAtop);
        [image unlockFocus];
    }
    image.template = NO;
    self.batteryIcon = image;
    self.batteryIconHasColor = nativeImage && known && (lowPower || (!pluggedIn && charge <= 20));
    self.powerFlowView.chargePercent = charge;
    NSString *state;
    if (!known) state = present ? @"battery status unavailable" : @"battery not detected";
    else if (needsService) state = @"battery service recommended";
    else if (heatPaused && pluggedIn) state = @"heat protection paused charging";
    else if (charging) state = @"charging";
    else state = pluggedIn ? @"plugged in, not charging" : @"on battery";
    if (known && lowPower) state = [state stringByAppendingString:@", Low Power Mode"];
    self.statusItem.button.toolTip = known ? [NSString stringWithFormat:@"Battery %ld%%, %@", (long)charge, state] : state;
    [self refreshStatusImage];
    self.powerFlowView.pluggedIn = pluggedIn;
    self.powerFlowView.chargingStateKnown = known;
    self.powerFlowView.batteryCharging = pluggedIn && charging;
    self.powerFlowView.heatPaused = heatPaused;
    [self.powerFlowView setNeedsDisplay:YES];
    [self refreshPopoverControls];
}

- (void)setPowerFlowAdapter:(double)adapter
                     system:(double)system
                    battery:(double)battery
                 heatPaused:(BOOL)heatPaused
                temperature:(double)temperature {
    NSString *summary = nil;
    BOOL inconsistent = battery > 0.25 &&
        (adapter < battery + 0.5 || system < 0.5);
    if (inconsistent) {
        summary = @"Power readings updating: adapter and battery data disagree";
        [self item:BattItemPowerSystem].attributedTitle = nil;
        [self item:BattItemPowerSystem].title = @"System: unavailable";
    } else if (adapter > 0.1) {
        summary = [NSString stringWithFormat:@"%.1f W adapter  →  %.1f W Mac", adapter, system];
    } else if (battery < -0.1) {
        summary = [NSString stringWithFormat:@"%.1f W battery  →  %.1f W Mac", fabs(battery), system];
    } else {
        summary = [NSString stringWithFormat:@"%.1f W powering the Mac", system];
    }
    [self item:BattItemPowerFlowSummary].title = summary;
    self.powerFlowView.accessibilityLabel = summary;
    if (heatPaused && adapter > 0.1) {
        [self item:BattItemPowerBattery].title = [NSString stringWithFormat:@"Battery held: %.1f°C", temperature];
    }
    self.powerFlowView.adapterWatts = adapter;
    self.powerFlowView.systemWatts = system;
    self.powerFlowView.batteryWatts = battery;
    self.powerFlowView.temperatureCelsius = temperature;
    self.powerFlowView.heatPaused = heatPaused;
    self.powerFlowView.hasTelemetry = YES;
    [self.powerFlowView setNeedsDisplay:YES];
}

- (void)setLimitPercent:(NSInteger)limitPercent {
    self.powerFlowView.limitPercent = limitPercent;
    [self.powerFlowView setNeedsDisplay:YES];
    [self refreshPopoverControls];
}

- (NSString *)keepAwakeToolPath {
    return [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"KeepAwake"];
}

- (BOOL)isKeepAwakeActive {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if ([self keepAwakeToolPath] && (self.keepAwakeStatusTime == 0 || now-self.keepAwakeStatusTime >= 10))
        [self requestKeepAwakeStatus];
    [self syncKeepAwakeLidGuard];
    return self.keepAwakeStatus.boolValue;
}

- (void)readKeepAwakeStatus:(void (^)(NSNumber *, NSString *))completion {
    WattReadSleepStatus(@"/usr/bin/pmset",@[@"-g"],2,completion);
}

- (void)requestKeepAwakeStatus {
    // Serialize reads and writes: no stale pre-toggle result can arrive after a write.
    if (self.keepAwakeStatusReading || self.keepAwakeChanging) return;
    self.keepAwakeStatusReading = YES;
    self.keepAwakeStatusTime = NSProcessInfo.processInfo.systemUptime;
    [self readKeepAwakeStatus:^(NSNumber *status, NSString *error) {
        NSNumber *previous = self.keepAwakeStatus;
        [previous retain];
        self.keepAwakeStatusReading = NO;
        self.keepAwakeStatusTime = NSProcessInfo.processInfo.systemUptime;
        self.keepAwakeStatus = status;
        self.keepAwakeError = error;
        if (![previous isEqual:status] && (previous || status))
            WattRecordAwakeEvent(self.keepAwakeError ?: (self.keepAwakeStatus.boolValue ? @"Sleep prevention confirmed on" : @"Sleep prevention confirmed off"));
        [previous release];
        [self syncKeepAwakeLidGuard];
        BOOL toggle = self.keepAwakeTogglePending;
        self.keepAwakeTogglePending = NO;
        [self refreshPopoverControls];
        if (toggle && status) [self performKeepAwakeToggle];
        // A failed pre-toggle read leaves the setting untouched; inline error stays visible.
    }];
}

- (void)syncKeepAwakeLidGuard {
    // Preview/test executables have no bundled helper and must not touch hardware.
    if ([self keepAwakeToolPath] != nil)
        WattSyncLidGuard(self,WattKeepLidGuard(self.keepAwakeStatus,self.lidGuard != nil ||
            [NSUserDefaults.standardUserDefaults objectForKey:@"WattNookClosedLidBrightness"] != nil));
}

- (void)toggleKeepAwake {
    if (self.keepAwakeChanging || self.keepAwakeTogglePending) return;
    NSString *tool = [self keepAwakeToolPath];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:tool]) {
        NSAlert *alert = [[[NSAlert alloc] init] autorelease];
        alert.messageText = @"Keep Awake helper is missing";
        alert.informativeText = @"Reinstall WattNook to restore its bundled Keep Awake helper.";
        [alert runModal];
        return;
    }
    self.keepAwakeTogglePending = YES;
    [self requestKeepAwakeStatus];
    [self refreshPopoverControls];
}

- (void)performKeepAwakeToggle {
    if (self.keepAwakeChanging || !self.keepAwakeStatus) return;
    BOOL active = self.keepAwakeStatus.boolValue;
    NSString *tool = [self keepAwakeToolPath];
    // A confirmation dialog runs a nested event loop: pause polling before it opens.
    self.keepAwakeChanging = YES;
    [self refreshPopoverControls];
    NSTask *task = [[[NSTask alloc] init] autorelease];
    task.executableURL = [NSURL fileURLWithPath:tool];
    if (!active && ![NSUserDefaults.standardUserDefaults boolForKey:@"WattNookKeepAwakeWarningAccepted"]) {
        NSAlert *confirm = [[[NSAlert alloc] init] autorelease];
        confirm.messageText = @"Keep working with the lid closed?";
        confirm.informativeText = @"This disables sleep for the entire Mac, including after WattNook quits. Turn Keep Awake off before carrying your Mac or putting it in a bag. Keep it ventilated, preferably on power. Keep WattNook running for closed-lid brightness handling. Administrator permission is needed unless the narrow sleep-toggle rule is installed. Do not manage this setting in Vorssaint at the same time.";
        [confirm addButtonWithTitle:@"Enable Keep Awake"];
        [confirm addButtonWithTitle:@"Cancel"];
        if ([confirm runModal] != NSAlertFirstButtonReturn) {
            self.keepAwakeChanging = NO;
            [self refreshPopoverControls];
            return;
        }
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"WattNookKeepAwakeWarningAccepted"];
    }
    task.arguments = @[active ? @"--disable" : @"--enable"];
    NSPipe *errors = [NSPipe pipe];
    task.standardError = errors;
    @try {
        self.keepAwakeChanging = YES;
        [self refreshPopoverControls];
        task.terminationHandler = ^(NSTask *finished) {
            NSData *data = [errors.fileHandleForReading readDataToEndOfFile];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.keepAwakeChanging = NO;
                self.keepAwakeStatusTime = 0;
                [self refreshPopoverControls];
                if (finished.terminationStatus != 0) {
                    NSString *detail = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
                    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
                    alert.messageText = @"Could not change Keep Awake";
                    alert.informativeText = detail.length ? detail : @"macOS did not confirm the change.";
                    [alert runModal];
                }
            });
        };
        [task launch];
    } @catch (NSException *exception) {
        self.keepAwakeChanging = NO;
        [self refreshPopoverControls];
        NSAlert *alert = [[[NSAlert alloc] init] autorelease];
        alert.messageText = @"Could not change Keep Awake";
        alert.informativeText = exception.reason ?: @"Unknown error";
        [alert runModal];
    }
}

- (void)setCustomHeatProtection {
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = @"Custom Heat Protection";
    alert.informativeText = @"Pause battery charging at this temperature. Charging resumes only below the second temperature.";
    [alert addButtonWithTitle:@"Apply"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *pause = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 80, 24)] autorelease];
    pause.stringValue = @"33";
    NSTextField *resume = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 80, 24)] autorelease];
    resume.stringValue = @"30";
    NSTextField *pauseLabel = [[[NSTextField alloc] initWithFrame:NSZeroRect] autorelease];
    pauseLabel.stringValue = @"Pause at (°C)";
    pauseLabel.editable = NO;
    pauseLabel.bordered = NO;
    pauseLabel.drawsBackground = NO;
    NSTextField *resumeLabel = [[[NSTextField alloc] initWithFrame:NSZeroRect] autorelease];
    resumeLabel.stringValue = @"Resume below (°C)";
    resumeLabel.editable = NO;
    resumeLabel.bordered = NO;
    resumeLabel.drawsBackground = NO;
    NSStackView *accessory = [NSStackView stackViewWithViews:@[
        pauseLabel, pause, resumeLabel, resume
    ]];
    accessory.orientation =NSUserInterfaceLayoutOrientationVertical;
    accessory.alignment = NSLayoutAttributeLeading;
    accessory.spacing = 4;
    alert.accessoryView = accessory;

    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }
    double pauseAt = pause.doubleValue;
    double resumeAt = resume.doubleValue;
    if (!isfinite(pauseAt) || !isfinite(resumeAt) || pauseAt <= 0 || resumeAt <= 0 || resumeAt >= pauseAt) {
        NSAlert *error = [[[NSAlert alloc] init] autorelease];
        error.messageText = @"Invalid heat protection thresholds";
        error.informativeText = @"Both temperatures must be above 0°C, and resume must be lower than pause.";
        [error runModal];
        return;
    }

    NSTask *task = [[[NSTask alloc] init] autorelease];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/local/bin/batt-thermal"];
    task.arguments = @[
        @"--daemon-socket=/var/run/batt-thermal.sock",
        @"heat-protection", @"set",
        [NSString stringWithFormat:@"%.1f", pauseAt],
        [NSString stringWithFormat:@"%.1f", resumeAt],
    ];
    @try {
        [task launch];
        [task waitUntilExit];
        if (task.terminationStatus != 0) {
            NSAlert *error = [[[NSAlert alloc] init] autorelease];
            error.messageText = @"Could not update heat protection";
            error.informativeText = @"The batt daemon did not accept the thresholds.";
            [error runModal];
        }
    } @catch (NSException *exception) {
        NSAlert *error = [[[NSAlert alloc] init] autorelease];
        error.messageText = @"Could not update heat protection";
        error.informativeText = exception.reason ?: @"Unknown error";
        [error runModal];
    }
}

- (void)setPowerItem:(BattMenuItem)item label:(NSString *)label value:(double)value {
    NSColor *color = NSColor.labelColor;
    char sign = ' ';
    if (![label isEqualToString:@"System"]) {
        if (value > 0) {
            color = NSColor.systemGreenColor;
            sign = '+';
        } else if (value < 0) {
            color = NSColor.systemRedColor;
            sign = '-';
        }
    }

    NSString *labelWithColon = [label stringByAppendingString:@":"];
    NSString *text = [NSString stringWithFormat:@"%-8s %c%7.2fW",
                      labelWithColon.UTF8String, sign, fabs(value)];
    NSMutableAttributedString *attributed = [[[NSMutableAttributedString alloc]
        initWithString:text] autorelease];
    NSRange labelRange = NSMakeRange(0, 9);
    NSRange valueRange = NSMakeRange(9, text.length - 9);
    [attributed addAttribute:NSForegroundColorAttributeName
                       value:NSColor.secondaryLabelColor
                       range:labelRange];
    [attributed addAttribute:NSForegroundColorAttributeName value:color range:valueRange];
    [attributed addAttribute:NSFontAttributeName
                       value:[NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular]
                       range:NSMakeRange(0, text.length)];
    [self item:item].attributedTitle = attributed;
}

@end

void BattBuildMenu(BattMenuController *controller, NSString *version) {
    NSMenu *root = controller.menu;
    NSMenuItem *flowCanvas = [[[NSMenuItem alloc] initWithTitle:@"Power Flow"
                                                         action:nil keyEquivalent:@""] autorelease];
    [controller rememberItem:flowCanvas as:BattItemPowerFlowCanvas];

    NSMenu *limits = AddSubmenu(controller, root, @"Charge Limit", BattItemQuickLimits);
    const NSInteger limitValues[] = {50, 60, 70, 80, 90};
    const BattMenuItem limitItems[] = {
        BattItemLimit50, BattItemLimit60, BattItemLimit70, BattItemLimit80, BattItemLimit90,
    };
    for (NSUInteger index = 0; index < 5; index++) {
        NSInteger limit = limitValues[index];
        NSString *title = [NSString stringWithFormat:@"%ld%%", (long)limit];
        NSString *key = [NSString stringWithFormat:@"%ld", (long)limit];
        [limits addItem:ActionItem(controller, title, key, limitItems[index])];
    }

    NSMenu *disableLimit = AddSubmenu(controller, limits, @"Temporarily Disable Limit",
                                      BattItemDisableLimit);
    NSMenuItem *disableCountdown = DisplayItem(controller, @"",
                                                BattItemDisableLimitCountdown, NO);
    disableCountdown.hidden = YES;
    [disableLimit addItem:disableCountdown];
    [disableLimit addItem:ActionItem(controller, @"Indefinitely", @"d",
                                      BattItemDisableLimitIndefinitely)];
    [disableLimit addItem:[NSMenuItem separatorItem]];
    [disableLimit addItem:ActionItem(controller, @"1 Hour", @"",
                                      BattItemDisableLimit1Hour)];
    [disableLimit addItem:ActionItem(controller, @"2 Hours", @"",
                                      BattItemDisableLimit2Hours)];
    [disableLimit addItem:ActionItem(controller, @"4 Hours", @"",
                                      BattItemDisableLimit4Hours)];
    [disableLimit addItem:ActionItem(controller, @"8 Hours", @"",
                                      BattItemDisableLimit8Hours)];
    [disableLimit addItem:ActionItem(controller, @"12 Hours", @"",
                                      BattItemDisableLimit12Hours)];
    [disableLimit addItem:ActionItem(controller, @"24 Hours", @"",
                                      BattItemDisableLimit24Hours)];
    [disableLimit addItem:ActionItem(controller, @"2 Days", @"",
                                      BattItemDisableLimit2Days)];
    [disableLimit addItem:ActionItem(controller, @"3 Days", @"",
                                      BattItemDisableLimit3Days)];
    [disableLimit addItem:ActionItem(controller, @"7 Days", @"",
                                      BattItemDisableLimit7Days)];

    NSMenu *heat = AddSubmenu(controller, root, @"Heat Protection: Loading...", BattItemHeatProtection);
    [heat addItem:ActionItem(controller, @"Off", @"", BattItemHeatOff)];
    [heat addItem:ActionItem(controller, @"Strict: pause 32°C, resume 29°C", @"", BattItemHeatStrict)];
    [heat addItem:ActionItem(controller, @"Balanced: pause 33°C, resume 30°C", @"", BattItemHeatBalanced)];
    [heat addItem:ActionItem(controller, @"Relaxed: pause 35°C, resume 32°C", @"", BattItemHeatRelaxed)];
    [heat addItem:[NSMenuItem separatorItem]];
    [heat addItem:ActionItem(controller, @"Custom…", @"", BattItemHeatCustom)];
    [root addItem:ActionItem(controller, @"Keep Awake: closed-lid work", @"", BattItemKeepAwake)];

    [root addItem:[NSMenuItem separatorItem]];
    NSMenu *diagnostics = [[[NSMenu alloc] initWithTitle:@"Diagnostics"] autorelease];
    diagnostics.autoenablesItems = NO;
    NSMenuItem *diagnosticsItem = [[[NSMenuItem alloc] initWithTitle:@"Diagnostics"
                                                             action:nil keyEquivalent:@""] autorelease];
    diagnosticsItem.submenu = diagnostics;
    [root addItem:diagnosticsItem];
    NSMenu *power = AddSubmenu(controller, diagnostics, @"Power Details", BattItemPowerFlow);
    [power addItem:DisplayItem(controller, @"Loading power flow...", BattItemPowerFlowSummary, NO)];
    [power addItem:[NSMenuItem separatorItem]];
    [power addItem:DisplayItem(controller, @"Loading...", BattItemState, NO)];
    [power addItem:DisplayItem(controller, @"Loading...", BattItemCurrentLimit, NO)];
    [power addItem:[NSMenuItem separatorItem]];
    [power addItem:DisplayItem(controller, @"", BattItemPowerSystem, YES)];
    [power addItem:DisplayItem(controller, @"", BattItemPowerAdapter, YES)];
    [power addItem:DisplayItem(controller, @"", BattItemPowerBattery, YES)];
    [controller setPowerItem:BattItemPowerSystem label:@"System" value:0];
    [controller setPowerItem:BattItemPowerAdapter label:@"Adapter" value:0];
    [controller setPowerItem:BattItemPowerBattery label:@"Battery" value:0];

    NSMenuItem *cpuApps = [[[NSMenuItem alloc] initWithTitle:@"Top CPU Apps"
                                                    action:nil keyEquivalent:@""] autorelease];
    controller.cpuAppsMenu = [[[NSMenu alloc] initWithTitle:@"Top CPU Apps"] autorelease];
    cpuApps.submenu = controller.cpuAppsMenu;
    [diagnostics addItem:cpuApps];
    NSMenuItem *memoryApps = [[[NSMenuItem alloc] initWithTitle:@"Top RAM Apps"
                                                       action:nil keyEquivalent:@""] autorelease];
    controller.memoryAppsMenu = [[[NSMenu alloc] initWithTitle:@"Top RAM Apps"] autorelease];
    memoryApps.submenu = controller.memoryAppsMenu;
    [diagnostics addItem:memoryApps];
    NSMenuItem *awakeDiagnostics = [[[NSMenuItem alloc] initWithTitle:@"Keep Awake diagnostics…"
        action:@selector(showKeepAwakeDiagnostics:) keyEquivalent:@""] autorelease];
    awakeDiagnostics.target = controller;
    [diagnostics addItem:[NSMenuItem separatorItem]];
    [diagnostics addItem:awakeDiagnostics];

    [root addItem:ActionItem(controller, @"Upgrade Daemon...", @"u", BattItemUpgrade)];
    [root addItem:ActionItem(controller, @"Install Daemon...", @"i", BattItemInstall)];
    NSMenu *advanced = AddSubmenu(controller, root, @"Advanced", BattItemAdvanced);
    NSMenu *magSafe = AddSubmenu(controller, advanced, @"Control MagSafe LED", BattItemMagSafe);
    [magSafe addItem:ActionItem(controller, @"Enable", @"", BattItemMagSafeEnabled)];
    [magSafe addItem:ActionItem(controller, @"Disable", @"", BattItemMagSafeDisabled)];
    [magSafe addItem:ActionItem(controller, @"Always-off", @"", BattItemMagSafeAlwaysOff)];

    [advanced addItem:ActionItem(controller, @"Prevent Idle Sleep when Charging", @"",
                                  BattItemPreventIdleSleep)];
    [advanced addItem:ActionItem(controller, @"Disable Charging before Sleep", @"",
                                  BattItemDisableChargingPreSleep)];
    [advanced addItem:ActionItem(controller,
                                  @"Prevent System Sleep when Charging (Experimental)", @"",
                                  BattItemPreventSystemSleep)];
    NSMenu *forceDischarge = AddSubmenu(controller, advanced, @"Force Discharge...",
                                        BattItemForceDischarge);
    NSMenuItem *forceDischargeCountdown = DisplayItem(controller, @"",
                                                       BattItemForceDischargeCountdown, NO);
    forceDischargeCountdown.hidden = YES;
    [forceDischarge addItem:forceDischargeCountdown];
    [forceDischarge addItem:ActionItem(controller, @"Stop Force Discharge", @"",
                                        BattItemForceDischargeStop)];
    [forceDischarge addItem:ActionItem(controller, @"Indefinitely", @"",
                                        BattItemForceDischargeIndefinitely)];
    [forceDischarge addItem:[NSMenuItem separatorItem]];
    [forceDischarge addItem:ActionItem(controller, @"1 Hour", @"",
                                        BattItemForceDischarge1Hour)];
    [forceDischarge addItem:ActionItem(controller, @"2 Hours", @"",
                                        BattItemForceDischarge2Hours)];
    [forceDischarge addItem:ActionItem(controller, @"4 Hours", @"",
                                        BattItemForceDischarge4Hours)];
    [forceDischarge addItem:ActionItem(controller, @"8 Hours", @"",
                                        BattItemForceDischarge8Hours)];

    NSMenu *calibration = AddSubmenu(controller, advanced,
                                     @"Auto Calibration (Experimental)...",
                                     BattItemAutoCalibration);
    [calibration addItem:DisplayItem(controller, @"Status: Idle",
                                      BattItemCalibrationStatus, NO)];
    [calibration addItem:ActionItem(controller, @"Start", @"", BattItemCalibrationStart)];
    [calibration addItem:ActionItem(controller, @"Pause", @"", BattItemCalibrationPause)];
    [calibration addItem:ActionItem(controller, @"Resume", @"", BattItemCalibrationResume)];
    [calibration addItem:ActionItem(controller, @"Cancel", @"", BattItemCalibrationCancel)];

    [advanced addItem:[NSMenuItem separatorItem]];
    NSString *versionTitle = [@"Version: " stringByAppendingString:version ?: @""];
    [advanced addItem:DisplayItem(controller, versionTitle, BattItemVersion, NO)];
    [advanced addItem:ActionItem(controller, @"Uninstall Daemon...", @"", BattItemUninstall)];

    [root addItem:ActionItem(controller, @"Quit Menubar App", @"q", BattItemQuit)];
}
