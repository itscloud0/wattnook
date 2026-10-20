package config

import (
	"time"

	"github.com/sirupsen/logrus"
)

type Config interface {
	UpperLimit() int
	LowerLimit() int
	PreventIdleSleep() bool
	DisableChargingPreSleep() bool
	PreventSystemSleep() bool
	AllowNonRootAccess() bool
	ControlMagSafeLED() ControlMagSafeMode
	CalibrationDischargeThreshold() int
	CalibrationHoldDurationMinutes() int
	Cron() string
	DisableUntil() time.Time
	PreDisableLimit() int
	AdapterDisableUntil() time.Time
	HeatProtectionEnabled() bool
	ThermalAdapterEnabled() bool
	HeatPauseTemperatureCelsius() float64
	HeatResumeTemperatureCelsius() float64
	// CustomChargeLimit is a native-mode limit outside Apple's advertised
	// values, enforced through a charge hold (0 = none).
	CustomChargeLimit() int
	// SailingLevel lets the charge fall this many points below the limit
	// before charging again (0 = off).
	SailingLevel() int
	// TopUpActive charges to 100% until the adapter is disconnected;
	// TopUpRestoreLimit is the Apple limit to restore afterwards.
	TopUpActive() bool
	TopUpRestoreLimit() int
	// DischargeActive drains the battery on AC down to the limit, once.
	DischargeActive() bool

	SetUpperLimit(int)
	SetLowerLimit(int)
	SetPreventIdleSleep(bool)
	SetDisableChargingPreSleep(bool)
	SetPreventSystemSleep(bool)
	SetAllowNonRootAccess(bool)
	SetControlMagSafeLED(ControlMagSafeMode)
	SetCron(string)
	SetCalibrationDischargeThreshold(int)
	SetCalibrationHoldDurationMinutes(int)
	SetDisableTimer(time.Time, int)
	ClearDisableTimer()
	SetAdapterDisableTimer(time.Time)
	ClearAdapterDisableTimer()
	SetHeatProtection(bool, float64, float64)
	SetThermalAdapterEnabled(bool)
	SetCustomChargeLimit(int)
	SetSailingLevel(int)
	SetTopUp(active bool, restoreLimit int)
	SetDischarge(active bool)

	LogrusFields() logrus.Fields

	// Load reads the configuration from the source.
	Load() error
	// Save saves the configuration to the source.
	Save() error
}
