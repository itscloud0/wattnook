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

// Control Center draws the macOS 27 menu-bar battery in private SwiftUI that
// no other process can call (BatteryUIKit's BUIImage is an older, wider,
// dimmer design). These numbers are measured from Control Center's own
// rendering at 2x: a solid 23x12 pt capsule, the charge filled opaque and the
// rest at 47.5%, a 1x4 pt cap at 57%, and the percentage punched out in SF Pro
// Semibold 9.5 pt with tight tracking.
static const NSRect WattBatteryBody = {{0, 1}, {23, 12}};
static const CGFloat WattBatteryCorner = 4, WattBatteryTrackAlpha = 0.475, WattBatteryCapAlpha = 0.57;

static NSImage *WattBatterySymbol(NSString *name, CGFloat size) {
    NSImage *symbol = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    return [symbol imageWithSymbolConfiguration:[NSImageSymbolConfiguration
        configurationWithPointSize:size weight:NSFontWeightBold]];
}

static NSImage *WattMeasuredMenuBattery(NSInteger charge, BOOL pluggedIn, BOOL charging,
                                 BOOL showPercentage, NSColor *fill) {
    charge = MAX(0, MIN(100, charge));
    NSImage *mark = !pluggedIn ? nil : charging ? WattBatterySymbol(@"bolt.fill", showPercentage ? 7 : 9)
        : (WattBatterySymbol(@"powerplug.portrait.fill", showPercentage ? 7 : 9) ?:
           WattBatterySymbol(@"powerplug.fill", showPercentage ? 7 : 9));
    NSString *number = showPercentage ? [NSString stringWithFormat:@"%ld",(long)charge] : nil;
    NSImage *image = [NSImage imageWithSize:NSMakeSize(26,14) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        // Template images keep only alpha; a coloured one draws its track in
        // the label colour of whatever appearance it lands on.
        NSColor *ink = fill ? NSColor.labelColor : NSColor.whiteColor;
        NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:WattBatteryBody
            xRadius:WattBatteryCorner yRadius:WattBatteryCorner];
        [[ink colorWithAlphaComponent:WattBatteryTrackAlpha] setFill];
        [body fill];
        [NSGraphicsContext saveGraphicsState];
        [body addClip];
        [(fill ?: ink) setFill];
        NSRectFillUsingOperation(NSMakeRect(NSMinX(WattBatteryBody),NSMinY(WattBatteryBody),
            round(NSWidth(WattBatteryBody)*charge/100.0*2)/2,NSHeight(WattBatteryBody)),NSCompositingOperationCopy);
        [NSGraphicsContext restoreGraphicsState];
        [[ink colorWithAlphaComponent:WattBatteryCapAlpha] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(24,5,1.6,4) xRadius:0.8 yRadius:0.8] fill];
        NSRectFill(NSMakeRect(24,5,0.8,4));
        // The number (and the bolt or plug beside it) is cut out of the glyph.
        NSFont *font = [NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold];
        NSDictionary *style = @{NSFontAttributeName:font, NSKernAttributeName:@(-0.4)};
        CGFloat numberWidth = number ? [number sizeWithAttributes:style].width+0.4 : 0;
        CGFloat gap = number && mark ? 0.5 : 0, width = numberWidth+gap+mark.size.width;
        CGFloat x = NSMidX(WattBatteryBody)-0.75-width/2, mid = NSMidY(WattBatteryBody);
        NSGraphicsContext.currentContext.compositingOperation = NSCompositingOperationDestinationOut;
        [number drawAtPoint:NSMakePoint(x,mid-font.capHeight/2+font.descender-0.5) withAttributes:style];
        [mark drawInRect:NSMakeRect(x+numberWidth+gap,mid-mark.size.height/2,mark.size.width,mark.size.height)
                fromRect:NSZeroRect operation:NSCompositingOperationDestinationOut fraction:1];
        return YES;
    }];
    return image;
}

NSImage *WattSystemMenuBattery(NSInteger charge, BOOL pluggedIn, BOOL charging,
                             BOOL present, BOOL needsService, BOOL lowPower, BOOL showPercentage) {
    if (!WattNativeBatteryRendererAvailable() || !NSThread.isMainThread) return nil;
    // A failed reading is not evidence of a missing physical battery. Let the
    // caller show Apple's unknown-status symbol instead of a fabricated 0%.
    if (present && charge < 0) return nil;
    if (!present || needsService)
        return BUIBattery(charge,pluggedIn,charging,present,needsService,lowPower,showPercentage);
    NSColor *fill = lowPower ? NSColor.systemYellowColor : (!pluggedIn && charge <= 20 ? NSColor.systemRedColor : nil);
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
