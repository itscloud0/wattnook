package compatibility

import "testing"

func TestAdapterInhibitionIsNotChargeOnlyHeatProtection(t *testing.T) {
	for _, adapter := range []bool{false, true} {
		c := Capabilities{ChargingControl: true, ChargeControlMode: ChargeControlNative, ThermalAdapter: adapter}
		if c.Supports(FeatureHeatProtection) {
			t.Fatalf("native adapter=%v advertised charge-only heat protection", adapter)
		}
	}
	if !Permissive().Supports(FeatureHeatProtection) {
		t.Fatal("legacy charge-only heat protection was removed")
	}
	for _, mode := range []ChargeControlMode{ChargeControlFirmware, ChargeControlUnsupported, ""} {
		if (Capabilities{ChargingControl: true, ChargeControlMode: mode}).Supports(FeatureHeatProtection) {
			t.Fatalf("%s advertises a thermal gate it does not execute", mode)
		}
	}
}
