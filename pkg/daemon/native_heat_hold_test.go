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
	active   bool
	saved    int
	holds    []int
	releases int
	failHold error
	failRel  error
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
		appleLimit: func() (int, error) { return 80, nil }}
	return h, holder, &s
}

func TestHeatHoldPausesAtCurrentPercentWhenHotOnAC(t *testing.T) {
	h, holder, _ := newHoldFixture(heatHoldSample{Temperature: 36, Percent: 72, PluggedIn: true})
	h.reconcile(true, 35, 32)
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
	// A limit change releases the hold, applies the limit, then re-holds
	// at once because the battery is still hot.
	w = httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest("PUT", "/limit", strings.NewReader("90")))
	writes := nativeCharge.(*nativeFixture).writes
	if w.Code != 201 || len(writes) != 1 || writes[0] != 90 || holder.releases != 1 || len(holder.holds) != 2 || !holder.active {
		t.Fatalf("limit write while held: %d writes=%v releases=%d holds=%v", w.Code, writes, holder.releases, holder.holds)
	}
	if w := put(`{"enabled":false}`); w.Code != 201 || holder.active || holder.releases != 2 {
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
