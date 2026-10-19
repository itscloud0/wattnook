// thermal-probe is a supervised, one-shot feasibility tool. It is not part of
// the installed WattNook daemon and must not be used for automatic control.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/charlie0129/gosmc"

	"github.com/charlie0129/batt/pkg/powerui"
	"github.com/charlie0129/batt/pkg/smc"
)

const (
	adapterKey      = smc.AdapterKey3
	maxCutDuration  = 8 * time.Second
	rescueDeadline  = 45 * time.Second
	processDeadline = 65 * time.Second
)

type batteryState struct {
	percent, maximum                           int
	connected, rawConnected, charging, lidOpen bool
}

func commandOutput(name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	bytes, err := exec.CommandContext(ctx, name, args...).Output()
	if err != nil {
		return "", fmt.Errorf("%s: %w", name, err)
	}
	return string(bytes), nil
}

func field(text, key string) (string, error) {
	re := regexp.MustCompile(`(?m)^\s*\|\s+"` + regexp.QuoteMeta(key) + `" = ([^\n]+)$`)
	matches := re.FindAllStringSubmatch(text, -1)
	if len(matches) != 1 {
		return "", fmt.Errorf("expected one %s field, found %d", key, len(matches))
	}
	return strings.TrimSpace(matches[0][1]), nil
}

func readBattery() (batteryState, error) {
	var state batteryState
	output, err := commandOutput("/usr/sbin/ioreg", "-r", "-c", "AppleSmartBattery", "-l")
	if err != nil {
		return state, err
	}
	for _, pair := range []struct {
		key    string
		target *int
	}{
		{"CurrentCapacity", &state.percent}, {"MaxCapacity", &state.maximum},
	} {
		value, err := field(output, pair.key)
		if err != nil {
			return state, err
		}
		*pair.target, err = strconv.Atoi(value)
		if err != nil {
			return state, fmt.Errorf("%s: %w", pair.key, err)
		}
	}
	for _, pair := range []struct {
		key    string
		target *bool
	}{
		{"ExternalConnected", &state.connected}, {"AppleRawExternalConnected", &state.rawConnected},
	} {
		value, err := field(output, pair.key)
		if err != nil {
			return state, err
		}
		if value != "Yes" && value != "No" {
			return state, fmt.Errorf("unknown %s state %q", pair.key, value)
		}
		*pair.target = value == "Yes"
	}
	charging := regexp.MustCompile(`"ChargerData" = \{[^\n]*"IsCharging"=([01])`).FindStringSubmatch(output)
	if len(charging) != 2 {
		return state, errors.New("charging state unavailable")
	}
	state.charging = charging[1] == "1"
	lid, err := commandOutput("/usr/sbin/ioreg", "-r", "-k", "AppleClamshellState", "-d", "4")
	if err != nil {
		return state, err
	}
	lidValue, err := field(lid, "AppleClamshellState")
	if err != nil {
		return state, err
	}
	if lidValue != "Yes" && lidValue != "No" {
		return state, fmt.Errorf("unknown lid state %q", lidValue)
	}
	state.lidOpen = lidValue == "No"
	return state, nil
}

func openSMC() (*gosmc.Client, error) { return gosmc.Open() }

type adapterClient interface {
	KeyInfo(string) (gosmc.KeyInfo, error)
	Read(string) (gosmc.Value, error)
	WriteBytes(string, []byte) error
}

func readAdapter(c adapterClient) (gosmc.KeyInfo, gosmc.Value, error) {
	info, err := c.KeyInfo(adapterKey)
	if err != nil {
		return info, gosmc.Value{}, err
	}
	value, err := c.Read(adapterKey)
	return info, value, err
}

func preflight(c *gosmc.Client, armed bool) (batteryState, int, error) {
	state, err := readBattery()
	if err != nil {
		return state, 0, err
	}
	if !state.lidOpen || !state.rawConnected || !state.charging || state.maximum != 100 {
		return state, 0, errors.New("open lid, physical AC, active charging and percent-scale battery reading required")
	}
	info, value, err := readAdapter(c)
	if err != nil {
		return state, 0, err
	}
	native, err := powerui.New()
	if err != nil {
		return state, 0, err
	}
	limit, err := native.Read()
	if err != nil {
		return state, 0, err
	}
	probe := smc.AdapterProbePreflight{
		Info: info, Value: value, PhysicalAC: state.connected,
		BatteryPercent: float64(state.percent), NativeLimit: limit.Limit,
		NativeLimitEnabled: limit.Enabled, RestorationArmed: armed,
	}
	if !armed {
		err = smc.ValidateAdapterProbeBaseline(probe)
	} else {
		err = smc.ValidateAdapterProbe(probe)
	}
	if err != nil {
		return state, limit.Limit, err
	}
	return state, limit.Limit, nil
}

// restore is called by the actor and, independently, by the rescue process.
// It never writes over an unknown CHIE encoding.
func restore(c adapterClient) error {
	info, value, err := readAdapter(c)
	if err != nil {
		return err
	}
	if info.Key != adapterKey || info.DataSize != 1 || info.DataType != "hex_" ||
		value.Key != adapterKey || value.DataType != "hex_" || len(value.Bytes) != 1 {
		return errors.New("CHIE restoration metadata or value unknown")
	}
	switch value.Bytes[0] {
	case 0:
		return nil
	case 8:
		if err := c.WriteBytes(adapterKey, []byte{0}); err != nil {
			return err
		}
		_, value, err = readAdapter(c)
		if err != nil {
			return err
		}
		if len(value.Bytes) != 1 || value.Bytes[0] != 0 {
			return errors.New("CHIE restoration readback disagrees")
		}
		return nil
	default:
		return fmt.Errorf("CHIE changed to unknown value %#02x; no write made", value.Bytes[0])
	}
}

// A failed restoration may be a transient SMC busy response. Retry only the
// idempotent enable command; never issue a second cut.
func restoreWithRetries(c adapterClient) error {
	var last error
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(500 * time.Millisecond)
		}
		if last = restore(c); last == nil {
			return nil
		}
	}
	return fmt.Errorf("adapter restoration failed after three checks: %w", last)
}

func rescue(directory string) error {
	c, err := openSMC()
	if err != nil {
		return err
	}
	defer c.Close()
	info, value, err := readAdapter(c)
	if err != nil {
		return err
	}
	if info.Key != adapterKey || info.DataSize != 1 || info.DataType != "hex_" ||
		len(value.Bytes) != 1 || value.Bytes[0] != 0 {
		return errors.New("rescue cannot establish an enabled CHIE baseline")
	}
	if err := os.WriteFile(filepath.Join(directory, "rescue-ready"), []byte(strconv.Itoa(os.Getpid())), 0600); err != nil {
		return err
	}
	time.Sleep(rescueDeadline)
	return restoreWithRetries(c)
}

func actor(directory string) (resultErr error) {
	ready, err := os.ReadFile(filepath.Join(directory, "rescue-ready"))
	if err != nil {
		return err
	}
	pid, err := strconv.Atoi(string(ready))
	if err != nil || pid <= 1 || syscall.Kill(pid, 0) != nil {
		return errors.New("independent rescue owner not running")
	}
	c, err := openSMC()
	if err != nil {
		return err
	}
	defer c.Close()
	before, originalLimit, err := preflight(c, true)
	if err != nil {
		return err
	}
	fmt.Printf("before: %d%% charging=%t AC=%t native=%d%%\n", before.percent, before.charging, before.connected, originalLimit)
	// Restoration is armed before the first possible state-changing operation.
	cutPossible := true
	defer func() {
		if !cutPossible {
			return
		}
		if err := restoreWithRetries(c); err != nil {
			resultErr = errors.Join(resultErr, fmt.Errorf("restore: %w", err))
		}
	}()
	if err := c.WriteBytes(adapterKey, []byte{8}); err != nil {
		return fmt.Errorf("single cut command: %w", err)
	}
	_, value, err := readAdapter(c)
	if err != nil {
		return err
	}
	if len(value.Bytes) != 1 || value.Bytes[0] != 8 {
		return errors.New("cut command not confirmed by CHIE readback")
	}
	var observedOff bool
	deadline := time.Now().Add(maxCutDuration)
	for time.Now().Before(deadline) {
		time.Sleep(time.Second)
		state, err := readBattery()
		if err != nil {
			return err
		}
		fmt.Printf("sample: %d%% charging=%t AC=%t rawAC=%t\n", state.percent, state.charging, state.connected, state.rawConnected)
		if !state.connected && !state.charging {
			observedOff = true
			break
		}
		if state.percent <= 20 {
			return errors.New("reserve reached during cut")
		}
		if !state.lidOpen {
			return errors.New("lid closed during cut")
		}
	}
	if err := restoreWithRetries(c); err != nil {
		return fmt.Errorf("immediate restore: %w", err)
	}
	cutPossible = false
	var restoredAC bool
	for i := 0; i < 5; i++ {
		state, err := readBattery()
		if err != nil {
			return err
		}
		if state.connected {
			restoredAC = true
			break
		}
		time.Sleep(time.Second)
	}
	native, err := powerui.New()
	if err != nil {
		return err
	}
	afterLimit, err := native.Read()
	if err != nil {
		return err
	}
	if !afterLimit.Enabled || afterLimit.Limit != originalLimit {
		return errors.New("native limit changed during probe")
	}
	if !observedOff || !restoredAC {
		return fmt.Errorf("physical transition not verified: off=%t restoredAC=%t", observedOff, restoredAC)
	}
	fmt.Printf("verified: adapter cut and restored; native limit %d%% unchanged\n", afterLimit.Limit)
	return nil
}

func launch(directory, mode string, log *os.File) (*os.Process, error) {
	return os.StartProcess(os.Args[0], []string{os.Args[0], mode, directory}, &os.ProcAttr{
		Files: []*os.File{os.Stdin, log, log},
		Sys:   &syscall.SysProcAttr{Setsid: true},
	})
}

// selfTest exercises the detached rescue process after an actor exit without
// touching the SMC. The real 45-second deadline is intentionally not shortened.
func selfTest() error {
	directory, err := os.MkdirTemp("/private/tmp", "wattnook-thermal-selftest-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(directory)
	log, err := os.OpenFile(filepath.Join(directory, "fixture.log"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer log.Close()
	rescueProcess, err := launch(directory, "--fixture-rescue", log)
	if err != nil {
		return err
	}
	actorProcess, err := launch(directory, "--fixture-crash", log)
	if err != nil {
		return err
	}
	actorState, err := actorProcess.Wait()
	if err != nil {
		return err
	}
	if actorState.Success() {
		return errors.New("fixture actor unexpectedly survived")
	}
	rescueState, err := rescueProcess.Wait()
	if err != nil {
		return err
	}
	if !rescueState.Success() {
		return fmt.Errorf("fixture rescue exited: %s", rescueState)
	}
	marker, err := os.ReadFile(filepath.Join(directory, "restored"))
	if err != nil || string(marker) != "yes" {
		return errors.New("detached rescue did not complete after actor exit")
	}
	fmt.Println("detached rescue survived actor exit (fixture only)")
	return nil
}

func run() error {
	if os.Geteuid() != 0 {
		return errors.New("supervised test needs an administrator process")
	}
	c, err := openSMC()
	if err != nil {
		return err
	}
	_, _, err = preflight(c, false) // Physical baseline; the actor rechecks after the rescue owner arms.
	c.Close()
	if err != nil {
		return err
	}
	directory, err := os.MkdirTemp("/private/tmp", "wattnook-thermal-probe-")
	if err != nil {
		return err
	}
	if err := os.Chmod(directory, 0700); err != nil {
		return err
	}
	fmt.Printf("probe record: %s\n", directory)
	log, err := os.OpenFile(filepath.Join(directory, "probe.log"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer log.Close()
	watchdog, err := launch(directory, "--rescue", log)
	if err != nil {
		return err
	}
	// Wait for a real arm acknowledgement. No CHIE write can occur before it.
	ready := filepath.Join(directory, "rescue-ready")
	for i := 0; i < 30; i++ {
		if _, err := os.Stat(ready); err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if _, err := os.Stat(ready); err != nil {
		return fmt.Errorf("rescue owner failed to arm: %w", err)
	}
	worker, err := launch(directory, "--actor", log)
	if err != nil {
		return err
	}
	workerDone := make(chan error, 1)
	go func() {
		state, err := worker.Wait()
		if err == nil && !state.Success() {
			err = fmt.Errorf("actor exited: %s", state)
		}
		workerDone <- err
	}()
	select {
	case err = <-workerDone:
	case <-time.After(processDeadline):
		err = errors.New("actor timed out; rescue owner remains active")
	}
	rescueDone := make(chan error, 1)
	go func() {
		state, waitErr := watchdog.Wait()
		if waitErr == nil && !state.Success() {
			waitErr = fmt.Errorf("rescue exited: %s", state)
		}
		rescueDone <- waitErr
	}()
	select {
	case waitErr := <-rescueDone:
		err = errors.Join(err, waitErr)
	case <-time.After(processDeadline):
		err = errors.Join(err, errors.New("rescue outcome unknown"))
	}
	if record, readErr := os.ReadFile(filepath.Join(directory, "probe.log")); readErr == nil {
		fmt.Print(string(record))
	} else {
		err = errors.Join(err, fmt.Errorf("read probe record: %w", readErr))
	}
	return err
}

func main() {
	var err error
	switch {
	case len(os.Args) == 2 && os.Args[1] == "--preflight":
		c, openErr := openSMC()
		if openErr != nil {
			err = openErr
			break
		}
		state, limit, checkErr := preflight(c, false)
		err = checkErr
		fmt.Printf("battery=%d%% charging=%t AC=%t lidOpen=%t nativeLimit=%d%%\n",
			state.percent, state.charging, state.connected, state.lidOpen, limit)
		c.Close()
	case len(os.Args) == 2 && os.Args[1] == "--run":
		err = run()
	case len(os.Args) == 2 && os.Args[1] == "--selftest":
		err = selfTest()
	case len(os.Args) == 3 && os.Args[1] == "--rescue":
		err = rescue(os.Args[2])
	case len(os.Args) == 3 && os.Args[1] == "--actor":
		err = actor(os.Args[2])
	case len(os.Args) == 3 && os.Args[1] == "--fixture-rescue":
		time.Sleep(250 * time.Millisecond)
		err = os.WriteFile(filepath.Join(os.Args[2], "restored"), []byte("yes"), 0600)
	case len(os.Args) == 3 && os.Args[1] == "--fixture-crash":
		os.Exit(12)
	default:
		err = errors.New("usage: thermal-probe --preflight | --run")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
