#import "native_internal.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <string.h>

// Use Apple's installed macOS 27 renderer, not a reconstruction or a bundled
// copy of its artwork. This UI-only path creates no power-source observer.
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

BOOL WattNativeBatteryRendererAvailable(void) { return BatteryImageClass() != Nil; }

NSImage *WattSystemMenuBattery(NSInteger charge, BOOL pluggedIn, BOOL charging,
                             BOOL present, BOOL needsService, BOOL lowPower, BOOL showPercentage) {
    Class cls = BatteryImageClass();
    if (!cls || !NSThread.isMainThread) return nil;
    // A failed reading is not evidence of a missing physical battery. Let the
    // caller show Apple's unknown-status symbol instead of a fabricated 0%.
    if (present && charge < 0) return nil;
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
