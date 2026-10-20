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
	Retarget(target int) error
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
	// pendingLimit is an Apple limit chosen while held (0 = none).
	pendingLimit int
	customLimit  func() int
	// USB-PD contract check around adapter pulses.
	contract       func() (adapterContract, error)
	contractWait   time.Duration
	sleep          func(time.Duration)
	adapterWarning string
	// Why the active hold exists and where it is.
	forHeat  bool
	forLimit int
	target   int
	// fault stops further transitions until Heat Protection is re-enabled.
	fault          string
	lastTransition time.Time
}

var heatHold *nativeHeatHold

// Heat Protection never holds a nearly empty battery: below heatHoldStart it
// does not start a hold, and below heatHoldRelease it ends one, so a hot Mac
// whose adapter cannot cover the load still charges instead of draining.
const (
	heatHoldStart   = 30
	heatHoldRelease = 25
)

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
		setLimit:    func(limit int) error { return nativeCharge.SetLimit(limit) },
		customLimit: func() int { return conf.CustomChargeLimit() },
		contract:    readAdapterContract,
		sleep:       time.Sleep,
	}
}

// release ends an active hold. It is used for Off, shutdown and cooling.
func (h *nativeHeatHold) release() error {
	if !h.holder.Active() {
		return nil
	}
	if err := h.guardAdapterContract(h.holder.Release); err != nil {
		h.fault = err.Error()
		return err
	}
	h.lastTransition = time.Now()
	h.target = 0
	logrus.Info("charge hold released; charging follows Apple's limit")
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
	status.Paused = status.Enabled && h.holder.Active() && h.forHeat
	status.Observed = "released"
	if h.holder.Active() {
		status.Observed = "held"
	}
	if h.fault != "" {
		status.Fault = true
		status.LastError = h.fault
	}
	status.AdapterWarning = h.adapterWarning
	heatProtectionMu.Lock()
	heatProtectionStatus = status
	heatProtectionMu.Unlock()
}

// reconcile drives one charge hold for two reasons: Heat Protection (hold at
// the current charge while hot) and a custom charge limit below Apple's
// choices (hold at the limit, or at the current charge when already above
// it; the Mac is never discharged on AC to reach a limit). The hold is moved
// only when its reason changes, never on percentage drift, so the adapter is
// pulsed once per transition. A sensor error never starts or ends a hold.
func (h *nativeHeatHold) reconcile(enabled bool, pause, resume float64) {
	status := HeatProtectionStatus{Enabled: enabled, PauseTemperatureCelsius: pause, ResumeTemperatureCelsius: resume}
	defer func() { h.publish(status) }()
	h.refreshAdapterWarning()
	custom := 0
	if h.customLimit != nil {
		custom = h.customLimit()
	}
	if !enabled {
		h.fault = ""
		status.Reason = "disabled"
	}
	if h.fault != "" {
		return
	}
	if !enabled && custom == 0 {
		h.forHeat, h.forLimit = false, 0
		if err := h.release(); err != nil {
			logrus.WithError(err).Error("charge hold release")
		}
		return
	}
	sample, err := h.sample()
	if err != nil {
		status.LastError = err.Error()
		return
	}
	temperature := sample.Temperature
	if enabled {
		status.TemperatureCelsius = &temperature
	}
	active := h.holder.Active()

	hot := false
	if enabled {
		if h.forHeat && active {
			hot = temperature > resume
		} else {
			hot = temperature >= pause
		}
	}
	if hot {
		floor := heatHoldStart
		if h.forHeat && active {
			floor = heatHoldRelease
		}
		if sample.Percent < floor {
			hot = false
			status.ReserveBlocked = true
			status.Reason = "battery low; charging despite heat"
		}
	}
	if hot && custom == 0 && !(h.forHeat && active) {
		// Without a custom limit, Apple's own limit may already stop charging.
		limit, err := h.appleLimit()
		if err != nil {
			status.LastError = err.Error()
			return
		}
		if sample.Percent >= limit {
			status.Reason = "at Apple charge limit"
			hot = false
		}
	}
	if !hot && custom == 0 {
		h.forHeat, h.forLimit = false, 0
		if active {
			status.Requested = "released"
			if err := h.release(); err != nil {
				logrus.WithError(err).Error("charge hold release")
			}
		} else if enabled && temperature >= pause && status.Reason == "" {
			status.Reason = "watching"
		}
		return
	}

	// A limit hold parked above the limit follows the charge down: once the
	// battery has drained (e.g. on battery) and is back on AC, lower the target
	// so it never charges back above the limit. Only on AC, so draining on
	// battery does not pulse the adapter for every percent.
	drained := !hot && active && !h.forHeat && h.forLimit == custom && sample.PluggedIn &&
		h.target > custom && sample.Percent < h.target
	// Already held for exactly this reason: leave it alone.
	if active && !drained && hot == h.forHeat && (hot || h.forLimit == custom) {
		status.Requested = "held"
		if hot {
			status.Reason = "cooling"
		}
		return
	}
	if !active && !sample.PluggedIn {
		status.Reason = "on battery"
		return
	}
	target := sample.Percent
	if !hot && custom > target {
		target = custom
	}
	if target < chargehold.MinTarget || target > chargehold.MaxTarget {
		status.Reason = "battery outside hold range"
		return
	}
	status.Requested = "held"
	if active && target == h.target {
		// Same target, new reason (e.g. heat starts at the limit): no pulse.
		h.forHeat, h.forLimit = hot, custom
		return
	}
	err = h.guardAdapterContract(func() error {
		if active {
			return h.holder.Retarget(target)
		}
		return h.holder.Hold(target)
	})
	if err != nil {
		h.fault = err.Error()
		logrus.WithError(err).Error("charge hold")
		return
	}
	h.forHeat, h.forLimit, h.target = hot, custom, target
	h.lastTransition = time.Now()
	logrus.WithFields(logrus.Fields{"target": target, "heat": hot, "customLimit": custom, "temperatureCelsius": temperature}).
		Info("charge hold set; adapter keeps powering the Mac")
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
