package daemon

import (
	"errors"
	"math"
	"testing"
	"time"
)

// These fixtures exercise decisions only: no daemon, config or SMC transport.
func thermalFixture() (ThermalAdapterPolicy, ThermalAdapterInput) {
	now := time.Date(2026, 10, 17, 12, 0, 0, 0, time.UTC)
	temp := 35.0
	return ThermalAdapterPolicy{Pause: 35, Resume: 32, Freshness: 20 * time.Second}, ThermalAdapterInput{
		Now: now, Temperature: &temp, SensorAt: now, BatteryPercent: 80,
		PhysicalAC: true, Enabled: true, Observed: "restored",
	}
}

func TestThermalAdapterHysteresis(t *testing.T) {
	p, in := thermalFixture()
	state, command := NextThermalAdapter(p, ThermalAdapterState{}, in)
	if command != "hold" || state.Requested != "held" || state.Observed != "restored" {
		t.Fatalf("hot request must not manufacture acknowledgement: %+v %q", state, command)
	}
	in.Observed = "held"
	state, command = NextThermalAdapter(p, state, in)
	if command != "" || state.Fault {
		t.Fatalf("satisfied request repeated: %+v %q", state, command)
	}
	in.Now = in.Now.Add(time.Minute)
	in.SensorAt = in.Now
	*in.Temperature = 33
	state, command = NextThermalAdapter(p, state, in)
	if command != "" {
		t.Fatal("hysteresis must retain hold")
	}
	*in.Temperature = 32
	state, command = NextThermalAdapter(p, state, in)
	if command != "restore" || state.Observed != "held" {
		t.Fatalf("cool: %+v %q", state, command)
	}
	in.Observed = "restored"
	state, command = NextThermalAdapter(p, state, in)
	if command != "" || state.Fault {
		t.Fatalf("restore repeated: %+v %q", state, command)
	}
}

func TestThermalAdapterCooldown(t *testing.T) {
	for _, tc := range []struct {
		age  time.Duration
		want string
	}{
		{59 * time.Second, ""}, {60 * time.Second, "restore"},
	} {
		p, in := thermalFixture()
		*in.Temperature = 32
		in.Observed = "held"
		s := ThermalAdapterState{Requested: "held", LastTransition: in.Now.Add(-tc.age)}
		_, got := NextThermalAdapter(p, s, in)
		if got != tc.want {
			t.Fatalf("age %v: %q, want %q", tc.age, got, tc.want)
		}
	}
	for _, tc := range []struct {
		age  time.Duration
		want string
	}{
		{59 * time.Second, ""}, {60 * time.Second, "hold"},
	} {
		p, in := thermalFixture()
		s := ThermalAdapterState{Requested: "restored", LastTransition: in.Now.Add(-tc.age), RecoveryAttempted: true}
		s, got := NextThermalAdapter(p, s, in)
		if got != tc.want || (got == "hold" && s.RecoveryAttempted) {
			t.Fatalf("new hold after %v: %+v %q", tc.age, s, got)
		}
	}
	for _, cause := range []string{"disable", "reserve", "conflict", "unplug"} {
		t.Run(cause, func(t *testing.T) {
			p, in := thermalFixture()
			in.Observed = "held"
			s := ThermalAdapterState{Requested: "held", LastTransition: in.Now}
			switch cause {
			case "disable":
				in.Enabled = false
			case "reserve":
				in.BatteryPercent = 20
			case "conflict":
				in.Conflicting = true
			case "unplug":
				in.PhysicalAC = false
			}
			_, got := NextThermalAdapter(p, s, in)
			if got != "restore" {
				t.Fatalf("recovery delayed: %q", got)
			}
		})
	}
}

func TestThermalAdapterFreshnessBoundary(t *testing.T) {
	p, in := thermalFixture()
	in.SensorAt = in.Now.Add(-20 * time.Second)
	_, cmd := NextThermalAdapter(p, ThermalAdapterState{}, in)
	if cmd != "hold" {
		t.Fatalf("freshness inclusive boundary: %q", cmd)
	}
	in.SensorAt = in.SensorAt.Add(-time.Nanosecond)
	s, cmd := NextThermalAdapter(p, ThermalAdapterState{}, in)
	if cmd != "" || !s.Fault {
		t.Fatalf("past freshness boundary: %+v %q", s, cmd)
	}
	_, in = thermalFixture()
	s, cmd = NextThermalAdapter(p, ThermalAdapterState{LastTransition: in.Now.Add(time.Second)}, in)
	if cmd != "" || !s.Fault {
		t.Fatalf("backwards clock: %+v %q", s, cmd)
	}
}

func TestThermalAdapterReserve(t *testing.T) {
	p, in := thermalFixture()
	in.BatteryPercent = 20
	s, cmd := NextThermalAdapter(p, ThermalAdapterState{}, in)
	if cmd != "" || !s.ReserveBlocked {
		t.Fatalf("low reserve: %+v %q", s, cmd)
	}
	in.BatteryPercent = 25
	s, cmd = NextThermalAdapter(p, s, in)
	if cmd != "" || !s.ReserveBlocked {
		t.Fatal("must not rearm at 25%")
	}
	in.BatteryPercent = 25.1
	s, cmd = NextThermalAdapter(p, s, in)
	if cmd != "hold" || s.ReserveBlocked {
		t.Fatalf("rearm: %+v %q", s, cmd)
	}
}

func TestThermalAdapterFaults(t *testing.T) {
	for _, kind := range []string{"missing", "stale", "future", "nan", "inf", "implausible", "battery", "unknown", "actuator", "freshness", "threshold", "clock"} {
		for _, held := range []bool{false, true} {
			t.Run(kind+"/held="+map[bool]string{false: "no", true: "yes"}[held], func(t *testing.T) {
				p, in := thermalFixture()
				s := ThermalAdapterState{}
				if held {
					in.Observed = "held"
					s.Requested = "held"
					s.Observed = "held"
				}
				switch kind {
				case "missing":
					in.Temperature = nil
				case "stale":
					in.SensorAt = in.Now.Add(-21 * time.Second)
				case "future":
					in.SensorAt = in.Now.Add(time.Second)
				case "nan":
					*in.Temperature = math.NaN()
				case "inf":
					*in.Temperature = math.Inf(1)
				case "implausible":
					*in.Temperature = 101
				case "battery":
					in.BatteryPercent = math.NaN()
				case "unknown":
					in.Observed = "unknown"
				case "actuator":
					in.ActuatorError = errors.New("readback failed")
				case "freshness":
					p.Freshness = 0
				case "threshold":
					p.Pause = math.NaN()
				case "clock":
					in.Now = time.Time{}
				}
				s, cmd := NextThermalAdapter(p, s, in)
				want := ""
				if held {
					want = "restore"
				}
				if !s.Fault || s.Reason == "" || cmd != want {
					t.Fatalf("fault: %+v %q, want %q", s, cmd, want)
				}
				_, cmd = NextThermalAdapter(p, s, in)
				if cmd != "" {
					t.Fatal("fault recovery must not repeat")
				}
				_, valid := thermalFixture()
				valid.Now = valid.Now.Add(2 * time.Minute)
				valid.SensorAt = valid.Now
				s, cmd = NextThermalAdapter(p, s, valid)
				if !s.Fault || cmd != "" {
					t.Fatalf("fault must stay latched: %+v %q", s, cmd)
				}
			})
		}
	}
}

func TestThermalAdapterReadbackMismatch(t *testing.T) {
	p, in := thermalFixture()
	s, _ := NextThermalAdapter(p, ThermalAdapterState{}, in)
	s, cmd := NextThermalAdapter(p, s, in) // Hold was not observed.
	if !s.Fault || cmd != "restore" {
		t.Fatalf("missing hold acknowledgement: %+v %q", s, cmd)
	}
	in.Observed = "held" // Restore was not observed either.
	s, cmd = NextThermalAdapter(p, s, in)
	if !s.Fault || cmd != "" {
		t.Fatalf("must not retry uncertain restore: %+v %q", s, cmd)
	}
}

// Catches bypass branches hiding a sensor failure and silently rearming later.
func TestThermalAdapterSensorFaultDuringBypass(t *testing.T) {
	for _, bypass := range []string{"reserve", "conflict", "unplug", "disabled"} {
		for _, sensor := range []string{"missing", "stale"} {
			t.Run(bypass+"/"+sensor, func(t *testing.T) {
				p, in := thermalFixture()
				in.Observed = "held"
				s := ThermalAdapterState{Requested: "held", Observed: "held", LastTransition: in.Now}
				switch bypass {
				case "reserve":
					in.BatteryPercent = 20
				case "conflict":
					in.Conflicting = true
				case "unplug":
					in.PhysicalAC = false
				case "disabled":
					in.Enabled = false
				}
				if sensor == "missing" {
					in.Temperature = nil
				} else {
					in.SensorAt = in.Now.Add(-time.Minute)
				}
				s, cmd := NextThermalAdapter(p, s, in)
				if cmd != "restore" || !s.Fault {
					t.Fatalf("must restore immediately and latch sensor fault: %+v %q", s, cmd)
				}
				_, in = thermalFixture()
				in.Now = in.Now.Add(2 * time.Minute)
				in.SensorAt = in.Now
				s, cmd = NextThermalAdapter(p, s, in)
				if cmd != "" || !s.Fault {
					t.Fatalf("must not silently rearm: %+v %q", s, cmd)
				}
			})
		}
	}
}

func TestThermalAdapterUnplugReplug(t *testing.T) {
	for _, blocked := range []string{"unplug", "disabled", "conflicting"} {
		p, in := thermalFixture()
		switch blocked {
		case "unplug":
			in.PhysicalAC = false
		case "disabled":
			in.Enabled = false
		case "conflicting":
			in.Conflicting = true
		}
		s, cmd := NextThermalAdapter(p, ThermalAdapterState{}, in)
		if cmd != "" || s.Fault {
			t.Fatalf("%s must not cut: %+v %q", blocked, s, cmd)
		}
		in.PhysicalAC, in.Enabled, in.Conflicting = true, true, false
		_, cmd = NextThermalAdapter(p, s, in)
		if cmd != "hold" {
			t.Fatalf("%s cleared: %q", blocked, cmd)
		}
	}
}

func TestHeatThresholdsFinite(t *testing.T) {
	for _, tc := range []struct {
		pause, resume float64
		valid         bool
	}{
		{35, 32, true}, {20, 10, true}, {60, 59, true},
		{19, 10, false}, {61, 32, false}, {35, 9, false}, {35, 35, false},
		{math.NaN(), 32, false}, {35, math.NaN(), false},
		{math.Inf(1), 32, false}, {35, math.Inf(-1), false},
	} {
		if err := validateHeatThresholds(tc.pause, tc.resume); (err == nil) != tc.valid {
			t.Fatalf("pause %v resume %v: %v", tc.pause, tc.resume, err)
		}
	}
}
