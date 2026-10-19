// Package chargehold pauses battery charging while the wall adapter keeps
// powering the Mac, on firmware without SMC charge-inhibit keys (macOS 27).
//
// The sequence mirrors AlDente 1.39.4's PreferencesBackend hold, verified on a
// Mac16,12 (docs/aldente-backend-research-20261017.md): write a top-off
// protection hold at the current percentage, post the defaults-changed
// notification, then pulse the CHIE adapter key 08 -> 500 ms -> 00 so powerd
// re-evaluates. Release restores the saved preferences and pulses again.
package chargehold

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"
	"time"

	"github.com/charlie0129/gosmc"
)

const (
	AdapterKey    = "CHIE"
	PulseDuration = 500 * time.Millisecond
	MinTarget     = 5
	MaxTarget     = 99
)

// Preferences owns com.apple.smartcharging.topoffprotection in the root
// CurrentUser/AnyHost scope.
type Preferences interface {
	// Snapshot returns an opaque copy of every touched key and the saved
	// mclLimitValue (-1 when absent).
	Snapshot() (data []byte, limit int, err error)
	Hold(target int) error
	Restore(snapshot []byte) error
}

// SMC is the subset of pkg/smc.AppleSMC used for the adapter pulse.
type SMC interface {
	Read(key string) (gosmc.Value, error)
	Write(key string, value []byte) error
}

func adapterValue(c SMC) (byte, error) {
	v, err := c.Read(AdapterKey)
	if err != nil {
		return 0, err
	}
	if v.Key != AdapterKey || v.DataType != "hex_" || len(v.Bytes) != 1 {
		return 0, errors.New("CHIE encoding changed")
	}
	if v.Bytes[0] != 0 && v.Bytes[0] != 8 {
		return 0, fmt.Errorf("unknown CHIE flags %#02x; adapter untouched", v.Bytes[0])
	}
	return v.Bytes[0], nil
}

// Pulse briefly inhibits adapter input once. Restoration is attempted even if
// the inhibit write reports an error, and is verified by readback.
func Pulse(c SMC, sleep func(time.Duration)) (err error) {
	v, err := adapterValue(c)
	if err != nil {
		return err
	}
	if v != 0 {
		return errors.New("adapter input already inhibited; pulse skipped")
	}
	defer func() {
		restoreErr := c.Write(AdapterKey, []byte{0})
		if restoreErr == nil {
			var after byte
			after, restoreErr = adapterValue(c)
			if restoreErr == nil && after != 0 {
				restoreErr = errors.New("CHIE restoration readback disagrees")
			}
		}
		err = errors.Join(err, restoreErr)
	}()
	if err = c.Write(AdapterKey, []byte{8}); err != nil {
		return err
	}
	sleep(PulseDuration)
	return nil
}

type record struct {
	Version     int    `json:"version"`
	Limit       int    `json:"limit"`
	Preferences []byte `json:"preferences"`
}

// Store persists the pre-hold snapshot. Its presence means a hold is active,
// so a restarted daemon can always release a hold left by a crash.
type Store struct{ Path string }

func (s Store) load() (record, error) {
	f, err := os.OpenFile(s.Path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return record{}, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return record{}, err
	}
	if !st.Mode().IsRegular() || st.Mode().Perm()&0o077 != 0 || st.Size() > 1<<20 {
		return record{}, errors.New("unsafe charge-hold record")
	}
	var r record
	if err := json.NewDecoder(f).Decode(&r); err != nil {
		return record{}, fmt.Errorf("decode charge-hold record: %w", err)
	}
	if r.Version != 1 || len(r.Preferences) == 0 {
		return record{}, errors.New("invalid charge-hold record")
	}
	return r, nil
}

func (s Store) save(r record) error {
	if err := os.MkdirAll(filepath.Dir(s.Path), 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(r)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(s.Path, os.O_CREATE|os.O_EXCL|os.O_WRONLY|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return err
	}
	_, writeErr := f.Write(data)
	if err = errors.Join(writeErr, f.Sync(), f.Close()); err != nil {
		_ = os.Remove(s.Path)
	}
	return err
}

func (s Store) remove() error {
	if err := os.Remove(s.Path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

// Holder performs hold and release transitions. It is not safe for
// concurrent use; the daemon calls it under its maintain-loop lock.
type Holder struct {
	Prefs Preferences
	SMC   SMC
	Store Store
	Sleep func(time.Duration)
}

// Active reports whether a hold record exists.
func (h *Holder) Active() bool {
	_, err := os.Lstat(h.Store.Path)
	return err == nil
}

// SavedLimit returns the mclLimitValue saved before the active hold.
func (h *Holder) SavedLimit() (int, bool) {
	r, err := h.Store.load()
	if err != nil || r.Limit < 0 {
		return 0, false
	}
	return r.Limit, true
}

// Hold pauses charging at target. The original preferences are saved first
// and are never overwritten by a later hold. On failure they are restored.
func (h *Holder) Hold(target int) (err error) {
	if target < MinTarget || target > MaxTarget {
		return fmt.Errorf("hold target %d outside %d–%d", target, MinTarget, MaxTarget)
	}
	if h.Active() {
		return errors.New("charge hold already active")
	}
	snapshot, limit, err := h.Prefs.Snapshot()
	if err != nil {
		return fmt.Errorf("snapshot charging preferences: %w", err)
	}
	if err = h.Store.save(record{Version: 1, Limit: limit, Preferences: snapshot}); err != nil {
		return fmt.Errorf("save charge-hold record: %w", err)
	}
	defer func() {
		if err == nil {
			return
		}
		// Undo without a pulse: a failed pulse must not be retried here.
		if restoreErr := h.Prefs.Restore(snapshot); restoreErr != nil {
			err = errors.Join(err, fmt.Errorf("restore preferences: %w", restoreErr))
			return
		}
		err = errors.Join(err, h.Store.remove())
	}()
	if err = h.Prefs.Hold(target); err != nil {
		return fmt.Errorf("write charge hold: %w", err)
	}
	if err = Pulse(h.SMC, h.Sleep); err != nil {
		return fmt.Errorf("adapter pulse: %w", err)
	}
	return nil
}

// Release restores the saved preferences. The record is removed once the
// preferences are restored, so a failing pulse is never repeated by retries.
func (h *Holder) Release() error {
	r, err := h.Store.load()
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if err = h.Prefs.Restore(r.Preferences); err != nil {
		return fmt.Errorf("restore charging preferences: %w", err)
	}
	if err = h.Store.remove(); err != nil {
		return err
	}
	if err = Pulse(h.SMC, h.Sleep); err != nil {
		return fmt.Errorf("preferences restored; adapter pulse failed: %w", err)
	}
	return nil
}
