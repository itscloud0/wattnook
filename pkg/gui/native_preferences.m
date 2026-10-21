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
// Energy and selection are light tones so they read on every sky.
NSColor *WattAccentColor(void) {
    NSString *palette = [NSUserDefaults.standardUserDefaults stringForKey:@"WattNookPalette"];
    if ([palette isEqual:@"Mint"]) return [NSColor colorWithSRGBRed:0.42 green:0.92 blue:0.78 alpha:1];
    if ([palette isEqual:@"Violet"]) return [NSColor colorWithSRGBRed:0.78 green:0.67 blue:1.00 alpha:1];
    if ([palette isEqual:@"Amber"]) return [NSColor colorWithSRGBRed:1.00 green:0.78 blue:0.42 alpha:1];
    if (WattGlassTheme()) return NSColor.controlAccentColor;
    return [NSColor colorWithSRGBRed:0.55 green:0.80 blue:1.00 alpha:1];
}
NSColor *WattWarningColor(void) {
    return [NSColor colorWithSRGBRed:1.00 green:0.72 blue:0.38 alpha:1];
}
NSColor *WattSurfaceColor(BOOL lighter) {
    CGFloat base = lighter ? 0.13 : 0.085;
    NSColor *surface = [NSColor colorWithCalibratedRed:base
        green:base+0.035 blue:base+0.080 alpha:1];
    return WattGlassTheme() ? [surface colorWithAlphaComponent:0.45] : surface;
}
static NSColor *Hex(unsigned rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0
                                blue:(rgb & 0xFF) / 255.0 alpha:1];
}
// Bottom, middle, top. Each sky keeps white text at 4.5:1 or better where text
// sits; the brightest hue stays in the top band behind the header.
NSGradient *WattSkyGradient(WattSky sky) {
    unsigned stops[3];
    switch (sky) {
    case WattSkyCharging:  stops[0] = 0x0B2240; stops[1] = 0x184A7E; stops[2] = 0x2563A0; break; // day
    case WattSkyHeld:      stops[0] = 0x101830; stops[1] = 0x1F2D58; stops[2] = 0x2F4580; break; // dusk
    case WattSkyHeat:      stops[0] = 0x24133A; stops[1] = 0x7E2C5C; stops[2] = 0xB04A2E; break; // sunset
    case WattSkyBattery:   stops[0] = 0x0A0B1C; stops[1] = 0x171A3C; stops[2] = 0x262B5E; break; // night
    case WattSkyDischarge: stops[0] = 0x110E28; stops[1] = 0x2B2052; stops[2] = 0x4F3683; break; // twilight
    default:               stops[0] = 0x161E2A; stops[1] = 0x1B2532; stops[2] = 0x212B3A; break; // overcast
    }
    CGFloat alpha = WattGlassTheme() ? 0.62 : 1;
    NSArray *colors = @[[Hex(stops[0]) colorWithAlphaComponent:alpha], [Hex(stops[1]) colorWithAlphaComponent:alpha],
                        [Hex(stops[2]) colorWithAlphaComponent:alpha]];
    CGFloat locations[3] = {0, 0.55, 1};
    return [[[NSGradient alloc] initWithColors:colors atLocations:locations
        colorSpace:NSColorSpace.sRGBColorSpace] autorelease];
}
NSColor *WattTileColor(BOOL highlighted) {
    return [NSColor.whiteColor colorWithAlphaComponent:highlighted ? 0.16 : 0.10];
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
