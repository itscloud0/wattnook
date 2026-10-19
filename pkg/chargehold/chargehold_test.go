package chargehold

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/charlie0129/gosmc"
)

type fakeSMC struct {
	value    byte
	dataType gosmc.DataType
	writes   []byte
	failSet  bool
}

func (f *fakeSMC) Read(key string) (gosmc.Value, error) {
	dataType := f.dataType
	if dataType == "" {
		dataType = "hex_"
	}
	return gosmc.Value{Key: key, DataType: dataType, Bytes: []byte{f.value}}, nil
}

func (f *fakeSMC) Write(_ string, v []byte) error {
	f.writes = append(f.writes, v[0])
	if f.failSet && v[0] == 8 {
		return errors.New("write failed")
	}
	f.value = v[0]
	return nil
}

type fakePrefs struct {
	ops         []string
	held        int
	failHold    bool
	failRestore bool
}

func (p *fakePrefs) Snapshot() ([]byte, int, error) {
	p.ops = append(p.ops, "snapshot")
	return []byte("original"), 80, nil
}

func (p *fakePrefs) Hold(target int) error {
	p.ops = append(p.ops, "hold")
	if p.failHold {
		return errors.New("hold failed")
	}
	p.held = target
	return nil
}

func (p *fakePrefs) Restore(s []byte) error {
	p.ops = append(p.ops, "restore:"+string(s))
	if p.failRestore {
		return errors.New("restore failed")
	}
	p.held = 0
	return nil
}

func newHolder(t *testing.T) (*Holder, *fakePrefs, *fakeSMC, *[]time.Duration) {
	var sleeps []time.Duration
	prefs, smc := &fakePrefs{}, &fakeSMC{}
	return &Holder{Prefs: prefs, SMC: smc, Store: Store{Path: filepath.Join(t.TempDir(), "hold", "record.json")},
		Sleep: func(d time.Duration) { sleeps = append(sleeps, d) }}, prefs, smc, &sleeps
}

func TestPulseInhibitsOnceAndRestores(t *testing.T) {
	smc := &fakeSMC{}
	var slept time.Duration
	if err := Pulse(smc, func(d time.Duration) { slept = d }); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(smc.writes, []byte{8, 0}) || slept != PulseDuration || smc.value != 0 {
		t.Fatalf("writes=%v slept=%s value=%d", smc.writes, slept, smc.value)
	}
}

func TestPulseRestoresAfterFailedInhibit(t *testing.T) {
	smc := &fakeSMC{failSet: true}
	if err := Pulse(smc, func(time.Duration) { t.Fatal("slept after failed write") }); err == nil {
		t.Fatal("expected error")
	}
	if !reflect.DeepEqual(smc.writes, []byte{8, 0}) {
		t.Fatalf("writes=%v", smc.writes)
	}
}

func TestPulseReportsRestorationReadbackMismatch(t *testing.T) {
	// Firmware that ignores the restore write must surface an error.
	stuck := &stuckSMC{fakeSMC: &fakeSMC{}}
	if err := Pulse(stuck, func(time.Duration) {}); err == nil {
		t.Fatal("expected readback error")
	}
}

type stuckSMC struct{ *fakeSMC }

func (s *stuckSMC) Write(k string, v []byte) error {
	s.writes = append(s.writes, v[0])
	if v[0] == 8 {
		s.value = 8
	}
	return nil
}

func TestPulseRefusesUnknownOrHeldAdapter(t *testing.T) {
	for _, smc := range []*fakeSMC{{value: 8}, {value: 4}, {dataType: "ui8"}} {
		if err := Pulse(smc, func(time.Duration) {}); err == nil || len(smc.writes) != 0 {
			t.Fatalf("value=%d type=%s writes=%v err=%v", smc.value, smc.dataType, smc.writes, err)
		}
	}
}

func TestHoldSavesSnapshotThenHoldsAndPulses(t *testing.T) {
	h, prefs, smc, sleeps := newHolder(t)
	if err := h.Hold(72); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(prefs.ops, []string{"snapshot", "hold"}) || prefs.held != 72 {
		t.Fatalf("ops=%v held=%d", prefs.ops, prefs.held)
	}
	if !reflect.DeepEqual(smc.writes, []byte{8, 0}) || len(*sleeps) != 1 {
		t.Fatalf("writes=%v sleeps=%v", smc.writes, *sleeps)
	}
	if !h.Active() {
		t.Fatal("hold record missing")
	}
	if limit, ok := h.SavedLimit(); !ok || limit != 80 {
		t.Fatalf("limit=%d ok=%v", limit, ok)
	}
	info, err := os.Stat(h.Store.Path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("record mode %v err=%v", info, err)
	}
	if err := h.Hold(70); err == nil {
		t.Fatal("second hold must not overwrite the original snapshot")
	}
}

func TestHoldRejectsTargetsOutsideRange(t *testing.T) {
	h, prefs, smc, _ := newHolder(t)
	for _, target := range []int{0, 4, 100} {
		if err := h.Hold(target); err == nil {
			t.Fatalf("accepted %d", target)
		}
	}
	if len(prefs.ops) != 0 || len(smc.writes) != 0 || h.Active() {
		t.Fatalf("ops=%v writes=%v", prefs.ops, smc.writes)
	}
}

func TestFailedHoldRestoresPreferencesWithoutPulse(t *testing.T) {
	h, prefs, smc, _ := newHolder(t)
	prefs.failHold = true
	if err := h.Hold(72); err == nil {
		t.Fatal("expected error")
	}
	if !reflect.DeepEqual(prefs.ops, []string{"snapshot", "hold", "restore:original"}) || len(smc.writes) != 0 || h.Active() {
		t.Fatalf("ops=%v writes=%v active=%v", prefs.ops, smc.writes, h.Active())
	}
}

func TestFailedPulseRestoresPreferences(t *testing.T) {
	h, prefs, smc, _ := newHolder(t)
	smc.value = 8
	if err := h.Hold(72); err == nil {
		t.Fatal("expected error")
	}
	if !reflect.DeepEqual(prefs.ops, []string{"snapshot", "hold", "restore:original"}) || h.Active() {
		t.Fatalf("ops=%v active=%v", prefs.ops, h.Active())
	}
}

func TestFailedUndoKeepsRecordForRelease(t *testing.T) {
	h, prefs, _, _ := newHolder(t)
	prefs.failHold, prefs.failRestore = true, true
	if err := h.Hold(72); err == nil {
		t.Fatal("expected error")
	}
	if !h.Active() {
		t.Fatal("record must survive a failed undo so release can retry")
	}
}

func TestReleaseRestoresRemovesRecordThenPulses(t *testing.T) {
	h, prefs, smc, _ := newHolder(t)
	if err := h.Hold(72); err != nil {
		t.Fatal(err)
	}
	prefs.ops, smc.writes = nil, nil
	if err := h.Release(); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(prefs.ops, []string{"restore:original"}) || !reflect.DeepEqual(smc.writes, []byte{8, 0}) || h.Active() {
		t.Fatalf("ops=%v writes=%v active=%v", prefs.ops, smc.writes, h.Active())
	}
	prefs.ops, smc.writes = nil, nil
	if err := h.Release(); err != nil || len(prefs.ops) != 0 || len(smc.writes) != 0 {
		t.Fatalf("idle release err=%v ops=%v writes=%v", err, prefs.ops, smc.writes)
	}
}

func TestReleaseKeepsRecordWhenRestoreFails(t *testing.T) {
	h, prefs, smc, _ := newHolder(t)
	if err := h.Hold(72); err != nil {
		t.Fatal(err)
	}
	prefs.failRestore, smc.writes = true, nil
	if err := h.Release(); err == nil {
		t.Fatal("expected error")
	}
	if !h.Active() || len(smc.writes) != 0 {
		t.Fatalf("active=%v writes=%v", h.Active(), smc.writes)
	}
}

func TestReleaseFailedPulseIsNotRetried(t *testing.T) {
	h, _, smc, _ := newHolder(t)
	if err := h.Hold(72); err != nil {
		t.Fatal(err)
	}
	smc.value = 8
	if err := h.Release(); err == nil {
		t.Fatal("expected pulse error")
	}
	if h.Active() {
		t.Fatal("restored preferences must clear the record")
	}
}

func TestStoreRejectsUnsafeRecord(t *testing.T) {
	path := filepath.Join(t.TempDir(), "record.json")
	if err := os.WriteFile(path, []byte(`{"version":1,"limit":80,"preferences":"b3JpZ2luYWw="}`), 0o644); err != nil {
		t.Fatal(err)
	}
	h := &Holder{Prefs: &fakePrefs{}, SMC: &fakeSMC{}, Store: Store{Path: path}, Sleep: func(time.Duration) {}}
	if err := h.Release(); err == nil {
		t.Fatal("world-readable record accepted")
	}
}
