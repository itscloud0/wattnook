package gui

import (
	"context"
	"fmt"
	"os"
	"slices"
	"strings"
	"time"

	"github.com/sirupsen/logrus"

	"github.com/charlie0129/batt/pkg/calibration"
	"github.com/charlie0129/batt/pkg/client"
	"github.com/charlie0129/batt/pkg/compatibility"
	"github.com/charlie0129/batt/pkg/config"
	"github.com/charlie0129/batt/pkg/powerinfo"
	"github.com/charlie0129/batt/pkg/version"
)

type menuController struct {
	api  *client.Client
	menu *nativeMenu

	calibrationThreshold    int
	calibrationPhase        calibration.Phase
	heatPaused              bool
	topUpActive             bool
	discharging             bool
	temperatureCelsius      float64
	capabilities            compatibility.Capabilities
	nativeLimit             int
	nativeLimitPending      bool
	compatibilityKnown      bool
	disableScheduled        bool
	adapterDisableScheduled bool
	adapterEnabled          bool
	adapterKnown            bool
	eventCancel             context.CancelFunc
	storage                 *storageAdapter
}

func (c *menuController) onWillOpen() {
	c.refreshOnOpen()
	c.updateTelemetry()
}

func (c *menuController) onTimerTick() {
	if !c.compatibilityKnown {
		// Started while the daemon was restarting: retry instead of keeping
		// the permissive fallback (which polls features this Mac lacks).
		c.refreshOnOpen()
	}
	c.refreshDisableSchedules()
	c.updateTelemetry()
}

func (c *menuController) refreshCompatibility() {
	logrus.Info("Getting config")
	rawConfig, err := c.api.GetConfig()
	if err != nil {
		logrus.WithError(err).Warn("Failed to get config")
		c.setCompatibility(false, compatibility.Permissive(), false)
		return
	}
	conf := config.NewFileFromConfig(rawConfig, "")
	logrus.WithFields(conf.LogrusFields()).Info("Got config")

	logrus.Info("Getting hardware compatibility")
	capabilities, err := c.api.GetCompatibility()
	c.compatibilityKnown = err == nil
	if err != nil {
		logrus.WithError(err).Warn("Detailed compatibility unavailable; enabling all GUI features")
		fallback := compatibility.Permissive()
		capabilities = &fallback
	}
	logrus.WithField("capabilities", capabilities).Info("Got hardware compatibility")

	logrus.Info("Getting daemon version")
	daemonVersion, err := c.api.GetVersion()
	if err != nil {
		logrus.WithError(err).Warn("Failed to get version")
		c.setCompatibility(true, *capabilities, true)
	} else {
		c.setCompatibility(true, *capabilities, daemonVersion != version.Version)
	}
	logrus.WithFields(logrus.Fields{
		"daemonVersion": daemonVersion,
		"clientVersion": version.Version,
	}).Info("Got daemon")
}

func (c *menuController) refreshOnOpen() {
	rawConfig, err := c.api.GetConfig()
	if err != nil {
		logrus.WithError(err).Error("Failed to get config")
		c.setCompatibility(false, compatibility.Permissive(), false)
		return
	}
	conf := config.NewFileFromConfig(rawConfig, "")
	logrus.WithFields(conf.LogrusFields()).Info("Got config")
	c.updateDisableSchedules(conf)

	capabilities, err := c.api.GetCompatibility()
	c.compatibilityKnown = err == nil
	if err != nil {
		logrus.WithError(err).Warn("Detailed compatibility unavailable; enabling all GUI features")
		fallback := compatibility.Permissive()
		capabilities = &fallback
	}
	daemonVersion, err := c.api.GetVersion()
	if err != nil {
		logrus.WithError(err).Error("Failed to get version")
		c.setCompatibility(true, *capabilities, true)
	} else {
		c.setCompatibility(true, *capabilities, daemonVersion != version.Version)
	}
	logrus.WithFields(logrus.Fields{
		"daemonVersion": daemonVersion,
		"clientVersion": version.Version,
	}).Info("Got daemon")

	isPluggedIn, err := c.api.GetPluggedIn()
	if err != nil {
		c.setStateError("Failed to get plugged in state", err)
		return
	}
	currentCharge, err := c.api.GetCurrentCharge()
	if err != nil {
		c.setStateError("Failed to get current charge", err)
		return
	}
	batteryInfo, err := c.api.GetBatteryInfo()
	if err != nil {
		c.setStateError("Failed to get battery info", err)
		return
	}
	allowsCharging := batteryInfo.State == powerinfo.Charging
	if capabilities.ChargeControlMode == compatibility.ChargeControlLegacy {
		allowsCharging, err = c.api.GetCharging()
		if err != nil {
			c.setStateError("Failed to get charging state", err)
			return
		}
	}

	c.calibrationThreshold = conf.CalibrationDischargeThreshold()
	limit := conf.UpperLimit()
	if capabilities.ChargeControlMode == compatibility.ChargeControlNative {
		limit = c.nativeLimit
		c.requestNativeLimit()
	}
	c.menu.setTitle(itemCurrentLimit, fmt.Sprintf("Current Limit: %d%%", limit))
	c.menu.setLimit(limit)
	for _, item := range quickLimitItems {
		c.menu.setChecked(item, quickLimitForItem(item) == limit)
	}

	state := "Not Charging"
	switch batteryInfo.State {
	case powerinfo.Charging:
		state = "Charging"
	case powerinfo.Discharging:
		if batteryInfo.ChargeRate != 0 {
			state = "Discharging"
		}
	case powerinfo.Full:
		state = "Full"
	}
	if capabilities.ChargeControlMode == compatibility.ChargeControlLegacy && !allowsCharging && isPluggedIn && conf.UpperLimit() < 100 && currentCharge < conf.LowerLimit() {
		state = "Will Charge Soon"
	}
	c.menu.setTitle(itemState, "State: "+state)
	heat, err := c.api.GetHeatProtection()
	if err == nil && heat != nil {
		c.heatPaused = heat.Paused
		if heat.TemperatureCelsius != nil {
			c.temperatureCelsius = *heat.TemperatureCelsius
		}
		c.updateHeatProtection(conf, heat)
		c.updateChargeModes(heat)
	}
	c.menu.setHeatStatus(c.heatPaused, c.temperatureCelsius)
	c.menu.setProcessorTemperature(processorTemperature.Celsius())

	c.updateMagSafeChecks(conf.ControlMagSafeLED())
	c.menu.setChecked(itemPreventIdleSleep, conf.PreventIdleSleep())
	c.menu.setChecked(itemDisableChargingPreSleep, conf.DisableChargingPreSleep())
	c.menu.setChecked(itemPreventSystemSleep, conf.PreventSystemSleep())
	if capabilities.AdapterControl {
		if adapter, err := c.api.GetAdapter(); err == nil {
			c.updateAdapterState(adapter)
		} else {
			logrus.WithError(err).Error("Failed to get adapter")
			if c.compatibilityKnown {
				c.menu.setEnabled(itemForceDischarge, false)
			}
		}
	}
}

func (c *menuController) refreshDisableSchedules() {
	if c.capabilities.ChargeControlMode == compatibility.ChargeControlNative {
		c.requestNativeLimit()
		return
	}
	rawConfig, err := c.api.GetConfig()
	if err != nil {
		logrus.WithError(err).Debug("Failed to refresh temporary disable schedule")
		return
	}
	c.updateDisableSchedules(config.NewFileFromConfig(rawConfig, ""))
	if c.capabilities.AdapterControl {
		if adapter, err := c.api.GetAdapter(); err == nil {
			c.updateAdapterState(adapter)
		}
	}
}

func (c *menuController) updateDisableSchedules(conf config.Config) {
	if c.capabilities.ChargeControlMode == compatibility.ChargeControlNative {
		return
	}
	c.updateDisableSchedule(conf)
	c.updateAdapterDisableSchedule(conf)
}

func (c *menuController) updateDisableSchedule(conf config.Config) {
	until := conf.DisableUntil()
	scheduled := !until.IsZero()
	c.disableScheduled = scheduled
	for _, item := range disableLimitActionItems {
		c.menu.setEnabled(item, !scheduled)
	}
	c.menu.setHidden(itemDisableLimitCountdown, !scheduled)

	if !scheduled {
		c.menu.setTooltip(itemDisableLimit, disableLimitTooltip)
		return
	}

	c.menu.setEnabled(itemCalibrationStart, false)
	c.menu.setEnabled(itemDisableLimit, true)
	c.menu.setTitle(
		itemDisableLimitCountdown,
		temporaryDisableCountdownTitle(conf.PreDisableLimit(), time.Until(until)),
	)
	c.menu.setTooltip(itemDisableLimit, disableLimitScheduledTooltip)
	c.menu.setTooltip(itemDisableLimitCountdown, disableLimitScheduledTooltip)
}

func (c *menuController) updateAdapterDisableSchedule(conf config.Config) {
	until := conf.AdapterDisableUntil()
	c.adapterDisableScheduled = !until.IsZero()
	c.menu.setHidden(itemForceDischargeCountdown, !c.adapterDisableScheduled)

	if !c.adapterDisableScheduled {
		c.menu.setTooltip(itemForceDischarge, forceDischargeTooltip)
		c.updateForceDischargeControls()
		return
	}

	c.menu.setEnabled(itemCalibrationStart, false)
	c.menu.setTitle(itemForceDischargeCountdown, temporaryAdapterDisableCountdownTitle(time.Until(until)))
	c.menu.setTooltip(itemForceDischarge, forceDischargeScheduledTooltip)
	c.menu.setTooltip(itemForceDischargeCountdown, forceDischargeScheduledTooltip)
	c.updateForceDischargeControls()
}

func (c *menuController) updateAdapterState(enabled bool) {
	c.adapterEnabled = enabled
	c.adapterKnown = true
	c.updateForceDischargeControls()
}

func (c *menuController) updateForceDischargeControls() {
	canControl := c.adapterKnown && c.calibrationPhase == calibration.PhaseIdle
	for _, item := range forceDischargeActionItems {
		c.menu.setEnabled(item, canControl && c.adapterEnabled && !c.adapterDisableScheduled)
	}
	c.menu.setEnabled(itemForceDischargeStop, canControl && (!c.adapterEnabled || c.adapterDisableScheduled))
	c.menu.setEnabled(itemForceDischarge, c.adapterKnown && canOpenForceDischargeMenu(c.calibrationPhase, c.adapterDisableScheduled))
}

func (c *menuController) setStateError(message string, err error) {
	logrus.WithError(err).Error(message)
	c.menu.setTitle(itemState, "State: Error")
}

func (c *menuController) setCompatibility(installed bool, capabilities compatibility.Capabilities, needsUpgrade bool) {
	if value := os.Getenv("BATT_GUI_NO_COMPATIBILITY_CHECK"); value == "1" || value == "true" {
		return
	}
	if capabilities.ChargeControlMode == compatibility.ChargeControlNative && c.capabilities.ChargeControlMode != compatibility.ChargeControlNative {
		c.nativeLimit = -1
		c.menu.setLimit(-1)
	}
	c.capabilities = capabilities
	c.menu.setLimitChoices(capabilities.SupportedLimits)
	c.menu.setStatusIcon(installed, capabilities.ChargingControl, needsUpgrade)

	usable := installed && capabilities.ChargingControl && !needsUpgrade
	c.menu.setHidden(itemPowerFlow, !usable)
	c.menu.setHidden(itemPowerFlowCanvas, !usable)
	c.menu.setHidden(itemInstall, installed)
	c.menu.setHidden(itemUpgrade, !installed || (!needsUpgrade && capabilities.ChargingControl))
	c.menu.setHidden(itemState, !installed || !capabilities.ChargingControl)
	c.menu.setHidden(itemCurrentLimit, !installed || !capabilities.ChargingControl)
	c.menu.setHidden(itemQuickLimits, !usable)
	for _, item := range quickLimitItems {
		c.menu.setHidden(item, !usable || !supportsQuickLimit(capabilities, quickLimitForItem(item)))
		c.menu.setEnabled(item, usable && supportsQuickLimit(capabilities, quickLimitForItem(item)))
	}

	c.menu.setHidden(itemAdvanced, !installed)
	c.menu.setHidden(itemMagSafe, !usable || !capabilities.MagSafeLED)
	c.menu.setHidden(itemPreventIdleSleep, !usable || !capabilities.SleepHooks)
	c.menu.setHidden(itemDisableChargingPreSleep, !usable || !capabilities.SleepHooks)
	c.menu.setHidden(itemPreventSystemSleep, !usable || !capabilities.SleepHooks)
	c.menu.setHidden(itemHeatProtection, !usable || !capabilities.Supports(compatibility.FeatureHeatProtection))
	c.menu.setHidden(itemForceDischarge, !usable || !capabilities.AdapterControl)
	c.menu.setHidden(itemAutoCalibration, !usable || !capabilities.Calibration)
	c.menu.setHidden(itemUninstall, !installed)
	c.menu.setHidden(itemDisableLimit, !usable || capabilities.ChargeControlMode == compatibility.ChargeControlNative)
	if installed {
		c.menu.setTooltip(itemQuit, quitTooltipInstalled)
	} else {
		c.menu.setTooltip(itemQuit, quitTooltipNotInstalled)
	}
}

func (c *menuController) updateTelemetry() {
	// Native snapshots own power and connection state. Do not overwrite them
	// with independently timed daemon power/charge/connection requests.
	heat, err := c.api.GetHeatProtection()
	if err == nil && heat != nil {
		c.heatPaused = heat.Paused
		if heat.TemperatureCelsius != nil {
			c.temperatureCelsius = *heat.TemperatureCelsius
		}
		c.menu.setHeatStatus(c.heatPaused, c.temperatureCelsius)
		c.updateChargeModes(heat)
		if c.capabilities.Supports(compatibility.FeatureHeatProtection) {
			title, detail := heatProtectionPresentation(heat.Enabled, heat)
			c.menu.setTitle(itemHeatProtection, title)
			c.menu.setHeatDetail(detail)
		}
	}
	telemetry, err := c.api.GetTelemetry(false, true)
	if err != nil || telemetry == nil {
		if err != nil {
			logrus.WithError(err).Debug("GetTelemetry failed")
		}
		return
	}
	if telemetry.Calibration != nil {
		c.updateCalibration(telemetry.Calibration)
	}
}

func (c *menuController) updateHeatProtection(conf config.Config, status *client.HeatProtectionStatus) {
	if !c.capabilities.Supports(compatibility.FeatureHeatProtection) {
		c.heatPaused = false
		c.menu.setTitle(itemHeatProtection, "Heat Protection unavailable on this Mac")
		return
	}
	enabled := conf.HeatProtectionEnabled()
	if status.Mechanism == "adapter" {
		enabled = status.Enabled
	}
	c.menu.setChecked(itemHeatOff, !enabled)
	c.menu.setChecked(itemHeatStrict, enabled && conf.HeatPauseTemperatureCelsius() == 32 && conf.HeatResumeTemperatureCelsius() == 29)
	c.menu.setChecked(itemHeatBalanced, enabled && conf.HeatPauseTemperatureCelsius() == 33 && conf.HeatResumeTemperatureCelsius() == 30)
	c.menu.setChecked(itemHeatRelaxed, enabled && conf.HeatPauseTemperatureCelsius() == 35 && conf.HeatResumeTemperatureCelsius() == 32)
	title, detail := heatProtectionPresentation(enabled, status)
	c.menu.setTitle(itemHeatProtection, title)
	c.menu.setHeatDetail(detail)
}

func heatProtectionPresentation(enabled bool, status *client.HeatProtectionStatus) (string, string) {
	if status.AdapterWarning != "" {
		detail := "Charger not used · reconnect cable"
		if strings.Contains(status.AdapterWarning, "5 V") {
			detail = "Adapter at 5 V · reconnect cable"
		}
		return "Heat Protection: " + status.AdapterWarning, detail
	}
	if status.Fault || status.LastError != "" {
		return "Heat Protection: stopped — " + status.LastError, "Stopped · see details"
	}
	if !enabled {
		if status.Mechanism == "adapter" {
			return "Heat Protection: off — uses battery while hot; Apple limit stays active", "Off · temperature control"
		}
		return "Heat Protection: off", "Off"
	}
	if status.Paused {
		if status.Mechanism == "adapter" {
			return "Heat Protection: cooling — running on battery", "Cooling · battery power"
		}
		// Name the state and the exit condition, not the feature.
		return "Heat Protection: charging paused", fmt.Sprintf("Paused · resumes at %.0f°", status.ResumeTemperatureCelsius)
	}
	if status.ReserveBlocked {
		if status.Mechanism == "adapter" {
			return "Heat Protection: low battery — adapter restored; re-arms above 25%", "Low battery · AC restored"
		}
		return "Heat Protection: adapter can't keep up and the battery is low — charging despite heat; pauses again at 30%", "Low battery · charging"
	}
	title := fmt.Sprintf("Heat Protection: on (%.0f°C → %.0f°C)", status.PauseTemperatureCelsius, status.ResumeTemperatureCelsius)
	if status.Mechanism == "adapter" {
		title += " — uses battery while hot"
	}
	if status.Mechanism == "adapter" {
		return title, fmt.Sprintf("On · %.0f° / %.0f°", status.PauseTemperatureCelsius, status.ResumeTemperatureCelsius)
	}
	return title, fmt.Sprintf("Watching · pauses at %.0f°", status.PauseTemperatureCelsius)
}

func (c *menuController) updateCalibration(status *calibration.Status) {
	c.calibrationPhase = status.Phase
	isIdle := status.Phase == calibration.PhaseIdle
	switch {
	case isIdle:
		c.menu.setTitle(itemAutoCalibration, "Auto Calibration (Experimental)...")
	case status.Paused:
		c.menu.setTitle(itemAutoCalibration, "Auto Calibration (Experimental) Paused...")
	default:
		c.menu.setTitle(itemAutoCalibration, "Auto Calibration (Experimental) In Progress...")
	}

	c.menu.setEnabled(itemCalibrationStart, canStartCalibration(status.Phase, c.disableScheduled, c.adapterDisableScheduled))
	c.menu.setEnabled(itemCalibrationCancel, !isIdle)
	c.menu.setEnabled(itemCalibrationPause, !isIdle && !status.Paused)
	c.menu.setEnabled(itemCalibrationResume, status.Paused)
	if title, ok := c.calibrationStatusTitle(status); ok {
		c.menu.setTitle(itemCalibrationStatus, title)
	}

	settingsEnabled := isIdle || status.Phase == calibration.PhaseError || status.Paused
	for _, item := range []menuItem{
		itemUninstall,
	} {
		c.menu.setEnabled(item, settingsEnabled)
	}
	for _, item := range quickLimitItems {
		c.menu.setEnabled(item, canSetChargeLimit(status.Phase) && supportsQuickLimit(c.capabilities, quickLimitForItem(item)))
	}
	// A persisted conflict may contain both states after a restart. Keep the
	// submenu openable only to show its countdown; its actions remain disabled.
	c.menu.setEnabled(itemDisableLimit, canOpenDisableLimitMenu(status.Phase, c.disableScheduled))
	c.updateForceDischargeControls()
}

func supportsQuickLimit(c compatibility.Capabilities, limit int) bool {
	return c.ChargeControlMode != compatibility.ChargeControlNative || slices.Contains(c.SupportedLimits, limit)
}

// The private framework's RPC may stall. Never wait for native reads/writes on
// AppKit's main thread, and never queue a second operation behind a pending one.
func (c *menuController) requestNativeLimit() {
	if c.nativeLimitPending {
		return
	}
	c.nativeLimitPending = true
	go func() {
		limit, err := c.api.GetLimit()
		if err != nil {
			limit = -1
		}
		runOnMain(func() { c.nativeLimitPending = false; c.applyNativeLimit(limit) })
	}()
}

func (c *menuController) applyNativeLimit(limit int) {
	if c.capabilities.ChargeControlMode != compatibility.ChargeControlNative {
		return
	}
	c.nativeLimit = limit
	c.menu.setTitle(itemCurrentLimit, fmt.Sprintf("Apple limit: %d%%", limit))
	if limit < 0 {
		c.menu.setTitle(itemCurrentLimit, "Apple limit unavailable")
	}
	for _, item := range quickLimitItems {
		c.menu.setChecked(item, quickLimitForItem(item) == limit)
	}
	c.menu.setLimit(limit)
}

func canStartCalibration(phase calibration.Phase, disableScheduled, adapterDisableScheduled bool) bool {
	return phase == calibration.PhaseIdle && !disableScheduled && !adapterDisableScheduled
}

func canOpenDisableLimitMenu(phase calibration.Phase, disableScheduled bool) bool {
	return phase == calibration.PhaseIdle || disableScheduled
}

func canSetChargeLimit(phase calibration.Phase) bool {
	return phase == calibration.PhaseIdle
}

func canOpenForceDischargeMenu(phase calibration.Phase, adapterDisableScheduled bool) bool {
	return phase == calibration.PhaseIdle || adapterDisableScheduled
}

func (c *menuController) calibrationStatusTitle(status *calibration.Status) (string, bool) {
	switch status.Phase {
	case calibration.PhaseIdle:
		return "Status: Idle", true
	case calibration.PhaseDischarge:
		return fmt.Sprintf("Status: Discharging (%d%% → %d%%)", status.ChargePercent, c.calibrationThreshold), true
	case calibration.PhaseCharge:
		return fmt.Sprintf("Status: Charging (%d%% → 100%%)", status.ChargePercent), true
	case calibration.PhaseHold:
		hours := status.RemainingHoldSecs / 3600
		minutes := (status.RemainingHoldSecs % 3600) / 60
		seconds := status.RemainingHoldSecs % 60
		return fmt.Sprintf("Status: Holding (%02d:%02d:%02d left)", hours, minutes, seconds), true
	case calibration.PhasePostHold:
		if status.TargetPercent > 0 {
			return fmt.Sprintf("Status: Discharging (%d%% → %d%%)", status.ChargePercent, status.TargetPercent), true
		}
		return "Status: Discharging to previous limit...", true
	case calibration.PhaseRestore:
		return "Status: Restoring settings...", true
	case calibration.PhaseError:
		if status.Message != "" {
			return "Status: Error - " + status.Message, true
		}
		return "Status: Error", true
	default:
		return "", false
	}
}

func (c *menuController) updateMagSafeChecks(mode config.ControlMagSafeMode) {
	c.menu.setChecked(itemMagSafeEnabled, mode == config.ControlMagSafeModeEnabled)
	c.menu.setChecked(itemMagSafeAlwaysOff, mode == config.ControlMagSafeModeAlwaysOff)
	c.menu.setChecked(itemMagSafeDisabled, mode != config.ControlMagSafeModeEnabled && mode != config.ControlMagSafeModeAlwaysOff)
}

// updateChargeModes mirrors Top Up and Sailing; both need the charge hold.
func (c *menuController) updateChargeModes(status *client.HeatProtectionStatus) {
	supported := c.capabilities.ChargeHold
	c.menu.setHidden(itemTopUp, !supported)
	c.menu.setHidden(itemSailing, !supported)
	c.menu.setHidden(itemDischargeToLimit, !supported)
	c.discharging = status.Discharging
	if status.Discharging {
		c.menu.setTitle(itemDischargeToLimit, "Stop Discharge")
	} else {
		c.menu.setTitle(itemDischargeToLimit, "Discharge to Limit")
	}
	c.topUpActive = status.TopUp
	if status.TopUp {
		c.menu.setTitle(itemTopUp, "Stop Top Up")
	} else {
		c.menu.setTitle(itemTopUp, "Top Up to 100%")
	}
	c.menu.setChecked(itemSailingOff, status.SailingLevel == 0)
	c.menu.setChecked(itemSailing5, status.SailingLevel == 5)
	c.menu.setChecked(itemSailing10, status.SailingLevel == 10)
	c.menu.setChargeModes(status.TopUp, status.Sailing, status.SailingLevel, status.Discharging)
}
