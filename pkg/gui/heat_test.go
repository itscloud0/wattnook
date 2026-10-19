package gui

import (
	"github.com/charlie0129/batt/pkg/client"
	"strings"
	"testing"
)

func TestAdapterHeatPresentation(t *testing.T) {
	for _, tc := range []struct {
		name    string
		enabled bool
		status  client.HeatProtectionStatus
		want    string
	}{
		{"off", false, client.HeatProtectionStatus{Mechanism: "adapter"}, "uses battery while hot"},
		{"monitoring", true, client.HeatProtectionStatus{Mechanism: "adapter", PauseTemperatureCelsius: 33, ResumeTemperatureCelsius: 30}, "33°C → 30°C"},
		{"verified pause", true, client.HeatProtectionStatus{Mechanism: "adapter", Paused: true}, "running on battery"},
		{"fault wins over stale pause", true, client.HeatProtectionStatus{Mechanism: "adapter", Paused: true, Fault: true, LastError: "sensor unavailable"}, "stopped"},
		{"reserve", true, client.HeatProtectionStatus{Mechanism: "adapter", ReserveBlocked: true}, "adapter restored"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			title, detail := heatProtectionPresentation(tc.enabled, &tc.status)
			if !strings.Contains(title, tc.want) || detail == "" {
				t.Fatalf("%q %q", title, detail)
			}
		})
	}
}

func TestChargeHoldHeatPresentationNamesState(t *testing.T) {
	for _, tc := range []struct {
		name    string
		enabled bool
		status  client.HeatProtectionStatus
		detail  string
	}{
		{"off", false, client.HeatProtectionStatus{Mechanism: "charge-hold"}, "Off"},
		{"watching", true, client.HeatProtectionStatus{Mechanism: "charge-hold", PauseTemperatureCelsius: 33, ResumeTemperatureCelsius: 30}, "Watching · pauses at 33°"},
		{"paused", true, client.HeatProtectionStatus{Mechanism: "charge-hold", Paused: true, PauseTemperatureCelsius: 33, ResumeTemperatureCelsius: 30}, "Paused · resumes at 30°"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, detail := heatProtectionPresentation(tc.enabled, &tc.status); detail != tc.detail {
				t.Fatalf("detail %q, want %q", detail, tc.detail)
			}
		})
	}
}

func TestAlertTextDropsTransportPrefix(t *testing.T) {
	for in, want := range map[string]string{
		`got 409: "Heat Protection is pausing charging"`:        "Heat Protection is pausing charging",
		`set limit: got 503: "native limit readback disagrees"`: "set limit: native limit readback disagrees",
		"plain message":     "plain message",
		`got 500: not json`: "not json",
	} {
		if got := alertText(in); got != want {
			t.Fatalf("alertText(%q) = %q, want %q", in, got, want)
		}
	}
}
