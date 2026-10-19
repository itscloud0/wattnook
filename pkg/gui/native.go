package gui

/*
#cgo CFLAGS: -mmacosx-version-min=13.0
#cgo LDFLAGS: -mmacosx-version-min=13.0 -framework Cocoa -framework ServiceManagement -framework CoreFoundation -framework IOKit -framework QuartzCore -framework Security
#include <stdlib.h>
#include "native.h"
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"runtime/cgo"
	"unsafe"

	"github.com/charlie0129/batt/pkg/cleanup"
	"github.com/charlie0129/batt/pkg/compatibility"
	"github.com/sirupsen/logrus"
)

func inspectStorageApplication(path string) (cleanup.AppIdentity, error) {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	raw := C.WattInspectStorageApplication(p)
	if raw == nil {
		return cleanup.AppIdentity{}, cleanup.ErrNotApplicationBundle
	}
	defer C.free(unsafe.Pointer(raw))
	var app struct {
		cleanup.AppIdentity
		InspectionError string `json:"inspectionError"`
	}
	err := json.Unmarshal([]byte(C.GoString(raw)), &app)
	if err == nil && app.InspectionError != "" {
		err = fmt.Errorf("%s", app.InspectionError)
	}
	return app.AppIdentity, err
}

type menuItem int

const (
	itemPowerFlowCanvas         menuItem = C.BattItemPowerFlowCanvas
	itemPowerFlow               menuItem = C.BattItemPowerFlow
	itemPowerFlowSummary        menuItem = C.BattItemPowerFlowSummary
	itemPowerSystem             menuItem = C.BattItemPowerSystem
	itemPowerAdapter            menuItem = C.BattItemPowerAdapter
	itemPowerBattery            menuItem = C.BattItemPowerBattery
	itemUpgrade                 menuItem = C.BattItemUpgrade
	itemInstall                 menuItem = C.BattItemInstall
	itemState                   menuItem = C.BattItemState
	itemCurrentLimit            menuItem = C.BattItemCurrentLimit
	itemQuickLimits             menuItem = C.BattItemQuickLimits
	itemLimit50                 menuItem = C.BattItemLimit50
	itemLimit60                 menuItem = C.BattItemLimit60
	itemLimit70                 menuItem = C.BattItemLimit70
	itemLimit80                 menuItem = C.BattItemLimit80
	itemLimit90                 menuItem = C.BattItemLimit90
	itemAdvanced                menuItem = C.BattItemAdvanced
	itemMagSafe                 menuItem = C.BattItemMagSafe
	itemMagSafeEnabled          menuItem = C.BattItemMagSafeEnabled
	itemMagSafeDisabled         menuItem = C.BattItemMagSafeDisabled
	itemMagSafeAlwaysOff        menuItem = C.BattItemMagSafeAlwaysOff
	itemPreventIdleSleep        menuItem = C.BattItemPreventIdleSleep
	itemDisableChargingPreSleep menuItem = C.BattItemDisableChargingPreSleep
	itemPreventSystemSleep      menuItem = C.BattItemPreventSystemSleep
	itemHeatProtection          menuItem = C.BattItemHeatProtection
	itemHeatOff                 menuItem = C.BattItemHeatOff
	itemHeatStrict              menuItem = C.BattItemHeatStrict
	itemHeatBalanced            menuItem = C.BattItemHeatBalanced
	itemHeatRelaxed             menuItem = C.BattItemHeatRelaxed
	itemHeatCustom              menuItem = C.BattItemHeatCustom
	itemForceDischarge          menuItem = C.BattItemForceDischarge
	itemAutoCalibration         menuItem = C.BattItemAutoCalibration
	itemCalibrationStatus       menuItem = C.BattItemCalibrationStatus
	itemCalibrationStart        menuItem = C.BattItemCalibrationStart
	itemCalibrationPause        menuItem = C.BattItemCalibrationPause
	itemCalibrationResume       menuItem = C.BattItemCalibrationResume
	itemCalibrationCancel       menuItem = C.BattItemCalibrationCancel
	itemVersion                 menuItem = C.BattItemVersion
	itemUninstall               menuItem = C.BattItemUninstall
	itemDisableLimit            menuItem = C.BattItemDisableLimit
	itemQuit                    menuItem = C.BattItemQuit
)

const (
	itemForceDischargeCountdown    menuItem = C.BattItemForceDischargeCountdown
	itemForceDischargeStop         menuItem = C.BattItemForceDischargeStop
	itemForceDischargeIndefinitely menuItem = C.BattItemForceDischargeIndefinitely
	itemForceDischarge1Hour        menuItem = C.BattItemForceDischarge1Hour
	itemForceDischarge2Hours       menuItem = C.BattItemForceDischarge2Hours
	itemForceDischarge4Hours       menuItem = C.BattItemForceDischarge4Hours
	itemForceDischarge8Hours       menuItem = C.BattItemForceDischarge8Hours
)

const (
	itemDisableLimitCountdown    menuItem = C.BattItemDisableLimitCountdown
	itemDisableLimitIndefinitely menuItem = C.BattItemDisableLimitIndefinitely
	itemDisableLimit1Hour        menuItem = C.BattItemDisableLimit1Hour
	itemDisableLimit2Hours       menuItem = C.BattItemDisableLimit2Hours
	itemDisableLimit4Hours       menuItem = C.BattItemDisableLimit4Hours
	itemDisableLimit8Hours       menuItem = C.BattItemDisableLimit8Hours
	itemDisableLimit12Hours      menuItem = C.BattItemDisableLimit12Hours
	itemDisableLimit24Hours      menuItem = C.BattItemDisableLimit24Hours
	itemDisableLimit2Days        menuItem = C.BattItemDisableLimit2Days
	itemDisableLimit3Days        menuItem = C.BattItemDisableLimit3Days
	itemDisableLimit7Days        menuItem = C.BattItemDisableLimit7Days
)

var quickLimitItems = []menuItem{
	itemLimit50,
	itemLimit60,
	itemLimit70,
	itemLimit80,
	itemLimit90,
}

var disableLimitActionItems = []menuItem{
	itemDisableLimitIndefinitely,
	itemDisableLimit1Hour,
	itemDisableLimit2Hours,
	itemDisableLimit4Hours,
	itemDisableLimit8Hours,
	itemDisableLimit12Hours,
	itemDisableLimit24Hours,
	itemDisableLimit2Days,
	itemDisableLimit3Days,
	itemDisableLimit7Days,
}

var forceDischargeActionItems = []menuItem{
	itemForceDischargeIndefinitely,
	itemForceDischarge1Hour,
	itemForceDischarge2Hours,
	itemForceDischarge4Hours,
	itemForceDischarge8Hours,
}

type confirmation int

const (
	confirmForceDischarge             confirmation = C.BattConfirmationForceDischarge
	confirmForceDischargeIndefinitely confirmation = C.BattConfirmationForceDischargeIndefinitely
	confirmStartCalibration           confirmation = C.BattConfirmationStartCalibration
)

type nativeMenu struct {
	ref C.BattMenuRef
}

func newNativeMenu(handle cgo.Handle, version string) *nativeMenu {
	cVersion := C.CString(version)
	defer C.free(unsafe.Pointer(cVersion))
	return &nativeMenu{ref: C.batt_menu_create(C.uintptr_t(handle), cVersion)}
}

func (m *nativeMenu) close() {
	if m == nil || m.ref == nil {
		return
	}
	C.batt_menu_destroy(m.ref)
	m.ref = nil
}

func (m *nativeMenu) setTitle(item menuItem, title string) {
	withCString(title, func(value *C.char) {
		C.batt_menu_set_title(m.ref, C.int(item), value)
	})
}

func (m *nativeMenu) setTooltip(item menuItem, tooltip string) {
	withCString(tooltip, func(value *C.char) {
		C.batt_menu_set_tooltip(m.ref, C.int(item), value)
	})
}

func (m *nativeMenu) setHidden(item menuItem, hidden bool) {
	C.batt_menu_set_hidden(m.ref, C.int(item), C.bool(hidden))
}

func (m *nativeMenu) setEnabled(item menuItem, enabled bool) {
	C.batt_menu_set_enabled(m.ref, C.int(item), C.bool(enabled))
}

func (m *nativeMenu) setChecked(item menuItem, checked bool) {
	C.batt_menu_set_checked(m.ref, C.int(item), C.bool(checked))
}

func (m *nativeMenu) setStatusIcon(installed, capable, needsUpgrade bool) {
	C.batt_menu_set_status_icon(m.ref, C.bool(installed), C.bool(capable), C.bool(needsUpgrade))
}

func (m *nativeMenu) setPower(item menuItem, label string, value float64) {
	withCString(label, func(cLabel *C.char) {
		C.batt_menu_set_power(m.ref, C.int(item), cLabel, C.double(value))
	})
}

func (m *nativeMenu) setPowerFlow(adapter, system, battery float64, heatPaused bool, temperatureCelsius float64) {
	C.batt_menu_set_power_flow(m.ref, C.double(adapter), C.double(system), C.double(battery), C.bool(heatPaused), C.double(temperatureCelsius))
}

func (m *nativeMenu) setLimit(limitPercent int) {
	C.batt_menu_set_limit(m.ref, C.int(limitPercent))
}

func (m *nativeMenu) setLimitChoices(limits []int) {
	values := make([]C.int, len(limits))
	for i, v := range limits {
		values[i] = C.int(v)
	}
	var ptr *C.int
	if len(values) > 0 {
		ptr = &values[0]
	}
	C.batt_menu_set_limit_choices(m.ref, ptr, C.int(len(values)))
}

func (m *nativeMenu) setHeatStatus(paused bool, temperatureCelsius float64) {
	C.batt_menu_set_heat_status(m.ref, C.bool(paused), C.double(temperatureCelsius))
}

func (m *nativeMenu) setProcessorTemperature(celsius float64) {
	C.batt_menu_set_processor_temperature(m.ref, C.double(celsius))
}

func (m *nativeMenu) setHeatDetail(detail string) {
	withCString(detail, func(value *C.char) { C.batt_menu_set_heat_detail(m.ref, value) })
}

func (m *nativeMenu) setLiveStatus(chargePercent int, pluggedIn, charging, heatPaused bool) {
	C.batt_menu_set_live_status(m.ref, C.int(chargePercent), C.bool(pluggedIn), C.bool(charging), C.bool(heatPaused))
}

func quickLimitForItem(item menuItem) int {
	return 50 + (int(item)-int(itemLimit50))*10
}

func runNativeApp() {
	C.batt_app_run()
}

func terminateNativeApp() {
	C.batt_app_terminate()
}

func showAlert(message, body string) {
	withTwoCStrings(message, body, func(cMessage, cBody *C.char) {
		C.batt_show_alert(cMessage, cBody)
	})
}

func showConfirmation(kind confirmation) bool {
	return bool(C.batt_show_confirmation(C.int(kind)))
}

func showNotification(title, body string) {
	withTwoCStrings(title, body, func(cTitle, cBody *C.char) {
		C.batt_show_notification(cTitle, cBody)
	})
}

func RegisterLoginItem() error {
	logrus.Info("Registering application to start at login")
	if bool(C.batt_register_login_item()) {
		logrus.Info("Successfully registered as login item")
		return nil
	}
	return fmt.Errorf("failed to register application as login item")
}

func UnregisterLoginItem() error {
	logrus.Info("Removing application from login items")
	if bool(C.batt_unregister_login_item()) {
		logrus.Info("Successfully unregistered login item")
		return nil
	}
	return fmt.Errorf("failed to unregister application as login item")
}

func IsLoginItemRegistered() bool {
	return bool(C.batt_is_login_item_registered())
}

func withCString(value string, call func(*C.char)) {
	cValue := C.CString(value)
	defer C.free(unsafe.Pointer(cValue))
	call(cValue)
}

func withTwoCStrings(first, second string, call func(*C.char, *C.char)) {
	cFirst := C.CString(first)
	cSecond := C.CString(second)
	defer C.free(unsafe.Pointer(cFirst))
	defer C.free(unsafe.Pointer(cSecond))
	call(cFirst, cSecond)
}

func controllerForHandle(handle C.uintptr_t) *menuController {
	return cgo.Handle(handle).Value().(*menuController)
}

func runOnMain(callback func()) {
	C.batt_dispatch_main(C.uintptr_t(cgo.NewHandle(callback)))
}

//export battStorageAction
func battStorageAction(handle C.uintptr_t, generation C.uint64_t, action C.int) {
	defer recoverNativeCallback("battStorageAction")
	c := controllerForHandle(handle)
	if c.storage == nil {
		c.storage = newStorageAdapter(userStorageScan, runOnMain, func(g uint64, b []byte) {
			withCString(string(b), func(value *C.char) { C.batt_menu_storage_update(c.menu.ref, C.uint64_t(g), value) })
		})
	}
	c.storage.action(uint64(generation), int(action))
}

//export battMainCallback
func battMainCallback(callback C.uintptr_t) {
	defer recoverNativeCallback("battMainCallback")
	handle := cgo.Handle(callback)
	defer handle.Delete()
	handle.Value().(func())()
}

func recoverNativeCallback(name string) {
	if recovered := recover(); recovered != nil {
		logrus.Errorf("panic in %s: %v", name, recovered)
	}
}

//export battMenuWillOpen
func battMenuWillOpen(handle C.uintptr_t) {
	defer recoverNativeCallback("battMenuWillOpen")
	controllerForHandle(handle).onWillOpen()
}

//export battMenuTimerFired
func battMenuTimerFired(handle C.uintptr_t) {
	defer recoverNativeCallback("battMenuTimerFired")
	controllerForHandle(handle).onTimerTick()
}

//export battMenuAction
func battMenuAction(handle C.uintptr_t, item C.int, checked C.bool) {
	defer recoverNativeCallback("battMenuAction")
	controllerForHandle(handle).handleAction(menuItem(item), bool(checked))
}

//export battMenuSetLimit
func battMenuSetLimit(handle C.uintptr_t, limit C.int) C.bool {
	defer recoverNativeCallback("battMenuSetLimit")
	c := controllerForHandle(handle)
	value := int(limit)
	if c.capabilities.ChargeControlMode != compatibility.ChargeControlNative {
		value = normalizeDraggedLimit(value)
	}
	return C.bool(c.setLimit(value))
}

func normalizeDraggedLimit(limit int) int {
	if limit < 20 {
		return 20
	}
	if limit > 95 {
		return 95
	}
	return ((limit + 2) / 5) * 5
}
