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
        for (NSInteger i = 0; i < WATT_AI_PROVIDERS*2; i++) _aiUsage[i] = -1;
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
        [self applyAIUsagePreference];
        BattUpdateBattery(self);
    }
    return self;
}

- (void)showStorageReview:(id)sender { WattShowStorageReview(self); }

- (void)dealloc {
    WattCloseStorageReview(self);
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
    [_menuPageTimer invalidate];
    [_menuPageTimer release];
    [_aiUsageNotes release];
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
    [_keepAwakeTarget release];
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
    // Recycle after AppKit finishes closing the current popover.
    dispatch_async(dispatch_get_main_queue(), ^{ BattRecyclePopover(self); });
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

- (void)toggleTopUpFromPopover:(NSButton *)sender {
    (void)sender;
    battMenuAction(_handle, BattItemTopUp, NO);
}

// One contextual button: Discharge when the charge is above the limit (or
// already discharging), Top Up otherwise. Its tag holds the shown action.
- (void)chargeActionFromPopover:(NSButton *)sender {
    BattMenuItem item = sender.tag == BattItemDischargeToLimit || sender.tag == BattItemUpgrade ||
        sender.tag == BattItemInstall ? (BattMenuItem)sender.tag : BattItemTopUp;
    battMenuAction(_handle, item, NO);
}

// Off, On, or On when plugged in, from the popover's Keep Awake button.
- (void)showKeepAwakeOptions:(NSButton *)sender {
    BOOL follows = WattKeepAwakeFollowsPower(), on = self.keepAwakeStatus.boolValue;
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Keep Awake"] autorelease];
    NSArray *titles = @[@"Off", @"On", @"On when plugged in"];
    for (NSInteger mode = 0; mode < 3; mode++) {
        NSMenuItem *item = [menu addItemWithTitle:titles[mode] action:@selector(selectKeepAwakeMode:) keyEquivalent:@""];
        item.target = self; item.tag = mode;
        item.state = (mode == 2 ? follows : !follows && self.keepAwakeStatus && on == (mode == 1))
            ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [menu itemAtIndex:2].toolTip = @"Sleep stays off while a charger is connected and returns 30 seconds after you unplug.";
    [self showMenu:menu fromButton:sender];
}

- (void)selectKeepAwakeMode:(NSMenuItem *)sender {
    if (self.keepAwakeChanging || self.keepAwakeTogglePending) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (sender.tag < 2) {
        [defaults removeObjectForKey:@"WattNookKeepAwakeMode"];
        self.keepAwakeTarget = @(sender.tag == 1);
    } else {
        if (![defaults boolForKey:@"WattNookKeepAwakeWarningAccepted"]) {
            NSAlert *confirm = [[[NSAlert alloc] init] autorelease];
            confirm.messageText = @"Keep the Mac awake whenever it is plugged in?";
            confirm.informativeText = @"While a charger is connected, sleep is disabled for the entire Mac, also with the lid closed. Sleep returns 30 seconds after you unplug, while WattNook is running. Switching happens without a password only when WattNook's sleep-toggle rule is installed.";
            [confirm addButtonWithTitle:@"Turn On"];
            [confirm addButtonWithTitle:@"Cancel"];
            if ([confirm runModal] != NSAlertFirstButtonReturn) return;
            [defaults setBool:YES forKey:@"WattNookKeepAwakeWarningAccepted"];
        }
        [defaults setObject:@"plugged" forKey:@"WattNookKeepAwakeMode"];
        self.keepAwakeUnpluggedSince = 0;
        self.keepAwakeRetryAfter = 0;
        self.keepAwakeTarget = @(self.powerFlowView.pluggedIn);
    }
    self.keepAwakeQuiet = NO;
    self.keepAwakeTogglePending = YES;
    [self requestKeepAwakeStatus];
    [self refreshPopoverControls];
}

// In "On when plugged in", follow the charger: on at once, off only after
// the unplugged grace period. Failures back off instead of retrying each poll.
- (void)followPowerForKeepAwake:(BOOL)pluggedIn {
    if (!WattKeepAwakeFollowsPower() || ![self keepAwakeToolPath]) { self.keepAwakeUnpluggedSince = 0; return; }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (pluggedIn) self.keepAwakeUnpluggedSince = 0;
    else if (self.keepAwakeUnpluggedSince == 0) self.keepAwakeUnpluggedSince = now;
    BOOL wanted = WattKeepAwakeWanted(pluggedIn, pluggedIn ? 0 : now-self.keepAwakeUnpluggedSince);
    if (!self.keepAwakeStatus || self.keepAwakeStatus.boolValue == wanted || now < self.keepAwakeRetryAfter ||
        self.keepAwakeChanging || self.keepAwakeTogglePending || self.keepAwakeStatusReading) return;
    self.keepAwakeTarget = @(wanted);
    self.keepAwakeQuiet = YES;
    self.keepAwakeTogglePending = YES;
    [self requestKeepAwakeStatus];
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

// The system metrics stay longest; each usage page is a short glance.
static const NSTimeInterval WattMenuSystemDwell = 10, WattMenuUsageDwell = 5;
static const NSTimeInterval WattUsageRefreshInterval = 300;

// The Claude and OpenAI marks, from Simple Icons (CC0; the marks belong to
// Anthropic and OpenAI), and xAI's Grok mark, drawn black so the item's
// template tints them.
static NSString *const WattClaudeMarkPath = @"m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z";
static NSString *const WattOpenAIMarkPath = @"M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z";

static NSString *const WattGrokMarkPath = @"M13.2371 21.0407L24.3186 12.8506C24.8619 12.4491 25.6384 12.6057 25.8973 13.2294C27.2597 16.5185 26.651 20.4712 23.9403 23.1851C21.2297 25.8989 17.4581 26.4941 14.0108 25.1386L10.2449 26.8843C15.6463 30.5806 22.2053 29.6665 26.304 25.5601C29.5551 22.3051 30.562 17.8683 29.6205 13.8673L29.629 13.8758C28.2637 7.99809 29.9647 5.64871 33.449 0.844576C33.5314 0.730667 33.6139 0.616757 33.6964 0.5L29.1113 5.09055V5.07631L13.2343 21.0436M10.9503 23.0313C7.07343 19.3235 7.74185 13.5853 11.0498 10.2763C13.4959 7.82722 17.5036 6.82767 21.0021 8.2971L24.7595 6.55998C24.0826 6.07017 23.215 5.54334 22.2195 5.17313C17.7198 3.31926 12.3326 4.24192 8.67479 7.90126C5.15635 11.4239 4.0499 16.8403 5.94992 21.4622C7.36924 24.9165 5.04257 27.3598 2.69884 29.826C1.86829 30.7002 1.0349 31.5745 0.36364 32.5L10.9474 23.0341";

static NSImage *WattAIGlyph(NSString *provider) {
    static NSMutableDictionary *marks;
    if (!marks) marks = [[NSMutableDictionary alloc] init];
    if (!marks[provider]) {
        BOOL grok = [provider isEqual:@"grok"];
        NSString *svg = [NSString stringWithFormat:@"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"%@\">"
            "<path d=\"%@\"/></svg>", grok ? @"0 0 34.06 33" : @"0 0 24 24",
            grok ? WattGrokMarkPath : [provider isEqual:@"claude"] ? WattClaudeMarkPath : WattOpenAIMarkPath];
        NSImage *mark = [[[NSImage alloc] initWithData:[svg dataUsingEncoding:NSUTF8StringEncoding]] autorelease];
        mark.size = NSMakeSize(11,11);
        if (mark) marks[provider] = mark;
    }
    return marks[provider];
}

static NSDictionary *WattStackFont(CGFloat size) {
    return @{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightMedium],
             NSForegroundColorAttributeName:NSColor.whiteColor};
}

static NSDictionary *WattStackAttributes(NSUInteger rows) { return WattStackFont(rows > 1 ? 8.5 : 11); }

// The pages' 11 pt mark plus its gap before the labels.
static const CGFloat WattUsageLead = 14;
// From the end of the labels to the start of a "100%"-wide value column.
static const CGFloat WattStackGap = 3;
// From the "%" to the battery: one menu-bar item's worth of breathing room,
// the same on every page because values are right-aligned.
static const CGFloat WattBatteryGap = 8;

// The metrics page's mark while usage pages rotate, in the logos' place.
static NSImage *WattSystemGlyph(void) {
    static NSImage *chip;
    if (!chip) chip = [[[NSImage imageWithSystemSymbolName:@"cpu" accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightMedium]] retain];
    return chip;
}

// Page 0 is the system metrics, then each shown provider (page n+1 for
// WattAIProviderIDs()[n]) in the user's order, while it has data.
- (NSArray *)menuPages {
    NSMutableArray *pages = [NSMutableArray arrayWithObject:@0];
    if (!WattMenuAIUsage()) return pages;
    for (NSString *provider in WattAIUsageShown()) {
        NSUInteger index = [WattAIProviderIDs() indexOfObject:provider];
        if (_aiUsage[index*2] >= 0 || _aiUsage[index*2+1] >= 0) [pages addObject:@(index+1)];
    }
    return pages;
}

static void WattPermutations(NSArray *items, NSArray *prefix, NSMutableArray *into) {
    if (!items.count) { [into addObject:prefix]; return; }
    for (id item in items) {
        NSMutableArray *rest = [[items mutableCopy] autorelease];
        [rest removeObject:item];
        WattPermutations(rest, [prefix arrayByAddingObject:item], into);
    }
}

// Which AI services rotate through the menu bar, and in what order.
- (void)showAIUsageOptions:(NSButton *)sender {
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"AI usage"] autorelease];
    NSArray *order = WattAIUsageOrder(), *shown = WattAIUsageShown();
    for (NSString *provider in order) {
        NSMenuItem *item = [menu addItemWithTitle:WattAIProviderName(provider)
            action:@selector(toggleAIProvider:) keyEquivalent:@""];
        item.target = self; item.representedObject = provider;
        item.state = [shown containsObject:provider] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *orderItem = [menu addItemWithTitle:@"Order" action:nil keyEquivalent:@""];
    NSMenu *orders = [[[NSMenu alloc] initWithTitle:@"Order"] autorelease];
    NSMutableArray *permutations = [NSMutableArray array];
    WattPermutations(order, @[], permutations);
    [permutations sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [@([a isEqual:order] ? 0 : 1) compare:@([b isEqual:order] ? 0 : 1)];
    }];
    for (NSArray *permutation in permutations) {
        NSMutableArray *names = [NSMutableArray array];
        for (NSString *provider in permutation) [names addObject:WattAIProviderName(provider)];
        NSMenuItem *item = [orders addItemWithTitle:[names componentsJoinedByString:@" → "]
            action:@selector(setAIUsageOrder:) keyEquivalent:@""];
        item.target = self; item.representedObject = permutation;
        item.state = [permutation isEqual:order] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    orderItem.submenu = orders;
    [self showMenu:menu fromButton:sender];
}

- (void)toggleAIProvider:(NSMenuItem *)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray *hidden = [[[defaults arrayForKey:@"WattNookAIUsageHidden"] mutableCopy] autorelease] ?: [NSMutableArray array];
    if ([hidden containsObject:sender.representedObject]) [hidden removeObject:sender.representedObject];
    else [hidden addObject:sender.representedObject];
    [defaults setObject:hidden forKey:@"WattNookAIUsageHidden"];
    [self refreshStatusImage];
}

- (void)setAIUsageOrder:(NSMenuItem *)sender {
    [NSUserDefaults.standardUserDefaults setObject:sender.representedObject forKey:@"WattNookAIUsageOrder"];
    [self refreshStatusImage];
}

- (void)scheduleMenuPage {
    [self.menuPageTimer invalidate];
    self.menuPageTimer = [NSTimer scheduledTimerWithTimeInterval:_menuPage ? WattMenuUsageDwell : WattMenuSystemDwell
        target:self selector:@selector(advanceMenuPage:) userInfo:nil repeats:NO];
    self.menuPageTimer.tolerance = 0.5;
}

- (void)requestAIUsageIfStale {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (_aiUsageRequestedAt && now-_aiUsageRequestedAt < WattUsageRefreshInterval) return;
    _aiUsageRequestedAt = now;
    battAIUsageRequested(_handle);
}

- (void)advanceMenuPage:(NSTimer *)timer {
    (void)timer;
    [self requestAIUsageIfStale];
    NSArray *pages = [self menuPages];
    NSUInteger index = [pages indexOfObject:@(_menuPage)];
    _menuPage = [pages[index == NSNotFound ? 0 : (index+1)%pages.count] integerValue];
    [self refreshStatusImage];
    [self scheduleMenuPage];
}

- (void)applyAIUsagePreference {
    if (WattMenuAIUsage()) {
        if (!self.menuPageTimer.isValid) [self scheduleMenuPage];
        [self requestAIUsageIfStale];
    } else {
        [self.menuPageTimer invalidate]; self.menuPageTimer = nil;
        for (NSInteger i = 0; i < WATT_AI_PROVIDERS*2; i++) _aiUsage[i] = -1;
        self.aiUsageNotes = nil;
        _menuPage = 0; _aiUsageRequestedAt = 0;
    }
    [self refreshStatusImage];
}

- (void)setAIUsage:(const double *)usage notes:(NSArray *)notes {
    if (!WattMenuAIUsage()) return; // a late answer after the setting went off
    for (NSInteger i = 0; i < WATT_AI_PROVIDERS*2; i++) _aiUsage[i] = usage[i];
    self.aiUsageNotes = notes;
    [self refreshStatusImage];
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
    // With the icon on, the number sits inside it, as macOS draws it.
    if (percent && icon && self.batteryIconShowsPercent) percent = NO;
    NSArray *pages = [self menuPages], *systemLabels = [[labels copy] autorelease];
    if (![pages containsObject:@(_menuPage)]) _menuPage = 0;
    NSImage *glyph = nil;
    NSString *usageNote = nil;
    if (_menuPage) {
        NSInteger base = (_menuPage-1)*2;
        NSString *provider = WattAIProviderIDs()[_menuPage-1];
        // Grok has only a weekly pool: its "wk" keeps the row it has on the
        // other pages, above it stays blank.
        BOOL weekOnly = [provider isEqual:@"grok"];
        labels = [NSMutableArray array];
        values = [NSMutableArray array];
        for (NSInteger i = 0; i < 2; i++) {
            BOOL blank = weekOnly && i == 0;
            [labels addObject:blank ? @"" : i ? @"WKL" : @"5HR"];
            [values addObject:blank ? @"" : _aiUsage[base+i] < 0 ? @"—" :
                [NSString stringWithFormat:@"%.0f%%",_aiUsage[base+i]]];
        }
        glyph = WattAIGlyph(provider);
        NSString *note = _menuPage-1 < (NSInteger)self.aiUsageNotes.count ? self.aiUsageNotes[_menuPage-1] : nil;
        usageNote = note.length ? note : nil;
    }
    // While usage pages rotate, every page is one grid: a mark at the left
    // (a CPU chip, or the service's logo), labels ending in one column, the
    // percentages right-aligned in the next, and one item width. Only the
    // mark, labels and digits change as pages turn; nothing moves.
    BOOL rotating = WattMenuAIUsage();
    if (rotating && !_menuPage && labels.count) glyph = WattSystemGlyph();
    NSDictionary *attributes = _menuPage ? WattStackAttributes(2) : WattStackAttributes(labels.count);
    NSDictionary *systemFont = WattStackAttributes(systemLabels.count), *usageFont = WattStackAttributes(2);
    CGFloat lead = rotating ? WattUsageLead : 0, labelWidth = 0;
    CGFloat valueWidth = labels.count ? [@"100%" sizeWithAttributes:attributes].width : 0;
    for (NSString *label in labels) labelWidth = MAX(labelWidth,[label sizeWithAttributes:attributes].width);
    if (rotating) {
        for (NSString *label in systemLabels) labelWidth = MAX(labelWidth,[label sizeWithAttributes:systemFont].width);
        for (NSString *label in @[@"5HR",@"WKL"]) labelWidth = MAX(labelWidth,[label sizeWithAttributes:usageFont].width);
        valueWidth = MAX([@"100%" sizeWithAttributes:usageFont].width,
            systemLabels.count ? [@"100%" sizeWithAttributes:systemFont].width : 0);
    }
    // Reserve "100%" so the item (and the popover anchored to it) keeps its
    // width as readings change; right-aligned, the "%" never moves either.
    CGFloat labelRight = lead+1+labelWidth, valueRight = labelRight+WattStackGap+valueWidth;
    CGFloat stackWidth = labels.count || rotating ? ceil(valueRight) : 0;
    NSString *charge = self.powerFlowView.chargePercent < 0 ? @"—%" :
        [NSString stringWithFormat:@"%ld%%",(long)self.powerFlowView.chargePercent];
    NSDictionary *chargeStyle = @{NSFontAttributeName:
        [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName:NSColor.whiteColor};
    CGFloat percentGap = percent && stackWidth > 0 ? 10 : 0;
    CGFloat percentWidth = percent ? percentGap+ceil(MAX([charge sizeWithAttributes:chargeStyle].width,
        [@"100%" sizeWithAttributes:chargeStyle].width))+4 : 0;
    CGFloat iconGap = icon && (stackWidth > 0 || percent) ? WattBatteryGap : 0;
    CGFloat iconWidth = self.batteryIcon ? self.batteryIcon.size.width : 25;
    NSImage *combined = [[[NSImage alloc] initWithSize:
        NSMakeSize(MAX(24,stackWidth+percentWidth+iconGap+(icon ? iconWidth+1 : 0)),24)] autorelease];
    [combined lockFocus];
    CGFloat height = [@"100%" sizeWithAttributes:attributes].height;
    if (glyph) {
        // The chip symbol carries its own margin; enlarge it so its ink spans
        // the same 11 pt as the logos.
        CGFloat box = _menuPage ? 11 : 13.5;
        NSSize size = glyph.size; CGFloat fit = box/MAX(size.width,size.height);
        [glyph drawInRect:NSMakeRect(6.5-size.width*fit/2,12-size.height*fit/2,size.width*fit,size.height*fit)];
    }
    for (NSInteger i=0;i<labels.count;i++) {
        CGFloat y = (24-height)/2 + ((labels.count-1)/2.0-i)*8;
        [labels[i] drawAtPoint:NSMakePoint(labelRight-[labels[i] sizeWithAttributes:attributes].width,y)
            withAttributes:attributes];
        [values[i] drawAtPoint:NSMakePoint(valueRight-[values[i] sizeWithAttributes:attributes].width,y)
            withAttributes:attributes];
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
    if (usageNote.length) [descriptions addObject:usageNote];
    else for (NSInteger i=0;i<labels.count;i++)
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
    // A healthy install keeps the live metrics image; the generic symbol is
    // only for setup states. Replacing it here collapsed the menu-bar item
    // after every action until the next stats tick.
    if (installed && capable && !needsUpgrade) { [self refreshStatusImage]; return; }
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
    if (known) [self followPowerForKeepAwake:pluggedIn];
    NSBundle *controlCenter = [NSBundle bundleWithPath:@"/System/Library/CoreServices/ControlCenter.app"];
    NSImage *outline = [controlCenter imageForResource:@"battery-outline"];
    NSImage *cap = [controlCenter imageForResource:@"battery-cap"];
    NSString *overlayName = !pluggedIn ? nil : (charging ? @"battery-bolt" : @"battery-plug");
    NSImage *overlay = overlayName == nil ? nil : [controlCenter imageForResource:overlayName];
    NSImage *mask = overlayName == nil ? nil :
        [controlCenter imageForResource:[overlayName stringByAppendingString:@"-mask"]];
    BOOL lowPower = NSProcessInfo.processInfo.lowPowerModeEnabled;
    BOOL percentInIcon = WattMenuBatteryIcon() && [WattMenuMetrics() containsObject:@"Battery"];
    NSImage *image = WattSystemMenuBattery(charge,pluggedIn,charging,present,needsService,lowPower,percentInIcon);
    BOOL nativeImage = image != nil;
    self.batteryIconShowsPercent = nativeImage && known && percentInIcon;
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
    self.batteryIconHasColor = nativeImage && known && (lowPower || charge <= 10);
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
    if (!inconsistent)
        [self.powerFlowView recordMacWatts:system charging:battery > 0.25 heat:heatPaused onBattery:adapter <= 0.1];
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
    // Switching by hand ends "On when plugged in".
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WattNookKeepAwakeMode"];
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
    BOOL enable = self.keepAwakeTarget ? self.keepAwakeTarget.boolValue : !active;
    BOOL quiet = self.keepAwakeQuiet;
    self.keepAwakeTarget = nil; self.keepAwakeQuiet = NO;
    BOOL accepted = [NSUserDefaults.standardUserDefaults boolForKey:@"WattNookKeepAwakeWarningAccepted"];
    // The fresh read already matches, or an automatic switch lacks consent.
    if (enable == active || (quiet && enable && !accepted)) { [self refreshPopoverControls]; return; }
    NSString *tool = [self keepAwakeToolPath];
    // A confirmation dialog runs a nested event loop: pause polling before it opens.
    self.keepAwakeChanging = YES;
    [self refreshPopoverControls];
    NSTask *task = [[[NSTask alloc] init] autorelease];
    task.executableURL = [NSURL fileURLWithPath:tool];
    if (enable && !accepted) {
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
    NSString *direction = enable ? @"--enable" : @"--disable";
    task.arguments = quiet ? @[direction,@"--no-prompt"] : @[direction];
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
                if (quiet) {
                    // Automatic switches report inline and back off; never a dialog.
                    NSString *detail = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
                    detail = [detail stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    BOOL failed = finished.terminationStatus != 0;
                    if (failed) {
                        self.keepAwakeError = detail.length ? detail : @"macOS did not confirm the change.";
                        self.keepAwakeRetryAfter = NSProcessInfo.processInfo.systemUptime + 300;
                    }
                    WattRecordAwakeEvent(failed ? [@"Automatic Keep Awake failed: " stringByAppendingString:self.keepAwakeError] :
                        enable ? @"Keep Awake on: charger connected" : @"Keep Awake off: on battery");
                    [self refreshPopoverControls];
                    return;
                }
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
    [root addItem:ActionItem(controller, @"Top Up to 100%", @"", BattItemTopUp)];
    [root addItem:ActionItem(controller, @"Discharge to Limit", @"", BattItemDischargeToLimit)];
    NSMenu *sailing = AddSubmenu(controller, root, @"Sailing", BattItemSailing);
    [sailing addItem:ActionItem(controller, @"Off", @"", BattItemSailingOff)];
    [sailing addItem:ActionItem(controller, @"5% below the limit", @"", BattItemSailing5)];
    [sailing addItem:ActionItem(controller, @"10% below the limit", @"", BattItemSailing10)];
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
