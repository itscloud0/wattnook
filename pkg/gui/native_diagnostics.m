#import "native_internal.h"
#import <libproc.h>
#import <unistd.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#include <math.h>

NSString *WattCPUUsageLabel(double corePercent, NSUInteger processorCount) {
    if (processorCount == 0 || !isfinite(corePercent) || corePercent < 0) return @"—";
    return [NSString stringWithFormat:@"%.1f%% CPU",corePercent/processorCount];
}

double BattProcessCPUPercent(uint64_t previous, uint64_t current, double elapsed,
                             uint32_t numer, uint32_t denom) {
    if (current < previous || elapsed <= 0 || denom == 0) return 0;
    // PROC_PIDTASKINFO returns Mach ticks, not nanoseconds (Apple Silicon != 1:1).
    return (current-previous) * ((double)numer/denom) / (elapsed*10000000.0);
}

static NSString *MemoryLabel(double bytes) {
    if (bytes >= 1024.0 * 1024.0 * 1024.0)
        return [NSString stringWithFormat:@"%.1f GB", bytes / (1024.0 * 1024.0 * 1024.0)];
    return [NSString stringWithFormat:@"%.0f MB", bytes / (1024.0 * 1024.0)];
}

// Memory that is compressed or written to swap rather than held in RAM.
// task_name_for_pid needs no entitlement for this read-only flavor.
static double OutOfRAMBytes(pid_t pid) {
    mach_port_t task = MACH_PORT_NULL;
    if (task_name_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) return 0;
    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t result = task_info(task, TASK_VM_INFO, (task_info_t)&info, &count);
    mach_port_deallocate(mach_task_self(), task);
    return result == KERN_SUCCESS ? (double)info.compressed : 0;
}

@implementation BattMenuController (Diagnostics)

- (void)updateAppStats {
    if (!WattMonitoringEnabled()) return;
    @autoreleasepool {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSTimeInterval elapsed = now - _previousProcessSampleTime;
    NSMutableDictionary *nextCPU = [NSMutableDictionary dictionary];
    NSMutableDictionary *nextDisk = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *roots = [NSMutableDictionary dictionary];
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        pid_t pid = app.processIdentifier;
        NSString *bundleID = app.bundleIdentifier;
        NSString *path = app.bundleURL.path;
        if (pid <= 0 || app.isTerminated ||
            (pid != getpid() && app.activationPolicy != NSApplicationActivationPolicyRegular) ||
            bundleID.length == 0 || path.length == 0 ||
            [path hasPrefix:@"/System/"]) continue;
        roots[@(pid)] = [[@{
            @"pid": @(pid),
            @"bundle": bundleID,
            @"name": app.localizedName ?: bundleID,
            @"path": path,
            @"cpu": @0,
            @"memory": @0,
            @"swapped": @0,
            @"diskRead": @0,
            @"diskWrite": @0,
            @"diskAvailable": @YES,
            @"canQuit": @(pid != getpid()),
        } mutableCopy] autorelease];
    }
    if (roots[@(getpid())] == nil) {
        roots[@(getpid())] = [[@{@"pid":@(getpid()), @"name":@"WattNook",
            @"path":[NSBundle.mainBundle.bundlePath hasSuffix:@".app"] ? NSBundle.mainBundle.bundlePath : @"",
            @"bundle":NSBundle.mainBundle.bundleIdentifier ?: @"",
            @"cpu":@0, @"memory":@0, @"swapped":@0, @"diskRead":@0, @"diskWrite":@0,
            @"diskAvailable":@YES, @"canQuit":@NO} mutableCopy] autorelease];
    }
    NSArray *appRoots = roots.allValues;
    NSMutableArray *background = [NSMutableArray array];
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&timebase); });

    int requiredBytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (requiredBytes <= 0) return;
    NSMutableData *pidData = [NSMutableData dataWithLength:requiredBytes + 4096];
    int countBytes = proc_listpids(PROC_ALL_PIDS, 0, pidData.mutableBytes, (int)pidData.length);
    if (countBytes <= 0) return;
    NSMutableDictionary<NSNumber *, NSDictionary *> *processes = [NSMutableDictionary dictionary];
    pid_t *pids = pidData.mutableBytes;
    for (NSInteger i = 0; i < countBytes / sizeof(pid_t); i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;
        struct proc_bsdinfo bsd = {0};
        struct proc_taskinfo task = {0};
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd) ||
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) != sizeof(task))
            continue;
        NSNumber *key = @(pid);
        uint64_t totalCPU = task.pti_total_user + task.pti_total_system;
        NSNumber *identity = @((uint64_t)bsd.pbi_start_tvsec*1000000+bsd.pbi_start_tvusec);
        nextCPU[key] = @[@(totalCPU),identity];
        NSArray *previous = self.previousProcessCPU[key];
        double cpu = previous.count == 2 && [previous[1] isEqual:identity]
            ? BattProcessCPUPercent([previous[0] unsignedLongLongValue],totalCPU,elapsed,timebase.numer,timebase.denom) : 0;
        struct rusage_info_v2 usage = {0};
        double read = -1, write = -1;
        // Activity Monitor's Memory: the footprint, which also counts what is
        // compressed or swapped. Resident size alone hid idle processes whose
        // memory had been pushed to swap.
        double memory = task.pti_resident_size;
        if (proc_pid_rusage(pid,RUSAGE_INFO_V2,(rusage_info_t *)&usage) == 0) {
            if (usage.ri_phys_footprint) memory = usage.ri_phys_footprint;
            NSArray *last = self.previousProcessDisk[key];
            nextDisk[key] = @[@(usage.ri_diskio_bytesread),@(usage.ri_diskio_byteswritten),identity];
            if (last.count == 3 && [last[2] isEqual:identity]) {
                read = BattCounterRate([last[0] unsignedLongLongValue],usage.ri_diskio_bytesread,elapsed);
                write = BattCounterRate([last[1] unsignedLongLongValue],usage.ri_diskio_byteswritten,elapsed);
            }
        }
        processes[key] = @{
            @"parent": @(bsd.pbi_ppid),
            @"cpu": @(cpu),
            @"memory": @(memory),
            @"swapped": @(MIN(memory, OutOfRAMBytes(pid))),
            @"diskRead": @(read), @"diskWrite": @(write),
            @"name": [NSString stringWithUTF8String:bsd.pbi_name] ?: @"Process",
        };
    }
    for (NSNumber *pid in processes) {
        NSDictionary *process = processes[pid];
        NSMutableDictionary *root = roots[pid];
        NSNumber *ancestor = process[@"parent"];
        for (NSInteger depth = 0; root == nil && depth < 20 && ancestor != nil; depth++) {
            root = roots[ancestor];
            ancestor = processes[ancestor][@"parent"];
        }
        if (root == nil) {
            char pathBuffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
            if (proc_pidpath(pid.intValue, pathBuffer, sizeof(pathBuffer)) > 0) {
                NSString *processPath = [NSString stringWithUTF8String:pathBuffer];
                for (NSMutableDictionary *candidate in appRoots) {
                    NSString *prefix = [candidate[@"path"] stringByAppendingString:@"/Contents/"];
                    if ([processPath hasPrefix:prefix]) {
                        root = candidate;
                        break;
                    }
                }
            }
        }
        if (root == nil) {
            NSMutableDictionary *sample = [[process mutableCopy] autorelease];
            sample[@"pid"] = pid; sample[@"canQuit"] = @NO;
            sample[@"path"] = @"";
            sample[@"disk"] = [process[@"diskRead"] doubleValue] < 0 || [process[@"diskWrite"] doubleValue] < 0 ?
                @-1 : @([process[@"diskRead"] doubleValue]+[process[@"diskWrite"] doubleValue]);
            [background addObject:sample];
            continue;
        }
        root[@"cpu"] = @([root[@"cpu"] doubleValue] + [process[@"cpu"] doubleValue]);
        root[@"memory"] = @([root[@"memory"] doubleValue] + [process[@"memory"] doubleValue]);
        root[@"swapped"] = @([root[@"swapped"] doubleValue] + [process[@"swapped"] doubleValue]);
        if ([process[@"diskRead"] doubleValue] < 0 || [process[@"diskWrite"] doubleValue] < 0)
            root[@"diskAvailable"] = @NO;
        else {
            root[@"diskRead"] = @([root[@"diskRead"] doubleValue]+[process[@"diskRead"] doubleValue]);
            root[@"diskWrite"] = @([root[@"diskWrite"] doubleValue]+[process[@"diskWrite"] doubleValue]);
        }
    }
    for (NSMutableDictionary *root in roots.allValues)
        root[@"disk"] = [root[@"diskAvailable"] boolValue] ?
            @([root[@"diskRead"] doubleValue]+[root[@"diskWrite"] doubleValue]) : @-1;
    self.previousProcessCPU = nextCPU;
    self.previousProcessDisk = nextDisk;
    self.appStats = [appRoots arrayByAddingObjectsFromArray:background];
    _previousProcessSampleTime = now;
    }
}

- (void)populateDiagnosticMenu:(NSMenu *)menu byCPU:(BOOL)byCPU {
    [menu removeAllItems];
    NSString *sortKey = byCPU ? @"cpu" : @"memory";
    NSArray<NSDictionary *> *sorted = [self.appStats sortedArrayUsingComparator:
        ^NSComparisonResult(NSDictionary *first, NSDictionary *second) {
            return [second[sortKey] compare:first[sortKey]];
        }];
    if (sorted.count == 0) {
        NSMenuItem *empty = [[[NSMenuItem alloc] initWithTitle:@"No app data"
                                                       action:nil keyEquivalent:@""] autorelease];
        empty.enabled = NO;
        [menu addItem:empty];
        return;
    }
    for (NSDictionary *sample in [sorted subarrayWithRange:NSMakeRange(0, MIN(5, sorted.count))]) {
        NSString *amount = byCPU
            ? WattCPUUsageLabel([sample[@"cpu"] doubleValue],NSProcessInfo.processInfo.processorCount)
            : MemoryLabel([sample[@"memory"] doubleValue]);
        NSString *title = [NSString stringWithFormat:@"%@  ·  %@", sample[@"name"], amount];
        NSMenuItem *row = [[[NSMenuItem alloc] initWithTitle:title
                                                    action:@selector(quitDiagnosedApp:)
                                               keyEquivalent:@""] autorelease];
        NSString *detail = [NSString stringWithFormat:@"%@ of total capacity · %.2f cores · Memory %@ (%@ swapped)",
            WattCPUUsageLabel([sample[@"cpu"] doubleValue],NSProcessInfo.processInfo.processorCount),
            [sample[@"cpu"] doubleValue]/100, MemoryLabel([sample[@"memory"] doubleValue]),
            MemoryLabel([sample[@"swapped"] doubleValue])];
        row.target = self;
        row.enabled = [sample[@"canQuit"] boolValue];
        row.toolTip = [sample[@"canQuit"] boolValue] ?
            [detail stringByAppendingString:@"  ·  Click to request Quit"] : detail;
        row.representedObject = sample;
        [menu addItem:row];
    }
}

- (void)updateDiagnosticMenus {
    [self updateAppStats];
    [self populateDiagnosticMenu:self.cpuAppsMenu byCPU:YES];
    [self populateDiagnosticMenu:self.memoryAppsMenu byCPU:NO];
}

- (void)quitDiagnosedApp:(NSMenuItem *)sender {
    NSDictionary *sample = sender.representedObject;
    if (sample[@"canQuit"] && ![sample[@"canQuit"] boolValue]) return;
    pid_t pid = [sample[@"pid"] intValue];
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (app == nil || app.isTerminated ||
        ![app.bundleIdentifier isEqualToString:sample[@"bundle"]] ||
        pid == getpid() || [app.bundleURL.path hasPrefix:@"/System/"]) return;

    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    alert.messageText = [NSString stringWithFormat:@"Quit %@?", sample[@"name"]];
    alert.informativeText = @"This sends a normal Quit request. The app may ask you to save unsaved work.";
    [alert addButtonWithTitle:@"Quit App"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    if (![app terminate]) {
        NSAlert *error = [[[NSAlert alloc] init] autorelease];
        error.messageText = @"Could not quit the app";
        error.informativeText = @"It may already have exited. No force quit was attempted.";
        [error runModal];
    }
}

@end
