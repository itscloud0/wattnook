#import <Cocoa/Cocoa.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <libproc.h>

static NSString *const WattAssertionTypeKey = @"AssertType";
static NSString *const WattAssertionLevelKey = @"AssertLevel";
static const NSUInteger WattSleepBlockerReportRowLimit = 50;
static const NSUInteger WattSleepBlockerProcessNameLimit = 80;
static NSString *const WattSleepBlockerReportFooter =
    @"Snapshot only; excludes kernel blockers and system-wide sleep settings; does not prove lid-closed wakefulness or connectivity.";

static BOOL WattIntegerNumber(id value, long long *result) {
    if (![value isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }

    CFNumberType type = CFNumberGetType((__bridge CFNumberRef)value);
    switch (type) {
        case kCFNumberSInt8Type:
        case kCFNumberSInt16Type:
        case kCFNumberSInt32Type:
        case kCFNumberSInt64Type:
        case kCFNumberCharType:
        case kCFNumberShortType:
        case kCFNumberIntType:
        case kCFNumberLongType:
        case kCFNumberLongLongType:
        case kCFNumberCFIndexType:
        case kCFNumberNSIntegerType:
            *result = [(NSNumber *)value longLongValue];
            return YES;
        default:
            return NO;
    }
}

static BOOL WattSupportedSleepAssertionType(id value) {
    return [value isKindOfClass:[NSString class]] &&
        ([(NSString *)value isEqualToString:@"PreventUserIdleDisplaySleep"] ||
         [(NSString *)value isEqualToString:@"PreventUserIdleSystemSleep"] ||
         [(NSString *)value isEqualToString:@"PreventSystemSleep"]);
}

NSArray<NSDictionary *> *WattSleepBlockersFromAssertions(NSDictionary *byPID) {
    if (![byPID isKindOfClass:[NSDictionary class]]) {
        return @[];
    }

    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (id pidValue in byPID) {
        long long pid = 0;
        if (!WattIntegerNumber(pidValue, &pid) || pid <= 0 || pid > INT_MAX) {
            continue;
        }

        id assertions = byPID[pidValue];
        if (![assertions isKindOfClass:[NSArray class]]) {
            continue;
        }
        for (id assertion in assertions) {
            if (![assertion isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            id type = assertion[WattAssertionTypeKey];
            long long level = 0;
            if (!WattSupportedSleepAssertionType(type) ||
                !WattIntegerNumber(assertion[WattAssertionLevelKey], &level) || level <= 0) {
                continue;
            }

            NSString *key = [NSString stringWithFormat:@"%lld:%@", pid, type];
            counts[key] = @([counts[key] integerValue] + 1);
        }
    }

    NSMutableArray<NSDictionary *> *rows = [NSMutableArray arrayWithCapacity:counts.count];
    for (NSString *key in counts) {
        NSRange separator = [key rangeOfString:@":"];
        if (separator.location == NSNotFound) {
            continue;
        }
        long long pid = [[key substringToIndex:separator.location] longLongValue];
        [rows addObject:@{
            @"pid": @(pid),
            @"type": [key substringFromIndex:NSMaxRange(separator)],
            @"count": counts[key],
        }];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSComparisonResult pidOrder = [left[@"pid"] compare:right[@"pid"]];
        return pidOrder == NSOrderedSame ? [left[@"type"] compare:right[@"type"]] : pidOrder;
    }];
    return rows;
}

static NSString *WattSleepBlockerScope(NSString *type) {
    if ([type isEqualToString:@"PreventUserIdleDisplaySleep"]) {
        return @"Display";
    }
    if ([type isEqualToString:@"PreventUserIdleSystemSleep"]) {
        return @"Idle sleep";
    }
    return @"System sleep";
}

static NSString *WattSanitizedProcessName(pid_t pid) {
    char nameBuffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int length = proc_name(pid, nameBuffer, sizeof(nameBuffer));
    if (length <= 0) {
        return @"unknown";
    }

    NSString *rawName = [[NSString alloc] initWithBytes:nameBuffer
                                                  length:(NSUInteger)length
                                                encoding:NSUTF8StringEncoding];
    if (rawName.length == 0) {
        [rawName release];
        return @"unknown";
    }
    NSString *name = [[rawName componentsSeparatedByCharactersInSet:[NSCharacterSet controlCharacterSet]]
        componentsJoinedByString:@" "];
    [rawName release];
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length > WattSleepBlockerProcessNameLimit) {
        name = [[name substringToIndex:WattSleepBlockerProcessNameLimit] stringByAppendingString:@"…"];
    }
    return name.length > 0 ? name : @"unknown";
}

NSString *WattFormatSleepBlockerReport(NSArray<NSDictionary *> *rows) {
    if (rows.count == 0) {
        return [@"Sleep blockers: none reported\n" stringByAppendingString:WattSleepBlockerReportFooter];
    }

    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:@"Sleep blockers (active assertions):"];
    NSUInteger renderedCount = MIN(rows.count, WattSleepBlockerReportRowLimit);
    for (NSUInteger index = 0; index < renderedCount; index++) {
        NSDictionary *row = rows[index];
        pid_t pid = [row[@"pid"] intValue];
        [lines addObject:[NSString stringWithFormat:@"PID %d (%@): %@ — %@",
                          pid,
                          WattSanitizedProcessName(pid),
                          WattSleepBlockerScope(row[@"type"]),
                          row[@"count"]]];
    }
    if (rows.count > renderedCount) {
        [lines addObject:[NSString stringWithFormat:@"… %lu additional blocker rows not shown",
                          (unsigned long)(rows.count - renderedCount)]];
    }
    [lines addObject:WattSleepBlockerReportFooter];
    return [lines componentsJoinedByString:@"\n"];
}

NSString *WattSleepBlockerReport(void) {
    CFDictionaryRef rawAssertions = NULL;
    IOReturn status = IOPMCopyAssertionsByProcess(&rawAssertions);
    if (status != kIOReturnSuccess || rawAssertions == NULL) {
        if (rawAssertions != NULL) {
            CFRelease(rawAssertions);
        }
        return [NSString stringWithFormat:@"Sleep blockers: unavailable (IOPMCopyAssertionsByProcess failed: 0x%08x)\n"
                @"%@",
                (unsigned int)status,
                WattSleepBlockerReportFooter];
    }

    NSDictionary *snapshot = [(NSDictionary *)rawAssertions copy];
    CFRelease(rawAssertions);
    NSArray<NSDictionary *> *rows = WattSleepBlockersFromAssertions(snapshot);
    [snapshot release];
    return WattFormatSleepBlockerReport(rows);
}
