package daemon

import (
	"errors"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charlie0129/batt/pkg/chargehold"
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
	// At the displayed charge: never charge a hot battery up a percent.
	if len(holder.holds) != 1 || holder.holds[0] != 72 {
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
	if len(holder.holds) != 1 || holder.holds[0] != 72 {
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
	if len(holder.holds) != 1 || len(holder.retargets) != 1 || holder.retargets[0] != 60 || !getHeatProtectionStatusUnchecked().Paused {
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
	if len(holder.holds) != 1 || holder.holds[0] != 13 {
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
	s.Percent, s.BatteryAmps = 17, 2.0
	h.reconcile(true, 35, 32)
	if len(holder.holds) != 1 {
		t.Fatalf("re-held while latched: %v", holder.holds)
	}
	s.Percent = 20
	h.reconcile(true, 35, 32)
	if len(holder.holds) != 2 || holder.holds[1] != 20 {
		t.Fatalf("not re-armed at 20%%: %v", holder.holds)
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

func newModesFixture(sample heatHoldSample, apple int) (*nativeHeatHold, *holderFixture, *heatHoldSample) {
	h, holder, s := newHoldFixture(sample)
	h.appleLimit = func() (int, error) { return apple, nil }
	return h, holder, s
}

func TestSailingHoldsUntilTheChargeFallsBelowTheBand(t *testing.T) {
	h, holder, s := newModesFixture(heatHoldSample{Temperature: 25, Percent: 80, PluggedIn: true}, 80)
	h.sailingLevel = func() int { return 5 }
	h.reconcile(false, 35, 32)
	if len(holder.holds) != 0 {
		t.Fatalf("held at the limit: %v", holder.holds)
	}
	// Drifts below the limit on AC: hold where it is instead of topping up.
	s.Percent = 79
	h.reconcile(false, 35, 32)
	if len(holder.holds) != 1 || holder.holds[0] != 79 || !getHeatProtectionStatusUnchecked().Sailing {
		t.Fatalf("sail hold: %v", holder.holds)
	}
	h.reconcile(false, 35, 32)
	if len(holder.holds) != 1 || len(holder.retargets) != 0 {
		t.Fatal("re-held while sailing steadily")
	}
	// Drains on battery, replugged inside the band: follow it down once.
	s.Percent, s.PluggedIn = 77, true
	h.reconcile(false, 35, 32)
	if len(holder.retargets) != 1 || holder.retargets[0] != 77 {
		t.Fatalf("band retarget: %v", holder.retargets)
	}
	// Falls to limit − sailing: release so macOS charges back to the limit.
	s.Percent = 75
	h.reconcile(false, 35, 32)
	if holder.releases != 1 || holder.active || getHeatProtectionStatusUnchecked().Sailing {
		t.Fatalf("not released at the band floor: releases=%d", holder.releases)
	}
	// Charging back up through the band does not sail until the limit again.
	s.Percent = 78
	h.reconcile(false, 35, 32)
	if len(holder.holds) != 1 {
		t.Fatalf("sailed before reaching the limit: %v", holder.holds)
	}
}

func TestSailingWithCustomLimitRetargetsToTheLimit(t *testing.T) {
	h, holder, s := newModesFixture(heatHoldSample{Temperature: 25, Percent: 70, PluggedIn: true}, 80)
	h.customLimit = func() int { return 70 }
	h.sailingLevel = func() int { return 10 }
	h.reconcile(false, 35, 32)
	if len(holder.holds) != 1 || holder.holds[0] != 70 {
		t.Fatalf("limit hold: %v", holder.holds)
	}
	s.Percent = 65
	h.reconcile(false, 35, 32)
	if len(holder.retargets) != 1 || holder.retargets[0] != 65 {
		t.Fatalf("sailing inside the band: %v", holder.retargets)
	}
	s.Percent = 60
	h.reconcile(false, 35, 32)
	if len(holder.retargets) != 2 || holder.retargets[1] != 70 {
		t.Fatalf("back to charging toward the limit: %v", holder.retargets)
	}
}

func TestTopUpSuspendsLimitsAndEndsOnUnplug(t *testing.T) {
	h, holder, s := newModesFixture(heatHoldSample{Temperature: 25, Percent: 70, PluggedIn: true}, 80)
	topUp, restore := true, 85
	h.customLimit = func() int { return 60 }
	h.sailingLevel = func() int { return 5 }
	h.topUpState = func() (bool, int) { return topUp, restore }
	h.clearTopUp = func() { topUp = false }
	var applied []int
	h.setLimit = func(limit int) error { applied = append(applied, limit); return nil }
	h.reconcile(false, 35, 32)
	if len(holder.holds) != 0 || !getHeatProtectionStatusUnchecked().TopUp {
		t.Fatalf("limit hold during Top Up: %v", holder.holds)
	}
	s.PluggedIn = false
	h.reconcile(false, 35, 32)
	if topUp || len(applied) != 1 || applied[0] != 85 || getHeatProtectionStatusUnchecked().TopUp {
		t.Fatalf("Top Up not ended on unplug: topUp=%v applied=%v", topUp, applied)
	}
}

func TestTopUpAPIStartsAndManualLimitEndsIt(t *testing.T) {
	_, _ = setupHeatHoldAPI(t)
	capabilities.SupportedLimits = append(append([]int{}, customChargeLimits...), 80, 85, 90, 95, 100)
	heatHold.customLimit = func() int { return conf.CustomChargeLimit() }
	heatHold.topUpState = func() (bool, int) { return conf.TopUpActive(), conf.TopUpRestoreLimit() }
	heatHold.clearTopUp = func() { conf.SetTopUp(false, 0) }
	var applied []int
	heatHold.setLimit = func(limit int) error { applied = append(applied, limit); return nil }
	router := setupRoutes()
	put := func(path, body string) int {
		w := httptest.NewRecorder()
		router.ServeHTTP(w, httptest.NewRequest("PUT", path, strings.NewReader(body)))
		return w.Code
	}
	if code := put("/top-up", "true"); code != 201 || !conf.TopUpActive() || conf.TopUpRestoreLimit() != 80 || len(applied) != 1 || applied[0] != 100 {
		t.Fatalf("start: %d active=%v restore=%d applied=%v", code, conf.TopUpActive(), conf.TopUpRestoreLimit(), applied)
	}
	if code := put("/limit", "90"); code != 201 || conf.TopUpActive() {
		t.Fatalf("manual limit kept Top Up: %d", code)
	}
	if code := put("/sailing", "25"); code != 400 {
		t.Fatalf("sailing 25 accepted: %d", code)
	}
	if code := put("/sailing", "10"); code != 201 || conf.SailingLevel() != 10 {
		t.Fatalf("sailing: %d level=%d", code, conf.SailingLevel())
	}
}

func TestDischargeDrainsToTheLimitThenHolds(t *testing.T) {
	h, holder, s := newModesFixture(heatHoldSample{Temperature: 40, Percent: 76, PluggedIn: true}, 80)
	discharging := true
	h.customLimit = func() int { return 70 }
	h.discharge = func() bool { return discharging }
	h.endDischarge = func() { discharging = false }
	h.reconcile(true, 35, 32)
	// Heat is moot while draining: the hold targets the limit, below the charge.
	if len(holder.holds) != 1 || holder.holds[0] != 70 || !getHeatProtectionStatusUnchecked().Discharging {
		t.Fatalf("discharge hold: %v", holder.holds)
	}
	s.Percent = 73
	h.reconcile(true, 35, 32)
	if len(holder.retargets) != 0 {
		t.Fatalf("retargeted mid-discharge: %v", holder.retargets)
	}
	// Reaching the limit ends discharge without another pulse; heat resumes
	// next pass with the hold already at the limit.
	s.Percent = 70
	h.reconcile(true, 35, 32)
	if discharging || getHeatProtectionStatusUnchecked().Discharging {
		t.Fatal("discharge not finished at the limit")
	}
}

func TestDischargeEndsWhenUnplugged(t *testing.T) {
	h, holder, s := newModesFixture(heatHoldSample{Temperature: 25, Percent: 76, PluggedIn: true}, 80)
	discharging := true
	h.customLimit = func() int { return 70 }
	h.discharge = func() bool { return discharging }
	h.endDischarge = func() { discharging = false }
	h.reconcile(false, 35, 32)
	s.PluggedIn = false
	h.reconcile(false, 35, 32)
	if discharging {
		t.Fatal("discharge continued on battery")
	}
	_ = holder
}

// The pulse that sets a hold switches the adapter input off for a moment;
// that reading must not end Discharge or Top Up as if the cable were pulled.
func TestPulseBlipDoesNotEndDischarge(t *testing.T) {
	h, holder, s := newModesFixture(heatHoldSample{Temperature: 25, Percent: 76, PluggedIn: true}, 80)
	h.pulseSettle = time.Minute
	discharging := true
	h.customLimit = func() int { return 70 }
	h.discharge = func() bool { return discharging }
	h.endDischarge = func() { discharging = false }
	h.reconcile(false, 35, 32)
	s.PluggedIn = false
	h.reconcile(false, 35, 32)
	if !discharging || len(holder.holds) != 1 || holder.holds[0] != 70 {
		t.Fatalf("discharging=%v holds=%v", discharging, holder.holds)
	}
	h.lastTransition = time.Now().Add(-2 * time.Minute)
	h.reconcile(false, 35, 32)
	if discharging {
		t.Fatal("discharge continued after a real unplug")
	}
}

// On battery a hold changes nothing, and a battery draining there says
// nothing about the adapter, so neither starts a heat pause nor the reserve.
func TestHeatWaitsForAdapterAndReserveIgnoresBatteryDrain(t *testing.T) {
	h, holder, s := newHoldFixture(heatHoldSample{Temperature: 30, Percent: 40, PluggedIn: true})
	h.customLimit = func() int { return 75 }
	h.reconcile(true, 33, 30)
	if len(holder.holds) != 1 || holder.holds[0] != 75 {
		t.Fatalf("limit hold: %v", holder.holds)
	}
	s.PluggedIn, s.Temperature, s.Percent, s.BatteryAmps = false, 34, 26, -1.5
	h.reconcile(true, 33, 30)
	s.Percent = 24
	h.reconcile(true, 33, 30)
	status := getHeatProtectionStatusUnchecked()
	if len(holder.retargets) != 0 || status.ReserveBlocked || h.reserveLatched {
		t.Fatalf("on battery: retargets=%v status=%+v", holder.retargets, status)
	}
	// Back on AC and still hot: pause at the charge.
	s.PluggedIn, s.BatteryAmps = true, 0
	h.reconcile(true, 33, 30)
	if len(holder.retargets) != 1 || holder.retargets[0] != 24 {
		t.Fatalf("no pause on AC: %v", holder.retargets)
	}
}

// A pulse that lands during a charger drop-out is retried, never a fault:
// a fault would leave a hot battery charging until re-enabled by hand.
func TestChargerDropOutDefersHoldWithoutFault(t *testing.T) {
	h, holder, _ := newHoldFixture(heatHoldSample{Temperature: 38, Percent: 19, PluggedIn: true})
	holder.failHold = chargehold.ErrAdapterBusy
	h.reconcile(true, 33, 30)
	if status := getHeatProtectionStatusUnchecked(); h.fault != "" || status.Fault || status.Reason != "charger reconnecting" {
		t.Fatalf("fault=%q status=%+v", h.fault, status)
	}
	holder.failHold = nil
	h.reconcile(true, 33, 30)
	if len(holder.holds) != 2 || !holder.active || holder.holds[1] != 19 {
		t.Fatalf("not retried: %v", holder.holds)
	}
}
