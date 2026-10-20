#import "native_internal.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>

void BattUpdateBattery(BattMenuController *controller) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
        IOServiceMatching("AppleSmartBattery"));
    if (!service) {
        [controller setLiveStatusCharge:-1 pluggedIn:NO charging:NO heatPaused:NO present:NO needsService:NO];
        return;
    }
    CFMutableDictionaryRef properties = NULL;
    kern_return_t result = IORegistryEntryCreateCFProperties(service,&properties,kCFAllocatorDefault,0);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS || !properties) {
        if (properties) CFRelease(properties);
        [controller setLiveStatusCharge:-1 pluggedIn:NO charging:NO heatPaused:NO present:YES needsService:NO];
        return;
    }
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)properties];
    CFRelease(properties);
    // Read Apple's reported health/presence, never infer service from cycles or
    // capacity. Reuse the existing battery refresh; no observer or new timer.
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    CFArrayRef sources = info ? IOPSCopyPowerSourcesList(info) : NULL;
    for (id source in (NSArray *)sources) {
        NSDictionary *description = (NSDictionary *)IOPSGetPowerSourceDescription(info,(CFTypeRef)source);
        if (![description[@kIOPSTypeKey] isEqual:@kIOPSInternalBatteryType]) continue;
        for (NSString *key in @[@kIOPSBatteryHealthKey,@kIOPSBatteryHealthConditionKey])
            if (description[key]) snapshot[key] = description[key];
        if ([description[@kIOPSIsPresentKey] isKindOfClass:NSNumber.class])
            snapshot[@"BatteryInstalled"] = description[@kIOPSIsPresentKey];
        break;
    }
    if (sources) CFRelease(sources);
    if (info) CFRelease(info);
    BattApplyBatterySnapshot(controller,snapshot);
}

void BattApplyBatterySnapshot(BattMenuController *controller, NSDictionary *battery) {
    NSNumber *connected = battery[@"ExternalConnected"], *voltage = battery[@"Voltage"];
    NSNumber *current = battery[@"InstantAmperage"] ?: battery[@"Amperage"];
    NSNumber *charge = battery[@"CurrentCapacity"];
    NSNumber *charging = battery[@"IsCharging"];
    BOOL present = ![battery[@"BatteryInstalled"] isKindOfClass:NSNumber.class] || [battery[@"BatteryInstalled"] boolValue];
    BOOL service = [battery[@kIOPSBatteryHealthKey] isEqual:@kIOPSPoorValue] ||
        [battery[@kIOPSBatteryHealthConditionKey] isEqual:@kIOPSCheckBatteryValue] ||
        [battery[@kIOPSBatteryHealthConditionKey] isEqual:@kIOPSPermanentFailureValue];
    BOOL known = present && [charge isKindOfClass:NSNumber.class] && [connected isKindOfClass:NSNumber.class];
    double watts = [voltage isKindOfClass:NSNumber.class] && [current isKindOfClass:NSNumber.class]
        ? voltage.doubleValue * current.longLongValue / 1000000.0 : NAN;
    [controller setLiveStatusCharge:known ? charge.integerValue : -1 pluggedIn:known && connected.boolValue
        charging:known && connected.boolValue && ([charging isKindOfClass:NSNumber.class]
            ? charging.boolValue : isfinite(watts) && watts > 0.25)
        heatPaused:controller.powerFlowView.heatPaused present:present needsService:service];
    // Health: full-charge capacity against design capacity. macOS 27 keeps
    // both in BatteryData; older releases report them at the top level.
    NSDictionary *data = [battery[@"BatteryData"] isKindOfClass:NSDictionary.class] ? battery[@"BatteryData"] : @{};
    NSNumber *full = data[@"NominalChargeCapacity"] ?: battery[@"NominalChargeCapacity"] ?: battery[@"AppleRawMaxCapacity"];
    NSNumber *design = data[@"DesignCapacity"] ?: battery[@"DesignCapacity"];
    BattPowerFlowView *flow = controller.powerFlowView;
    if ([full isKindOfClass:NSNumber.class] && [design isKindOfClass:NSNumber.class] &&
        design.doubleValue > 0 && full.doubleValue > 0) {
        NSInteger health = (NSInteger)lround(MIN(100.0, 100.0 * full.doubleValue / design.doubleValue));
        if (health != flow.healthPercent) { flow.healthPercent = health; flow.needsDisplay = YES; }
    }
    NSNumber *cycles = battery[@"CycleCount"];
    if ([cycles isKindOfClass:NSNumber.class]) {
        flow.cycleCount = cycles.integerValue;
    }
    if ([connected isKindOfClass:NSNumber.class] && [voltage isKindOfClass:NSNumber.class] &&
        [current isKindOfClass:NSNumber.class] && [charge isKindOfClass:NSNumber.class]) {
        BOOL plugged = connected.boolValue;
        NSDictionary *power = battery[@"PowerTelemetryData"];
        double adapter = plugged ? [power[@"SystemPowerIn"] doubleValue]/1000.0 : 0;
        // All three flow values and the connection state come from this one snapshot.
        // Never reuse adapter input after unplugging or invent load from adapter rating.
        if (isfinite(watts) && fabs(watts) < 250 && adapter >= 0 && adapter < 250) {
            [controller setPowerItem:BattItemPowerAdapter label:@"Adapter" value:adapter];
            [controller setPowerItem:BattItemPowerSystem label:@"System" value:MAX(0,adapter-watts)];
            [controller setPowerItem:BattItemPowerBattery label:@"Battery" value:watts];
            [controller setPowerFlowAdapter:adapter system:MAX(0,adapter-watts) battery:watts
                heatPaused:controller.powerFlowView.heatPaused
                temperature:controller.powerFlowView.temperatureCelsius];
        }
    }
}
