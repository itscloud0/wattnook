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
    if ([palette isEqual:@"Mint"]) return NSColor.systemMintColor;
    if ([palette isEqual:@"Violet"]) return NSColor.systemPurpleColor;
    if ([palette isEqual:@"Amber"]) return NSColor.systemOrangeColor;
    if (WattGlassTheme()) return NSColor.controlAccentColor;
    return NSColor.systemBlueColor;
}
NSColor *WattWarningColor(void) {
    return NSColor.systemOrangeColor;
}
NSColor *WattSurfaceColor(BOOL lighter) {
    CGFloat base = lighter ? 0.13 : 0.085;
    NSColor *surface = [NSColor colorWithCalibratedRed:base
        green:base+0.035 blue:base+0.080 alpha:1];
    return WattGlassTheme() ? [surface colorWithAlphaComponent:0.45] : surface;
}
// Apple's dark grouped greys: a neutral ground and one step lighter for
// groups. No gradient and no tint; colour belongs to the data.
NSColor *WattGroundColor(void) {
    NSColor *ground = [NSColor colorWithSRGBRed:0x1C/255.0 green:0x1C/255.0 blue:0x1E/255.0 alpha:1];
    return WattGlassTheme() ? [ground colorWithAlphaComponent:0.55] : ground;
}
NSColor *WattTileColor(BOOL highlighted) {
    if (WattGlassTheme()) return [NSColor.whiteColor colorWithAlphaComponent:highlighted ? 0.14 : 0.08];
    CGFloat level = highlighted ? 0x3A/255.0 : 0x2C/255.0;
    return [NSColor colorWithSRGBRed:level green:level blue:level + 0x02/255.0 alpha:1];
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
// "On when plugged in": WattNook switches Keep Awake with the power source.
BOOL WattKeepAwakeFollowsPower(void) {
    return [[NSUserDefaults.standardUserDefaults stringForKey:@"WattNookKeepAwakeMode"] isEqual:@"plugged"];
}
// Unplugging keeps sleep off this long, so a charger drop-out never lets a
// closed Mac fall asleep mid-task.
BOOL WattKeepAwakeWanted(BOOL pluggedIn, NSTimeInterval unpluggedFor) {
    return pluggedIn || unpluggedFor < 30;
}
// AI usage pages: page n+1 belongs to WattAIProviderIDs()[n].
NSArray *WattAIProviderIDs(void) { return @[@"claude", @"codex", @"grok"]; }
NSString *WattAIProviderName(NSString *provider) {
    return @{@"claude":@"Claude", @"codex":@"ChatGPT", @"grok":@"Grok"}[provider] ?: provider;
}
// The user's order: saved providers first, any not yet saved after them.
NSArray *WattAIUsageOrder(void) {
    NSArray *known = WattAIProviderIDs();
    NSMutableArray *order = [NSMutableArray array];
    for (id provider in [NSUserDefaults.standardUserDefaults arrayForKey:@"WattNookAIUsageOrder"])
        if ([known containsObject:provider] && ![order containsObject:provider]) [order addObject:provider];
    for (NSString *provider in known) if (![order containsObject:provider]) [order addObject:provider];
    return order;
}
NSArray *WattAIUsageShown(void) {
    NSArray *hidden = [NSUserDefaults.standardUserDefaults arrayForKey:@"WattNookAIUsageHidden"];
    NSMutableArray *shown = [NSMutableArray array];
    for (NSString *provider in WattAIUsageOrder()) if (![hidden containsObject:provider]) [shown addObject:provider];
    return shown;
}
// Off by default: on, WattNook reads the Claude Code and Codex logins and
// Grok Bot's cached reading.
BOOL WattMenuAIUsage(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:@"WattNookMenuAIUsage"];
}
