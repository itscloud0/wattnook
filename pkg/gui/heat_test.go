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
