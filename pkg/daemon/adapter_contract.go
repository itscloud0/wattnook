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
	// adapterIgnoredAfter is how long the ignored state must last to warn.
	adapterIgnoredAfter = 30 * time.Second
	// The charger is unstable after adapterUnstableDetaches USB-C detaches
	// within adapterUnstableWindow, and stable again after a window with none.
	// A pulse or a replug by hand costs one or two.
	adapterUnstableDetaches = 4
	adapterUnstableWindow   = 2 * time.Minute
	adapterDetachCheckEvery = 10 * time.Second
)

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
	if h.detachCount == nil || time.Since(h.detachCheckedAt) < adapterDetachCheckEvery {
		return
	}
	h.detachCheckedAt = time.Now()
	count, err := h.detachCount()
	if err != nil || count < 0 {
		return
	}
	now := time.Now()
	if n := len(h.detaches); n > 0 && count < h.detaches[n-1].count {
		h.detaches = nil // counter reset
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
