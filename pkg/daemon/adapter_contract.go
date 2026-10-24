package daemon

import (
	"context"
	"errors"
	"os/exec"
	"regexp"
	"strconv"
	"time"

	"github.com/sirupsen/logrus"
)

// adapterContract is the USB-PD contract the charger negotiated: the index
// into its voltage menu (255 = none, i.e. plain 5 V) and the input voltage.
type adapterContract struct {
	Index     int
	VoltageMV int
	// Ignored: the charger is live at a high voltage but macOS reports no
	// external power, so the Mac runs on battery until the cable is replugged.
	Ignored bool
	// Detaches is the USB-C port controllers' detach count since boot (-1 when
	// not reported). It also counts drop-outs the cable never noticed.
	Detaches int
}

// highVoltage reports a negotiated PD level above 5 V.
func (a adapterContract) highVoltage() bool {
	return a.Index > 0 && a.Index != 255
}

var (
	hvcIndexPattern      = regexp.MustCompile(`"UsbHvcHvcIndex"=(\d+)`)
	systemVoltagePattern = regexp.MustCompile(`"SystemVoltageIn"=(\d+)`)
	externalPattern      = regexp.MustCompile(`"ExternalConnected" = (Yes|No)`)
	detachPattern        = regexp.MustCompile(`"PortControllerDetachCount"=(\d+)`)
)

func parseAdapterContract(ioreg string) (adapterContract, error) {
	index := hvcIndexPattern.FindStringSubmatch(ioreg)
	if index == nil {
		return adapterContract{}, errors.New("no USB-PD contract reported")
	}
	contract := adapterContract{Detaches: -1}
	contract.Index, _ = strconv.Atoi(index[1])
	for _, detach := range detachPattern.FindAllStringSubmatch(ioreg, -1) {
		count, _ := strconv.Atoi(detach[1])
		contract.Detaches = max(contract.Detaches, 0) + count
	}
	if voltage := systemVoltagePattern.FindStringSubmatch(ioreg); voltage != nil {
		contract.VoltageMV, _ = strconv.Atoi(voltage[1])
	}
	if external := externalPattern.FindStringSubmatch(ioreg); external != nil {
		contract.Ignored = external[1] == "No" && contract.highVoltage() && contract.VoltageMV >= 9000
	}
	return contract, nil
}

func readDetachCount() (int, error) {
	contract, err := readAdapterContract()
	return contract.Detaches, err
}

func readAdapterContract() (adapterContract, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/sbin/ioreg", "-rn", "AppleSmartBattery").Output()
	if err != nil {
		return adapterContract{}, err
	}
	return parseAdapterContract(string(out))
}

const (
	adapterDegradedWarning = "The power adapter dropped to 5 V (about 12 W) after a charge-hold pulse. Unplug and reconnect the power cable."
	adapterIgnoredWarning  = "macOS stopped drawing power from the connected charger, so the Mac runs on battery. Unplug and reconnect the power cable."
	adapterUnstableWarning = "The charger keeps disconnecting and reconnecting, so the battery drains between short bursts of charging. Try another cable or port, or a stronger charger."
	adapterTestingWarning  = "The charger keeps disconnecting and reconnecting. WattNook has handed charging back to macOS for 3 minutes to check whether its charge control is the cause."
	adapterNotUsWarning    = "The charger kept disconnecting with WattNook's charge control off, so the cause is the charger, cable or port, not WattNook. Try another cable, port or charger."
	adapterUsWarning       = "The charger stopped disconnecting once WattNook released its charge control, so WattNook keeps it off for 30 minutes and macOS charges normally."
	// adapterIgnoredAfter is how long the ignored state must last to warn.
	adapterIgnoredAfter = 30 * time.Second
	// The charger is unstable after adapterUnstableDetaches USB-C detaches
	// within adapterUnstableWindow, and stable again after a window with none.
	// A pulse or a replug by hand costs one or two.
	adapterUnstableDetaches = 4
	adapterUnstableWindow   = 2 * time.Minute
	adapterDetachCheckEvery = 10 * time.Second
	// The self-test releases the hold for stepAsideFor; a verdict stands for
	// verdictFor before the next test.
	stepAsideFor = 3 * time.Minute
	verdictFor   = 30 * time.Minute
	// A release pulse costs a detach or two; more means the drop-outs went on.
	stepAsideContinued = adapterUnstableDetaches

	diagnosisCharger = "charger"
	diagnosisHold    = "hold"
	diagnosisUnknown = "unknown"
)

func (h *nativeHeatHold) clock() time.Time {
	if h.now != nil {
		return h.now()
	}
	return time.Now()
}

type detachSample struct {
	at    time.Time
	count int
}

// guardAdapterContract runs one hold transition and verifies that a
// high-voltage USB-PD contract held before it comes back afterwards. A CHIE
// pulse can make the charger fall back to 5 V without renegotiating, which
// caps input near 12 W and drains the battery under load.
func (h *nativeHeatHold) guardAdapterContract(transition func() error) error {
	if h.contract == nil {
		return transition()
	}
	before, beforeErr := h.contract()
	err := transition()
	if beforeErr != nil || !before.highVoltage() {
		return err
	}
	wait := h.contractWait
	if wait == 0 {
		wait = 8 * time.Second
	}
	for deadline := time.Now().Add(wait); ; {
		if after, readErr := h.contract(); readErr == nil && after.highVoltage() {
			h.adapterWarning = ""
			return err
		}
		if !time.Now().Before(deadline) {
			break
		}
		h.sleep(500 * time.Millisecond)
	}
	h.adapterWarning = adapterDegradedWarning
	return err
}

// refreshAdapterWarning warns when macOS ignores a live charger and clears
// either warning once the user reconnects the cable. The adapter is read
// only while a warning is shown or macOS reports no external power.
func (h *nativeHeatHold) refreshAdapterWarning(pluggedIn bool) {
	if h.contract == nil || (pluggedIn && h.adapterWarning == "") {
		h.ignoredSince = time.Time{}
		return
	}
	contract, err := h.contract()
	if err != nil {
		return
	}
	if !contract.Ignored {
		h.ignoredSince = time.Time{}
		if h.adapterWarning == adapterIgnoredWarning || (h.adapterWarning != "" && contract.highVoltage()) {
			h.adapterWarning = ""
		}
		return
	}
	if h.ignoredSince.IsZero() {
		h.ignoredSince = time.Now()
	}
	if time.Since(h.ignoredSince) >= adapterIgnoredAfter && time.Since(h.lastTransition) >= h.pulseSettle {
		h.adapterWarning = adapterIgnoredWarning
	}
}

// watchDetaches warns when the charger keeps dropping out by itself. The
// maintain loop is too slow to see each drop-out, so it compares the port
// controllers' detach counter over a window instead.
func (h *nativeHeatHold) watchDetaches() {
	now := h.clock()
	if h.detachCount == nil || now.Sub(h.detachCheckedAt) < adapterDetachCheckEvery {
		return
	}
	h.detachCheckedAt = now
	count, err := h.detachCount()
	if err != nil || count < 0 {
		return
	}
	if n := len(h.detaches); n > 0 && count < h.detaches[n-1].count {
		h.detaches = nil // counter reset
	} else if n > 0 && count > h.detaches[n-1].count {
		// One line per check with what WattNook was doing, so drop-outs can
		// be matched against its own transitions afterwards.
		logrus.WithFields(logrus.Fields{"detaches": count - h.detaches[n-1].count, "held": h.holder.Active(),
			"target": h.target, "heat": h.forHeat, "sinceTransition": now.Sub(h.lastTransition).Round(time.Second)}).
			Info("charger dropped out")
	}
	h.detaches = append(h.detaches, detachSample{at: now, count: count})
	// Keep the newest sample at least a window old as the baseline.
	for len(h.detaches) > 1 && now.Sub(h.detaches[1].at) >= adapterUnstableWindow {
		h.detaches = h.detaches[1:]
	}
	baseline := h.detaches[0]
	recent := count - baseline.count
	switch {
	case recent >= adapterUnstableDetaches:
		if !h.adapterUnstable {
			logrus.WithField("detaches", recent).Warn("charger keeps disconnecting")
		}
		h.adapterUnstable = true
	case recent == 0 && now.Sub(baseline.at) >= adapterUnstableWindow:
		h.adapterUnstable = false
	}
}

// diagnoseDropOuts is the self-test for a charger that keeps dropping out
// while WattNook holds charging: release the hold for stepAsideFor and see
// whether the drop-outs stop. If they go on, the charger side is at fault and
// the hold resumes; if they stop, WattNook keeps charge control off for
// verdictFor. It returns true while no hold may be set.
func (h *nativeHeatHold) diagnoseDropOuts() bool {
	now := h.clock()
	if !h.stepAsideUntil.IsZero() {
		if now.Before(h.stepAsideUntil) {
			return true
		}
		h.stepAsideUntil, h.diagnosedAt = time.Time{}, now
		continued := h.freshDetachCount() - h.stepAsideDetaches
		switch {
		case continued < 0:
			h.diagnosis = diagnosisUnknown // the counter reset (replug); no verdict
		case continued >= stepAsideContinued:
			h.diagnosis = diagnosisCharger
			logrus.WithField("detaches", continued).Warn("charger kept dropping out with the hold released; not caused by WattNook")
		default:
			h.diagnosis = diagnosisHold
			logrus.WithField("detaches", continued).Warn("drop-outs stopped with the hold released; charge control stays off")
		}
	}
	if h.diagnosis != "" && now.Sub(h.diagnosedAt) >= verdictFor {
		h.diagnosis = ""
	}
	if h.diagnosis == diagnosisHold {
		return true
	}
	if h.diagnosis != "" || !h.adapterUnstable || !h.holder.Active() {
		return false
	}
	if err := h.release(); err != nil {
		logrus.WithError(err).Error("release hold for drop-out test")
		return false
	}
	// Read the counter now: the last periodic sample can be 10 s old, and a
	// storm in those seconds must not count against the test.
	h.stepAsideUntil, h.stepAsideDetaches = now.Add(stepAsideFor), h.freshDetachCount()
	logrus.Warn("charger keeps dropping out while WattNook holds charging; released the hold for 3 minutes to test")
	return true
}

func (h *nativeHeatHold) freshDetachCount() int {
	if h.detachCount != nil {
		if count, err := h.detachCount(); err == nil && count >= 0 {
			return count
		}
	}
	if n := len(h.detaches); n > 0 {
		return h.detaches[n-1].count
	}
	return h.stepAsideDetaches
}

// dropOutWarning explains drop-outs, including the self-test and its verdict.
func (h *nativeHeatHold) dropOutWarning() string {
	switch {
	case !h.stepAsideUntil.IsZero():
		return adapterTestingWarning
	case h.diagnosis == diagnosisHold:
		return adapterUsWarning
	case h.diagnosis == diagnosisCharger && h.adapterUnstable:
		return adapterNotUsWarning
	case h.adapterUnstable:
		return adapterUnstableWarning
	}
	return ""
}
