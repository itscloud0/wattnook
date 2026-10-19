#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <string.h>

// Private API: fail closed on missing methods or changed ABI. No entitlement
// bypass, powerd writes, adapter control or fallback to raw SMC calls.
int watt_native_charge(int write, int value, int *limit, int *enabled,
                       int *limits, int *count, char **message) {
    @autoreleasepool {
        id client = nil;
        @try {
            static void *framework;
            static dispatch_once_t once;
            dispatch_once(&once, ^{ framework = dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI", RTLD_LAZY | RTLD_LOCAL); });
            if (!framework)
                @throw [NSException exceptionWithName:@"Unavailable" reason:@"PowerUI unavailable" userInfo:nil];
            Class cls = NSClassFromString(@"PowerUISmartChargeClient");
            NSDictionary *abi = @{
                @"initWithClientName:": @"@24@0:8@16", @"isMCLSupported": @"B16@0:8",
                @"getMCLLimitWithError:": @"C24@0:8^@16", @"isMCLCurrentlyEnabled:": @"Q24@0:8^@16",
                @"availableChargeLimitsWithError:": @"@24@0:8^@16",
                @"setMCLLimit:error:": @"B28@0:8C16^@20", @"disableMCL:": @"B24@0:8^@16"};
            for (NSString *name in abi) {
                Method m = class_getInstanceMethod(cls, NSSelectorFromString(name));
                if (!m || strcmp(method_getTypeEncoding(m), [abi[name] UTF8String]))
                    @throw [NSException exceptionWithName:@"Unavailable" reason:@"PowerUI method ABI unsupported" userInfo:nil];
            }
            client = ((id(*)(id,SEL,id))objc_msgSend)([cls alloc], NSSelectorFromString(@"initWithClientName:"), @"WattNook");
            if (!client || !((BOOL(*)(id,SEL))objc_msgSend)(client, NSSelectorFromString(@"isMCLSupported")))
                @throw [NSException exceptionWithName:@"Unavailable" reason:@"Native charge limits unsupported" userInfo:nil];
            NSError *error = nil;
            if (write) {
                BOOL ok = value == 100
                  ? ((BOOL(*)(id,SEL,NSError **))objc_msgSend)(client, NSSelectorFromString(@"disableMCL:"), &error)
                  : ((BOOL(*)(id,SEL,unsigned char,NSError **))objc_msgSend)(client, NSSelectorFromString(@"setMCLLimit:error:"), (unsigned char)value, &error);
                if (!ok || error) @throw [NSException exceptionWithName:@"WriteFailed" reason:error.localizedDescription ?: @"Native setter rejected request" userInfo:nil];
            } else {
                id available = ((id(*)(id,SEL,NSError **))objc_msgSend)(client, NSSelectorFromString(@"availableChargeLimitsWithError:"), &error);
                if (error || ![available isKindOfClass:NSArray.class] || [available count] == 0 || [available count] > 21)
                    @throw [NSException exceptionWithName:@"ReadFailed" reason:error.localizedDescription ?: @"Invalid available limits" userInfo:nil];
                for (id v in available) {
                    if (![v isKindOfClass:NSNumber.class]) @throw [NSException exceptionWithName:@"ReadFailed" reason:@"Invalid limit type" userInfo:nil];
                    limits[(*count)++] = [v intValue];
                }
                *limit = ((unsigned char(*)(id,SEL,NSError **))objc_msgSend)(client, NSSelectorFromString(@"getMCLLimitWithError:"), &error);
                if (error) @throw [NSException exceptionWithName:@"ReadFailed" reason:error.localizedDescription userInfo:nil];
                *enabled = ((unsigned long long(*)(id,SEL,NSError **))objc_msgSend)(client, NSSelectorFromString(@"isMCLCurrentlyEnabled:"), &error) != 0;
                if (error) @throw [NSException exceptionWithName:@"ReadFailed" reason:error.localizedDescription userInfo:nil];
            }
            [client release];
            return 1;
        } @catch (NSException *exception) {
            *message = strdup((exception.reason ?: @"Native charge control failed").UTF8String);
            [client release];
            return 0;
        }
    }
}
