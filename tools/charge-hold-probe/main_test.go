package main

import (
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/charlie0129/gosmc"
)

type fakeAdapter struct {
	value     byte
	writes    []byte
	uncertain bool
}

func (f *fakeAdapter) KeyInfo(k string) (gosmc.KeyInfo, error) {
	return gosmc.KeyInfo{Key: k, DataSize: 1, DataType: "hex_"}, nil
}
func (f *fakeAdapter) Read(k string) (gosmc.Value, error) {
	return gosmc.Value{Key: k, DataType: "hex_", Bytes: []byte{f.value}}, nil
}
func (f *fakeAdapter) WriteBytes(k string, b []byte) error {
	if k != key || len(b) != 1 {
		return errors.New("unexpected write")
	}
	f.writes = append(f.writes, b[0])
	f.value = b[0]
	if f.uncertain && b[0] == 8 {
		return errors.New("write completion unknown")
	}
	return nil
}

func TestPulseOneCutAndRestore(t *testing.T) {
	f := &fakeAdapter{}
	var waited time.Duration
	if err := pulse(f, func(d time.Duration) { waited = d }); err != nil {
		t.Fatal(err)
	}
	if waited != 500*time.Millisecond || !reflect.DeepEqual(f.writes, []byte{8, 0}) {
		t.Fatalf("wait=%s writes=%v", waited, f.writes)
	}
}

func TestUncertainCutStillRestoresWithoutRetry(t *testing.T) {
	f := &fakeAdapter{uncertain: true}
	if err := pulse(f, func(time.Duration) { t.Fatal("must not wait after uncertain cut") }); err == nil {
		t.Fatal("uncertainty hidden")
	}
	if !reflect.DeepEqual(f.writes, []byte{8, 0}) {
		t.Fatalf("writes=%v", f.writes)
	}
}

func TestForeignOrUnknownAdapterUntouched(t *testing.T) {
	for _, v := range []byte{4, 8} {
		f := &fakeAdapter{value: v}
		if err := pulse(f, func(time.Duration) { t.Fatal("unexpected wait") }); err == nil || len(f.writes) != 0 {
			t.Fatalf("value=%d writes=%v error=%v", v, f.writes, err)
		}
	}
}

func TestHoldRequiresPhysicalACActualPauseAndRetainedTarget(t *testing.T) {
	good := sample{Percent: 70, AC: true, RawAC: true, LidOpen: true}
	if !held(good, 68, 68) {
		t.Fatal("valid state rejected")
	}
	for name, bad := range map[string]sample{
		"adapter cut":                   {Percent: 70, LidOpen: true},
		"raw adapter missing":           {Percent: 70, AC: true, LidOpen: true},
		"charging":                      {Percent: 70, AC: true, RawAC: true, LidOpen: true, Charging: true},
		"discharging":                   {Percent: 70, AC: true, RawAC: true, LidOpen: true, CurrentMA: -400},
		"positive current despite flag": {Percent: 70, AC: true, RawAC: true, LidOpen: true, CurrentMA: 400},
		"closed lid":                    {Percent: 70, AC: true, RawAC: true},
	} {
		if held(bad, 68, 68) {
			t.Fatalf("accepted %s", name)
		}
	}
	if held(good, 68, 80) {
		t.Fatal("Apple clamped target to80 accepted")
	}
	if !held(good, 70, 70) {
		t.Fatal("hold at current charge rejected")
	}
	if held(good, 72, 72) {
		t.Fatal("charge below target accepted")
	}
}

func TestPrivateSnapshotRejectsSymlinkAndLoosePermissions(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "snapshot")
	if err := os.WriteFile(p, []byte("data"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := privateFile(p); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(p, filepath.Join(dir, "link")); err != nil {
		t.Fatal(err)
	}
	if _, err := privateFile(filepath.Join(dir, "link")); err == nil {
		t.Fatal("symlink accepted")
	}
	if err := os.Chmod(p, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := privateFile(p); err == nil {
		t.Fatal("loose permissions accepted")
	}
}

func TestInvalidPreferencesCommandsDoNotMutate(t *testing.T) {
	for _, target := range []int{0, 25, 79, 80, 100} {
		if _, _, err := preferences(1, target, nil); err == nil {
			t.Fatalf("target=%d accepted", target)
		}
	}
	if _, _, err := preferences(2, 0, []byte("not a property list")); err == nil {
		t.Fatal("invalid snapshot accepted")
	}
	if _, _, err := preferences(9, 0, nil); err == nil {
		t.Fatal("unknown operation accepted")
	}
}

func TestFieldRejectsAmbiguousTelemetry(t *testing.T) {
	if v, err := field("  |   \"CurrentCapacity\" = 70\n", "CurrentCapacity"); err != nil || v != "70" {
		t.Fatalf("%q %v", v, err)
	}
	if _, err := field("  |   \"CurrentCapacity\" = 70\n  |   \"CurrentCapacity\" = 71\n", "CurrentCapacity"); err == nil {
		t.Fatal("ambiguous field accepted")
	}
}

// A real detached child exercises the same arm, crash and kill/reap code as
// the hardware actor. It never calls preferences, SMC or a native setter.
func TestActorFixture(t *testing.T) {
	mode := os.Getenv("WATTNOOK_HOLD_FIXTURE")
	if mode == "" {
		return
	}
	var b [1]byte
	if _, err := io.ReadFull(os.Stdin, b[:]); err != nil || b[0] != 'A' {
		os.Exit(13)
	}
	if mode == "crash" {
		os.Exit(12)
	}
	if mode == "hang" {
		time.Sleep(600 * time.Millisecond)
		_ = os.WriteFile(os.Getenv("WATTNOOK_HOLD_MARKER"), []byte("late write"), 0600)
	}
	os.Exit(0)
}

func TestActorDeadlineReapsBeforeRecovery(t *testing.T) {
	for _, mode := range []string{"success", "crash", "hang"} {
		t.Run(mode, func(t *testing.T) {
			marker := filepath.Join(t.TempDir(), "late")
			cmd := exec.Command(os.Args[0], "-test.run=^TestActorFixture$")
			cmd.Env = append(os.Environ(), "WATTNOOK_HOLD_FIXTURE="+mode, "WATTNOOK_HOLD_MARKER="+marker)
			armed := false
			limit := 150 * time.Millisecond
			if mode != "hang" {
				limit = 3 * time.Second
			}
			err := executeActor(cmd, limit, func() { armed = true })
			if !armed || cmd.ProcessState == nil || (mode == "success") != (err == nil) {
				t.Fatalf("armed=%v state=%v err=%v", armed, cmd.ProcessState, err)
			}
			if mode == "hang" {
				if !strings.Contains(err.Error(), "deadline") {
					t.Fatal(err)
				}
				time.Sleep(650 * time.Millisecond)
				if _, err := os.Stat(marker); !os.IsNotExist(err) {
					t.Fatal("actor survived recovery boundary")
				}
			}
		})
	}
}
