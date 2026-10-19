// charge-hold-probe reproduces one investigated AlDente hold sequence. It is
// never installed or invoked by WattNook and has no automatic/retry hold mode.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/charlie0129/batt/pkg/powerui"
	"github.com/charlie0129/gosmc"
)

const key = "CHIE"
const pulseDuration = 500 * time.Millisecond
const actorDeadline = 170 * time.Second

type sample struct {
	Percent   int  `json:"percent"`
	CurrentMA int  `json:"currentMA"`
	AC        bool `json:"ac"`
	RawAC     bool `json:"rawAC"`
	Charging  bool `json:"charging"`
	LidOpen   bool `json:"lidOpen"`
}

func output(name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.WaitDelay = time.Second
	b, err := cmd.Output()
	return string(b), err
}

func field(text, name string) (string, error) {
	re := regexp.MustCompile(`(?m)^\s*\|\s+"` + regexp.QuoteMeta(name) + `" = ([^\n]+)$`)
	v := re.FindAllStringSubmatch(text, -1)
	if len(v) != 1 {
		return "", fmt.Errorf("ambiguous or missing %s", name)
	}
	return strings.TrimSpace(v[0][1]), nil
}

func readSample() (sample, error) {
	var s sample
	text, err := output("/usr/sbin/ioreg", "-r", "-c", "AppleSmartBattery", "-l")
	if err != nil {
		return s, err
	}
	for _, f := range []struct {
		name string
		p    *int
	}{{"CurrentCapacity", &s.Percent}, {"Amperage", &s.CurrentMA}} {
		v, err := field(text, f.name)
		if err != nil {
			return s, err
		}
		// Negative current may be serialized as an unsigned 64-bit integer.
		if strings.HasPrefix(v, "-") {
			*f.p, err = strconv.Atoi(v)
		} else {
			var u uint64
			u, err = strconv.ParseUint(v, 10, 64)
			*f.p = int(int64(u))
		}
		if err != nil {
			return s, err
		}
	}
	for _, f := range []struct {
		name string
		p    *bool
	}{{"ExternalConnected", &s.AC}, {"AppleRawExternalConnected", &s.RawAC}, {"IsCharging", &s.Charging}} {
		v, err := field(text, f.name)
		if err != nil {
			return s, err
		}
		if v != "Yes" && v != "No" {
			return s, fmt.Errorf("invalid %s", f.name)
		}
		*f.p = v == "Yes"
	}
	lid, err := output("/usr/sbin/ioreg", "-r", "-k", "AppleClamshellState", "-d", "4")
	if err != nil {
		return s, err
	}
	v, err := field(lid, "AppleClamshellState")
	if err != nil {
		return s, err
	}
	if v != "Yes" && v != "No" {
		return s, errors.New("unknown lid state")
	}
	s.LidOpen = v == "No"
	if s.Percent < 0 || s.Percent > 100 || math.Abs(float64(s.CurrentMA)) > 20000 {
		return s, errors.New("implausible battery sample")
	}
	return s, nil
}

func safe(s sample) error {
	if !s.LidOpen || !s.AC || !s.RawAC || s.Percent < 28 || s.Percent > 85 {
		return errors.New("probe requires open lid, physical AC, and battery 28–85%")
	}
	return nil
}

type adapter interface {
	KeyInfo(string) (gosmc.KeyInfo, error)
	Read(string) (gosmc.Value, error)
	WriteBytes(string, []byte) error
}

func adapterValue(c adapter) (byte, error) {
	info, err := c.KeyInfo(key)
	if err != nil {
		return 0, err
	}
	v, err := c.Read(key)
	if err != nil {
		return 0, err
	}
	if info.Key != key || info.DataSize != 1 || info.DataType != "hex_" || v.Key != key || v.DataType != "hex_" || len(v.Bytes) != 1 {
		return 0, errors.New("CHIE metadata changed")
	}
	if v.Bytes[0] != 0 && v.Bytes[0] != 8 {
		return 0, errors.New("unknown CHIE flags; untouched")
	}
	return v.Bytes[0], nil
}

func restoreAdapter(c adapter) error {
	v, err := adapterValue(c)
	if err != nil || v == 0 {
		return err
	}
	if err = c.WriteBytes(key, []byte{0}); err != nil {
		return err
	}
	v, err = adapterValue(c)
	if err == nil && v != 0 {
		err = errors.New("CHIE restoration disagrees")
	}
	return err
}

// Restoration is attempted even if the cut reports an error: a failed reply
// does not prove that the write failed. There is never a second cut attempt.
func pulse(c adapter, sleep func(time.Duration)) (err error) {
	v, err := adapterValue(c)
	if err != nil {
		return err
	}
	if v != 0 {
		return errors.New("adapter is already held")
	}
	defer func() { err = errors.Join(err, restoreAdapter(c)) }()
	if err = c.WriteBytes(key, []byte{8}); err != nil {
		return err
	}
	sleep(pulseDuration)
	return nil
}

func held(s sample, requested, observed int) bool {
	return s.LidOpen && s.AC && s.RawAC && !s.Charging && math.Abs(float64(s.CurrentMA)) <= 100 && observed == requested && s.Percent >= requested
}

func privateFile(path string) ([]byte, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	u, ok := st.Sys().(*syscall.Stat_t)
	if !ok || u.Uid != uint32(os.Geteuid()) || !st.Mode().IsRegular() || st.Mode().Perm() != 0600 || st.Size() > 65536 {
		return nil, errors.New("unsafe snapshot file")
	}
	return io.ReadAll(io.LimitReader(f, 65537))
}

func privateDirectory(dir string) error {
	st, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	u, ok := st.Sys().(*syscall.Stat_t)
	if !ok || !st.IsDir() || st.Mode().Perm() != 0700 || u.Uid != uint32(os.Geteuid()) || !filepath.IsAbs(dir) {
		return errors.New("unsafe probe directory")
	}
	return nil
}

func baseline(c adapter) (sample, error) {
	s, err := readSample()
	if err != nil {
		return s, err
	}
	if err = safe(s); err != nil {
		return s, err
	}
	v, err := adapterValue(c)
	if err != nil {
		return s, err
	}
	if v != 0 {
		return s, errors.New("adapter not restored at baseline")
	}
	return s, nil
}

func actor(dir string) (result error) {
	if err := privateDirectory(dir); err != nil {
		return err
	}
	// An acknowledged arm from our independent parent is required before any
	// mutation. EOF, timeout or another command is a zero-write failure.
	var arm [1]byte
	if _, err := io.ReadFull(os.Stdin, arm[:]); err != nil || arm[0] != 'A' {
		return errors.New("actor not armed")
	}
	c, err := gosmc.Open()
	if err != nil {
		return err
	}
	defer c.Close()
	if _, err = baseline(c); err != nil {
		return err
	}
	native, err := powerui.New()
	if err != nil {
		return err
	}
	original, err := native.Read()
	if err != nil {
		return err
	}
	if !original.Enabled || original.Limit != 80 {
		return errors.New("original Apple 80% limit required")
	}
	if os.Getenv("WATTNOOK_PROBE_MODE") == "above" {
		return actorAbove(c)
	}
	// Only the independent guardian restores preferences/native MCL, after
	// this actor has exited. The pulse itself immediately restores CHIE.
	// A noncharging baseline at Apple's existing 80% limit cannot demonstrate
	// a new hold. Temporarily choose an advertised limit above this charge.
	if err = native.SetLimit(90); err != nil {
		return err
	}
	var s sample
	stable := 0
	for until := time.Now().Add(20 * time.Second); time.Now().Before(until); {
		s, err = baseline(c)
		if err != nil {
			return err
		}
		fmt.Printf("charging baseline: %+v\n", s)
		if s.Charging && s.CurrentMA > 100 {
			stable++
		} else {
			stable = 0
		}
		if stable >= 3 {
			break
		}
		time.Sleep(2 * time.Second)
	}
	if stable < 3 {
		return errors.New("stable active charging baseline not established; no hold or pulse issued")
	}
	// AlDente's hold uses the truncated current percentage. A target below
	// the current charge makes macOS discharge toward it while on AC.
	target := min(78, s.Percent)
	if _, _, err = preferences(1, target, nil); err != nil {
		return err
	}
	fmt.Printf("one hold target=%d; one pulse=%s\n", target, pulseDuration)
	if err = pulse(c, time.Sleep); err != nil {
		return err
	}
	stable = 0
	for i := 0; i < 24; i++ {
		time.Sleep(5 * time.Second)
		s, err = readSample()
		if err != nil {
			return err
		}
		_, observed, err := preferences(0, 0, nil)
		if err != nil {
			return err
		}
		v, err := adapterValue(c)
		if err != nil {
			return err
		}
		fmt.Printf("post-pulse sample=%+v CHIE=%02x requested=%d observed=%d\n", s, v, target, observed)
		if !s.LidOpen || s.Percent <= 25 || v != 0 {
			return errors.New("post-pulse safety condition failed")
		}
		if i >= 1 && (!s.AC || !s.RawAC) {
			return errors.New("adapter input did not remain restored")
		}
		if held(s, target, observed) {
			stable++
		} else {
			stable = 0
		}
	}
	if stable < 3 {
		return errors.New("charge-only hold NOT verified; no automatic mode enabled")
	}
	fmt.Println("VERIFIED: requested limit retained, adapter restored, no charging/discharging in final consecutive samples")
	return nil
}

// actorAbove tests a hold target ABOVE the current charge: does the Mac charge
// up to the target and then stop on AC? One preferences hold, one pulse,
// observation only; the guardian restores everything afterwards.
func actorAbove(c adapter) error {
	s, err := baseline(c)
	if err != nil {
		return err
	}
	target := s.Percent + 2
	if target > 95 {
		return errors.New("charge too high for an above-target test")
	}
	if _, _, err = preferences(1, target, nil); err != nil {
		return err
	}
	fmt.Printf("one hold target=%d (current %d); one pulse=%s\n", target, s.Percent, pulseDuration)
	if err = pulse(c, time.Sleep); err != nil {
		return err
	}
	sawCharging, stable := false, 0
	for i := 0; i < 40; i++ {
		time.Sleep(10 * time.Second)
		s, err = readSample()
		if err != nil {
			return err
		}
		_, observed, err := preferences(0, 0, nil)
		if err != nil {
			return err
		}
		v, err := adapterValue(c)
		if err != nil {
			return err
		}
		fmt.Printf("sample=%+v CHIE=%02x requested=%d observed=%d\n", s, v, target, observed)
		if !s.LidOpen || v != 0 || s.Percent > 96 || (i >= 1 && (!s.AC || !s.RawAC)) {
			return errors.New("safety condition failed")
		}
		if s.Charging && s.CurrentMA > 100 {
			sawCharging = true
		}
		if s.Percent >= target && held(s, target, observed) {
			stable++
		} else {
			stable = 0
		}
		if sawCharging && stable >= 3 {
			fmt.Println("VERIFIED: charged up to the target and held there on AC")
			return nil
		}
	}
	return fmt.Errorf("above-target hold NOT verified (sawCharging=%v)", sawCharging)
}

func recoverOriginal(c adapter, snapshot []byte) error {
	adapterErr := restoreAdapter(c)
	_, _, prefsErr := preferences(2, 0, snapshot)
	native, err := powerui.New()
	if err != nil {
		return errors.Join(adapterErr, prefsErr, err)
	}
	limitErr := native.SetLimit(80)
	state, readErr := native.Read()
	if readErr == nil && (!state.Enabled || state.Limit != 80) {
		readErr = errors.New("Apple limit restoration disagrees")
	}
	fmt.Printf("RECOVERY: adapter=%v preferences=%v limit=%v read=%+v error=%v\n", adapterErr, prefsErr, limitErr, state, readErr)
	return errors.Join(adapterErr, prefsErr, limitErr, readErr)
}

func recoverRecord(dir string) error {
	if err := privateDirectory(dir); err != nil {
		return err
	}
	var arm [1]byte
	if _, err := io.ReadFull(os.Stdin, arm[:]); err != nil || arm[0] != 'A' {
		return errors.New("recovery not armed")
	}
	snapshot, err := privateFile(filepath.Join(dir, "snapshot.plist"))
	if err != nil {
		return err
	}
	c, err := gosmc.Open()
	if err != nil {
		return err
	}
	defer c.Close()
	return recoverOriginal(c, snapshot)
}

// Keep process ownership and timeout handling independent of hardware code so
// real child crash/timeout fixtures exercise the same kill-and-reap path.
func executeActor(cmd *exec.Cmd, limit time.Duration, onArmed func()) error {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	input, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	if err = cmd.Start(); err != nil {
		input.Close()
		return err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	onArmed()
	if _, err = input.Write([]byte{'A'}); err != nil {
		input.Close()
		_ = cmd.Process.Kill()
		<-done
		return err
	}
	input.Close()
	select {
	case err = <-done:
		return err
	case <-time.After(limit):
		// Kill AND reap before restoring so a delayed actor cannot issue a
		// command after the independent owner restores the original state.
		killErr := cmd.Process.Kill()
		waitErr := <-done
		return errors.Join(errors.New("worker deadline; stopped and reaped; recovery state unknown"), killErr, waitErr)
	}
}

func guard(dir string) (result error) {
	if err := privateDirectory(dir); err != nil {
		return err
	}
	if err := privateDirectory("/var/db/wattnook-thermal"); err != nil {
		return err
	}
	lock, err := os.OpenFile("/var/db/wattnook-thermal/adapter.lock", os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return errors.New("adapter already owned; zero-write exit")
	}
	c, err := gosmc.Open()
	if err != nil {
		return err
	}
	defer c.Close()
	if _, err = baseline(c); err != nil {
		return err
	}
	native, err := powerui.New()
	if err != nil {
		return err
	}
	original, err := native.Read()
	if err != nil {
		return err
	}
	if !original.Enabled || original.Limit != 80 {
		return errors.New("original Apple 80% limit required")
	}
	snapshot, _, err := preferences(0, 0, nil)
	if err != nil {
		return err
	}
	path := filepath.Join(dir, "snapshot.plist")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return err
	}
	_, writeErr := f.Write(snapshot)
	err = errors.Join(writeErr, f.Sync(), f.Close())
	if err != nil {
		return err
	}
	snapshot, err = privateFile(path)
	if err != nil {
		return err
	}
	// Arm only after the recovery owner has the exact snapshot and independent
	// hardware connection. This defer runs after the actor has been reaped.
	armed := false
	defer func() {
		if !armed {
			return
		}
		// The recovery worker has its own deadline too: a stuck framework call
		// must not block the detached guard forever. Timeout is an explicit
		// recovery FAILURE, never a claim that original state was restored.
		recovery := exec.Command(os.Args[0], "--recover", dir)
		recovery.Stdout, recovery.Stderr = os.Stdout, os.Stderr
		result = errors.Join(result, executeActor(recovery, 20*time.Second, func() {}))
	}()
	cmd := exec.Command(os.Args[0], "--actor", dir)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	deadline := actorDeadline
	if os.Getenv("WATTNOOK_PROBE_MODE") == "above" {
		deadline = 460 * time.Second
	}
	return executeActor(cmd, deadline, func() { armed = true })
}

func run() error {
	c, err := gosmc.Open()
	if err != nil {
		return err
	}
	s, err := baseline(c)
	c.Close()
	if err != nil {
		return err
	}
	fmt.Printf("read-only preflight: %+v\n", s)
	dir, err := os.MkdirTemp("/private/tmp", "wattnook-charge-hold-")
	if err != nil {
		return err
	}
	fmt.Printf("private recovery record: %s\n", dir)
	log, err := os.OpenFile(filepath.Join(dir, "probe.log"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer log.Close()
	cmd := exec.Command(os.Args[0], "--guard", dir)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Stdout, cmd.Stderr = log, log
	if err = cmd.Start(); err != nil {
		return err
	}
	// The detached owner survives this supervisor exiting. It, not this
	// process, owns the deadline and restoration of the original settings.
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err = <-done:
	case <-time.After(540 * time.Second):
		// Do not kill the recovery owner while it may still own the writer.
		return errors.New("supervisor deadline: detached recovery owner still running; inspect private record")
	}
	bytes, readErr := os.ReadFile(filepath.Join(dir, "probe.log"))
	fmt.Print(string(bytes))
	return errors.Join(err, readErr)
}

func main() {
	var err error
	if len(os.Args) == 2 && os.Args[1] == "--read-only" {
		s, e := readSample()
		err = e
		_ = json.NewEncoder(os.Stdout).Encode(s)
	} else if os.Geteuid() != 0 {
		err = errors.New("administrator required; no mutation performed")
	} else if len(os.Args) == 2 && os.Args[1] == "--run-above" {
		// Children inherit the mode through the environment.
		_ = os.Setenv("WATTNOOK_PROBE_MODE", "above")
		err = run()
	} else if len(os.Args) == 2 && os.Args[1] == "--run-once" {
		err = run()
	} else if len(os.Args) == 3 && os.Args[1] == "--guard" {
		err = guard(os.Args[2])
	} else if len(os.Args) == 3 && os.Args[1] == "--actor" {
		err = actor(os.Args[2])
	} else if len(os.Args) == 3 && os.Args[1] == "--recover" {
		err = recoverRecord(os.Args[2])
	} else {
		err = errors.New("usage: charge-hold-probe --read-only | --run-once | --run-above")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
