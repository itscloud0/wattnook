#import <Cocoa/Cocoa.h>
#import <stdint.h>

#include "native.h"

double BattProcessCPUPercent(uint64_t previous, uint64_t current, double elapsed,
                             uint32_t numer, uint32_t denom);
NSString *WattCPUUsageLabel(double corePercent, NSUInteger processorCount);
NSDictionary *WattLidBrightnessPlan(BOOL enabled, BOOL closed, NSNumber *current, NSNumber *saved);
BOOL WattKeepLidGuard(NSNumber *status, BOOL currentlyGuarded);
BOOL WattMonitoringEnabled(void);
BOOL WattHistoryEnabled(void);
NSInteger WattMemoryPressureLevel(void);
NSString *WattMemoryPressureLabel(NSInteger level);
void WattReadSleepStatus(NSString *executable, NSArray<NSString *> *arguments, NSTimeInterval timeout,
                        void (^completion)(NSNumber *status, NSString *error));
NSString *WattSleepBlockerReport(void);
BOOL WattNativeBatteryRendererAvailable(void);
NSImage *WattSystemMenuBattery(NSInteger charge, BOOL pluggedIn, BOOL charging,
                             BOOL present, BOOL needsService, BOOL lowPower);
NSImageView *WattCreateBatteryColorView(void);

typedef struct {
    NSTimeInterval time;
    double cpu, memory, watts, disk;
} WattMetricSample;
enum { WattHistoryCapacity = 90 };
@interface WattMetricHistory : NSObject {
    WattMetricSample _samples[WattHistoryCapacity];
    NSUInteger _count, _next;
}
@property(nonatomic, readonly) NSUInteger count;
- (void)append:(WattMetricSample)sample;
- (WattMetricSample)sampleAtIndex:(NSUInteger)index;
@end
@interface WattHistoryView : NSView
@property(nonatomic, retain) WattMetricHistory *history;
@end

@class WattPowerStripView;
@interface BattPowerFlowView : NSView
// The last 15 minutes of Mac power, one sample per 10 s (90 at most).
@property(nonatomic, assign) WattPowerStripView *stripView;
- (void)recordMacWatts:(double)watts charging:(BOOL)charging heat:(BOOL)heat onBattery:(BOOL)onBattery;
- (NSInteger)powerSampleCount;
- (double)powerSampleAt:(NSInteger)index state:(NSInteger *)state;
@property(nonatomic, assign) double adapterWatts;
@property(nonatomic, assign) double systemWatts;
@property(nonatomic, assign) double batteryWatts;
@property(nonatomic, assign) double temperatureCelsius;
// Hottest CPU/GPU die sensor; <= 0 when unavailable.
@property(nonatomic, assign) double processorTemperatureCelsius;
// Capacity left against design capacity (0 = unknown) and charge cycles (-1 = unknown).
@property(nonatomic, assign) NSInteger healthPercent;
@property(nonatomic, assign) NSInteger cycleCount;
@property(nonatomic, assign) NSInteger chargePercent;
@property(nonatomic, assign) NSInteger limitPercent;
@property(nonatomic, copy) NSArray<NSNumber *> *supportedLimits;
@property(nonatomic, assign) BOOL pluggedIn;
@property(nonatomic, assign) BOOL chargingStateKnown;
@property(nonatomic, assign) BOOL batteryCharging;
@property(nonatomic, assign) BOOL heatPaused;
// Charge modes from the daemon (native charge hold).
@property(nonatomic, assign) BOOL topUpActive;
@property(nonatomic, assign) BOOL sailing;
@property(nonatomic, assign) NSInteger sailingLevel;
@property(nonatomic, assign) BOOL dischargingToLimit;
@property(nonatomic, assign) BOOL hasTelemetry;
@property(nonatomic, assign) BOOL limitEditable;
@property(nonatomic, assign) id limitTarget;
@property(nonatomic, assign) SEL limitAction;
@property(nonatomic, assign, readonly) NSInteger displayedLimitPercent;
@property(nonatomic, assign) BOOL flowAnimationEnabled;
@end

@interface BattMenuController : NSObject <NSMenuDelegate, NSPopoverDelegate> {
    uint64_t _previousCPUTicks[4];
    BOOL _hasCPUSample;
    NSInteger _statsTickCount;
    double _cpuPercent;
    double _memoryPercent;
    double _diskPercent;
    NSTimeInterval _previousProcessSampleTime;
}
@property(nonatomic, assign) uintptr_t handle;
@property(nonatomic, retain) NSStatusItem *statusItem;
@property(nonatomic, retain) NSImage *batteryIcon;
@property(nonatomic, retain) NSImageView *batteryColorView;
@property(nonatomic, assign) BOOL batteryIconHasColor;
@property(nonatomic, retain) NSMenu *menu;
@property(nonatomic, retain) NSMutableDictionary<NSNumber *, NSMenuItem *> *items;
@property(nonatomic, retain) NSTimer *timer;
@property(nonatomic, retain) NSTimer *statsTimer;
@property(nonatomic, retain) BattPowerFlowView *powerFlowView;
@property(nonatomic, retain) NSPopover *popover;
@property(nonatomic, retain) NSView *storageView;
@property(nonatomic, assign) uint64_t storageGeneration;
@property(nonatomic, retain) NSButton *chargeButton;
@property(nonatomic, retain) NSButton *heatButton;
@property(nonatomic, copy) NSString *heatDetail;
@property(nonatomic, retain) NSButton *darkButton;
@property(nonatomic, assign) BOOL keepAwakeChanging;
@property(nonatomic, assign) BOOL keepAwakeStatusReading;
@property(nonatomic, assign) BOOL keepAwakeTogglePending;
@property(nonatomic, assign) BOOL awakeDiagnosticsLoading;
@property(nonatomic, retain) NSWindowController *awakeDetailsWindow;
@property(nonatomic, copy) NSString *awakeBlockerReport;
@property(nonatomic, retain) NSDate *awakeSnapshotDate;
@property(nonatomic, retain) NSNumber *keepAwakeStatus;
@property(nonatomic, copy) NSString *keepAwakeError;
@property(nonatomic, copy) NSString *lidGuardError;
@property(nonatomic, retain) NSObject *lidGuard;
@property(nonatomic, assign) NSTimeInterval keepAwakeStatusTime;
@property(nonatomic, retain) NSButton *statsButton;
@property(nonatomic, retain) NSButton *memoryButton;
@property(nonatomic, retain) NSButton *diskButton;
@property(nonatomic, retain) NSTextField *cpuTopAppLabel;
@property(nonatomic, retain) NSTextField *memoryTopAppLabel;
@property(nonatomic, retain) NSButton *cpuQuitButton;
@property(nonatomic, retain) NSButton *memoryQuitButton;
@property(nonatomic, retain) NSDictionary *cpuFeaturedApp;
@property(nonatomic, retain) NSDictionary *memoryFeaturedApp;
@property(nonatomic, retain) NSMenu *cpuAppsMenu;
@property(nonatomic, retain) NSMenu *memoryAppsMenu;
@property(nonatomic, retain) NSArray<NSDictionary *> *appStats;
@property(nonatomic, retain) NSDictionary<NSNumber *, NSArray *> *previousProcessCPU;
@property(nonatomic, retain) NSDictionary *previousProcessDisk;
@property(nonatomic, retain) NSDictionary *previousDiskCounters;
@property(nonatomic, assign) NSTimeInterval previousDiskSampleTime;
@property(nonatomic, assign) double diskReadRate;
@property(nonatomic, assign) double diskWriteRate;
@property(nonatomic, assign) double diskSpacePercent;
@property(nonatomic, assign) uint64_t diskTotalBytes;
@property(nonatomic, assign) uint64_t diskFreeBytes;
@property(nonatomic, assign) double swapUsedBytes;
@property(nonatomic, assign) NSInteger memoryPressure;
@property(nonatomic, assign) NSTimeInterval memoryPressureSince;
@property(nonatomic, retain) WattMetricHistory *metricHistory;
@property(nonatomic, assign) BOOL systemPageVisible;

- (instancetype)initWithHandle:(uintptr_t)handle version:(NSString *)version;
- (NSMenuItem *)item:(BattMenuItem)item;
- (void)rememberItem:(NSMenuItem *)item as:(BattMenuItem)identifier;
- (void)menuAction:(NSMenuItem *)sender;
- (void)noop:(NSMenuItem *)sender;
- (void)setStatusIconInstalled:(BOOL)installed
                       capable:(BOOL)capable
                  needsUpgrade:(BOOL)needsUpgrade;
- (void)setPowerItem:(BattMenuItem)item label:(NSString *)label value:(double)value;
- (void)setPowerFlowAdapter:(double)adapter
                     system:(double)system
                    battery:(double)battery
                 heatPaused:(BOOL)heatPaused
                temperature:(double)temperature;
- (void)setLimitPercent:(NSInteger)limitPercent;
- (void)setLiveStatusCharge:(NSInteger)charge
                   pluggedIn:(BOOL)pluggedIn
                    charging:(BOOL)charging
                 heatPaused:(BOOL)heatPaused;
- (void)setLiveStatusCharge:(NSInteger)charge pluggedIn:(BOOL)pluggedIn charging:(BOOL)charging
                heatPaused:(BOOL)heatPaused present:(BOOL)present needsService:(BOOL)needsService;
- (void)updateSystemStats:(NSTimer *)timer;
- (void)applyMonitoringPreferences;
- (void)refreshStatusImage;
- (void)updateAppStats;
- (void)updateDiagnosticMenus;
- (void)quitDiagnosedApp:(NSMenuItem *)sender;
- (void)toggleKeepAwake;
- (void)setCustomHeatProtection;
- (void)refreshPopoverControls;
- (void)commitLimitFromRail:(BattPowerFlowView *)sender;
- (BOOL)isKeepAwakeActive;
- (void)readKeepAwakeStatus:(void (^)(NSNumber *, NSString *))completion;
- (void)requestKeepAwakeStatus;
- (void)syncKeepAwakeLidGuard;
- (void)performKeepAwakeToggle;
- (void)showKeepAwakeDiagnostics:(id)sender;
- (void)refreshKeepAwakeDiagnostics:(id)sender;
- (void)showStorageReview:(id)sender;
@end

void WattShowStorageReview(BattMenuController *controller);
NSView *WattCreateStorageReview(BattMenuController *controller);
void WattSetStorageReviewActive(BattMenuController *controller, BOOL active);
void WattCloseStorageReview(BattMenuController *controller);
void BattShowStoragePage(BattMenuController *controller);
void WattUpdateStorageReview(BattMenuController *controller, uint64_t generation, NSDictionary *snapshot);

void WattSyncLidGuard(BattMenuController *controller, BOOL enabled);
void WattRecordAwakeEvent(NSString *event);
NSString *WattAwakeReport(BattMenuController *controller);
void WattShowAwakeDetails(BattMenuController *controller);
void WattRefreshAwakeDetails(BattMenuController *controller);

void BattBuildMenu(BattMenuController *controller, NSString *version);
void BattApplyTooltips(BattMenuController *controller);
void BattBuildPopover(BattMenuController *controller);
void BattRefreshPopover(BattMenuController *controller, double cpu, double memory);
NSString *WattCompactBytes(double bytes, BOOL binary);
void BattUpdateStorage(BattMenuController *controller);
void BattUpdateBattery(BattMenuController *controller);
void BattApplyBatterySnapshot(BattMenuController *controller, NSDictionary *battery);
BOOL WattGlassAvailable(void);
BOOL WattGlassTheme(void);
NSColor *WattAccentColor(void);
NSButton *WattActionButton(NSView *parent, NSRect frame, NSString *title, NSString *symbol, id target, SEL action);
void WattSetButtonSelected(NSButton *button, BOOL selected);
void WattSetButtonPlain(NSButton *button, BOOL plain);
void WattSetButtonGrouped(NSButton *button, BOOL grouped);
void BattRecyclePopover(BattMenuController *controller);
NSColor *WattSurfaceColor(BOOL lighter);
NSColor *WattGroundColor(void);
// The 15-minute Mac-power strip, drawn from BattPowerFlowView's samples.
@interface WattPowerStripView : NSView
@property(nonatomic, assign) BattPowerFlowView *source;
@end
// Groups sit one grey step above the ground, no border.
NSColor *WattTileColor(BOOL highlighted);
NSColor *WattWarningColor(void);
NSArray *WattMenuMetrics(void);
BOOL WattMenuBatteryIcon(void);
double BattCounterRate(uint64_t previous, uint64_t current, double elapsed);
