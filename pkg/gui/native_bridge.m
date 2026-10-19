#import "native_internal.h"

static NSString *BattString(const char *value) {
    return value == NULL ? @"" : [NSString stringWithUTF8String:value];
}

static BattMenuController *BattController(BattMenuRef menu) {
    return (BattMenuController *)menu;
}

void batt_dispatch_main(uintptr_t callback) {
    dispatch_async(dispatch_get_main_queue(), ^{ battMainCallback(callback); });
}

void batt_menu_storage_update(BattMenuRef menu, uint64_t generation, const char *json) {
    @autoreleasepool {
        NSData *data=[BattString(json) dataUsingEncoding:NSUTF8StringEncoding];
        id value=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([value isKindOfClass:NSDictionary.class]) WattUpdateStorageReview(BattController(menu),generation,value);
    }
}

BattMenuRef batt_menu_create(uintptr_t handle, const char *version) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        return [[BattMenuController alloc] initWithHandle:handle version:BattString(version)];
    }
}

void batt_menu_destroy(BattMenuRef menu) {
    @autoreleasepool {
        [BattController(menu) release];
    }
}

void batt_app_run(void) {
    @autoreleasepool {
        [[NSApplication sharedApplication] run];
    }
}

void batt_app_terminate(void) {
    @autoreleasepool {
        [[NSApplication sharedApplication] terminate:nil];
    }
}

void batt_menu_set_title(BattMenuRef menu, int item, const char *title) {
    @autoreleasepool {
        [BattController(menu) item:(BattMenuItem)item].title = BattString(title);
    }
}

void batt_menu_set_tooltip(BattMenuRef menu, int item, const char *tooltip) {
    @autoreleasepool {
        [BattController(menu) item:(BattMenuItem)item].toolTip = BattString(tooltip);
    }
}

void batt_menu_set_hidden(BattMenuRef menu, int item, bool hidden) {
    [BattController(menu) item:(BattMenuItem)item].hidden = hidden;
}

void batt_menu_set_enabled(BattMenuRef menu, int item, bool enabled) {
    [BattController(menu) item:(BattMenuItem)item].enabled = enabled;
}

void batt_menu_set_checked(BattMenuRef menu, int item, bool checked) {
    [BattController(menu) item:(BattMenuItem)item].state = checked
        ? NSControlStateValueOn : NSControlStateValueOff;
}

void batt_menu_set_status_icon(BattMenuRef menu,
                               bool installed,
                               bool capable,
                               bool needs_upgrade) {
    @autoreleasepool {
        [BattController(menu) setStatusIconInstalled:installed
                                            capable:capable
                                       needsUpgrade:needs_upgrade];
    }
}

void batt_menu_set_power(BattMenuRef menu, int item, const char *label, double value) {
    @autoreleasepool {
        [BattController(menu) setPowerItem:(BattMenuItem)item label:BattString(label) value:value];
    }
}

void batt_menu_set_heat_status(BattMenuRef menu, bool paused, double temperature_celsius) {
    BattController(menu).powerFlowView.heatPaused = paused;
    BattController(menu).powerFlowView.temperatureCelsius = temperature_celsius;
}

void batt_menu_set_processor_temperature(BattMenuRef menu, double celsius) {
    BattController(menu).powerFlowView.processorTemperatureCelsius = celsius;
    [BattController(menu).powerFlowView setNeedsDisplay:YES];
}

void batt_menu_set_heat_detail(BattMenuRef menu, const char *detail) {
    @autoreleasepool { BattController(menu).heatDetail = BattString(detail); }
}

void batt_menu_set_power_flow(BattMenuRef menu,
                              double adapter,
                              double system,
                              double battery,
                              bool heat_paused,
                              double temperature_celsius) {
    @autoreleasepool {
        [BattController(menu) setPowerFlowAdapter:adapter
                                           system:system
                                          battery:battery
                                       heatPaused:heat_paused
                                      temperature:temperature_celsius];
    }
}

void batt_menu_set_limit(BattMenuRef menu, int limit_percent) {
    @autoreleasepool {
        [BattController(menu) setLimitPercent:limit_percent];
    }
}

void batt_menu_set_limit_choices(BattMenuRef menu, const int *values, int count) {
    @autoreleasepool {
        NSMutableArray *limits = [NSMutableArray array];
        for (int i=0; i<count; i++) [limits addObject:@(values[i])];
        BattController(menu).powerFlowView.supportedLimits = limits.count ? limits : nil;
    }
}

void batt_menu_set_live_status(BattMenuRef menu,
                               int charge_percent,
                               bool plugged_in,
                               bool charging,
                               bool heat_paused) {
    @autoreleasepool {
        [BattController(menu) setLiveStatusCharge:charge_percent
                                         pluggedIn:plugged_in
                                          charging:charging
                                       heatPaused:heat_paused];
        // Finish the daemon refresh with one coherent local snapshot, rather than
        // leaving separate power/connection requests visible during a transition.
        BattUpdateBattery(BattController(menu));
    }
}
