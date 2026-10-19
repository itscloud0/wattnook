package daemon

import (
	"fmt"
	"math"
	"time"
)

type ThermalAdapterInput struct {
	Now                              time.Time
	Temperature                      *float64
	SensorAt                         time.Time
	BatteryPercent                   float64
	PhysicalAC, Enabled, Conflicting bool
	Observed                         string
	ActuatorError                    error
}

type ThermalAdapterPolicy struct {
	Pause, Resume float64
	Freshness     time.Duration
}

type ThermalAdapterState struct {
	Requested, Observed, Reason string
	LastTransition              time.Time
	ReserveBlocked, Fault       bool
	RecoveryAttempted           bool
}

// NextThermalAdapter is a pure decision function, not a hardware controller.
// The native thermal controller serializes commands through its guardian,
// executes each returned command once and supplies completed, verified
// readback on the next call. Observed must never be a command acknowledgement.
// A fault is latched for this session; clearing it requires external supervised
// reconciliation, not toggling Enabled. No state here proves physical charging.
func NextThermalAdapter(policy ThermalAdapterPolicy, state ThermalAdapterState, input ThermalAdapterInput) (ThermalAdapterState, string) {
	mayBeHeld := state.Requested == "held" || state.Observed == "held" || input.Observed == "held"
	state.Observed = input.Observed
	command := func(target, reason string) (ThermalAdapterState, string) {
		state.Requested, state.Reason = target, reason
		state.LastTransition = input.Now // Conservative: cooldown starts at issuance.
		if target == "held" {
			state.RecoveryAttempted = false
			return state, "hold"
		}
		state.RecoveryAttempted = true
		return state, "restore"
	}
	restore := func(reason string) (ThermalAdapterState, string) {
		state.Reason = reason
		if mayBeHeld && !state.RecoveryAttempted {
			return command("restored", reason)
		}
		return state, ""
	}
	fault := func(reason string) (ThermalAdapterState, string) {
		if !state.Fault {
			state.Reason = reason
		}
		state.Fault = true
		return restore(state.Reason)
	}
	if state.Fault {
		return restore(state.Reason)
	}
	if input.ActuatorError != nil {
		return fault("actuator: " + input.ActuatorError.Error())
	}
	if input.Observed != "held" && input.Observed != "restored" {
		return fault("unknown actuator state")
	}
	if state.Requested != "" && state.Requested != input.Observed {
		return fault("actuator readback disagrees with request")
	}
	if input.Now.IsZero() || state.LastTransition.After(input.Now) {
		return fault("invalid policy clock")
	}
	if !finite(input.BatteryPercent) || input.BatteryPercent < 0 || input.BatteryPercent > 100 {
		return fault("battery reserve unavailable")
	}
	if input.BatteryPercent <= 20 {
		state.ReserveBlocked = true
	}
	if input.BatteryPercent > 25 {
		state.ReserveBlocked = false
	}
	// A bypass must not hide loss of supervision while an adapter is held.
	// Only an inactive, restored session can ignore unavailable sensor data.
	if input.Enabled || mayBeHeld {
		if err := validateHeatThresholds(policy.Pause, policy.Resume); err != nil {
			return fault(err.Error())
		}
		if policy.Freshness <= 0 {
			return fault("sensor freshness bound unavailable")
		}
		if input.Temperature == nil || !finite(*input.Temperature) || *input.Temperature < 0 || *input.Temperature > 100 {
			return fault("battery temperature unavailable or implausible")
		}
		if input.SensorAt.IsZero() || input.SensorAt.After(input.Now) || input.Now.Sub(input.SensorAt) > policy.Freshness {
			return fault("battery temperature stale or timestamp invalid")
		}
	}
	// These restoration paths deliberately bypass the automatic cooldown.
	if !input.Enabled {
		return restore("disabled")
	}
	if input.Conflicting {
		return restore("conflicting operation")
	}
	if !input.PhysicalAC {
		return restore("physical AC disconnected")
	}
	if state.ReserveBlocked {
		return restore("battery reserve bypass")
	}
	state.Reason = "hysteresis"
	if !state.LastTransition.IsZero() && input.Now.Sub(state.LastTransition) < time.Minute {
		state.Reason = "cooldown"
		return state, ""
	}
	if input.Observed == "restored" && *input.Temperature >= policy.Pause {
		return command("held", "hot")
	}
	if input.Observed == "held" && *input.Temperature <= policy.Resume {
		return command("restored", "cooled")
	}
	return state, ""
}

func finite(value float64) bool { return !math.IsNaN(value) && !math.IsInf(value, 0) }

func validateHeatThresholds(pause, resume float64) error {
	if !finite(pause) || pause < 20 || pause > 60 {
		return fmt.Errorf("heat pause temperature must be finite and between 20 and 60 Celsius, got %.1f", pause)
	}
	if !finite(resume) || resume < 10 || resume >= pause {
		return fmt.Errorf("heat resume temperature must be finite, at least 10 Celsius and below the pause temperature, got %.1f", resume)
	}
	return nil
}
