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
	current := adapterContract{Index: 255}    // after: fell back to 5 V
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
