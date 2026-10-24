#import "../../pkg/gui/native_internal.h"
#import <unistd.h>
#import <signal.h>

extern void WattReadSleepStatus(NSString *, NSArray *, NSTimeInterval,
    void (^)(NSNumber *, NSString *)) __attribute__((weak_import));

static void Check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr,"FAIL: %s\n",message); exit(1); }
}
static BOOL WaitFor(BOOL (^ready)(void), NSTimeInterval timeout) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime+timeout;
    while (!ready() && NSProcessInfo.processInfo.systemUptime < deadline)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return ready();
}

void battMenuWillOpen(uintptr_t handle) { (void)handle; }
void battMenuTimerFired(uintptr_t handle) { (void)handle; }
void battMenuAction(uintptr_t handle, int item, bool checked) { (void)handle; (void)item; (void)checked; }
bool battMenuSetLimit(uintptr_t handle, int limit) { (void)handle; (void)limit; return true; }
void battMainCallback(uintptr_t handle) { (void)handle; }
void battStorageAction(uintptr_t handle,uint64_t generation,int action) {}
void battAIUsageRequested(uintptr_t handle) { (void)handle; }

static NSString *testExecutable;
@interface SlowStatusController : BattMenuController
@property(nonatomic, copy) NSString *fixture;
@property(nonatomic, assign) NSUInteger reads;
@property(nonatomic, assign) NSUInteger toggles;
@property(nonatomic, assign) BOOL guarded;
@end
@implementation SlowStatusController
- (NSString *)keepAwakeToolPath { return testExecutable; }
- (void)readKeepAwakeStatus:(void (^)(NSNumber *, NSString *))completion {
    self.reads++;
    WattReadSleepStatus(testExecutable,@[@"--fake-pmset",self.fixture ?: @"slow-off"],0.8,completion);
}
- (void)syncKeepAwakeLidGuard { self.guarded = WattKeepLidGuard(self.keepAwakeStatus,self.guarded); }
- (void)performKeepAwakeToggle { self.toggles++; }
- (void)dealloc { [_fixture release]; [super dealloc]; }
@end

int main(int argc, const char *argv[]) {
    if (argc == 2 && strcmp(argv[1],"--status") == 0) {
        usleep(350000);
        puts("off");
        return 0;
    }
    if (argc == 3 && strcmp(argv[1],"--fake-pmset") == 0) {
        if (strcmp(argv[2],"slow-off") == 0) { usleep(350000); puts("SleepDisabled 0"); }
        else if (strcmp(argv[2],"on") == 0) puts("Power settings:\n\tSleepDisabled\t1\n");
        else if (strcmp(argv[2],"duplicate") == 0) puts("SleepDisabled 1\nSleepDisabled 0");
        else if (strcmp(argv[2],"bad") == 0) puts("SleepDisabled unknown");
        else if (strcmp(argv[2],"fail") == 0) { puts("SleepDisabled 1"); return 7; }
        else if (strcmp(argv[2],"flood") == 0) { for (int i=0;i<20000;i++) puts("SleepDisabled 1"); }
        else if (strcmp(argv[2],"hang") == 0 || strcmp(argv[2],"closed-output") == 0) {
            signal(SIGTERM,SIG_IGN);
            if (strcmp(argv[2],"closed-output") == 0) close(STDOUT_FILENO);
            sleep(5); // Bounds even a broken test runner; correct runner kills it much sooner.
        }
        return 0;
    }
    @autoreleasepool {
        [NSApplication sharedApplication];
        Check(NSBundle.mainBundle.bundleIdentifier == nil,"status tests must run outside the installed app bundle");
        if (argc == 2 && strcmp(argv[1],"--live") == 0) {
            __block BOOL done = NO;
            WattReadSleepStatus(@"/usr/bin/pmset",@[@"-g"],2,^(NSNumber *status, NSString *error) {
                Check(status != nil && error == nil,"host sleep setting readable");
                printf("Live sleep prevention: %s\n",status.boolValue ? "on" : "off"); done = YES;
            });
            Check(WaitFor(^BOOL { return done; },3),"live status read completes");
            NSString *report = WattSleepBlockerReport();
            Check(![report hasPrefix:@"Sleep blockers: unavailable"],"host assertions readable");
            Check([report containsString:@"\n"] && report.length < 15000,"live assertion report bounded and multiline");
            printf("Live assertion report: %lu characters (process details not printed)\n",(unsigned long)report.length);
            return 0;
        }
        testExecutable = [NSString stringWithUTF8String:argv[0]];
        // Isolated executable has no app prefs/helper; off cannot start a lid guard.
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WattNookClosedLidBrightness"];
        SlowStatusController *controller = [[SlowStatusController alloc] init];
        NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
        [controller isKeepAwakeActive];
        NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime-start;
        if (elapsed >= 0.1) {
            fprintf(stderr,"FAIL: status refresh blocked caller for %.3f seconds\n",elapsed);
            return 1;
        }
        Check(WattReadSleepStatus != NULL,"bounded status reader exists");
        for (int i=0;i<20;i++) [controller isKeepAwakeActive];
        Check(controller.reads == 1,"timer/UI refreshes coalesce into one pending read");
        Check(WaitFor(^BOOL { return controller.keepAwakeStatus != nil; },2),"slow result arrives without blocking UI");
        Check(!controller.keepAwakeStatus.boolValue,"valid off result applied");
        controller.keepAwakeStatus = @YES; controller.guarded = YES;
        controller.fixture = @"bad"; controller.keepAwakeStatusTime = 0;
        [controller isKeepAwakeActive];
        Check(controller.guarded,"pending read retains last display guard");
        Check(WaitFor(^BOOL { return controller.keepAwakeError != nil; },2),"malformed result becomes visible error");
        Check(controller.keepAwakeStatus == nil && controller.guarded,"unknown result cannot switch off existing display guard");
        controller.keepAwakeChanging = YES; controller.keepAwakeStatusTime = 0;
        NSUInteger readsBeforeWrite = controller.reads;
        [controller isKeepAwakeActive];
        Check(controller.reads == readsBeforeWrite,"status query cannot overlap a write/confirmation");
        controller.keepAwakeChanging = NO;
        controller.fixture = @"slow-off";
        [controller toggleKeepAwake]; [controller toggleKeepAwake];
        Check(controller.toggles == 0,"toggle waits for fresh status");
        Check(WaitFor(^BOOL { return controller.toggles == 1; },2),"queued click toggles exactly once after fresh read");
        Check(!controller.guarded,"confirmed off stops simulated guard");
        controller.fixture = @"hang"; controller.keepAwakeStatus = @YES; controller.guarded = YES;
        [controller toggleKeepAwake];
        Check(WaitFor(^BOOL { return !controller.keepAwakeStatusReading; },2),"controller clears timed-out pending read");
        Check(!controller.keepAwakeTogglePending && controller.toggles == 1,
            "timed-out pre-toggle read cancels requested change");
        Check(controller.keepAwakeStatus == nil && controller.keepAwakeError.length > 0 && controller.guarded,
            "controller timeout exposes unknown state without dropping guard");
        for (NSString *fixture in @[@"on",@"duplicate",@"bad",@"fail",@"flood",@"hang",@"closed-output"]) {
            __block BOOL done = NO; __block NSUInteger calls = 0;
            WattReadSleepStatus(testExecutable,@[@"--fake-pmset",fixture],0.15,^(NSNumber *status, NSString *error) {
                Check(NSThread.isMainThread,"status completion runs on main thread");
                if ([fixture isEqual:@"on"]) Check(status.boolValue && !error,"valid status parsed");
                else Check(status == nil && error.length > 0,"invalid, failed or timed-out reads report unknown");
                calls++; done = YES;
            });
            Check(WaitFor(^BOOL { return done; },2),"status subprocess has bounded completion");
            Check(calls == 1,"completion happens once");
        }
        // "On when plugged in": the charger switches it on quietly; unplugging
        // waits out the grace period; a manual toggle ends the mode.
        [NSUserDefaults.standardUserDefaults setObject:@"plugged" forKey:@"WattNookKeepAwakeMode"];
        controller.fixture = @"slow-off"; controller.keepAwakeStatus = @NO; controller.keepAwakeError = nil;
        NSUInteger before = controller.toggles;
        [controller followPowerForKeepAwake:YES];
        Check(controller.keepAwakeTogglePending && controller.keepAwakeQuiet && controller.keepAwakeTarget.boolValue,
            "charger requests a quiet switch on");
        Check(WaitFor(^BOOL { return controller.toggles == before+1; },2),"automatic switch runs after a fresh read");
        controller.keepAwakeStatus = @YES;
        [controller followPowerForKeepAwake:NO];
        Check(!controller.keepAwakeTogglePending && controller.keepAwakeUnpluggedSince > 0,"unplugging waits out the grace period");
        controller.keepAwakeUnpluggedSince -= 31;
        [controller followPowerForKeepAwake:NO];
        Check(controller.keepAwakeTogglePending && !controller.keepAwakeTarget.boolValue,"after the grace period sleep returns");
        Check(WaitFor(^BOOL { return controller.toggles == before+2; },2),"switch off runs once");
        controller.keepAwakeStatus = @NO; controller.keepAwakeRetryAfter = NSProcessInfo.processInfo.systemUptime+300;
        [controller followPowerForKeepAwake:YES];
        Check(!controller.keepAwakeTogglePending,"a failed automatic switch backs off");
        [controller toggleKeepAwake];
        Check(!WattKeepAwakeFollowsPower(),"a manual toggle ends the automatic mode");
        Check(WaitFor(^BOOL { return controller.toggles == before+3; },2),"manual toggle still runs");
        [controller release];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WattNookKeepAwakeMode"];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WattNookAwakeEvents"];
        puts("Status responsiveness, single-flight, error, toggle and timeout checks passed");
    }
    return 0;
}
