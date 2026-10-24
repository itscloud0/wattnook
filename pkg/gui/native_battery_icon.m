#import "native_internal.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <string.h>

// BatteryUIKit's renderer, kept for the no-battery and service glyphs. This
// UI-only path creates no power-source observer.
static Class BatteryImageClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27) return;
        if (!dlopen("/System/Library/PrivateFrameworks/BatteryUIKit.framework/Versions/A/BatteryUIKit",
                    RTLD_LAZY | RTLD_LOCAL)) return;
        Class candidate = NSClassFromString(@"BUIImage");
        Method cache = class_getClassMethod(candidate, NSSelectorFromString(@"sharedBUIImageCache"));
        Method render = class_getInstanceMethod(candidate, NSSelectorFromString(
            @"_modernBatteryImageForLevel:charging:pluggedIn:noBattery:needsReplacement:lowPowerMode:showPercentage:useRed:"));
        if (cache && render && !strcmp(method_getTypeEncoding(cache), "@16@0:8") &&
            !strcmp(method_getTypeEncoding(render), "@52@0:8d16B24B28B32B36B40B44B48")) cls = candidate;
    });
    return cls;
}

// The measured glyph below needs no private API; BUIImage only draws the
// rare no-battery and service states.
BOOL WattNativeBatteryRendererAvailable(void) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27;
}

static NSImage *BUIBattery(NSInteger charge, BOOL pluggedIn, BOOL charging,
                           BOOL present, BOOL needsService, BOOL lowPower, BOOL showPercentage) {
    Class cls = BatteryImageClass();
    if (!cls) return nil;
    @try {
        id cache = ((id(*)(id,SEL))objc_msgSend)(cls, NSSelectorFromString(@"sharedBUIImageCache"));
        if (![cache isKindOfClass:cls]) return nil;
        BOOL known = charge >= 0 && present;
        double level = MAX(0, MIN(100, charge)) / 100.0;
        SEL render = NSSelectorFromString(@"_modernBatteryImageForLevel:charging:pluggedIn:noBattery:needsReplacement:lowPowerMode:showPercentage:useRed:");
        NSImage *image = ((id(*)(id,SEL,double,BOOL,BOOL,BOOL,BOOL,BOOL,BOOL,BOOL))objc_msgSend)(
            cache, render, level, known && pluggedIn && charging, known && pluggedIn,
            !present, known && needsService, lowPower, known && showPercentage, known && !pluggedIn && charge <= 20);
        if (![image isKindOfClass:NSImage.class] || image.size.width <= 0 || image.size.width > 40 ||
            image.size.height <= 0 || image.size.height > 24) return nil;
        // Do not mutate Apple's shared/cache-owned NSImage.
        return [[image copy] autorelease];
    } @catch (NSException *exception) {
        return nil; // A changed private API must not crash the menu-bar app.
    }
}

// Control Center's macOS 27 menu-bar battery (ControlCenterApp.BatteryGlyph,
// a private SwiftUI view no other process can call), rebuilt from the
// constants in its code (PRODUCT.md, "Menu-bar battery"). 26x14 pt: a 23x12 body with continuous 4 pt corners,
// the charge clipped into it, the battery-cap asset 1 pt to the right, and
// the number in .footnote knocked out of both. BatteryUIKit's BUIImage is an
// older, wider, dimmer design.
static NSBezierPath *WattBatteryBodyPath(void) {
    // SwiftUI's RoundedRectangle(cornerRadius: 4, style: .continuous) in
    // CGRect(0, 1, 23, 12): symmetric, so its y-down points need no flip.
    static const CGFloat c[16][6] = {
        {23,7.6739,23,8.5369,22.7004,9.4740}, {22.3238,10.5087,21.5087,11.3238,20.4740,11.7004},
        {19.5264,12,18.6460,12,16.8853,12}, {0,0,0,0,6.1147,12},
        {4.3540,12,3.4736,12,2.5260,11.7004}, {1.4913,11.3238,0.6762,10.5087,0.2996,9.4740},
        {0,8.5369,0,7.6739,0,6}, {0,4.3261,0,3.4631,0.2996,2.5260},
        {0.6762,1.4913,1.4913,0.6762,2.5260,0.2996}, {3.4736,0,4.3540,0,6.1147,0},
        {0,0,0,0,16.8853,0}, {18.6460,0,19.5264,0,20.4740,0.2996},
        {21.5087,0.6762,22.3238,1.4913,22.7004,2.5260}, {23,3.4631,23,4.3261,23,6}};
    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:NSMakePoint(23,7)];
    for (NSInteger i = 0; i < 14; i++) {
        if (i == 3 || i == 10) { [path lineToPoint:NSMakePoint(c[i][4],c[i][5]+1)]; continue; }
        [path curveToPoint:NSMakePoint(c[i][4],c[i][5]+1) controlPoint1:NSMakePoint(c[i][0],c[i][1]+1)
             controlPoint2:NSMakePoint(c[i][2],c[i][3]+1)];
    }
    [path closePath];
    return path;
}

// What the menu bar shows of Control Center's .secondary track and cap asset
// relative to its fill, measured live (the code itself gives the shapes).
static const CGFloat WattBatteryTrackAlpha = 0.475, WattBatteryCapFraction = 0.95;
// The number is drawn in 0.9-opacity ink and knocked out, leaving 10%.
static const CGFloat WattBatteryKnockout = 0.9;

static NSImage *WattControlCenterAsset(NSString *name) {
    static NSBundle *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bundle = [[NSBundle bundleWithPath:@"/System/Library/CoreServices/ControlCenter.app"] retain];
    });
    return [bundle imageForResource:name];
}

// An asset drawn in `ink` (or knocked out, with no ink) centred on a point.
static void WattDrawAsset(NSImage *asset, NSSize size, NSPoint centre, NSColor *ink, CGFloat fraction) {
    if (!asset) return;
    NSRect rect = NSMakeRect(centre.x-size.width/2, centre.y-size.height/2, size.width, size.height);
    if (!ink) {
        [asset drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationDestinationOut fraction:fraction];
        return;
    }
    NSImage *tinted = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect bounds) {
        [asset drawInRect:bounds];
        [ink setFill];
        NSRectFillUsingOperation(bounds, NSCompositingOperationSourceAtop);
        return YES;
    }];
    [tinted drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:fraction];
}

static NSImage *WattMeasuredMenuBattery(NSInteger charge, BOOL pluggedIn, BOOL charging,
                                        BOOL showPercentage, NSColor *fill) {
    charge = MAX(0, MIN(100, charge));
    NSString *mark = charging ? @"battery-bolt" : pluggedIn ? @"battery-plug" : nil;
    return [NSImage imageWithSize:NSMakeSize(26,14) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        // Template images keep only alpha; a coloured one draws its track in
        // the label colour of whatever appearance it lands on.
        NSColor *ink = fill ? NSColor.labelColor : NSColor.whiteColor;
        NSBezierPath *body = WattBatteryBodyPath();
        [[ink colorWithAlphaComponent:WattBatteryTrackAlpha] setFill];
        [body fill];
        [NSGraphicsContext saveGraphicsState];
        [body addClip];
        [(fill ?: ink) setFill];
        NSRectFillUsingOperation(NSMakeRect(0,1,MAX(round(23*charge/100.0),2),12), NSCompositingOperationCopy);
        [NSGraphicsContext restoreGraphicsState];
        WattDrawAsset(WattControlCenterAsset(@"battery-cap"), NSMakeSize(2,12), NSMakePoint(25,7), ink, WattBatteryCapFraction);
        NSPoint centre = NSMakePoint(11.5,7);
        if (showPercentage) {
            // HStack(spacing: -1) { number, 7x8.9 bolt or plug } at x 12;
            // at 100% the number drops to 9 pt and the mark to 5.5x7.
            NSFont *font = mark && charge >= 100 ? [NSFont systemFontOfSize:9] :
                [NSFont preferredFontForTextStyle:NSFontTextStyleFootnote options:@{}];
            NSString *number = [NSString stringWithFormat:@"%ld",(long)charge];
            NSDictionary *style = @{NSFontAttributeName:font, NSForegroundColorAttributeName:NSColor.blackColor};
            NSSize text = [number sizeWithAttributes:style];
            NSSize markSize = !mark ? NSZeroSize : charge >= 100 ? NSMakeSize(5.5,7) : NSMakeSize(7,8.9);
            CGFloat width = text.width + (mark ? markSize.width-1 : 0);
            CGFloat x = (mark ? 12 : centre.x) - width/2;
            NSImage *knock = [NSImage imageWithSize:NSMakeSize(26,14) flipped:NO drawingHandler:^BOOL(NSRect bounds) {
                [number drawAtPoint:NSMakePoint(x, centre.y-text.height/2) withAttributes:style];
                if (mark) WattDrawAsset(WattControlCenterAsset(mark), markSize,
                    NSMakePoint(x+text.width-1+markSize.width/2, centre.y), NSColor.blackColor, 1);
                return YES;
            }];
            [knock drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationDestinationOut
                     fraction:WattBatteryKnockout];
        } else if (mark) {
            // A larger mask clears a gap, then the 13x16 symbol is drawn in ink.
            NSString *large = [mark stringByAppendingString:@"-large"];
            WattDrawAsset(WattControlCenterAsset([mark stringByAppendingString:@"-mask-large"]),
                NSMakeSize(13,16), centre, nil, 1);
            WattDrawAsset(WattControlCenterAsset(large), NSMakeSize(13,16), centre, ink, 1);
        }
        return YES;
    }];
}

NSImage *WattSystemMenuBattery(NSInteger charge, BOOL pluggedIn, BOOL charging,
                             BOOL present, BOOL needsService, BOOL lowPower, BOOL showPercentage) {
    if (!WattNativeBatteryRendererAvailable() || !NSThread.isMainThread) return nil;
    // A failed reading is not evidence of a missing physical battery. Let the
    // caller show Apple's unknown-status symbol instead of a fabricated 0%.
    if (present && charge < 0) return nil;
    if (!present || needsService)
        return BUIBattery(charge,pluggedIn,charging,present,needsService,lowPower,showPercentage);
    // Control Center: Low Power Mode yellow first, then red at 10% or less.
    NSColor *fill = lowPower ? NSColor.systemYellowColor : (charge <= 10 ? NSColor.systemRedColor : nil);
    return WattMeasuredMenuBattery(charge,pluggedIn,charging,showPercentage,fill);
}

// The status button owns mouse/VoiceOver interaction, including the colored
// native glyph drawn above its template metrics. Never intercept its clicks.
@interface WattBatteryColorView : NSImageView @end
@implementation WattBatteryColorView
- (NSView *)hitTest:(NSPoint)point { return nil; }
// Native menu-bar vibrancy owns neutral-ink contrast even when the image also
// contains Apple's red/yellow fill. Do not paint a fixed background or tint it.
- (BOOL)allowsVibrancy { return YES; }
@end

NSImageView *WattCreateBatteryColorView(void) {
    NSImageView *view = [[[WattBatteryColorView alloc] initWithFrame:NSZeroRect] autorelease];
    view.imageScaling = NSImageScaleNone;
    view.accessibilityElement = NO;
    view.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    return view;
}
