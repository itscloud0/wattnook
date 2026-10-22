package daemon

import (
	"strings"
	"testing"
	"time"
)

func TestParseAdapterContract(t *testing.T) {
	high := `"AdapterDetails" = {"Watts"=60,"UsbHvcHvcIndex"=3} "PowerTelemetryData" = {"SystemVoltageIn"=19551}`
	if c, err := parseAdapterContract(high); err != nil || c.Index != 3 || c.VoltageMV != 19551 || !c.highVoltage() {
		t.Fatalf("%+v %v", c, err)
	}
	low := `"UsbHvcHvcIndex"=255 "SystemVoltageIn"=4030`
	if c, err := parseAdapterContract(low); err != nil || c.highVoltage() {
		t.Fatalf("5 V contract reported as high voltage: %+v %v", c, err)
	}
	if _, err := parseAdapterContract(`"Watts"=60`); err == nil {
		t.Fatal("missing contract accepted")
	}
}

func TestPulseThatDropsAdapterTo5VWarnsUntilReconnect(t *testing.T) {
	h, holder, _ := newHoldFixture(heatHoldSample{Temperature: 40, Percent: 72, PluggedIn: true})
	contracts := []adapterContract{{Index: 3}} // before the pulse
	current := adapterContract{Index: 255}     // after: fell back to 5 V
	h.contract = func() (adapterContract, error) {
		if len(contracts) > 0 {
			c := contracts[0]
			contracts = contracts[1:]
			return c, nil
		}
		return current, nil
	}
	h.contractWait = time.Millisecond
	h.sleep = func(time.Duration) {}
	h.reconcile(true, 35, 32)
	status := getHeatProtectionStatusUnchecked()
	if len(holder.holds) != 1 || !strings.Contains(status.AdapterWarning, "5 V") {
		t.Fatalf("holds=%v warning=%q", holder.holds, status.AdapterWarning)
	}
	// Reconnecting the cable restores 20 V; the warning clears on the next pass.
	current = adapterContract{Index: 3}
	h.reconcile(true, 35, 32)
	if w := getHeatProtectionStatusUnchecked().AdapterWarning; w != "" {
		t.Fatalf("warning kept after reconnect: %q", w)
	}
}

func TestPulseThatKeeps20VDoesNotWarn(t *testing.T) {
	h, _, _ := newHoldFixture(heatHoldSample{Temperature: 40, Percent: 72, PluggedIn: true})
	h.contract = func() (adapterContract, error) { return adapterContract{Index: 3}, nil }
	h.sleep = func(time.Duration) { t.Fatal("waited although 20 V held") }
	h.reconcile(true, 35, 32)
	if w := getHeatProtectionStatusUnchecked().AdapterWarning; w != "" {
		t.Fatalf("unexpected warning %q", w)
	}
}

// Seen live on macOS 27: a 20 V charger with ExternalConnected = No and the
// Mac on battery until the cable was replugged.
func TestIgnoredChargerWarnsUntilReconnect(t *testing.T) {
	ignored := `"ExternalConnected" = No "UsbHvcHvcIndex"=3 "SystemVoltageIn"=20418`
	if c, err := parseAdapterContract(ignored); err != nil || !c.Ignored {
		t.Fatalf("%+v %v", c, err)
	}
	if c, _ := parseAdapterContract(`"ExternalConnected" = Yes "UsbHvcHvcIndex"=3 "SystemVoltageIn"=20418`); c.Ignored {
		t.Fatal("connected charger reported as ignored")
	}

	h, _, _ := newHoldFixture(heatHoldSample{Temperature: 25, Percent: 57})
	current := adapterContract{Index: 3, VoltageMV: 20418, Ignored: true}
	h.contract = func() (adapterContract, error) { return current, nil }
	h.refreshAdapterWarning(false)
	if h.adapterWarning != "" {
		t.Fatal("warned before the ignored state lasted")
	}
	h.ignoredSince = time.Now().Add(-time.Minute)
	h.refreshAdapterWarning(false)
	if h.adapterWarning != adapterIgnoredWarning {
		t.Fatalf("warning=%q", h.adapterWarning)
	}
	current.Ignored = false
	h.refreshAdapterWarning(false)
	if h.adapterWarning != "" {
		t.Fatal("warning kept after reconnect")
	}
}

func TestParseDetachCountsSumsPorts(t *testing.T) {
	ports := `"UsbHvcHvcIndex"=3 "PortControllerInfo" = ({"PortControllerDetachCount"=1},{"PortControllerDetachCount"=366})`
	if c, err := parseAdapterContract(ports); err != nil || c.Detaches != 367 {
		t.Fatalf("%+v %v", c, err)
	}
	if c, _ := parseAdapterContract(`"UsbHvcHvcIndex"=3`); c.Detaches != -1 {
		t.Fatalf("missing counter read as %d", c.Detaches)
	}
}

// A charger that drops out every few seconds is invisible to a 5 s loop, so
// the warning comes from the port's detach counter.
func TestChargerThatKeepsDisconnectingWarnsUntilStable(t *testing.T) {
	h, _, _ := newHoldFixture(heatHoldSample{Temperature: 25, Percent: 50, PluggedIn: true})
	detaches := 300
	h.detachCount = func() (int, error) { return detaches, nil }
	// Each step is one check, 30 s after the last.
	step := func() {
		for i := range h.detaches {
			h.detaches[i].at = h.detaches[i].at.Add(-30 * time.Second)
		}
		h.detachCheckedAt = time.Time{}
		h.watchDetaches()
	}
	step()
	detaches += 2 // a replug by hand
	step()
	if h.adapterUnstable {
		t.Fatal("a single replug warned")
	}
	for range 4 {
		detaches += 2
		step()
	}
	h.reconcile(true, 33, 30)
	if !strings.Contains(getHeatProtectionStatusUnchecked().AdapterWarning, "keeps disconnecting") {
		t.Fatalf("no warning: %+v", getHeatProtectionStatusUnchecked())
	}
	// Quiet for under a window: still warns; a full quiet window clears it.
	step()
	step()
	if !h.adapterUnstable {
		t.Fatal("cleared before a quiet window")
	}
	for range 4 {
		step()
	}
	if h.adapterUnstable {
		t.Fatal("still warning after a quiet window")
	}
}
