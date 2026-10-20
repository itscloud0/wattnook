package daemon

import (
	"fmt"
	"sync"
	"time"

	"github.com/charlie0129/batt/pkg/compatibility"
	"github.com/peterneutron/powerkit-go/pkg/powerkit"
)

// HeatProtectionStatus reports the last sensor result and observed control state.
// Mechanism distinguishes direct charge inhibition from native thermal adapter use.
type HeatProtectionStatus struct {
	Enabled                  bool      `json:"enabled"`
	Paused                   bool      `json:"paused"`
	TemperatureCelsius       *float64  `json:"temperatureCelsius,omitempty"`
	PauseTemperatureCelsius  float64   `json:"pauseTemperatureCelsius"`
	ResumeTemperatureCelsius float64   `json:"resumeTemperatureCelsius"`
	LastError                string    `json:"lastError,omitempty"`
	UpdatedAt                time.Time `json:"updatedAt"`
	Mechanism                string    `json:"mechanism,omitempty"`
	Requested                string    `json:"requested,omitempty"`
	Observed                 string    `json:"observed,omitempty"`
	Reason                   string    `json:"reason,omitempty"`
	Fault                    bool      `json:"fault"`
	ReserveBlocked           bool      `json:"reserveBlocked"`
	LastTransition           time.Time `json:"lastTransition,omitempty"`
	// AdapterWarning is set when a charge-hold pulse left the charger at 5 V.
	AdapterWarning string `json:"adapterWarning,omitempty"`
}

var (
	heatProtectionMu              sync.RWMutex
	heatProtectionStatus          HeatProtectionStatus
	readBatteryTemperatureCelsius = func() (float64, error) {
		info, err := powerkit.GetSystemInfo(powerkit.FetchOptions{QueryIOKit: true, QuerySMC: false})
		if err != nil {
			return 0, fmt.Errorf("read IOKit battery data: %w", err)
		}
		if info == nil || info.IOKit == nil || info.IOKit.Battery.Temperature <= 0 {
			return 0, fmt.Errorf("battery temperature is unavailable")
		}
		return info.IOKit.Battery.Temperature, nil
	}
)

func getHeatProtectionStatus() HeatProtectionStatus {
	if capabilities.ChargeControlMode == compatibility.ChargeControlNative && !capabilities.ChargeHold && !capabilities.ThermalAdapter {
		return HeatProtectionStatus{LastError: "Custom heat protection unavailable with Apple's native charge limit", UpdatedAt: time.Now()}
	}
	heatProtectionMu.RLock()
	defer heatProtectionMu.RUnlock()

	status := heatProtectionStatus
	if status.TemperatureCelsius != nil {
		temperature := *status.TemperatureCelsius
		status.TemperatureCelsius = &temperature
	}
	return status
}

func clearHeatProtectionStatus() {
	heatProtectionMu.Lock()
	defer heatProtectionMu.Unlock()
	heatProtectionStatus = HeatProtectionStatus{
		Enabled:                  false,
		PauseTemperatureCelsius:  conf.HeatPauseTemperatureCelsius(),
		ResumeTemperatureCelsius: conf.HeatResumeTemperatureCelsius(),
		UpdatedAt:                time.Now(),
	}
}

// heatProtectionBlocksCharging reads the actual battery sensor and applies a
// hysteresis gate. On a sensor error it fails closed: charging is inhibited,
// while AC power remains enabled, until a valid cool reading is observed.
func heatProtectionBlocksCharging() bool {
	if !conf.HeatProtectionEnabled() {
		clearHeatProtectionStatus()
		return false
	}

	pauseAt := conf.HeatPauseTemperatureCelsius()
	resumeAt := conf.HeatResumeTemperatureCelsius()
	temperature, err := readBatteryTemperatureCelsius()

	heatProtectionMu.Lock()
	defer heatProtectionMu.Unlock()

	wasPaused := heatProtectionStatus.Paused
	status := HeatProtectionStatus{
		Enabled:                  true,
		Paused:                   wasPaused,
		PauseTemperatureCelsius:  pauseAt,
		ResumeTemperatureCelsius: resumeAt,
		UpdatedAt:                time.Now(),
	}
	if err != nil {
		status.Paused = true
		status.LastError = err.Error()
		heatProtectionStatus = status
		return true
	}

	status.TemperatureCelsius = &temperature
	if !wasPaused && temperature >= pauseAt {
		status.Paused = true
	}
	if wasPaused && temperature <= resumeAt {
		status.Paused = false
	}
	heatProtectionStatus = status
	return status.Paused
}
