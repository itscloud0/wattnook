package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/charlie0129/batt/pkg/thermalguard"
	"github.com/gin-gonic/gin"
	"github.com/sirupsen/logrus"
)

type thermalSession interface {
	Exchange(string) (thermalguard.Reply, error)
	Close() error
}

type guardianProcess struct {
	input     io.WriteCloser
	replies   chan thermalguard.Reply
	done      chan error
	stop      chan struct{}
	closeOnce sync.Once
}

func startThermalGuardian(statePath string) (thermalSession, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(executable, "thermal-guardian", "--state-path", statePath)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Stderr = os.Stderr
	input, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	output, err := cmd.StdoutPipe()
	if err != nil {
		input.Close()
		return nil, err
	}
	if err = cmd.Start(); err != nil {
		input.Close()
		output.Close()
		return nil, err
	}
	p := &guardianProcess{input: input, replies: make(chan thermalguard.Reply, 1), done: make(chan error, 1), stop: make(chan struct{})}
	go func() {
		defer close(p.replies)
		defer func() { p.done <- cmd.Wait() }()
		decoder := json.NewDecoder(output)
		for {
			var reply thermalguard.Reply
			if err := decoder.Decode(&reply); err != nil {
				return
			}
			select {
			case p.replies <- reply:
			case <-p.stop:
				return
			}
		}
	}()
	// A handshake is consumed by the first status Exchange.
	return p, nil
}

func (p *guardianProcess) receive() (thermalguard.Reply, error) {
	select {
	case reply, ok := <-p.replies:
		if !ok {
			return reply, errors.New("thermal guardian stopped; power recovery requested")
		}
		if reply.Error != "" {
			return reply, errors.New(reply.Error)
		}
		return reply, nil
	case <-time.After(12 * time.Second):
		p.input.Close()
		return thermalguard.Reply{}, errors.New("thermal guardian did not respond; power recovery requested")
	}
}

func (p *guardianProcess) Exchange(command string) (thermalguard.Reply, error) {
	if command == "hello" {
		return p.receive()
	}
	if _, err := fmt.Fprintln(p.input, command); err != nil {
		return thermalguard.Reply{}, err
	}
	return p.receive()
}

func (p *guardianProcess) Close() error {
	p.closeOnce.Do(func() { close(p.stop); p.input.Close() }) // EOF restores after a crash.
	select {
	case err := <-p.done:
		return err
	case <-time.After(4 * time.Second):
		return errors.New("thermal guardian recovery still pending")
	}
}

// All methods are called under maintainLoopInnerLock. This is the sole native
// adapter owner; manual adapter/discharge/calibration APIs remain unavailable.
type adapterThermalController struct {
	start    func(string) (thermalSession, error)
	path     string
	session  thermalSession
	state    ThermalAdapterState
	sleeping bool
	stopping bool
}

var nativeThermal *adapterThermalController

const nativeHeatUnavailable = "Charge-only Heat Protection is not verified on this Mac; adapter disconnection is not a substitute"

func setNativeHeatProtection(c *gin.Context, request heatProtectionRequest) {
	if request.Enabled {
		c.AbortWithStatusJSON(http.StatusConflict, nativeHeatUnavailable)
		return
	}
	maintainLoopInnerLock.Lock()
	defer maintainLoopInnerLock.Unlock()
	oldEnabled, oldAdapter := conf.HeatProtectionEnabled(), conf.ThermalAdapterEnabled()
	oldPause, oldResume := conf.HeatPauseTemperatureCelsius(), conf.HeatResumeTemperatureCelsius()
	var controlErr error
	if nativeThermal != nil {
		controlErr = nativeThermal.configure(false)
	}
	// Off is a recovery operation, not a temperature-setting operation. It
	// must work even for old callers that omit the thresholds entirely.
	conf.SetHeatProtection(false, oldPause, oldResume)
	conf.SetThermalAdapterEnabled(false)
	if err := conf.Save(); err != nil {
		conf.SetHeatProtection(oldEnabled, oldPause, oldResume)
		conf.SetThermalAdapterEnabled(oldAdapter)
		c.AbortWithStatusJSON(http.StatusInternalServerError, err.Error())
		return
	}
	if nativeThermal != nil {
		nativeThermal.reconcile(false, oldPause, oldResume)
	} else {
		clearHeatProtectionStatus()
	}
	status := getHeatProtectionStatus()
	if controlErr != nil || status.Fault {
		message := status.LastError
		if controlErr != nil {
			message = controlErr.Error()
		}
		c.AbortWithStatusJSON(http.StatusServiceUnavailable, message)
		return
	}
	c.IndentedJSON(http.StatusCreated, "Heat Protection updated; Apple charge limit preserved")
}

func newAdapterThermalController(statePath string) *adapterThermalController {
	return &adapterThermalController{start: startThermalGuardian, path: statePath,
		state: ThermalAdapterState{LastTransition: time.Now()}}
}

func (t *adapterThermalController) open() (thermalguard.Reply, error) {
	if t.session != nil {
		return t.session.Exchange("status")
	}
	session, err := t.start(t.path)
	if err != nil {
		return thermalguard.Reply{}, err
	}
	t.session = session
	return session.Exchange("hello")
}

func (t *adapterThermalController) fault(err error) {
	t.state.Fault = true
	t.state.Reason = err.Error()
	t.state.Observed = "unknown"
	if t.session != nil {
		_, restoreErr := t.session.Exchange("restore")
		closeErr := t.session.Close()
		t.session = nil
		if restoreErr != nil || closeErr != nil {
			logrus.WithError(errors.Join(restoreErr, closeErr)).Error("thermal adapter recovery")
		}
	}
	// One fresh owner reconciles a durable hold if the previous guardian died.
	if recovery, startErr := t.start(t.path); startErr == nil {
		if reply, readErr := recovery.Exchange("hello"); readErr == nil {
			t.state.Observed = reply.Observed
		}
		_ = recovery.Close()
	}
	logrus.WithError(err).Error("heat protection stopped; explicit re-enable required")
}

func (t *adapterThermalController) configure(enabled bool) error {
	if !enabled {
		if t.session != nil {
			reply, err := t.session.Exchange("restore")
			if err != nil {
				t.fault(err)
				return err
			}
			t.state.Observed = reply.Observed
			t.state.Requested = "restored"
			t.state.LastTransition = time.Now()
			_ = t.session.Close()
			t.session = nil
		}
		return nil
	}
	reply, err := t.open()
	if err != nil {
		t.fault(err)
		return err
	}
	// Editing thresholds on a healthy enabled session must not reconnect AC.
	// The next hysteresis decision decides whether this existing hold can end.
	if reply.Owned && !reply.Recovered && !t.state.Fault {
		return nil
	}
	if reply.Owned {
		reply, err = t.session.Exchange("restore")
		if err != nil {
			t.fault(err)
			return err
		}
		t.state.LastTransition = time.Now()
	}
	if _, err = t.session.Exchange("reset"); err != nil {
		t.fault(err)
		return err
	}
	t.state = ThermalAdapterState{Observed: "restored", LastTransition: t.state.LastTransition}
	return nil
}

func (t *adapterThermalController) reconcile(enabled bool, pause, resume float64) bool {
	now := time.Now()
	status := HeatProtectionStatus{Enabled: enabled, Mechanism: "adapter", PauseTemperatureCelsius: pause, ResumeTemperatureCelsius: resume, UpdatedAt: now}
	defer func() {
		status.Requested = t.state.Requested
		status.Observed = t.state.Observed
		status.Reason = t.state.Reason
		status.LastTransition = t.state.LastTransition
		status.Fault = t.state.Fault
		status.ReserveBlocked = t.state.ReserveBlocked
		if t.state.Fault {
			status.LastError = t.state.Reason
			status.Paused = false
		}
		heatProtectionMu.Lock()
		heatProtectionStatus = status
		heatProtectionMu.Unlock()
	}()
	if t.state.Fault {
		return false
	}
	if t.stopping {
		t.state.Reason = "shutting down"
		return true
	}
	if t.sleeping {
		t.state.Reason = "sleeping"
		return true
	}
	if !enabled {
		if err := t.configure(false); err != nil {
			t.fault(err)
			return false
		}
		t.state.Reason = "disabled"
		return true
	}
	reply, err := t.open()
	if err != nil {
		t.fault(err)
		return false
	}
	if reply.Recovered {
		t.fault(errors.New("power restored after interruption; re-enable Heat Protection"))
		return false
	}
	temperature := reply.Sample.Temperature
	status.TemperatureCelsius = &temperature
	input := ThermalAdapterInput{Now: now, Temperature: &temperature, SensorAt: reply.Sample.At,
		BatteryPercent: reply.Sample.Percent, PhysicalAC: reply.Sample.Connected || reply.Owned,
		Enabled: enabled && !t.sleeping, Observed: reply.Observed}
	// Take the decision clock after the new sensor sample, never before it.
	input.Now = time.Now()
	if !reply.Owned && reply.Sample.Percent <= 25 {
		t.state.ReserveBlocked = true
	}
	var command string
	t.state, command = NextThermalAdapter(ThermalAdapterPolicy{Pause: pause, Resume: resume, Freshness: 15 * time.Second}, t.state, input)
	if t.state.Fault {
		t.fault(errors.New(t.state.Reason))
		return false
	}
	if command != "" {
		reply, err = t.session.Exchange(command)
		if err != nil {
			t.fault(err)
			return false
		}
		t.state.Observed = reply.Observed
		t.state.LastTransition = time.Now()
		if t.state.Requested != reply.Observed {
			t.fault(errors.New("thermal transition readback disagrees"))
			return false
		}
		logrus.WithFields(logrus.Fields{"command": command, "temperature": temperature, "observed": reply.Observed}).Info("heat protection adapter transition")
	}
	status.Paused = enabled && !t.state.Fault && reply.Owned && reply.Observed == "held" && !reply.Sample.Connected && !reply.Sample.Charging
	return !t.state.Fault
}

func setThermalSleeping(sleeping bool) {
	maintainLoopInnerLock.Lock()
	defer maintainLoopInnerLock.Unlock()
	if nativeThermal == nil {
		return
	}
	nativeThermal.sleeping = sleeping
	if sleeping && nativeThermal.session != nil {
		if err := nativeThermal.configure(false); err != nil {
			return
		}
	}
	if sleeping {
		nativeThermal.reconcile(false, conf.HeatPauseTemperatureCelsius(), conf.HeatResumeTemperatureCelsius())
	}
	if !sleeping {
		nativeThermal.state.LastTransition = time.Now()
	}
}

func initializeNativeThermal(configPath string) {
	if !capabilities.ThermalAdapter {
		return
	}
	// One private root-owned directory, with a record for this daemon's config.
	statePath := filepath.Join("/var/db/wattnook-thermal", filepath.Base(configPath)+".adapter.json")
	nativeThermal = newAdapterThermalController(statePath)
	if _, err := os.Stat(statePath); err == nil {
		// Startup recovery precedes any enabled temperature decisions.
		reply, err := nativeThermal.open()
		if err != nil {
			nativeThermal.fault(err)
			return
		}
		if reply.Recovered {
			nativeThermal.fault(errors.New("power restored after interruption; re-enable Heat Protection"))
		}
		if !conf.ThermalAdapterEnabled() {
			_ = nativeThermal.configure(false)
		}
	}
}
