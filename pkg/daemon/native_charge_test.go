package daemon

import (
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/charlie0129/batt/pkg/compatibility"
	"github.com/charlie0129/batt/pkg/powerui"
	"github.com/charlie0129/batt/pkg/smc"
)

type nativeFixture struct {
	state  powerui.State
	err    error
	writes []int
}

func (f *nativeFixture) Read() (powerui.State, error) { return f.state, f.err }
func (f *nativeFixture) SetLimit(v int) error {
	f.writes = append(f.writes, v)
	f.state.Limit = v
	return f.err
}

func setupNativeFixture(t *testing.T) *nativeFixture {
	t.Helper()
	oldSMC, oldConf, oldCaps, oldNative := smcConn, conf, capabilities, nativeCharge
	t.Cleanup(func() { smcConn, conf, capabilities, nativeCharge = oldSMC, oldConf, oldCaps, oldNative })
	// No SMC connection: any accidental SMC access fails the test immediately.
	smcConn = nil
	conf = &mockConf{upper: 60, lower: 58, heatProtection: true, disableUntil: time.Now().Add(-time.Hour), preDisableLimit: 70}
	f := &nativeFixture{state: powerui.State{Limit: 80, Enabled: true, Limits: []int{80, 85, 90, 95, 100}}}
	nativeCharge = f
	capabilities = compatibility.Capabilities{ChargingControl: true, ChargeControlMode: compatibility.ChargeControlNative, SupportedLimits: []int{80, 85, 90, 95, 100}}
	return f
}

func TestNativeLimitAPIUsesSystemNotSavedConfig(t *testing.T) {
	f := setupNativeFixture(t)
	r := setupRoutes()
	for _, want := range []string{"80", "90"} {
		if want == "90" {
			f.state.Limit = 90
		}
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest("GET", "/limit", nil))
		if w.Code != 200 || strings.TrimSpace(w.Body.String()) != want {
			t.Fatalf("%d %s", w.Code, w.Body.String())
		}
	}
	f.err = errors.New("read unavailable")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest("GET", "/limit", nil))
	if w.Code != 503 {
		t.Fatalf("failed read showed stale config: %d %s", w.Code, w.Body.String())
	}
	if conf.UpperLimit() != 60 || len(f.writes) != 0 {
		t.Fatal("passive read changed state")
	}
}

func TestNativeMutationsGatedAndLimitValidated(t *testing.T) {
	f := setupNativeFixture(t)
	r := setupRoutes()
	for _, tc := range []struct {
		path, body string
		code       int
	}{
		{"/limit", "70", 400}, {"/limit", "85", 201},
		{"/heat-protection", `{"enabled":true}`, 409},
		{"/disable", `"1h"`, 409}, {"/lower-limit-delta", "2", 409},
		{"/adapter", "false", 409}, {"/adapter/disable", `"1h"`, 409},
	} {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest("PUT", tc.path, strings.NewReader(tc.body)))
		if w.Code != tc.code {
			t.Fatalf("%s: %d %s", tc.path, w.Code, w.Body.String())
		}
	}
	if len(f.writes) != 1 || f.writes[0] != 85 || conf.UpperLimit() != 60 {
		t.Fatal("incorrect native writes or persisted historical limit", f.writes)
	}
}

func TestNativeLifecycleNeverTouchesSMCOrSavedLimit(t *testing.T) {
	f := setupNativeFixture(t)
	// Expired legacy timer must be inactive, not applied to the system backend.
	if restoreDisabledLimit(conf, time.Now()) {
		t.Fatal("legacy timer restored in native mode")
	}
	maintainLoopForced()
	resetChargeControlOnShutdown()
	if len(f.writes) != 0 || conf.UpperLimit() != 60 {
		t.Fatal("lifecycle changed charge limit")
	}
	status := getHeatProtectionStatus()
	if status.Enabled || status.Paused || status.LastError == "" {
		t.Fatalf("unavailable heat shown as working: %+v", status)
	}
}

func TestNativeDetectionDoesNotOverrideSMC(t *testing.T) {
	f := setupNativeFixture(t)
	smcConn = smc.NewMockValues()
	if err := smcConn.Open(); err != nil {
		t.Fatal(err)
	}
	defer smcConn.Close()
	got := detectCapabilities()
	if got.ChargeControlMode != compatibility.ChargeControlNative || !got.ChargingControl || got.AdapterControl || got.Calibration || got.Supports(compatibility.FeatureHeatProtection) {
		t.Fatalf("bad native capabilities: %+v", got)
	}
	f.err = errors.New("unavailable")
	got = detectCapabilities()
	if got.ChargingControl {
		t.Fatal("failed native probe advertised control")
	}
}
