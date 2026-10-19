package daemon

import (
	"errors"
	"math"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charlie0129/batt/pkg/config"
	"github.com/charlie0129/batt/pkg/thermalguard"
)

type thermalFixtureSession struct {
	held, recovered, closed bool
	holds, restores         int
	temperature, percent    float64
	failHold                bool
}

func (f *thermalFixtureSession) Exchange(command string) (thermalguard.Reply, error) {
	switch command {
	case "hold":
		f.holds++
		f.held = true
		if f.failHold {
			return thermalguard.Reply{}, errors.New("cut acknowledgement lost")
		}
	case "restore":
		if f.held {
			f.restores++
		}
		f.held = false
	case "reset":
		f.recovered = false
	}
	observed := "restored"
	if f.held {
		observed = "held"
	}
	return thermalguard.Reply{Observed: observed, Owned: f.held, Recovered: f.recovered,
		Sample: thermalguard.Sample{Percent: f.percent, Temperature: f.temperature, Connected: !f.held, Charging: !f.held, At: time.Now()}}, nil
}
func (f *thermalFixtureSession) Close() error { f.closed = true; f.held = false; return nil }

func setupThermalFixture(t *testing.T) (*thermalFixtureSession, *adapterThermalController) {
	t.Helper()
	setupNativeFixture(t)
	oldThermal := nativeThermal
	t.Cleanup(func() { nativeThermal = oldThermal })
	path := filepath.Join(t.TempDir(), "config.json")
	f, err := config.NewFile(path)
	if err != nil {
		t.Fatal(err)
	}
	conf = f
	capabilities.ThermalAdapter = true
	session := &thermalFixtureSession{temperature: 40, percent: 50}
	controller := &adapterThermalController{start: func(string) (thermalSession, error) { session.closed = false; return session, nil }, path: "fixture"}
	nativeThermal = controller
	return session, controller
}

func TestNativeHeatRejectsAdapterCutRequests(t *testing.T) {
	session, controller := setupThermalFixture(t)
	conf.SetHeatProtection(true, 35, 32) // Historical config alone cannot cut power.
	maintainLoopForced()
	if session.holds != 0 || nativeThermal.session != nil {
		t.Fatal("legacy preference activated adapter")
	}
	router := setupRoutes()
	for _, tc := range []struct {
		body string
		code int
	}{
		{`{"enabled":true,"pauseTemperatureCelsius":35,"resumeTemperatureCelsius":32}`, 409},
		{`{"enabled":true,"adapterMode":true,"pauseTemperatureCelsius":35,"resumeTemperatureCelsius":32}`, 409},
	} {
		w := httptest.NewRecorder()
		router.ServeHTTP(w, httptest.NewRequest("PUT", "/heat-protection", strings.NewReader(tc.body)))
		if w.Code != tc.code {
			t.Fatalf("%d %s", w.Code, w.Body.String())
		}
	}
	if conf.ThermalAdapterEnabled() || session.holds != 0 || controller.session != nil {
		t.Fatal("rejected request changed adapter state")
	}
	// Off remains available to restore a hold owned by a previous build.
	session.held = true
	controller.session = session
	conf.SetThermalAdapterEnabled(true)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest("PUT", "/heat-protection", strings.NewReader(`{"enabled":false}`)))
	if w.Code != 201 || session.restores != 1 || !session.closed || conf.ThermalAdapterEnabled() {
		t.Fatalf("disable: %d %s %+v", w.Code, w.Body.String(), session)
	}
	if len(nativeCharge.(*nativeFixture).writes) != 0 {
		t.Fatal("heat changed Apple charge limit")
	}
	if conf.HeatProtectionEnabled() || conf.HeatPauseTemperatureCelsius() != 35 || conf.HeatResumeTemperatureCelsius() != 32 {
		t.Fatal("Off did not preserve the saved thresholds")
	}
}

// Keep recovery/reserve/fault unit coverage for the retired adapter controller.
// Production-loop gating is covered separately below; these fixtures do not
// make adapter inhibition a supported Heat Protection implementation.
func reconcileAdapterFixture() {
	nativeThermal.reconcile(conf.ThermalAdapterEnabled() && conf.HeatProtectionEnabled(),
		conf.HeatPauseTemperatureCelsius(), conf.HeatResumeTemperatureCelsius())
}

func TestNativeHeatCannotCutFromSavedConfig(t *testing.T) {
	session, _ := setupThermalFixture(t)
	conf.SetHeatProtection(true, 33, 30)
	conf.SetThermalAdapterEnabled(true)
	for i := 0; i < 4; i++ {
		maintainLoopForced()
	}
	if session.holds != 0 || nativeThermal.session != nil {
		t.Fatal("unverified native heat mode disconnected adapter from a saved config")
	}
	if len(nativeCharge.(*nativeFixture).writes) != 0 {
		t.Fatal("blocking adapter cuts changed Apple's charge limit")
	}
}

func TestNativeHeatRestoresPreviouslyOwnedAdapterHold(t *testing.T) {
	session, controller := setupThermalFixture(t)
	session.held = true // A previous version owned a thermal adapter hold.
	controller.session = session
	conf.SetHeatProtection(true, 33, 30)
	conf.SetThermalAdapterEnabled(true)
	maintainLoopForced()
	if session.holds != 0 || session.held || !session.closed || session.restores != 1 {
		t.Fatalf("previous adapter hold was not safely retired: %+v", session)
	}
	maintainLoopForced()
	if session.holds != 0 || session.restores != 1 {
		t.Fatal("retired adapter mode restarted or repeated restoration")
	}
}

func TestThermalAdapterReserveAndSleepRecovery(t *testing.T) {
	session, controller := setupThermalFixture(t)
	conf.SetHeatProtection(true, 35, 32)
	conf.SetThermalAdapterEnabled(true)
	reconcileAdapterFixture()
	session.percent = 20
	reconcileAdapterFixture()
	if session.held || session.restores != 1 || !getHeatProtectionStatus().ReserveBlocked {
		t.Fatal("low reserve did not restore AC")
	}
	controller.state.LastTransition = time.Time{}
	session.percent = 26
	reconcileAdapterFixture()
	if !session.held {
		t.Fatal("did not rearm after reserve recovered")
	}
	setThermalSleeping(true)
	if session.held || !session.closed {
		t.Fatal("sleep left adapter cut")
	}
	holds := session.holds
	reconcileAdapterFixture()
	if session.holds != holds || controller.session != nil {
		t.Fatal("sleep restarted thermal owner")
	}
	setThermalSleeping(false)
	reconcileAdapterFixture()
	if session.holds != holds {
		t.Fatal("wake bypassed cooldown")
	}
}

func TestThermalAdapterFaultDoesNotRetryCuts(t *testing.T) {
	session, _ := setupThermalFixture(t)
	session.failHold = true
	conf.SetHeatProtection(true, 35, 32)
	conf.SetThermalAdapterEnabled(true)
	reconcileAdapterFixture()
	for i := 0; i < 4; i++ {
		reconcileAdapterFixture()
	}
	status := getHeatProtectionStatus()
	if session.holds != 1 || session.held || !status.Fault || status.Paused || status.LastError == "" {
		t.Fatalf("unsafe fault handling: %+v %+v", session, status)
	}
}

func TestThermalAdapterRestoredAfterCrashRequiresReenable(t *testing.T) {
	session, _ := setupThermalFixture(t)
	session.recovered = true
	conf.SetHeatProtection(true, 35, 32)
	conf.SetThermalAdapterEnabled(true)
	reconcileAdapterFixture()
	if session.holds != 0 || !getHeatProtectionStatus().Fault {
		t.Fatal("crash recovery automatically started a new cut")
	}
}

func TestThermalAdapterSensorFaultRestoresImmediately(t *testing.T) {
	session, controller := setupThermalFixture(t)
	conf.SetHeatProtection(true, 35, 32)
	conf.SetThermalAdapterEnabled(true)
	reconcileAdapterFixture()
	session.temperature = math.NaN()
	reconcileAdapterFixture()
	if session.held || controller.session != nil || !controller.state.Fault {
		t.Fatal("sensor fault left adapter supervision active")
	}
}

func TestThermalAdapterInitialLowReserveWaitsWithoutFault(t *testing.T) {
	session, _ := setupThermalFixture(t)
	session.percent = 23
	conf.SetHeatProtection(true, 35, 32)
	conf.SetThermalAdapterEnabled(true)
	reconcileAdapterFixture()
	status := getHeatProtectionStatus()
	if session.holds != 0 || status.Fault || !status.ReserveBlocked {
		t.Fatalf("%+v", status)
	}
}

func TestThermalAdapterThresholdEditKeepsHealthyHold(t *testing.T) {
	session, controller := setupThermalFixture(t)
	conf.SetHeatProtection(true, 35, 32)
	conf.SetThermalAdapterEnabled(true)
	reconcileAdapterFixture()
	if err := controller.configure(true); err != nil {
		t.Fatal(err)
	}
	controller.reconcile(true, 33, 30)
	if session.holds != 1 || session.restores != 0 || !session.held {
		t.Fatal("threshold edit caused unnecessary AC reconnection")
	}
}
