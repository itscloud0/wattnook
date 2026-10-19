package main

import (
	"errors"
	"testing"

	"github.com/charlie0129/gosmc"
)

type fakeAdapter struct {
	value       byte
	reads       int
	writes      int
	writeErr    error
	failWrites  int
	readbackBad bool
}

func (f *fakeAdapter) KeyInfo(key string) (gosmc.KeyInfo, error) {
	return gosmc.KeyInfo{Key: key, DataSize: 1, DataType: "hex_"}, nil
}

func (f *fakeAdapter) Read(key string) (gosmc.Value, error) {
	f.reads++
	value := f.value
	if f.readbackBad && f.reads > 1 {
		value = 8
	}
	return gosmc.Value{Key: key, DataType: "hex_", Bytes: []byte{value}}, nil
}

func (f *fakeAdapter) WriteBytes(key string, bytes []byte) error {
	f.writes++
	if key != adapterKey || len(bytes) != 1 || bytes[0] != 0 {
		return errors.New("unexpected restoration command")
	}
	if f.writeErr != nil {
		return f.writeErr
	}
	if f.failWrites > 0 {
		f.failWrites--
		return errors.New("transient SMC busy")
	}
	f.value = 0
	return nil
}

func TestRestoreRetriesOnlyTheEnableCommand(t *testing.T) {
	f := &fakeAdapter{value: 8, failWrites: 1}
	if err := restoreWithRetries(f); err != nil {
		t.Fatal(err)
	}
	if f.value != 0 || f.writes != 2 {
		t.Fatalf("restoration value=%d writes=%d", f.value, f.writes)
	}
	unknown := &fakeAdapter{value: 4}
	if err := restoreWithRetries(unknown); err == nil || unknown.writes != 0 {
		t.Fatalf("unknown state must remain untouched: err=%v writes=%d", err, unknown.writes)
	}
}

func TestRestoreOnlyKnownHeldState(t *testing.T) {
	for _, test := range []struct {
		name        string
		value       byte
		writeErr    error
		readbackBad bool
		wantWrites  int
		wantErr     bool
	}{
		{"already restored", 0, nil, false, 0, false},
		{"held", 8, nil, false, 1, false},
		{"unknown bits", 4, nil, false, 0, true},
		{"write failure", 8, errors.New("write failed"), false, 1, true},
		{"readback failure", 8, nil, true, 1, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := &fakeAdapter{value: test.value, writeErr: test.writeErr, readbackBad: test.readbackBad}
			err := restore(f)
			if (err != nil) != test.wantErr || f.writes != test.wantWrites {
				t.Fatalf("restore error=%v writes=%d; wantErr=%t wantWrites=%d", err, f.writes, test.wantErr, test.wantWrites)
			}
		})
	}
}

func TestFieldRejectsMissingAndDuplicate(t *testing.T) {
	if value, err := field("  |   \"CurrentCapacity\" = 27\n", "CurrentCapacity"); err != nil || value != "27" {
		t.Fatalf("current capacity parse = %q, %v", value, err)
	}
	for _, input := range []string{"", "  |   \"CurrentCapacity\" = 27\n  |   \"CurrentCapacity\" = 28\n"} {
		if _, err := field(input, "CurrentCapacity"); err == nil {
			t.Fatal("unreliable battery field accepted")
		}
	}
}
