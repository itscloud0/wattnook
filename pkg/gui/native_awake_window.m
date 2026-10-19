#import "native_internal.h"

@interface WattAwakeBackgroundView : NSView @end
@implementation WattAwakeBackgroundView
- (BOOL)isOpaque { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.windowBackgroundColor setFill]; NSRectFill(dirtyRect);
}
@end

@interface WattAwakePanel : NSPanel
@end
@implementation WattAwakePanel
- (void)cancelOperation:(id)sender { (void)sender; [self performClose:nil]; }
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if ((event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) == NSEventModifierFlagCommand &&
        [[event charactersIgnoringModifiers] isEqualToString:@"w"]) { [self performClose:nil]; return YES; }
    return [super performKeyEquivalent:event];
}
@end

@interface WattAwakeWindowController : NSWindowController <NSWindowDelegate> {
    BattMenuController *_awakeOwner;
}
@property(nonatomic, retain) NSTextField *sleepValue;
@property(nonatomic, retain) NSTextField *lidValue;
@property(nonatomic, retain) NSTextField *errorValue;
@property(nonatomic, retain) NSTextField *snapshotValue;
@property(nonatomic, retain) NSTextView *reportView;
@property(nonatomic, retain) NSButton *refreshButton;
@property(nonatomic, retain) NSButton *reportCopyButton;
- (void)refreshCachedValues;
@end

static NSTextField *WattAwakeLabel(NSString *text, NSFont *font, NSColor *color) {
    NSTextField *label = [[[NSTextField alloc] initWithFrame:NSZeroRect] autorelease];
    label.editable = NO; label.selectable = NO; label.bezeled = NO; label.drawsBackground = NO;
    label.stringValue = text ?: @""; label.font = font; label.textColor = color;
    label.alignment = NSTextAlignmentLeft;
    label.usesSingleLineMode = NO; label.lineBreakMode = NSLineBreakByWordWrapping; label.maximumNumberOfLines = 0;
    label.preferredMaxLayoutWidth = 480;
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

static NSString *WattAwakeTimestamp(NSDate *date) {
    if (!date) return @"Snapshot: not yet collected";
    NSString *time = [NSDateFormatter localizedStringFromDate:date
                                                     dateStyle:NSDateFormatterMediumStyle
                                                     timeStyle:NSDateFormatterMediumStyle];
    return [NSString stringWithFormat:@"Snapshot: %@",time];
}

@implementation WattAwakeWindowController

- (instancetype)initWithOwner:(BattMenuController *)owner {
    NSPanel *panel = [[[WattAwakePanel alloc] initWithContentRect:NSMakeRect(0,0,520,520)
                                                 styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                           NSWindowStyleMaskResizable
                                                   backing:NSBackingStoreBuffered defer:NO] autorelease];
    if (!(self = [super initWithWindow:panel])) return nil;
    _awakeOwner = owner;
    panel.title = @"Keep Awake details";
    panel.level = NSNormalWindowLevel;
    panel.hidesOnDeactivate = NO;
    panel.minSize = NSMakeSize(480,440);
    panel.delegate = self;
    panel.releasedWhenClosed = NO;
    panel.contentView = [[[WattAwakeBackgroundView alloc] initWithFrame:panel.contentView.bounds] autorelease];
    [self buildWindow];
    [panel center];
    return self;
}

- (void)dealloc {
    self.window.delegate = nil;
    [_sleepValue release]; [_lidValue release]; [_errorValue release]; [_snapshotValue release];
    [_reportView release]; [_refreshButton release]; [_reportCopyButton release];
    [super dealloc];
}

- (void)buildWindow {
    NSView *content = self.window.contentView;
    content.wantsLayer = YES;
    NSStackView *stack = [[[NSStackView alloc] initWithFrame:NSZeroRect] autorelease];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 9;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-20],
    ]];

    NSTextField *title = WattAwakeLabel(@"Keep Awake", [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold], NSColor.labelColor);
    [stack addArrangedSubview:title];
    NSArray *names = @[@"Sleep prevention", @"Closed-lid display", @"Remote access"];
    NSArray *identifiers = @[@"awake.sleep", @"awake.lid", @"awake.remote"];
    NSMutableArray *values = [NSMutableArray array];
    for (NSUInteger i=0; i<names.count; i++) {
        NSStackView *row = [[[NSStackView alloc] initWithFrame:NSZeroRect] autorelease];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.distribution = NSStackViewDistributionFill;
        NSTextField *name = WattAwakeLabel(names[i], [NSFont systemFontOfSize:13 weight:NSFontWeightMedium], NSColor.secondaryLabelColor);
        NSTextField *value = WattAwakeLabel(@"—", [NSFont systemFontOfSize:13], NSColor.labelColor);
        value.identifier = identifiers[i];
        [row addArrangedSubview:name]; [row addArrangedSubview:value];
        [name.widthAnchor constraintEqualToConstant:135].active = YES;
        [stack addArrangedSubview:row]; [values addObject:value];
    }
    _sleepValue = [values[0] retain]; _lidValue = [values[1] retain];
    ((NSTextField *)values[2]).stringValue = @"Not monitored";

    _errorValue = [WattAwakeLabel(@"", [NSFont systemFontOfSize:12], NSColor.systemRedColor) retain];
    _errorValue.identifier = @"awake.error";
    [stack addArrangedSubview:_errorValue];
    NSTextField *limit = WattAwakeLabel(@"Stays on after quitting. Turn off before transport.\nBrightness guard does not guarantee panel shutdown.",
                                         [NSFont systemFontOfSize:12], NSColor.secondaryLabelColor);
    limit.identifier = @"awake.limitation";
    [stack addArrangedSubview:limit];

    NSTextField *heading = WattAwakeLabel(@"Sleep blockers", [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], NSColor.labelColor);
    [stack addArrangedSubview:heading];
    _snapshotValue = [WattAwakeLabel(@"Snapshot: not yet collected", [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor) retain];
    _snapshotValue.identifier = @"awake.snapshot";
    [stack addArrangedSubview:_snapshotValue];

    NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:NSZeroRect] autorelease];
    scroll.hasVerticalScroller = YES; scroll.borderType = NSBezelBorder;
    scroll.identifier = @"awake.reportScroll";
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _reportView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    _reportView.editable = NO; _reportView.selectable = YES;
    _reportView.identifier = @"awake.report";
    _reportView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _reportView.textColor = NSColor.labelColor; _reportView.backgroundColor = NSColor.textBackgroundColor;
    _reportView.textContainer.widthTracksTextView = YES;
    _reportView.verticallyResizable = YES;
    _reportView.horizontallyResizable = NO;
    _reportView.minSize = NSMakeSize(0,0);
    _reportView.maxSize = NSMakeSize(CGFLOAT_MAX,CGFLOAT_MAX);
    _reportView.autoresizingMask = NSViewWidthSizable;
    scroll.documentView = _reportView;
    [stack addArrangedSubview:scroll];
    [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:130].active = YES;
    [scroll setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    [scroll setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];

    NSStackView *buttons = [[[NSStackView alloc] initWithFrame:NSZeroRect] autorelease];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.distribution = NSStackViewDistributionGravityAreas;
    _refreshButton = [[NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refresh:)] retain];
    _refreshButton.keyEquivalent = @"r"; _refreshButton.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    _reportCopyButton = [[NSButton buttonWithTitle:@"Copy report" target:self action:@selector(copy:)] retain];
    _reportCopyButton.keyEquivalent = @"c"; _reportCopyButton.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    NSButton *close = [NSButton buttonWithTitle:@"Close" target:self action:@selector(close:)];
    [buttons addView:_refreshButton inGravity:NSStackViewGravityLeading];
    [buttons addView:_reportCopyButton inGravity:NSStackViewGravityLeading];
    [buttons addView:close inGravity:NSStackViewGravityTrailing];
    [stack addArrangedSubview:buttons];
    for (NSView *row in stack.arrangedSubviews) {
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [row.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    }
}

- (void)refreshCachedValues {
    BattMenuController *owner = _awakeOwner;
    if (!owner) return;
    NSString *sleep = (owner.keepAwakeChanging || owner.keepAwakeStatusReading) ?
        (owner.keepAwakeChanging ? @"Changing" : @"Checking") :
        !owner.keepAwakeStatus ? @"Unknown" : owner.keepAwakeStatus.boolValue ? @"On" : @"Off";
    _sleepValue.stringValue = sleep;
    _lidValue.stringValue = owner.lidGuardError.length ? @"Unavailable" : owner.lidGuard ? @"Guard running" : @"Off";
    NSMutableArray *errors = [NSMutableArray array];
    if (owner.keepAwakeError.length) [errors addObject:[NSString stringWithFormat:@"Sleep prevention: %@",owner.keepAwakeError]];
    if (owner.lidGuardError.length) [errors addObject:[NSString stringWithFormat:@"Closed-lid display: %@",owner.lidGuardError]];
    _errorValue.stringValue = [errors componentsJoinedByString:@"\n"];
    _errorValue.hidden = errors.count == 0;
    _snapshotValue.stringValue = WattAwakeTimestamp(owner.awakeSnapshotDate);
    NSString *report = owner.awakeDiagnosticsLoading ? @"Loading sleep blockers…" :
        (owner.awakeBlockerReport.length ? owner.awakeBlockerReport : @"No sleep-blocker snapshot available.");
    if (![_reportView.string isEqualToString:report]) _reportView.string = report;
    _refreshButton.enabled = !owner.awakeDiagnosticsLoading;
    _reportCopyButton.enabled = !owner.awakeDiagnosticsLoading;
}

- (void)refresh:(id)sender { (void)sender; [_awakeOwner refreshKeepAwakeDiagnostics:nil]; [self refreshCachedValues]; }
- (void)copy:(id)sender {
    (void)sender;
    if (_awakeOwner.awakeDiagnosticsLoading) return;
    NSString *snapshot = WattAwakeTimestamp(_awakeOwner.awakeSnapshotDate);
    NSString *text = [NSString stringWithFormat:@"%@\n\n%@\n\n%@",WattAwakeReport(_awakeOwner),snapshot,
                      _awakeOwner.awakeBlockerReport ?: @"No sleep-blocker snapshot available."];
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
}
- (void)close:(id)sender { (void)sender; [self.window performClose:nil]; }
- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    [self retain];
    if (_awakeOwner.awakeDetailsWindow == self) {
        _awakeOwner.awakeDetailsWindow = nil;
        _awakeOwner.awakeBlockerReport = nil;
        _awakeOwner.awakeSnapshotDate = nil;
    }
    _awakeOwner = nil;
    [self autorelease];
}
@end

void WattRefreshAwakeDetails(BattMenuController *controller) {
    WattAwakeWindowController *window = (WattAwakeWindowController *)controller.awakeDetailsWindow;
    if (window) [window refreshCachedValues];
}

void WattShowAwakeDetails(BattMenuController *controller) {
    WattAwakeWindowController *window = (WattAwakeWindowController *)controller.awakeDetailsWindow;
    if (!window) {
        window = [[WattAwakeWindowController alloc] initWithOwner:controller];
        controller.awakeDetailsWindow = window;
        [window release];
        [window refreshCachedValues];
        [controller refreshKeepAwakeDiagnostics:nil];
        [window refreshCachedValues];
    } else [window refreshCachedValues];
    if (NSApp.activationPolicy == NSApplicationActivationPolicyAccessory)
        [NSApp activateIgnoringOtherApps:YES];
    [window showWindow:nil];
    [window.window makeKeyAndOrderFront:nil];
}
