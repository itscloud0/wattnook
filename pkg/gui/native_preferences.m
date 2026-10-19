#import "native_internal.h"

// Glass lets the popover's own Liquid Glass show through and puts system glass
// behind the main controls; it needs the macOS 26 glass APIs.
BOOL WattGlassAvailable(void) {
    return [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){26,0,0}] &&
        NSClassFromString(@"NSGlassEffectView") != Nil &&
        NSClassFromString(@"NSGlassEffectContainerView") != Nil;
}
BOOL WattGlassTheme(void) {
    return WattGlassAvailable() &&
        [[NSUserDefaults.standardUserDefaults stringForKey:@"WattNookPalette"] isEqual:@"Glass"];
}
NSColor *WattAccentColor(void) {
    NSString *palette = [NSUserDefaults.standardUserDefaults stringForKey:@"WattNookPalette"];
    if ([palette isEqual:@"Mint"]) return [NSColor colorWithCalibratedRed:0.20 green:0.78 blue:0.64 alpha:1];
    if ([palette isEqual:@"Violet"]) return [NSColor colorWithCalibratedRed:0.64 green:0.46 blue:0.96 alpha:1];
    if ([palette isEqual:@"Amber"]) return [NSColor colorWithCalibratedRed:0.94 green:0.63 blue:0.23 alpha:1];
    if (WattGlassTheme()) return NSColor.controlAccentColor;
    return NSColor.systemBlueColor;
}
NSColor *WattSurfaceColor(BOOL lighter) {
    CGFloat base = lighter ? 0.13 : 0.085;
    NSColor *surface = [NSColor colorWithCalibratedRed:base
        green:base+0.035 blue:base+0.080 alpha:1];
    return WattGlassTheme() ? [surface colorWithAlphaComponent:0.45] : surface;
}
NSArray *WattMenuMetrics(void) {
    NSArray *saved = [NSUserDefaults.standardUserDefaults arrayForKey:@"WattNookMenuMetrics"];
    if (!saved) return @[@"CPU", @"RAM", @"SSD"];
    NSMutableArray *valid = [NSMutableArray array];
    for (NSString *metric in @[@"CPU", @"RAM", @"SSD", @"Battery"])
        if ([saved containsObject:metric]) [valid addObject:metric];
    return valid;
}
BOOL WattMenuBatteryIcon(void) {
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:@"WattNookMenuBatteryIcon"];
    return saved == nil ? YES : [saved boolValue];
}
