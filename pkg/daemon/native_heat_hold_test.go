package daemon

import (
	"errors"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charlie0129/batt/pkg/config"
)

type holderFixture struct {
	active    bool
	saved     int
	holds     []int
	releases  int
	retargets []int
	failHold  error
	failRel   error
}

func (h *holderFixture) Active() bool            { return h.active }
func (h *holderFixture) SavedLimit() (int, bool) { return h.saved, h.active }
func (h *holderFixture) Hold(target int) error {
	h.holds = append(h.holds, target)
	if h.failHold != nil {
		return h.failHold
	}
	h.active, h.saved = true, 80
	return nil
}
func (h *holderFixture) Retarget(target int) error {
	h.retargets = append(h.retargets, target)
	return nil
}
func (h *holderFixture) Release() error {
	h.releases++
	if h.failRel != nil {
		return h.failRel
	}
	h.active = false
	return nil
}

func newHoldFixture(sample heatHoldSample) (*nativeHeatHold, *holderFixture, *heatHoldSample) {
	holder := &holderFixture{}
	s := sample
	h := &nativeHeatHold{holder: holder,
		sample:     func() (heatHoldSample, error) { return s, nil },
		appleLimit: func() (int, error) { return 80, nil },
		setLimit:   func(int) error { return nil }}
	return h, holder, &s
}

func TestHeatHoldPausesAtCurrentPercentWhenHotOnAC(t *testing.T) {
	h, holder, _ := newHoldFixture(heatHoldSample{Temperature: 36, Percent: 72, PluggedIn: true})
	h.reconcile(true, 35, 32)
	// One point above the rounded-down charge, so the hold never drains.
	if len(holder.holds) != 1 || holder.holds[0] != 73 {
		t.Fatalf("holds=%v", holder.holds)
	}
	status := getHeatProtectionStatusUnchecked()
	if !status.Paused || status.Mechanism != "charge-hold" || status.Observed != "held" || status.Fault {
		t.Fatalf("%+v", status)
	}
	h.reconcile(true, 35, 32)
	if len(holder.holds) != 1 {
		t.Fatal("hold repeated while active")
	}
}

func TestHeatHoldSkipsWhenNotNeeded(t *testing.T) {
	for name, s := range map[string]heatHoldSample{
		"cool":           {Temperature: 34.9, Percent: 72, PluggedIn: true},
		"on battery":     {Temperature: 40, Percent: 72},
		"at Apple limit": {Temperature: 40, Percent: 80, PluggedIn: true},
		"too low":        {Temperature: 40, Percent: 3, PluggedIn: true},
	} {
		h, holder, _ := newHoldFixture(s)
		h.reconcile(true, 35, 32)
		if len(holder.holds) != 0 || getHeatProtectionStatusUnchecked().Paused {
			t.Fatalf("%s: holds=%v", name, holder.holds)
		}
	}
}

func TestHeatHoldHysteresisReleasesOnlyWhenCool(t *testing.T) {
	h, holder, s := newHoldFixture(heatHoldSample{Temperature: 36, Percent: 72, PluggedIn: true})
	h.reconcile(true, 35, 32)
	for _, temperature := range []float64{34, 32.1} {
		s.Temperature = temperature
		h.reconcile(true, 35, 32)
		if holder.releases != 0 {
			t.Fatalf("released at %.1f", temperature)
		}
	}
	// Unplugging keeps the hold; it is harmless on battery and avoids flapping.
	s.PluggedIn = false
	h.reconcile(true, 35, 32)
	if holder.releases != 0 {
		t.Fatal("released on unplug")
	}
	s.Temperature = 32
	h.reconcile(true, 35, 32)
	if holder.releases != 1 || holder.active || getHeatProtectionStatusUnchecked().Paused {
		t.Fatalf("releases=%d", holder.releases)
	}
}

func TestHeatHoldSensorErrorNeitherHoldsNorReleases(t *testing.T) {
	h, holder, _ := newHoldFixture(heatHoldSample{})
	h.sample = func() (heatHoldSample, error) { return heatHoldSample{}, errors.New("sensor gone") }
	h.reconcile(true, 35, 32)
	holder.active = true
	h.reconcile(true, 35, 32)
	status := getHeatProtectionStatusUnchecked()
	if len(holder.holds) != 0 || holder.releases != 0 || status.LastError != "sensor gone" || status.Fault {
		t.Fatalf("holds=%v releases=%d %+v", holder.holds, holder.releases, status)
	}
}

func TestHeatHoldFaultStopsRetriesUntilReset(t *testing.T) {
	h, holder, _ := newHoldFixture(heatHoldSample{Temperature: 40, Percent: 72, PluggedIn: true})
	holder.failHold = errors.New("pulse failed")
	h.reconcile(true, 35, 32)
	h.reconcile(true, 35, 32)
	if len(holder.holds) != 1 || !getHeatProtectionStatusUnchecked().Fault {
		t.Fatalf("holds=%v", holder.holds)
	}
	holder.failHold = nil
	h.reset()
	h.reconcile(true, 35, 32)
	if len(holder.holds) != 2 || !holder.active {
		t.Fatalf("holds=%v", holder.holds)
	}
}

func TestHeatHoldDisableReleasesAndClearsFault(t *testing.T) {
	h, holder, _ := newHoldFixture(heatHoldSample{Temperature: 40, Percent: 72, PluggedIn: true})
	h.reconcile(true, 35, 32)
	h.fault = "old fault"
	h.reconcile(false, 35, 32)
	status := getHeatProtectionStatusUnchecked()
	if holder.releases != 1 || holder.active || status.Enabled || status.Paused || status.Fault || h.fault != "" {
		t.Fatalf("releases=%d %+v", holder.releases, status)
	}
}

func TestHeatHoldAppleLimitErrorDoesNotHold(t *testing.T) {
	h, holder, _ := newHoldFixture(heatHoldSample{Temperature: 40, Percent: 72, PluggedIn: true})
	h.appleLimit = func() (int, error) { return 0, errors.New("powerui busy") }
	h.reconcile(true, 35, 32)
	if len(holder.holds) != 0 || getHeatProtectionStatusUnchecked().LastError != "powerui busy" {
		t.Fatal("held without a known Apple limit")
	}
}

func setupHeatHoldAPI(t *testing.T) (*holderFixture, *heatHoldSample) {
	t.Helper()
	setupNativeFixture(t)
	oldHold, oldThermal := heatHold, nativeThermal
	t.Cleanup(func() { heatHold, nativeThermal = oldHold, oldThermal })
	nativeThermal = nil
	f, err := config.NewFile(filepath.Join(t.TempDir(), "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	conf = f
	capabilities.ChargeHold = true
	h, holder, s := newHoldFixture(heatHoldSample{Temperature: 30, Percent: 72, PluggedIn: true})
	heatHold = h
	return holder, s
}

func TestNativeHeatProtectionAPIEnablesChargeHold(t *testing.T) {
	holder, s := setupHeatHoldAPI(t)
	router := setupRoutes()
	put := func(body string) *httptest.ResponseRecorder {
		w := httptest.NewRecorder()
		router.ServeHTTP(w, httptest.NewRequest("PUT", "/heat-protection", strings.NewReader(body)))
		return w
	}
	for _, body := range []string{
		`{"enabled":true,"adapterMode":true,"pauseTemperatureCelsius":35,"resumeTemperatureCelsius":32}`,
		`{"enabled":true,"pauseTemperatureCelsius":35,"resumeTemperatureCelsius":36}`,
	} {
		if w := put(body); w.Code < 400 || conf.HeatProtectionEnabled() {
			t.Fatalf("accepted %s: %d", body, w.Code)
		}
	}
	if w := put(`{"enabled":true,"pauseTemperatureCelsius":35,"resumeTemperatureCelsius":32}`); w.Code != 201 {
		t.Fatalf("%d %s", w.Code, w.Body.String())
	}
	if !conf.HeatProtectionEnabled() || conf.HeatPauseTemperatureCelsius() != 35 || conf.ThermalAdapterEnabled() {
		t.Fatal("config not saved")
	}
	s.Temperature = 36
	maintainLoopForced()
	if len(holder.holds) != 1 || holder.holds[0] != 73 {
		t.Fatalf("loop did not hold: %v", holder.holds)
	}
	// While held, /limit reports the saved Apple limit.
	w := httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest("GET", "/limit", nil))
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != "80" {
		t.Fatalf("limit while held: %d %s", w.Code, w.Body.String())
	}
	// A limit change while held is kept pending: no release, no adapter
	// pulse, no Apple write until the hold ends.
	for _, limit := range []string{"85", "90"} {
		w = httptest.NewRecorder()
		router.ServeHTTP(w, httptest.NewRequest("PUT", "/limit", strings.NewReader(limit)))
		if w.Code != 201 {
			t.Fatalf("limit write while held: %d %s", w.Code, w.Body.String())
		}
	}
	if holder.releases != 0 || len(holder.holds) != 1 || len(nativeCharge.(*nativeFixture).writes) != 0 {
		t.Fatalf("pending limit touched hardware: releases=%d holds=%v", holder.releases, holder.holds)
	}
	w = httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest("GET", "/limit", nil))
	if strings.TrimSpace(w.Body.String()) != "90" {
		t.Fatalf("pending limit not reported: %s", w.Body.String())
	}
	var applied []int
	heatHold.setLimit = func(limit int) error { applied = append(applied, limit); return nil }
	if w := put(`{"enabled":false}`); w.Code != 201 || holder.active || holder.releases != 1 || len(applied) != 1 || applied[0] != 90 {
		t.Fatalf("off: %d active=%v", w.Code, holder.active)
	}
}

func TestShutdownReleasesChargeHold(t *testing.T) {
	holder, _ := setupHeatHoldAPI(t)
	holder.active = true
	resetChargeControlOnShutdown()
	if holder.active || holder.releases != 1 {
		t.Fatal("shutdown left charging paused")
	}
}

// getHeatProtectionStatusUnchecked reads the published status regardless of
// the capability gate, for controller-level tests.
func getHeatProtectionStatusUnchecked() HeatProtectionStatus {
	heatProtectionMu.RLock()
	defer heatProtectionMu.RUnlock()
	return heatProtectionStatus
}

func TestCustomLimitHoldsAtLimitOrCurrentCharge(t *testing.T) {
	for name, tc := range map[string]struct{ percent, want int }{
		"charges up to the limit": {60, 70},
		"never discharges on AC":  {76, 76},
	} {
		h, holder, _ := newHoldFixture(heatHoldSample{Temperature: 25, Percent: tc.percent, PluggedIn: true})
		h.customLimit = func() int { return 70 }
		h.reconcile(false, 35, 32)
		if len(holder.holds) != 1 || holder.holds[0] != tc.want {
			t.Fatalf("%s: holds=%v", name, holder.holds)
		}
		h.reconcile(false, 35, 32)
		if len(holder.holds) != 1 || len(holder.retargets) != 0 {
			t.Fatalf("%s: re-held without a reason change", name)
		}
	}
}

func TestCustomLimitWaitsForAdapter(t *testing.T) {
	h, holder, _ := newHoldFixture(heatHoldSample{Temperature: 25, Percent: 60})
	h.customLimit = func() int { return 70 }
	h.reconcile(false, 35, 32)
	if len(holder.holds) != 0 {
		t.Fatal("held on battery")
	}
}

func TestHeatAndCustomLimitShareOneHold(t *testing.T) {
	h, holder, s := newHoldFixture(heatHoldSample{Temperature: 25, Percent: 60, PluggedIn: true})
	limit := 70
	h.customLimit = func() int { return limit }
	h.reconcile(true, 35, 32)
	if len(holder.holds) != 1 || holder.holds[0] != 70 {
		t.Fatalf("limit hold: %v", holder.holds)
	}
	// Heat pauses at the current charge: one retarget, still one snapshot.
	s.Temperature = 36
	h.reconcile(true, 35, 32)
	if len(holder.holds) != 1 || len(holder.retargets) != 1 || holder.retargets[0] != 61 || !getHeatProtectionStatusUnchecked().Paused {
		t.Fatalf("heat retarget: holds=%v retargets=%v", holder.holds, holder.retargets)
	}
	// Cooling returns to the limit without releasing.
	s.Temperature = 30
	h.reconcile(true, 35, 32)
	if holder.releases != 0 || len(holder.retargets) != 2 || holder.retargets[1] != 70 || getHeatProtectionStatusUnchecked().Paused {
		t.Fatalf("cool retarget: retargets=%v releases=%d", holder.retargets, holder.releases)
	}
	// Clearing the limit with Heat Protection idle releases the hold.
	limit = 0
	h.reconcile(true, 35, 32)
	if holder.releases != 1 || holder.active {
		t.Fatalf("release: %d", holder.releases)
	}
}

func TestNativeCustomLimitAPI(t *testing.T) {
	holder, _ := setupHeatHoldAPI(t)
	capabilities.SupportedLimits = append(append([]int{}, customChargeLimits...), 80, 85, 90, 95, 100)
	heatHold.customLimit = func() int { return conf.CustomChargeLimit() }
	router := setupRoutes()
	put := func(limit string) int {
		w := httptest.NewRecorder()
		router.ServeHTTP(w, httptest.NewRequest("PUT", "/limit", strings.NewReader(limit)))
		return w.Code
	}
	if code := put("65"); code != 201 || conf.CustomChargeLimit() != 65 || len(holder.holds) != 1 || holder.holds[0] != 72 {
		t.Fatalf("custom: %d limit=%d holds=%v", code, conf.CustomChargeLimit(), holder.holds)
	}
	w := httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest("GET", "/limit", nil))
	if strings.TrimSpace(w.Body.String()) != "65" {
		t.Fatalf("GET /limit %s", w.Body.String())
	}
	if code := put("67"); code != 400 {
		t.Fatalf("unsupported value accepted: %d", code)
	}
	var applied []int
	heatHold.setLimit = func(limit int) error { applied = append(applied, limit); return nil }
	if code := put("90"); code != 201 || conf.CustomChargeLimit() != 0 || holder.active || len(applied) != 1 || applied[0] != 90 {
		t.Fatalf("back to Apple: %d custom=%d active=%v applied=%v", code, conf.CustomChargeLimit(), holder.active, applied)
	}
}

func TestCustomLimitHoldFollowsChargeDownOnlyOnAC(t *testing.T) {
	h, holder, s := newHoldFixture(heatHoldSample{Temperature: 25, Percent: 81, PluggedIn: true})
	h.customLimit = func() int { return 70 }
	h.reconcile(false, 35, 32)
	if len(holder.holds) != 1 || holder.holds[0] != 81 {
		t.Fatalf("parked hold: %v", holder.holds)
	}
	// Draining on battery never pulses the adapter.
	s.PluggedIn = false
	for _, percent := range []int{79, 74, 65} {
		s.Percent = percent
		h.reconcile(false, 35, 32)
	}
	if len(holder.retargets) != 0 {
		t.Fatalf("retargeted on battery: %v", holder.retargets)
	}
	// Back on AC at 65%: the target drops to the limit, not back to 81.
	s.PluggedIn = true
	h.reconcile(false, 35, 32)
	if len(holder.retargets) != 1 || holder.retargets[0] != 70 {
		t.Fatalf("replug retarget: %v", holder.retargets)
	}
	h.reconcile(false, 35, 32)
	if len(holder.retargets) != 1 {
		t.Fatalf("retargeted again at the limit: %v", holder.retargets)
	}
	// Above-limit replug: parks at the new, lower charge.
	h2, holder2, s2 := newHoldFixture(heatHoldSample{Temperature: 25, Percent: 81, PluggedIn: true})
	h2.customLimit = func() int { return 70 }
	h2.reconcile(false, 35, 32)
	s2.Percent = 76
	h2.reconcile(false, 35, 32)
	if len(holder2.retargets) != 1 || holder2.retargets[0] != 76 {
		t.Fatalf("partial drain: %v", holder2.retargets)
	}
}

func TestHeatHoldPausesLowChargeButNotADrainingOne(t *testing.T) {
	// A capable adapter: hold even at a low charge.
	h, holder, s := newHoldFixture(heatHoldSample{Temperature: 40, Percent: 13, PluggedIn: true})
	h.reconcile(true, 35, 32)
	if len(holder.holds) != 1 || holder.holds[0] != 14 {
		t.Fatalf("low but steady charge not held: %v", holder.holds)
	}
	// Held and steady at 13%: keep holding.
	h.reconcile(true, 35, 32)
	if holder.releases != 0 {
		t.Fatal("released a steady hold")
	}
	// The adapter stops covering the load: the held battery drains below the
	// reserve, so the hold ends and charging may resume.
	s.Percent, s.BatteryAmps = 12, -1.2
	h.reconcile(true, 35, 32)
	if holder.releases != 1 || holder.active || !getHeatProtectionStatusUnchecked().ReserveBlocked {
		t.Fatalf("draining hold kept: releases=%d", holder.releases)
	}
	// No re-hold while latched, even with the drain gone.
	s.Percent, s.BatteryAmps = 20, 2.0
	h.reconcile(true, 35, 32)
	if len(holder.holds) != 1 {
		t.Fatalf("re-held while latched: %v", holder.holds)
	}
	s.Percent = 30
	h.reconcile(true, 35, 32)
	if len(holder.holds) != 2 || holder.holds[1] != 31 {
		t.Fatalf("not re-armed at 30%%: %v", holder.holds)
	}
	// Never start below the minimum.
	h2, holder2, _ := newHoldFixture(heatHoldSample{Temperature: 40, Percent: 8, PluggedIn: true})
	h2.reconcile(true, 35, 32)
	if len(holder2.holds) != 0 {
		t.Fatalf("held below the minimum: %v", holder2.holds)
	}
}

func TestHeatTargetNeverExceedsCustomLimit(t *testing.T) {
	h, holder, _ := newHoldFixture(heatHoldSample{Temperature: 40, Percent: 70, PluggedIn: true})
	h.customLimit = func() int { return 70 }
	h.reconcile(true, 35, 32)
	if len(holder.holds) != 1 || holder.holds[0] != 70 {
		t.Fatalf("heat hold above the custom limit: %v", holder.holds)
	}
}
