// Package thermalguard owns the adapter while a thermal pause is active.
// It runs in a detached child: loss of its parent's pipe restores wall power.
package thermalguard

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"time"
)

const Lease = 30 * time.Second

type Sample struct {
	Percent     float64   `json:"percent"`
	Temperature float64   `json:"temperature"`
	Connected   bool      `json:"connected"`
	Charging    bool      `json:"charging"`
	At          time.Time `json:"at"`
}

type Reply struct {
	Observed  string `json:"observed"`
	Owned     bool   `json:"owned"`
	Recovered bool   `json:"recovered"`
	Sample    Sample `json:"sample"`
	Error     string `json:"error,omitempty"`
}

type Hardware interface {
	Read() (string, error)
	SetHeld(bool) error
	Sample() (Sample, error)
}

type Journal interface {
	Load() (owned, recovered bool, err error)
	Save(owned, recovered bool) error
}

type Guard struct {
	Hardware         Hardware
	Journal          Journal
	owned, recovered bool
	lastTransition   time.Time
}

func (g *Guard) Initialize() error {
	var err error
	g.owned, g.recovered, err = g.Journal.Load()
	if err != nil {
		return err
	}
	if g.owned {
		return g.Recover()
	}
	state, err := g.Hardware.Read()
	if err != nil {
		return err
	}
	if state != "restored" {
		return errors.New("adapter already held by another owner")
	}
	return nil
}

func (g *Guard) restore() error {
	if !g.owned {
		return nil
	}
	state, err := g.Hardware.Read()
	if err != nil {
		return err
	}
	if state == "held" {
		if err := g.Hardware.SetHeld(false); err != nil {
			return err
		}
		g.lastTransition = time.Now()
		state, err = g.Hardware.Read()
		if err != nil {
			return err
		}
	}
	if state != "restored" {
		return errors.New("adapter restoration readback unknown")
	}
	if err := g.Journal.Save(false, g.recovered); err != nil {
		return err
	}
	g.owned = false
	return nil
}

// Recover is bounded and may only enable an adapter with our durable ownership.
func (g *Guard) Recover() error {
	if !g.owned {
		return nil
	}
	g.recovered = true
	var err error
	for i := 0; i < 3; i++ {
		if i > 0 {
			time.Sleep(300 * time.Millisecond)
		}
		if err = g.restore(); err == nil {
			return nil
		}
	}
	return fmt.Errorf("emergency adapter restoration: %w", err)
}

func (g *Guard) Execute(command string) Reply {
	var err error
	switch command {
	case "status":
	case "reset":
		if g.owned {
			err = errors.New("restore adapter before resetting fault")
		} else {
			err = g.Journal.Save(false, false)
			if err == nil {
				g.recovered = false
			}
		}
	case "restore", "close":
		err = g.restore()
	case "hold":
		if g.recovered {
			err = errors.New("recovered after interruption; explicitly re-enable heat protection")
			break
		}
		if g.owned {
			break
		}
		if !g.lastTransition.IsZero() && time.Since(g.lastTransition) < time.Minute {
			err = errors.New("adapter transition cooldown")
			break
		}
		sample, readErr := g.Hardware.Sample()
		if readErr != nil {
			err = readErr
			break
		}
		if !sample.Connected || math.IsNaN(sample.Percent) || math.IsInf(sample.Percent, 0) || sample.Percent <= 25 || sample.Percent > 100 ||
			math.IsNaN(sample.Temperature) || math.IsInf(sample.Temperature, 0) || sample.Temperature <= 0 || sample.Temperature > 100 ||
			sample.At.IsZero() || time.Since(sample.At) > 5*time.Second || sample.At.After(time.Now()) {
			err = errors.New("adapter cut requires fresh battery data, AC and more than 25% reserve")
			break
		}
		state, readErr := g.Hardware.Read()
		if readErr != nil {
			err = readErr
			break
		}
		if state != "restored" {
			err = errors.New("adapter ownership conflict")
			break
		}
		// Persist before a write that could succeed even if its acknowledgement fails.
		if err = g.Journal.Save(true, false); err != nil {
			break
		}
		g.owned = true
		g.lastTransition = time.Now()
		err = g.Hardware.SetHeld(true)
		if err == nil {
			state, err = g.Hardware.Read()
			if err == nil && state != "held" {
				err = errors.New("adapter cut readback disagrees")
			}
		}
	default:
		err = errors.New("unknown thermal guardian command")
	}
	if err != nil {
		err = errors.Join(err, g.Recover())
	}
	reply := Reply{Owned: g.owned, Recovered: g.recovered}
	var readErr error
	reply.Observed, readErr = g.Hardware.Read()
	if err == nil {
		err = readErr
	}
	var sampleErr error
	reply.Sample, sampleErr = g.Hardware.Sample()
	if err == nil {
		err = sampleErr
	}
	if reply.Observed == "held" && (!g.owned || reply.Sample.Connected || reply.Sample.Charging) {
		reply.Observed = "unknown"
		if err == nil {
			err = errors.New("adapter and battery readings disagree")
		}
	}
	if err != nil {
		reply.Error = err.Error()
	}
	return reply
}

// Serve restores on EOF, malformed input, an expired heartbeat or process exit.
// The event loop alone owns the hardware; the reader goroutine never writes it.
func Serve(input io.Reader, output io.Writer, guard *Guard, lease time.Duration) (result error) {
	if lease <= 0 {
		return errors.New("positive guardian lease required")
	}
	if err := guard.Initialize(); err != nil {
		return err
	}
	defer func() { result = errors.Join(result, guard.Recover()) }()
	encoder := json.NewEncoder(output)
	if err := encoder.Encode(guard.Execute("status")); err != nil {
		return err
	}
	commands := make(chan string)
	go func() {
		defer close(commands)
		scanner := bufio.NewScanner(input)
		scanner.Buffer(make([]byte, 128), 1024)
		for scanner.Scan() {
			select {
			case commands <- scanner.Text():
			case <-time.After(lease):
				return
			}
		}
	}()
	timer := time.NewTimer(lease)
	defer timer.Stop()
	for {
		select {
		case command, ok := <-commands:
			if !ok {
				return nil
			}
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(lease)
			reply := guard.Execute(command)
			if err := encoder.Encode(reply); err != nil {
				return err
			}
			if reply.Error != "" {
				return errors.New(reply.Error)
			}
			if command == "close" {
				return nil
			}
		case <-timer.C:
			return errors.New("thermal guardian heartbeat expired")
		}
	}
}
