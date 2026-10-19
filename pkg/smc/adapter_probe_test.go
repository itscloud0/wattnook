package smc

import (
	"math"
	"testing"

	"github.com/charlie0129/gosmc"
)

func TestAdapterProbeRejectsUnsafeBaseline(t *testing.T) {
	baseline := func() AdapterProbePreflight {
		return AdapterProbePreflight{
			Info:       gosmc.KeyInfo{Key: AdapterKey3, DataType: "hex_", DataSize: 1},
			Value:      gosmc.Value{Key: AdapterKey3, DataType: "hex_", Bytes: []byte{0}},
			PhysicalAC: true, BatteryPercent: 40,
			NativeLimit: 80, NativeLimitEnabled: true, RestorationArmed: true,
		}
	}
	if err := ValidateAdapterProbe(baseline()); err != nil {
		t.Fatalf("valid fixture rejected: %v", err)
	}
	unarmed := baseline()
	unarmed.RestorationArmed = false
	if err := ValidateAdapterProbeBaseline(unarmed); err != nil {
		t.Fatalf("read-only baseline should be valid before arming: %v", err)
	}
	for name, change := range map[string]func(*AdapterProbePreflight){
		"wrong key":          func(p *AdapterProbePreflight) { p.Info.Key = "CH0I" },
		"wrong value key":    func(p *AdapterProbePreflight) { p.Value.Key = "CH0I" },
		"wrong type":         func(p *AdapterProbePreflight) { p.Info.DataType = "ui8 " },
		"wrong value type":   func(p *AdapterProbePreflight) { p.Value.DataType = "ui8 " },
		"zero size":          func(p *AdapterProbePreflight) { p.Info.DataSize = 0 },
		"long value":         func(p *AdapterProbePreflight) { p.Value.Bytes = []byte{0, 0} },
		"unknown flags":      func(p *AdapterProbePreflight) { p.Value.Bytes[0] = 0x04 },
		"already disabled":   func(p *AdapterProbePreflight) { p.Value.Bytes[0] = 0x08 },
		"no physical AC":     func(p *AdapterProbePreflight) { p.PhysicalAC = false },
		"low reserve":        func(p *AdapterProbePreflight) { p.BatteryPercent = 20 },
		"rearm boundary":     func(p *AdapterProbePreflight) { p.BatteryPercent = 25 },
		"invalid percentage": func(p *AdapterProbePreflight) { p.BatteryPercent = math.NaN() },
		"native disabled":    func(p *AdapterProbePreflight) { p.NativeLimitEnabled = false },
		"native below 80":    func(p *AdapterProbePreflight) { p.NativeLimit = 79 },
		"no watchdog":        func(p *AdapterProbePreflight) { p.RestorationArmed = false },
	} {
		t.Run(name, func(t *testing.T) {
			p := baseline()
			change(&p)
			if err := ValidateAdapterProbe(p); err == nil {
				t.Fatal("unsafe baseline accepted")
			}
		})
	}
}
