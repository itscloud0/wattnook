#import <Foundation/Foundation.h>
#include <string.h>

// Root CurrentUser/AnyHost scope, as written by AlDente's privileged helper. No arbitrary domain/key
// writer; the key list is fixed to the topoff-protection hold sequence.
static NSString * const domain = @"com.apple.smartcharging.topoffprotection";
static NSArray *keys(void) {
    return @[@"checkpoint", @"currentState", @"MCLTempDisabledUntilDate",
             @"mclLimitValue", @"MCLFeatureState", @"isEngaged",
             @"isManuallyChargeLimited", @"enabled"];
}
static NSDictionary *readValues(void) {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *key in keys()) {
        id value = CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)key,
            (__bridge CFStringRef)domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
        if (value) values[key] = value;
    }
    return values;
}
static void setValue(NSString *key, id value) {
    CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value,
        (__bridge CFStringRef)domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (!CFPreferencesSynchronize((__bridge CFStringRef)domain,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
        @throw [NSException exceptionWithName:@"Sync" reason:@"preferences synchronization failed" userInfo:nil];
}
static void notify(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.apple.smartcharging.defaultschanged"), NULL, NULL, true);
}
// 0 snapshot/read; 1 apply one hold; 2 restore a validated private snapshot.
int wattnook_charge_hold_preferences(int operation, int target, void *input, int inputSize,
                     void **output, int *outputSize, int *readLimit, char **message) {
    @autoreleasepool {
        @try {
            if (operation == 1) {
                if (target < 5 || target > 99)
                    @throw [NSException exceptionWithName:@"Target" reason:@"hold target outside 5–99" userInfo:nil];
                for (NSString *key in [keys() subarrayWithRange:NSMakeRange(0, 3)]) setValue(key, nil);
                setValue(@"mclLimitValue", @(target));
                setValue(@"MCLFeatureState", @1);
                setValue(@"isEngaged", @1);
                setValue(@"isManuallyChargeLimited", @1);
                notify();
            } else if (operation == 2) {
                NSData *data = [NSData dataWithBytes:input length:inputSize];
                NSError *error = nil;
                id snapshot = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:&error];
                if (error || ![snapshot isKindOfClass:NSDictionary.class] ||
                    ![snapshot[@"version"] isEqual:@1] ||
                    ![snapshot[@"values"] isKindOfClass:NSDictionary.class])
                    @throw [NSException exceptionWithName:@"Snapshot" reason:@"invalid recovery snapshot" userInfo:nil];
                NSDictionary *values = snapshot[@"values"];
                for (id key in values) if (![keys() containsObject:key])
                    @throw [NSException exceptionWithName:@"Snapshot" reason:@"unexpected recovery key" userInfo:nil];
                // Restore all fields before notification, then verify exact values.
                for (NSString *key in keys()) setValue(key, values[key]);
                notify();
                if (![readValues() isEqualToDictionary:values])
                    @throw [NSException exceptionWithName:@"Restore" reason:@"preferences restoration disagrees" userInfo:nil];
            } else if (operation != 0) {
                @throw [NSException exceptionWithName:@"Operation" reason:@"invalid preferences operation" userInfo:nil];
            }
            NSDictionary *values = readValues();
            id value = values[@"mclLimitValue"];
            *readLimit = [value isKindOfClass:NSNumber.class] ? [value intValue] : -1;
            NSError *error = nil;
            NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{@"version": @1, @"values": values}
                format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
            if (error || !data || data.length > 65536)
                @throw [NSException exceptionWithName:@"Snapshot" reason:@"cannot encode recovery snapshot" userInfo:nil];
            *outputSize = (int)data.length;
            *output = malloc(data.length);
            if (!*output) @throw [NSException exceptionWithName:@"Memory" reason:@"snapshot allocation failed" userInfo:nil];
            memcpy(*output, data.bytes, data.length);
            return 1;
        } @catch (NSException *exception) {
            *message = strdup((exception.reason ?: @"preferences operation failed").UTF8String);
            return 0;
        }
    }
}
