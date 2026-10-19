package smc

import (
	"fmt"
	"math"

	"github.com/charlie0129/gosmc"
)

// AdapterProbePreflight describes the observations required before a supervised
// CHIE feasibility test. It does not issue a command or prove write permission.
type AdapterProbePreflight struct {
	Info               gosmc.KeyInfo
	Value              gosmc.Value
	PhysicalAC         bool
	BatteryPercent     float64
	NativeLimit        int
	NativeLimitEnabled bool
	RestorationArmed   bool
}

// ValidateAdapterProbeBaseline checks only read-only physical and SMC state.
// It does not authorize a cut before the independent recovery owner is armed.
func ValidateAdapterProbeBaseline(p AdapterProbePreflight) error {
	if p.Info.Key != AdapterKey3 || p.Value.Key != AdapterKey3 ||
		p.Info.DataType != gosmc.DataType("hex_") || p.Value.DataType != gosmc.DataType("hex_") ||
		p.Info.DataSize != 1 || len(p.Value.Bytes) != 1 {
		return fmt.Errorf("CHIE metadata or value is not the known one-byte hex format")
	}
	if p.Value.Bytes[0] != 0x00 {
		return fmt.Errorf("CHIE has unknown or already-disabled value %#02x", p.Value.Bytes[0])
	}
	if !p.PhysicalAC {
		return fmt.Errorf("physical adapter power is not confirmed")
	}
	if math.IsNaN(p.BatteryPercent) || math.IsInf(p.BatteryPercent, 0) ||
		p.BatteryPercent <= 25 || p.BatteryPercent > 100 {
		return fmt.Errorf("battery reserve is unavailable or at most 25%%")
	}
	if !p.NativeLimitEnabled || p.NativeLimit < 80 || p.NativeLimit > 100 {
		return fmt.Errorf("native charge limit baseline is not confirmed")
	}
	return nil
}

// ValidateAdapterProbe also requires an acknowledged restoration owner. The
// caller must independently verify that owner remains alive immediately before
// writing; this pure check is not itself SMC write authorization.
func ValidateAdapterProbe(p AdapterProbePreflight) error {
	if err := ValidateAdapterProbeBaseline(p); err != nil {
		return err
	}
	if !p.RestorationArmed {
		return fmt.Errorf("independent restoration owner is not armed")
	}
	return nil
}
