package thermalguard

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"

	"github.com/charlie0129/batt/pkg/powerui"
	"github.com/charlie0129/batt/pkg/smc"
	"github.com/charlie0129/gosmc"
	"github.com/peterneutron/powerkit-go/pkg/powerkit"
)

type nativeHardware struct{ c *gosmc.Client }

func (h *nativeHardware) Read() (string, error) {
	info, err := h.c.KeyInfo(smc.AdapterKey3)
	if err != nil {
		return "unknown", err
	}
	v, err := h.c.Read(smc.AdapterKey3)
	if err != nil {
		return "unknown", err
	}
	if info.Key != smc.AdapterKey3 || info.DataType != "hex_" || info.DataSize != 1 || v.Key != smc.AdapterKey3 || v.DataType != "hex_" || len(v.Bytes) != 1 {
		return "unknown", errors.New("CHIE encoding changed")
	}
	switch v.Bytes[0] {
	case 0:
		return "restored", nil
	case 8:
		return "held", nil
	}
	return "unknown", errors.New("unknown CHIE flags; adapter untouched")
}

func (h *nativeHardware) Sample() (Sample, error) {
	info, err := powerkit.GetSystemInfo(powerkit.FetchOptions{QueryIOKit: true, QuerySMC: false})
	if err != nil {
		return Sample{}, err
	}
	if info == nil || info.IOKit == nil {
		return Sample{}, errors.New("battery data unavailable")
	}
	b := info.IOKit
	temperature, err := readBatteryTemperature(h.c, b.Battery.Temperature)
	if err != nil {
		return Sample{}, err
	}
	return Sample{Percent: float64(b.Battery.CurrentCharge), Temperature: temperature,
		Connected: b.State.IsConnected, Charging: b.State.IsCharging, At: time.Now()}, nil
}

func (h *nativeHardware) SetHeld(held bool) error {
	if held {
		native, err := powerui.New()
		if err != nil {
			return err
		}
		if _, err = native.Read(); err != nil {
			return err
		}
	}
	state, err := h.Read()
	if err != nil {
		return err
	}
	target, value := "restored", byte(0)
	if held {
		target, value = "held", 8
	}
	if state == target {
		return nil
	}
	if err := h.c.WriteBytes(smc.AdapterKey3, []byte{value}); err != nil {
		return err
	}
	for deadline := time.Now().Add(8 * time.Second); time.Now().Before(deadline); {
		state, err = h.Read()
		if err != nil {
			return err
		}
		if state == target {
			if !held {
				return nil
			}
			sample, err := h.Sample()
			if err != nil {
				return err
			}
			if !sample.Connected && !sample.Charging {
				return nil
			}
		}
		time.Sleep(250 * time.Millisecond)
	}
	return errors.New("adapter physical transition was not confirmed")
}

type fileJournal struct{ path string }
type record struct {
	Version   int  `json:"version"`
	Owned     bool `json:"owned"`
	Recovered bool `json:"recovered"`
}

func (j fileJournal) Load() (bool, bool, error) {
	f, err := os.OpenFile(j.path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if os.IsNotExist(err) {
		return false, false, nil
	}
	if err != nil {
		return false, false, err
	}
	defer f.Close()
	var r record
	if err = json.NewDecoder(f).Decode(&r); err != nil {
		return false, false, err
	}
	if r.Version != 1 {
		return false, false, errors.New("unknown thermal recovery record")
	}
	return r.Owned, r.Recovered, nil
}

func (j fileJournal) Save(owned, recovered bool) error {
	f, err := os.CreateTemp(filepath.Dir(j.path), ".thermal-state-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	err = json.NewEncoder(f).Encode(record{Version: 1, Owned: owned, Recovered: recovered})
	if err == nil {
		err = f.Sync()
	}
	err = errors.Join(err, f.Close())
	if err != nil {
		return err
	}
	if err = os.Rename(f.Name(), j.path); err != nil {
		return err
	}
	dir, err := os.Open(filepath.Dir(j.path))
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

// RunNative has one process-wide owner across configs. The root-only state
// directory keeps the recovery record and lock outside user-writable paths.
func RunNative(statePath string) error {
	if os.Geteuid() != 0 {
		return errors.New("thermal guardian requires administrator service")
	}
	if !filepath.IsAbs(statePath) {
		return errors.New("absolute thermal state path required")
	}
	dir := filepath.Dir(statePath)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.IsDir() || info.Mode().Perm()&0077 != 0 || stat.Uid != 0 {
		return errors.New("thermal state directory must be root-owned and private")
	}
	lock, err := os.OpenFile(filepath.Join(dir, "adapter.lock"), os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return fmt.Errorf("another thermal guardian owns the adapter: %w", err)
	}
	c, err := gosmc.Open()
	if err != nil {
		return err
	}
	defer c.Close()
	// Recovery must also work if Apple's native-limit service is unavailable.
	// Only a new hold checks that service; this process never changes its limit.
	return Serve(os.Stdin, os.Stdout, &Guard{Hardware: &nativeHardware{c: c}, Journal: fileJournal{path: statePath}}, Lease)
}
