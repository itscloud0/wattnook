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
	// BatteryAmps is negative while the battery discharges.
	BatteryAmps float64
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
	sailingLevel func() int
	topUpState   func() (bool, int)
	clearTopUp   func()
	discharge    func() bool
	endDischarge func()
	// USB-PD contract check around adapter pulses.
	contract     func() (adapterContract, error)
	contractWait time.Duration
	sleep        func(time.Duration)
	// pulseSettle ignores "unplugged" readings this long after a pulse: the
	// adapter input is briefly off, which is not the user pulling the cable.
	pulseSettle    time.Duration
	adapterWarning string
	ignoredSince   time.Time
	// reserveLatched blocks heat holds after a reserve release until rearm.
	reserveLatched bool
	// USB-C detach counts sampled to spot a charger that keeps dropping out.
	detachCount     func() (int, error)
	detaches        []detachSample
	detachCheckedAt time.Time
	adapterUnstable bool
	// Why the active hold exists and where it is.
	forHeat   bool
	forSail   bool
	forDrain  bool
	forLimit  int
	target    int
	sailArmed bool
	// fault stops further transitions until Heat Protection is re-enabled.
	fault          string
	lastTransition time.Time
}

var heatHold *nativeHeatHold

// Heat Protection pauses charging at any charge from heatHoldMinimum, as
// long as the adapter covers the Mac. If it cannot (the held battery is
// discharging) and the charge falls below heatHoldReserve, the hold ends so
// the battery can recover, and it re-arms only at heatHoldRearm.
const (
	heatHoldMinimum  = 10
	heatHoldReserve  = 25
	heatHoldRearm    = 30
	heatDrainingAmps = -0.1
	// Sailing never lets the battery sail below this charge.
	sailingAlwaysCharge = 20
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
	return heatHoldSample{Temperature: temperature, Percent: b.Battery.CurrentCharge, PluggedIn: b.State.IsConnected,
		BatteryAmps: b.Battery.Amperage}, nil
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
		setLimit:     func(limit int) error { return nativeCharge.SetLimit(limit) },
		customLimit:  func() int { return conf.CustomChargeLimit() },
		sailingLevel: func() int { return conf.SailingLevel() },
		topUpState:   func() (bool, int) { return conf.TopUpActive(), conf.TopUpRestoreLimit() },
		discharge:    func() bool { return conf.DischargeActive() },
		endDischarge: func() {
			conf.SetDischarge(false)
			if err := conf.Save(); err != nil {
				logrus.WithError(err).Error("save config after discharge")
			}
		},
		clearTopUp: func() {
			conf.SetTopUp(false, 0)
			if err := conf.Save(); err != nil {
				logrus.WithError(err).Error("save config after Top Up")
			}
		},
		contract:    readAdapterContract,
		detachCount: readDetachCount,
		sleep:       time.Sleep,
		pulseSettle: 15 * time.Second,
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
	if status.AdapterWarning == "" && h.adapterUnstable {
		status.AdapterWarning = adapterUnstableWarning
	}
	heatProtectionMu.Lock()
	heatProtectionStatus = status
	heatProtectionMu.Unlock()
}

// reconcile drives one charge hold for several reasons, in priority order:
//   - Heat Protection: hold at the current charge while the battery is hot;
//   - Sailing: after reaching the limit, hold wherever the charge drifts to
//     until it falls `sailing` points below the limit, then charge again;
//   - a custom limit below Apple's choices: hold at the limit, or at the
//     current charge when already above it (never discharging on AC).
//
// Top Up suspends Sailing and the custom limit until the adapter is
// disconnected. The hold moves only when its reason changes (or the battery
// drained below a parked hold while unplugged), so the adapter is pulsed once
// per transition. A sensor error never starts or ends a hold.
func (h *nativeHeatHold) reconcile(enabled bool, pause, resume float64) {
	status := HeatProtectionStatus{Enabled: enabled, PauseTemperatureCelsius: pause, ResumeTemperatureCelsius: resume}
	defer func() { h.publish(status) }()
	custom, sailing := 0, 0
	if h.customLimit != nil {
		custom = h.customLimit()
	}
	if h.sailingLevel != nil {
		sailing = h.sailingLevel()
	}
	topUp, restore := false, 0
	if h.topUpState != nil {
		topUp, restore = h.topUpState()
	}
	draining := h.discharge != nil && h.discharge()
	status.SailingLevel, status.TopUp, status.Discharging = sailing, topUp, draining
	if !enabled {
		h.fault = ""
		status.Reason = "disabled"
	}
	if h.fault != "" {
		return
	}
	if !enabled && custom == 0 && sailing == 0 && !topUp && !draining {
		h.forHeat, h.forSail, h.forDrain, h.forLimit, h.sailArmed = false, false, false, 0, false
		h.refreshAdapterWarning(true)
		h.detaches, h.adapterUnstable = nil, false
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
	h.refreshAdapterWarning(sample.PluggedIn)
	h.watchDetaches()
	temperature := sample.Temperature
	if enabled {
		status.TemperatureCelsius = &temperature
	}
	unplugged := !sample.PluggedIn && time.Since(h.lastTransition) >= h.pulseSettle
	if draining && (topUp || unplugged) {
		// Discharge is a one-shot on AC; unplugging or Top Up ends it.
		h.stopDischarge()
		draining = false
		status.Discharging = false
	}
	if topUp {
		if unplugged {
			// Unplugging ends Top Up and brings the previous limit back.
			h.endTopUp(restore)
			topUp = false
			status.TopUp = false
		} else {
			custom, sailing = 0, 0
		}
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
	if sample.Percent >= heatHoldRearm {
		h.reserveLatched = false
	}
	if hot && unplugged && !(h.forHeat && active) {
		// On battery a hold changes nothing; start one when the adapter is back.
		hot = false
		status.Reason = "on battery"
	}
	if hot {
		heldForHeat := h.forHeat && active
		// Below the hold point on AC means the adapter cannot cover the load;
		// the fraction drained down to the hold point is expected. On battery
		// the battery drains anyway, which says nothing about the adapter.
		draining := !unplugged && sample.BatteryAmps < heatDrainingAmps && sample.Percent < h.target
		switch {
		case heldForHeat && sample.Percent < heatHoldReserve && draining:
			// The adapter cannot cover the load: let the battery recover.
			h.reserveLatched = true
			hot = false
		case !heldForHeat && (sample.Percent < heatHoldMinimum || h.reserveLatched):
			hot = false
		}
		if !hot {
			status.ReserveBlocked = true
			status.Reason = "battery low; charging despite heat"
		}
	}

	// The limit the battery charges to: the custom limit, otherwise Apple's.
	limit := custom
	if limit == 0 && !topUp && (sailing > 0 || draining || (hot && !(h.forHeat && active))) {
		limit, err = h.effectiveAppleLimit(active)
		if err != nil {
			status.LastError = err.Error()
			return
		}
	}
	if hot && custom == 0 && !(h.forHeat && active) && sample.Percent >= limit {
		// Apple's own limit already stops charging.
		status.Reason = "at Apple charge limit"
		hot = false
	}

	drain := false
	if draining {
		if limit <= 0 || sample.Percent <= limit {
			// Reached the limit: hand over to the normal limit behaviour.
			h.stopDischarge()
			status.Discharging = false
		} else {
			// Draining keeps the battery from charging, so heat is moot.
			drain, hot = true, false
		}
	}

	sail := false
	if sailing > 0 && limit > 0 && !drain {
		if sample.Percent >= limit {
			h.sailArmed = true
		}
		if sample.Percent <= limit-sailing || sample.Percent < sailingAlwaysCharge {
			h.sailArmed = false
		}
		sail = h.sailArmed && sample.Percent < limit
		status.Sailing = sail
	} else {
		h.sailArmed = false
	}

	if !hot && !sail && !drain && custom == 0 {
		h.forHeat, h.forSail, h.forDrain, h.forLimit = false, false, false, 0
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

	// A hold parked at a charge (sailing, or a limit below the charge)
	// follows the charge down: once the battery drained on battery and is back
	// on AC, lower the target so it never charges back up. Only on AC, so
	// draining on battery does not pulse the adapter for every percent.
	drained := !hot && !drain && active && !h.forHeat && sample.PluggedIn && sample.Percent < h.target &&
		((sail && h.forSail) || (!sail && !h.forSail && h.forLimit == custom && h.target > custom))
	sameReason := active && hot == h.forHeat && sail == h.forSail && drain == h.forDrain &&
		(hot || sail || drain || h.forLimit == custom)
	if sameReason && !drained {
		status.Requested = "held"
		if hot {
			status.Reason = "cooling"
		} else if drain {
			status.Reason = "discharging to the limit"
		} else if sail {
			status.Reason = "sailing"
		}
		return
	}
	if !active && !sample.PluggedIn {
		status.Reason = "on battery"
		return
	}
	target := sample.Percent
	switch {
	case hot:
		// Hold at the displayed (rounded-down) charge. macOS may let the
		// battery give back the fraction above it, which cools it; a target one
		// point up made it charge a whole percent at full power instead.
	case drain:
		// A target below the charge makes macOS run the Mac partly from the
		// battery on AC until it reaches the target; the adapter stays on.
		target = limit
	case sail:
		// Hold where the charge drifted to; it falls further only on battery.
	case custom > target:
		target = custom
	}
	if target < chargehold.MinTarget || target > chargehold.MaxTarget {
		status.Reason = "battery outside hold range"
		return
	}
	status.Requested = "held"
	if active && target == h.target {
		// Same target, new reason (e.g. heat starts at the limit): no pulse.
		h.forHeat, h.forSail, h.forDrain, h.forLimit = hot, sail, drain, custom
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
	h.forHeat, h.forSail, h.forDrain, h.forLimit, h.target = hot, sail, drain, custom, target
	h.lastTransition = time.Now()
	logrus.WithFields(logrus.Fields{"target": target, "heat": hot, "sailing": sail, "discharge": drain, "customLimit": custom, "temperatureCelsius": temperature}).
		Info("charge hold set; adapter keeps powering the Mac")
}

// effectiveAppleLimit is Apple's limit, read from the snapshot while a hold
// has replaced it (PowerUI then reports the hold's value).
func (h *nativeHeatHold) effectiveAppleLimit(active bool) (int, error) {
	if active {
		if h.pendingLimit > 0 {
			return h.pendingLimit, nil
		}
		if limit, ok := h.holder.SavedLimit(); ok {
			return limit, nil
		}
	}
	return h.appleLimit()
}

// stopDischarge ends a discharge (reached the limit, unplugged, Top Up).
func (h *nativeHeatHold) stopDischarge() {
	if h.endDischarge != nil {
		h.endDischarge()
	}
	logrus.Info("discharge finished")
}

// endTopUp clears Top Up and restores the Apple limit it replaced.
func (h *nativeHeatHold) endTopUp(restore int) {
	if h.clearTopUp != nil {
		h.clearTopUp()
	}
	if restore < 80 || restore > 100 {
		restore = 80
	}
	if h.holder.Active() {
		h.pendingLimit = restore
		return
	}
	if h.setLimit != nil {
		if err := h.setLimit(restore); err != nil {
			logrus.WithError(err).WithField("limit", restore).Error("restore charge limit after Top Up")
		}
	}
	logrus.WithField("limit", restore).Info("Top Up ended; charge limit restored")
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
