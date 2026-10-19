#import <Cocoa/Cocoa.h>
#import <IOKit/pwr_mgt/IOPMLib.h>

extern NSArray<NSDictionary *> *WattSleepBlockersFromAssertions(NSDictionary *byPID);
extern NSString *WattFormatSleepBlockerReport(NSArray<NSDictionary *> *rows);

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSDictionary *Assertion(id type, id level) {
    return @{ @"AssertType": type, @"AssertLevel": level };
}

static void CheckReportFormatting(void) {
    NSString *emptyReport = WattFormatSleepBlockerReport(@[]);
    Check([emptyReport isEqualToString:
        @"Sleep blockers: none reported\n"
        @"Snapshot only; excludes kernel blockers and system-wide sleep settings; does not prove lid-closed wakefulness or connectivity."],
        @"empty report has a real newline and snapshot limitations");

    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (NSInteger index = 0; index < 51; index++) {
        [rows addObject:@{
            @"pid": @(100000 + index),
            @"type": @"PreventSystemSleep",
            @"count": @1,
            @"AssertName": @"private URL https://example.invalid/secret",
        }];
    }
    NSString *report = WattFormatSleepBlockerReport(rows);
    Check([report rangeOfString:@"\\n"].location == NSNotFound,
          @"report renders real newlines, not literal escape text");
    NSArray<NSString *> *lines = [report componentsSeparatedByString:@"\n"];
    Check(lines.count == 53, @"report caps rows and includes overflow plus footer");
    NSUInteger renderedRows = 0;
    for (NSString *line in lines) {
        if ([line hasPrefix:@"PID "]) {
            renderedRows++;
        }
    }
    Check(renderedRows == 50, @"report renders at most fifty blocker rows");
    Check([report containsString:@"… 1 additional blocker rows not shown"],
          @"report states omitted row count");
    Check([report rangeOfString:@"AssertName"].location == NSNotFound &&
          [report rangeOfString:@"example.invalid/secret"].location == NSNotFound,
          @"report does not render assertion names or details");
}

int main(void) {
    @autoreleasepool {
        NSDictionary *fixtures = @{
            @42: @[
                Assertion(@"PreventUserIdleDisplaySleep", @1),
                Assertion(@"PreventUserIdleDisplaySleep", @1),
                Assertion(@"PreventUserIdleSystemSleep", @0),
                Assertion(@"PreventDiskIdle", @1),
                Assertion(@"PreventSystemSleep", @2),
                Assertion(@"PreventSystemSleep", @"1"),
                Assertion(@42, @1),
                Assertion(@"PreventUserIdleDisplaySleep", @1.5),
            ],
            @7: @[
                Assertion(@"PreventUserIdleSystemSleep", @1),
                Assertion(@"PreventSystemSleep", @-1),
            ],
            @"44": @[Assertion(@"PreventSystemSleep", @1)],
            @(-3): @[Assertion(@"PreventSystemSleep", @1)],
            @9.5: @[Assertion(@"PreventSystemSleep", @1)],
            @11: @"not an assertion array",
        };

        NSArray<NSDictionary *> *rows = WattSleepBlockersFromAssertions(fixtures);
        NSArray<NSDictionary *> *expected = @[
            @{ @"pid": @7, @"type": @"PreventUserIdleSystemSleep", @"count": @1 },
            @{ @"pid": @42, @"type": @"PreventSystemSleep", @"count": @1 },
            @{ @"pid": @42, @"type": @"PreventUserIdleDisplaySleep", @"count": @2 },
        ];
        Check([rows isEqualToArray:expected], @"filters, aggregates, and sorts active supported assertions");

        NSDictionary *reorderedFixtures = @{
            @42: @[
                Assertion(@"PreventSystemSleep", @2),
                Assertion(@"PreventUserIdleDisplaySleep", @1),
                Assertion(@"PreventUserIdleDisplaySleep", @1),
            ],
            @7: @[Assertion(@"PreventUserIdleSystemSleep", @1)],
        };
        Check([WattSleepBlockersFromAssertions(reorderedFixtures) isEqualToArray:expected],
              @"result order is deterministic regardless of dictionary order");
        CheckReportFormatting();
        NSLog(@"PASS: assertion converter regression tests");
    }
    return 0;
}
