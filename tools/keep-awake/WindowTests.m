#import "../../pkg/gui/native_internal.h"

static void Check(BOOL condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static BOOL WaitFor(BOOL (^ready)(void), NSTimeInterval timeout) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
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

@interface WindowTestController : BattMenuController
@property(nonatomic, assign) NSUInteger refreshes;
@end
@implementation WindowTestController
- (void)refreshKeepAwakeDiagnostics:(id)sender { (void)sender; self.refreshes++; }
@end
@interface RealRefreshWindowTestController : BattMenuController @end
@implementation RealRefreshWindowTestController
- (BOOL)isKeepAwakeActive { return self.keepAwakeStatus.boolValue; }
@end

static NSView *Find(NSView *view, NSString *identifier) {
    if ([view.identifier isEqual:identifier]) return view;
    for (NSView *child in view.subviews) { NSView *found = Find(child, identifier); if (found) return found; }
    return nil;
}
static BOOL FitsVertically(NSStackView *stack) {
    CGFloat previousBottom = CGRectGetMaxY(stack.bounds) + 1;
    for (NSView *view in stack.arrangedSubviews) {
        if (view.hidden) continue;
        NSRect frame = view.frame;
        if (NSMinX(frame) < -3 || NSMaxX(frame) > NSWidth(stack.bounds)+3 ||
            NSMinY(frame) < -3 || NSMaxY(frame) > NSHeight(stack.bounds)+3 ||
            NSMaxY(frame) > previousBottom + 3) return NO;
        previousBottom = NSMinY(frame);
    }
    return YES;
}
static void Capture(NSView *view, NSString *name) {
    const char *destination = getenv("WATTNOOK_WINDOW_PREVIEW_DIR");
    if (!destination) return;
    NSString *directory = [NSString stringWithUTF8String:destination];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
    [view layoutSubtreeIfNeeded]; [view displayIfNeeded];
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:[directory stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
}
static void CheckTextFits(NSView *view, NSString *identifier) {
    NSTextField *label = (NSTextField *)Find(view,identifier);
    CGFloat needed = [label.cell cellSizeForBounds:NSMakeRect(0,0,NSWidth(label.bounds),CGFLOAT_MAX)].height;
    Check(NSHeight(label.bounds) + 1 >= needed, "visible text is not vertically clipped at minimum size");
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        WindowTestController *controller = [[WindowTestController alloc] init];
        controller.keepAwakeStatus = @YES; controller.lidGuard = [[[NSObject alloc] init] autorelease];
        controller.awakeBlockerReport = @"Assertions: none"; controller.awakeSnapshotDate = [NSDate date];
        WattShowAwakeDetails(controller);
        NSWindowController *first = controller.awakeDetailsWindow;
        Check(first != nil && first.window.visible, "opening shows one nonmodal native window");
        Check(controller.refreshes == 1, "first opening requests one snapshot");
        WattShowAwakeDetails(controller);
        Check(controller.awakeDetailsWindow == first && controller.refreshes == 1, "second opening reuses window without request");
        NSView *content = first.window.contentView;
        [content layoutSubtreeIfNeeded];
        Check(first.window.minSize.width == 420 && first.window.minSize.height == 400 && first.window.level == NSNormalWindowLevel,
              "normal resizable window has minimum size");
        Check(Find(content,@"awake.sleep") && Find(content,@"awake.lid") && Find(content,@"awake.remote"), "structured rows exist");
        Check(((first.window.styleMask & NSWindowStyleMaskResizable) != 0) && FitsVertically((NSStackView *)content.subviews.firstObject),
              "native layout contains non-overlapping rows while resizable");
        Check([(NSTextField *)Find(content,@"awake.sleep") textColor] != nil &&
              [(NSTextField *)Find(content,@"awake.limitation") textColor] != nil,
              "state labels use native semantic colors");
        NSStackView *stack = (NSStackView *)content.subviews.firstObject;
        for (NSView *row in stack.arrangedSubviews) {
            if (row.hidden) continue;
            NSRect alignment = [row alignmentRectForFrame:row.frame];
            if (fabs(NSWidth(alignment)-NSWidth(stack.bounds)) >= 1)
                fprintf(stderr,"row %s width %.1f, alignment %.1f, column %.1f\n",
                    NSStringFromClass(row.class).UTF8String,NSWidth(row.frame),NSWidth(alignment),NSWidth(stack.bounds));
            Check(fabs(NSWidth(alignment)-NSWidth(stack.bounds)) < 1,
                  "detail rows span the content column, not a trailing intrinsic-width stack");
        }
        NSTextView *report = (NSTextView *)Find(content,@"awake.report");
        [report setSelectedRange:NSMakeRange(2,0)];
        WattRefreshAwakeDetails(controller);
        Check(report.selectedRange.location == 2, "cached refresh preserves report selection when unchanged");
        first.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        Capture(content,@"light");
        first.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        Capture(content,@"dark");
        controller.keepAwakeChanging = YES; WattRefreshAwakeDetails(controller);
        Check([[(NSTextField *)Find(content,@"awake.sleep") stringValue] isEqual:@"Changing"], "pending changes never report old On as current");
        controller.keepAwakeChanging = NO;
        controller.keepAwakeStatus = nil;
        controller.keepAwakeError = @"Cannot read the macOS sleep setting within two seconds. Last display guard state retained. Try Refresh.";
        controller.lidGuardError = @"Built-in display brightness service unavailable.";
        WattRefreshAwakeDetails(controller);
        Check([(NSTextField *)Find(content,@"awake.sleep") stringValue].length > 0 && !Find(content,@"awake.error").hidden,
              "cached unknown status and errors become visible");
        NSRect minimumFrame = first.window.frame; minimumFrame.size = first.window.minSize;
        [first.window setFrame:minimumFrame display:YES];
        [content layoutSubtreeIfNeeded];
        Capture(content,@"minimum-error");
        Check(FitsVertically((NSStackView *)content.subviews.firstObject), "minimum window keeps rows within bounds");
        CheckTextFits(content,@"awake.error"); CheckTextFits(content,@"awake.limitation");
        Check(NSHeight(Find(content,@"awake.reportScroll").bounds) >= 100, "minimum window retains a usable report viewport");
        NSMutableArray *rows = [NSMutableArray array];
        for (NSUInteger i=0;i<50;i++) [rows addObject:@"Example process · Idle system sleep · 1 request"];
        controller.awakeBlockerReport = [rows componentsJoinedByString:@"\n"];
        WattRefreshAwakeDetails(controller);
        [report.layoutManager ensureLayoutForTextContainer:report.textContainer]; [report sizeToFit];
        NSScrollView *reportScroll = (NSScrollView *)Find(content,@"awake.reportScroll");
        Check(NSHeight(report.frame) > NSHeight(reportScroll.contentView.bounds), "long report can scroll instead of being clipped");
        controller.awakeDiagnosticsLoading = YES; WattRefreshAwakeDetails(controller);
        NSButton *refresh = nil, *copy = nil;
        // Buttons are located by their titles without touching the real pasteboard.
        NSMutableArray *pending = [NSMutableArray arrayWithObject:content];
        while (pending.count) { NSView *v = pending.lastObject; [pending removeLastObject]; if ([v isKindOfClass:NSButton.class]) { NSButton *b=(NSButton *)v; if ([b.title isEqual:@"Refresh"]) refresh=b; if ([b.title isEqual:@"Copy report"]) copy=b; } [pending addObjectsFromArray:v.subviews]; }
        Check(!refresh.enabled && !copy.enabled, "loading disables refresh and copy");
        Check([refresh.keyEquivalent isEqual:@"r"] && refresh.keyEquivalentModifierMask == NSEventModifierFlagCommand,
              "Refresh uses Command-R");
        Check([copy.keyEquivalent isEqual:@"c"] && copy.keyEquivalentModifierMask == (NSEventModifierFlagCommand | NSEventModifierFlagShift),
              "Copy report does not steal Command-C from text selection");
        controller.awakeDiagnosticsLoading = YES;
        [first.window cancelOperation:nil];
        Check(controller.awakeDetailsWindow == nil && controller.awakeBlockerReport == nil && controller.awakeSnapshotDate == nil,
              "Escape close releases window snapshot state");
        Check(controller.awakeDiagnosticsLoading, "close does not reset in-flight request");
        WattShowAwakeDetails(controller);
        NSWindowController *second = controller.awakeDetailsWindow;
        NSEvent *commandW = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                                         modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:0 context:nil
                                            characters:@"w" charactersIgnoringModifiers:@"w" isARepeat:NO keyCode:13];
        Check([second.window performKeyEquivalent:commandW], "Command-W has a native close binding");
        Check(controller.awakeDetailsWindow == nil, "Command-W closes detail window");
        [controller release];

        WindowTestController *dying = [[WindowTestController alloc] init];
        WattShowAwakeDetails(dying);
        NSWindowController *retainedWindow = [dying.awakeDetailsWindow retain];
        [dying release];
        Check(!retainedWindow.window.visible, "owner deallocation closes an open detail window safely");
        [retainedWindow release];

        RealRefreshWindowTestController *real = [[RealRefreshWindowTestController alloc] init];
        [real refreshKeepAwakeDiagnostics:nil];
        Check(!real.awakeDiagnosticsLoading, "refresh without a detail window does no work");
        WattShowAwakeDetails(real);
        Check(real.awakeDiagnosticsLoading, "real refresh starts only for an open window");
        [real.awakeDetailsWindow close];
        Check(WaitFor(^BOOL { return !real.awakeDiagnosticsLoading; },5), "late query completes after close");
        Check(real.awakeDetailsWindow == nil && real.awakeBlockerReport == nil && real.awakeSnapshotDate == nil,
              "late completion neither reopens nor stores a closed snapshot");
        WattShowAwakeDetails(real);
        Check(real.awakeDiagnosticsLoading, "reopened window starts a fresh query");
        [real.awakeDetailsWindow close];
        WattShowAwakeDetails(real);
        Check(real.awakeDetailsWindow != nil && real.awakeDiagnosticsLoading,
              "reopen during one-flight query reuses its pending result");
        Check(WaitFor(^BOOL { return !real.awakeDiagnosticsLoading; },5) && real.awakeBlockerReport.length > 0,
              "pending result reaches a newly reopened window");
        [real release];
        puts("Keep Awake detail window checks passed");
    }
    return 0;
}
