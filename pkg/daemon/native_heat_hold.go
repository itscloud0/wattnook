package daemon

import (
	"errors"
	"fmt"
	"path/filepath"
	"time"

	"github.com/peterneutron/powerkit-go/pkg/powerkit"
	"github.com/sirupsen/logrus"

	"github.com/charlie0129/batt/pkg/chargehold"
	"github.com/charlie0129/batt/pkg/thermalguard"
)

// heatHoldSample is one reading taken before a Heat Protection decision.
type heatHoldSample struct {
	Temperature float64
	Percent     int
	PluggedIn   bool
}

type chargeHolder interface {
	Active() bool
	SavedLimit() (int, bool)
	Hold(target int) error
	Release() error
}

// nativeHeatHold implements charge-only Heat Protection in native mode: when
// the battery is hot on AC, charging pauses at the current percentage while
// the adapter keeps powering the Mac. All methods run under
// maintainLoopInnerLock.
type nativeHeatHold struct {
	holder     chargeHolder
	sample     func() (heatHoldSample, error)
	appleLimit func() (int, error)
	setLimit   func(int) error
	// pendingLimit is a charge limit chosen while held (0 = none).
	pendingLimit int
	// fault stops further transitions until Heat Protection is re-enabled.
	fault          string
	lastTransition time.Time
}

var heatHold *nativeHeatHold

func heatHoldRecordPath(configPath string) string {
	name := "batt.json"
	if configPath != "" {
		name = filepath.Base(configPath)
	}
	return filepath.Join("/var/db/wattnook-thermal", name+".charge-hold.json")
}

func newSystemChargeHolder(configPath string) *chargehold.Holder {
	return &chargehold.Holder{Prefs: chargehold.SystemPreferences{}, SMC: smcConn,
		Store: chargehold.Store{Path: heatHoldRecordPath(configPath)}, Sleep: time.Sleep}
}

// releaseStaleChargeHold runs before native capability detection: an active
// hold leaves mclLimitValue outside Apple's advertised limits, and a hold left
// by a crashed daemon must never keep charging paused indefinitely.
func releaseStaleChargeHold(configPath string) {
	holder := newSystemChargeHolder(configPath)
	if !holder.Active() {
		return
	}
	if err := holder.Release(); err != nil {
		logrus.WithError(err).Error("release charge hold left by a previous daemon")
		return
	}
	logrus.Info("released charge hold left by a previous daemon")
}

func readHeatHoldSample() (heatHoldSample, error) {
	info, err := powerkit.GetSystemInfo(powerkit.FetchOptions{QueryIOKit: true, QuerySMC: false})
	if err != nil {
		return heatHoldSample{}, fmt.Errorf("read IOKit battery data: %w", err)
	}
	if info == nil || info.IOKit == nil {
		return heatHoldSample{}, errors.New("battery data unavailable")
	}
	b := info.IOKit
	temperature, err := thermalguard.BatteryTemperature(smcConn, b.Battery.Temperature)
	if err != nil {
		return heatHoldSample{}, err
	}
	return heatHoldSample{Temperature: temperature, Percent: b.Battery.CurrentCharge, PluggedIn: b.State.IsConnected}, nil
}

func initializeHeatHold(configPath string) {
	if !capabilities.ChargeHold {
		return
	}
	heatHold = &nativeHeatHold{
		holder: newSystemChargeHolder(configPath),
		sample: readHeatHoldSample,
		appleLimit: func() (int, error) {
			state, err := nativeCharge.Read()
			if err != nil {
				return 0, err
			}
			return state.EffectiveLimit(), nil
		},
		setLimit: func(limit int) error { return nativeCharge.SetLimit(limit) },
	}
}

// release ends an active hold. It is used for Off, shutdown and cooling.
func (h *nativeHeatHold) release() error {
	if !h.holder.Active() {
		return nil
	}
	if err := h.holder.Release(); err != nil {
		h.fault = err.Error()
		return err
	}
	h.lastTransition = time.Now()
	logrus.Info("heat protection resumed charging")
	if limit := h.pendingLimit; limit > 0 {
		h.pendingLimit = 0
		if err := h.setLimit(limit); err != nil {
			logrus.WithError(err).WithField("limit", limit).Error("apply charge limit chosen during heat hold")
		}
	}
	return nil
}

// reset clears a fault after the user explicitly re-configures Heat Protection.
func (h *nativeHeatHold) reset() { h.fault = "" }

func (h *nativeHeatHold) publish(status HeatProtectionStatus) {
	status.Mechanism = "charge-hold"
	status.UpdatedAt = time.Now()
	status.LastTransition = h.lastTransition
	status.Paused = status.Enabled && h.holder.Active()
	status.Observed = "released"
	if h.holder.Active() {
		status.Observed = "held"
	}
	if h.fault != "" {
		status.Fault = true
		status.LastError = h.fault
	}
	heatProtectionMu.Lock()
	heatProtectionStatus = status
	heatProtectionMu.Unlock()
}

// reconcile applies the hysteresis: hold when hot on AC below Apple's limit,
// release once cool. A sensor error never starts a hold and never releases
// one; the next valid reading decides.
func (h *nativeHeatHold) reconcile(enabled bool, pause, resume float64) {
	status := HeatProtectionStatus{Enabled: enabled, PauseTemperatureCelsius: pause, ResumeTemperatureCelsius: resume}
	defer func() { h.publish(status) }()

	if !enabled {
		h.fault = ""
		if err := h.release(); err != nil {
			logrus.WithError(err).Error("heat protection release")
		}
		status.Reason = "disabled"
		return
	}
	if h.fault != "" {
		return
	}
	sample, err := h.sample()
	if err != nil {
		status.LastError = err.Error()
		return
	}
	temperature := sample.Temperature
	status.TemperatureCelsius = &temperature

	if h.holder.Active() {
		status.Requested = "held"
		if temperature > resume {
			status.Reason = "cooling"
			return
		}
		status.Requested = "released"
		if err := h.release(); err != nil {
			logrus.WithError(err).Error("heat protection release")
		}
		return
	}

	status.Requested = "released"
	if temperature < pause {
		return
	}
	if !sample.PluggedIn {
		status.Reason = "on battery"
		return
	}
	limit, err := h.appleLimit()
	if err != nil {
		status.LastError = err.Error()
		return
	}
	if sample.Percent >= limit {
		// Apple's own limit already keeps the battery from charging.
		status.Reason = "at Apple charge limit"
		return
	}
	if sample.Percent < chargehold.MinTarget {
		status.Reason = "battery too low to pause"
		return
	}
	status.Requested = "held"
	if err := h.holder.Hold(sample.Percent); err != nil {
		h.fault = err.Error()
		logrus.WithError(err).Error("heat protection hold")
		return
	}
	h.lastTransition = time.Now()
	logrus.WithFields(logrus.Fields{"temperatureCelsius": temperature, "percent": sample.Percent}).Info("heat protection paused charging; adapter keeps powering the Mac")
}

// savedAppleLimit reports the user's Apple limit while a hold replaces it.
func (h *nativeHeatHold) savedAppleLimit() (int, bool) {
	if h == nil || !h.holder.Active() {
		return 0, false
	}
	if h.pendingLimit > 0 {
		return h.pendingLimit, true
	}
	return h.holder.SavedLimit()
}
