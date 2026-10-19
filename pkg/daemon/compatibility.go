package daemon

import (
	"fmt"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/sirupsen/logrus"

	"github.com/charlie0129/batt/pkg/calibration"
	"github.com/charlie0129/batt/pkg/compatibility"
	"github.com/charlie0129/batt/pkg/config"
)

func detectCapabilities() compatibility.Capabilities {
	mode := smcConn.ChargeControlMode()
	if mode == compatibility.ChargeControlUnsupported && nativeCharge != nil {
		if state, err := nativeCharge.Read(); err == nil {
			limits := state.Limits
			hold := smcConn.HasKey("CHIE")
			if hold {
				limits = append(append([]int{}, customChargeLimits...), state.Limits...)
			}
			return compatibility.Capabilities{ChargingControl: true, ChargeControlMode: compatibility.ChargeControlNative, SupportedLimits: limits,
				ThermalAdapter: hold, ChargeHold: hold}
		}
	}
	legacy := mode == compatibility.ChargeControlLegacy
	adapter := smcConn.IsAdapterControlCapable()
	return compatibility.Capabilities{
		ChargingControl:   mode != compatibility.ChargeControlUnsupported,
		ChargeControlMode: mode,
		SleepHooks:        legacy,
		// LED state follows batt's direct charging state, which is not
		// available when the firmware owns charge control.
		MagSafeLED:     legacy && smcConn.CheckMagSafeExistence(),
		AdapterControl: adapter,
		// Adapter control performs the discharge phases. Both the legacy and
		// firmware backends can temporarily allow charging to 100%.
		Calibration: mode != compatibility.ChargeControlUnsupported && adapter,
	}
}

func rejectNativeOperation(c *gin.Context) bool {
	if capabilities.ChargeControlMode != compatibility.ChargeControlNative {
		return false
	}
	c.AbortWithStatusJSON(http.StatusConflict, "This operation is unavailable with Apple's native charge limit")
	return true
}

func capabilityLogFields(capabilities compatibility.Capabilities) logrus.Fields {
	return logrus.Fields{
		"chargingControl":   capabilities.ChargingControl,
		"chargeControlMode": capabilities.ChargeControlMode,
		"sleepHooks":        capabilities.SleepHooks,
		"magSafeLED":        capabilities.MagSafeLED,
		"adapterControl":    capabilities.AdapterControl,
		"calibration":       capabilities.Calibration,
		"chargeHold":        capabilities.ChargeHold,
	}
}

func disableUnsupportedCalibrationState() {
	if capabilities.Calibration {
		return
	}
	calibrationMu.Lock()
	defer calibrationMu.Unlock()
	if calibrationState.Phase == calibration.PhaseIdle {
		return
	}
	logrus.WithField("phase", calibrationState.Phase).Info("discarding unsupported persisted calibration state")
	releaseCalibrationSleepAssertion()
	// Calibration may have temporarily changed the configured limit to 100%.
	// Restore its saved limits without touching unsupported charging/adapter
	// keys before discarding the workflow state.
	if calibrationState.SnapshotUpperLimit >= 10 && calibrationState.SnapshotUpperLimit <= 100 &&
		calibrationState.SnapshotLowerLimit >= 0 && calibrationState.SnapshotLowerLimit < calibrationState.SnapshotUpperLimit {
		conf.SetUpperLimit(calibrationState.SnapshotUpperLimit)
		conf.SetLowerLimit(calibrationState.SnapshotLowerLimit)
		if err := conf.Save(); err != nil {
			logrus.WithError(err).Error("failed to restore limits from unsupported calibration state")
		}
	}
	calibrationState = &calibration.State{Phase: calibration.PhaseIdle}
	persistCalibrationState()
}

// disableUnsupportedConfiguredFeatures prevents settings left behind by an
// OS/firmware upgrade from activating features that are unsafe on the current
// hardware. It intentionally persists the disabled values.
func disableUnsupportedConfiguredFeatures() {
	changed := false
	if conf.ThermalAdapterEnabled() && capabilities.ChargeControlMode == compatibility.ChargeControlNative {
		// Adapter disconnection is never a Heat Protection mechanism.
		conf.SetThermalAdapterEnabled(false)
		changed = true
	}
	if !capabilities.Supports(compatibility.FeatureHeatProtection) &&
		(conf.HeatProtectionEnabled() || conf.ThermalAdapterEnabled()) {
		conf.SetHeatProtection(false, conf.HeatPauseTemperatureCelsius(), conf.HeatResumeTemperatureCelsius())
		conf.SetThermalAdapterEnabled(false)
		changed = true
	}
	if conf.CustomChargeLimit() > 0 && !capabilities.ChargeHold {
		// A limit below Apple's choices is only enforceable with the hold.
		conf.SetCustomChargeLimit(0)
		changed = true
	}
	if !capabilities.SleepHooks {
		if conf.PreventIdleSleep() {
			conf.SetPreventIdleSleep(false)
			changed = true
		}
		if conf.DisableChargingPreSleep() {
			conf.SetDisableChargingPreSleep(false)
			changed = true
		}
		if conf.PreventSystemSleep() {
			conf.SetPreventSystemSleep(false)
			changed = true
		}
	}
	if !capabilities.MagSafeLED && conf.ControlMagSafeLED() != config.ControlMagSafeModeDisabled {
		conf.SetControlMagSafeLED(config.ControlMagSafeModeDisabled)
		changed = true
	}
	if !capabilities.Calibration && conf.Cron() != "" {
		conf.SetCron("")
		changed = true
	}
	if !capabilities.AdapterControl && !conf.AdapterDisableUntil().IsZero() {
		conf.ClearAdapterDisableTimer()
		changed = true
	}
	if !changed {
		return
	}
	if err := conf.Save(); err != nil {
		logrus.WithError(err).Error("failed to persist disabled unsupported features")
		return
	}
	logrus.WithFields(capabilityLogFields(capabilities)).Info("disabled unsupported configured features")
}

func requireCapability(c *gin.Context, feature compatibility.Feature) bool {
	if capabilities.Supports(feature) {
		return true
	}
	err := fmt.Errorf("%s is not supported on this Mac", feature)
	c.IndentedJSON(http.StatusConflict, err.Error())
	_ = c.AbortWithError(http.StatusConflict, err)
	return false
}

func getCompatibility(c *gin.Context) {
	c.IndentedJSON(http.StatusOK, capabilities)
}
