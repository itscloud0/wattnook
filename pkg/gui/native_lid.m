#import "native_internal.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/pwr_mgt/IOPM.h>
#import <dlfcn.h>
#import <math.h>

BOOL WattKeepLidGuard(NSNumber *status, BOOL currentlyGuarded) {
    return status ? status.boolValue : currentlyGuarded;
}

void WattRecordAwakeEvent(NSString *event) {
    // Bounded, local diagnostics: no process names, network addresses or input data.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *stored = [defaults arrayForKey:@"WattNookAwakeEvents"] ?: @[];
    NSMutableArray *events = [NSMutableArray array];
    for (id value in stored) if ([value isKindOfClass:NSString.class] && [value length] < 300) [events addObject:value];
    NSDateFormatter *format = [[[NSDateFormatter alloc] init] autorelease];
    format.locale = [[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease];
    format.dateFormat = @"yyyy-MM-dd HH:mm:ss Z";
    [events addObject:[NSString stringWithFormat:@"%@  %@",[format stringFromDate:NSDate.date],
        event.length > 180 ? [event substringToIndex:180] : event]];
    if (events.count > 64) [events removeObjectsInRange:NSMakeRange(0,events.count-64)];
    [defaults setObject:events forKey:@"WattNookAwakeEvents"];
}
NSString *WattAwakeReport(BattMenuController *controller) {
    NSString *status = !controller.keepAwakeStatus ? @"Unknown" : controller.keepAwakeStatus.boolValue ? @"On" : @"Off";
    if (controller.keepAwakeStatusReading)
        status = [NSString stringWithFormat:@"Refreshing (last confirmed: %@)",status];
    NSArray *events = [NSUserDefaults.standardUserDefaults arrayForKey:@"WattNookAwakeEvents"] ?: @[];
    NSMutableString *report = [NSMutableString stringWithFormat:
        @"Sleep prevention: %@\nStatus check: %@\nDisplay guard: %@\n\nRemote access is not monitored. Keeping macOS awake does not confirm a Codex connection.\n\nRecent events (local time):\n",
        status,controller.keepAwakeError ?: @"OK",controller.lidGuardError ?: (controller.lidGuard ? @"Running" : @"Off")];
    for (id event in events) if ([event isKindOfClass:NSString.class] && [event length] < 300) [report appendFormat:@"%@\n",event];
    if (!events.count) [report appendString:@"No events recorded yet.\n"];
    return report;
}

NSDictionary *WattLidBrightnessPlan(BOOL enabled, BOOL closed, NSNumber *current, NSNumber *saved) {
    if (!current || !isfinite(current.doubleValue) || current.doubleValue < 0 || current.doubleValue > 1) return nil;
    BOOL validSaved = saved && isfinite(saved.doubleValue) && saved.doubleValue > 0 && saved.doubleValue <= 1;
    if (enabled && closed) {
        if (current.doubleValue == 0) return nil;
        return @{@"action":@"dim", @"level":validSaved ? saved : current};
    }
    if (!validSaved) return nil;
    // Do not overwrite a brightness the user/system already restored or changed.
    if (current.doubleValue > 0.01) return @{@"action":@"forget"};
    return @{@"action":@"restore", @"level":saved};
}

static NSString *const SavedBrightnessKey = @"WattNookClosedLidBrightness";
typedef int (*BrightnessGet)(CGDirectDisplayID, float *);
typedef int (*BrightnessSet)(CGDirectDisplayID, float);

@interface WattLidGuard : NSObject {
    io_service_t _root;
    io_object_t _interest;
    IONotificationPortRef _port;
    BOOL _enabled;
    float _lastOpenBrightness;
    NSNumber *_lastClosed;
    NSTimeInterval _lastHeartbeat;
}
@property(nonatomic, assign) BattMenuController *controller;
- (void)start;
- (void)reconcile;
- (void)stop;
@end

static void LidChanged(void *context, io_service_t service, uint32_t message, void *argument) {
    (void)service; (void)argument;
    if (message == kIOPMMessageClamshellStateChange) {
        @autoreleasepool { [(WattLidGuard *)context reconcile]; }
    }
}

@implementation WattLidGuard
- (void)problem:(NSString *)problem {
    if (![self.controller.lidGuardError isEqual:problem] && problem) WattRecordAwakeEvent(problem);
    self.controller.lidGuardError = problem;
}
- (void)workspaceEvent:(NSNotification *)event {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self workspaceEvent:event]; });
        return;
    }
    if (!_enabled) return;
    if ([event.name isEqual:NSWorkspaceWillSleepNotification]) WattRecordAwakeEvent(@"macOS will sleep while Keep Awake is enabled");
    else { WattRecordAwakeEvent(@"macOS woke"); self.controller.keepAwakeStatusTime = 0; [self reconcile]; }
}
- (void)start {
    if (!_enabled) {
        NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
        [center addObserver:self selector:@selector(workspaceEvent:) name:NSWorkspaceWillSleepNotification object:nil];
        [center addObserver:self selector:@selector(workspaceEvent:) name:NSWorkspaceDidWakeNotification object:nil];
        WattRecordAwakeEvent(@"Keep Awake guard started");
    }
    _enabled = YES;
    [self cleanupNotifications];
    _root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (!_root) { [self problem:@"Lid service unavailable"]; return; }
    _port = IONotificationPortCreate(kIOMainPortDefault);
    if (!_port) { [self problem:@"Lid notification port unavailable"]; return; }
    CFRunLoopSourceRef source = IONotificationPortGetRunLoopSource(_port);
    if (!source) { [self problem:@"Lid notification source unavailable"]; return; }
    CFRunLoopAddSource(CFRunLoopGetMain(),source,kCFRunLoopCommonModes);
    if (IOServiceAddInterestNotification(_port,_root,kIOGeneralInterest,LidChanged,self,&_interest) != KERN_SUCCESS) {
        [self problem:@"Lid notifications unavailable; display guard cannot run"];
        return;
    }
    [self reconcile];
}
- (void)reconcile {
    if (_enabled && (!_root || !_interest)) { [self start]; return; }
    CFTypeRef lid = _root ? IORegistryEntryCreateCFProperty(_root,CFSTR(kAppleClamshellStateKey),kCFAllocatorDefault,0) : NULL;
    if (_enabled && (!lid || CFGetTypeID(lid) != CFBooleanGetTypeID())) {
        if (lid) CFRelease(lid);
        [self problem:@"Lid state unavailable"];
        return;
    }
    BOOL closed = lid && CFGetTypeID(lid) == CFBooleanGetTypeID() && CFBooleanGetValue(lid);
    if (lid) CFRelease(lid);
    if (_enabled) {
        NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
        if (!_lastClosed || _lastClosed.boolValue != closed) {
            WattRecordAwakeEvent(closed ? @"Lid closed" : @"Lid opened");
            [_lastClosed release]; _lastClosed = [@(closed) retain];
        } else if (now-_lastHeartbeat >= 900) {
            WattRecordAwakeEvent(closed ? @"Guard running; lid closed" : @"Guard running; lid open");
        }
        // At most four heartbeats/hour: 64 slots can cover an overnight session.
        if (now-_lastHeartbeat >= 900) _lastHeartbeat = now;
    }
    NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:SavedBrightnessKey];
    if (![saved isKindOfClass:NSNumber.class]) saved = nil;
    if (!_enabled && !saved) { [self problem:nil]; return; }
    static void *framework;
    static BrightnessGet get;
    static BrightnessSet set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",RTLD_LAZY);
        if (framework) {
            get = (BrightnessGet)dlsym(framework,"DisplayServicesGetBrightness");
            set = (BrightnessSet)dlsym(framework,"DisplayServicesSetBrightness");
        }
    });
    if (!get || !set) { [self problem:@"Brightness API unavailable"]; return; }
    CGDirectDisplayID displays[32]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(32,displays,&count) != kCGErrorSuccess) { [self problem:@"Cannot read display list"]; return; }
    for (uint32_t i=0; i<count; i++) {
        if (!CGDisplayIsBuiltin(displays[i])) continue;
        float brightness = 0;
        if (get(displays[i],&brightness) != 0) { [self problem:@"Cannot read built-in brightness"]; return; }
        if (!isfinite(brightness) || brightness < 0 || brightness > 1) { [self problem:@"Invalid brightness reading"]; return; }
        if (!closed && isfinite(brightness) && brightness > 0 && brightness <= 1)
            _lastOpenBrightness = brightness;
        // Some panels report zero immediately on lid close. Still request a real
        // hardware dim using the last valid open reading, never save a false zero.
        if (_enabled && closed && !saved && brightness == 0 && _lastOpenBrightness > 0)
            brightness = _lastOpenBrightness;
        NSDictionary *plan = WattLidBrightnessPlan(_enabled,closed,@(brightness),saved);
        if (!plan) { [self problem:nil]; return; }
        NSString *action = plan[@"action"];
        if ([action isEqual:@"dim"]) {
            // Persist BEFORE dimming so a later launch can recover after a crash.
            [NSUserDefaults.standardUserDefaults setObject:plan[@"level"] forKey:SavedBrightnessKey];
            [NSUserDefaults.standardUserDefaults synchronize];
            if (set(displays[i],0) != 0) [self problem:@"Closed-lid brightness write failed"];
            else [self problem:nil];
        } else if ([action isEqual:@"forget"] || set(displays[i],[plan[@"level"] floatValue]) == 0) {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:SavedBrightnessKey];
            [self problem:nil];
        } else {
            [self problem:@"Brightness restore failed; saved level retained for retry"];
        }
        return; // Never affect an external display.
    }
    [self problem:closed ? nil : @"Built-in display unavailable"];
}
- (void)stop {
    BOOL wasEnabled = _enabled;
    _enabled = NO;
    [self reconcile];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [self cleanupNotifications];
    if (wasEnabled) WattRecordAwakeEvent(@"Keep Awake guard stopped");
}
- (void)cleanupNotifications {
    if (_interest) { IOObjectRelease(_interest); _interest = 0; }
    if (_port) {
        CFRunLoopSourceRef source = IONotificationPortGetRunLoopSource(_port);
        if (source) CFRunLoopRemoveSource(CFRunLoopGetMain(),source,kCFRunLoopCommonModes);
        IONotificationPortDestroy(_port); _port = NULL;
    }
    if (_root) { IOObjectRelease(_root); _root = 0; }
}
- (void)dealloc { [self stop]; [_lastClosed release]; [super dealloc]; }
@end

void WattSyncLidGuard(BattMenuController *controller, BOOL enabled) {
    if (enabled) {
        if (!controller.lidGuard) {
            WattLidGuard *guard = [[[WattLidGuard alloc] init] autorelease];
            guard.controller = controller;
            controller.lidGuard = guard;
            [guard start];
        } else [(WattLidGuard *)controller.lidGuard reconcile];
    } else if (controller.lidGuard) {
        [(WattLidGuard *)controller.lidGuard stop];
        controller.lidGuard = nil;
    } else if ([NSUserDefaults.standardUserDefaults objectForKey:SavedBrightnessKey]) {
        WattLidGuard *recovery = [[[WattLidGuard alloc] init] autorelease];
        recovery.controller = controller;
        [recovery stop];
    }
}
