// Package powerui controls Apple's native charge limit without SMC or adapter writes.
package powerui

import (
	"errors"
	"fmt"
	"slices"
	"sync"
	"time"
)

type State struct {
	Limit   int
	Enabled bool
	Limits  []int
}

func (s State) EffectiveLimit() int {
	if !s.Enabled {
		return 100
	}
	return s.Limit
}

type backend interface {
	Read() (State, error)
	Set(int) error
}

// Controller allows at most one in-flight framework call. A stalled private
// framework must not create an unbounded queue of goroutines or delayed writes.
type Controller struct {
	backend backend
	mu      sync.Mutex
	timeout time.Duration
}

func newController(b backend, timeout time.Duration) *Controller {
	return &Controller{backend: b, timeout: timeout}
}

func (c *Controller) run(fn func() (State, error)) (State, error) {
	if !c.mu.TryLock() {
		return State{}, errors.New("native charge control busy; refresh before retrying")
	}
	type result struct {
		state State
		err   error
	}
	done := make(chan result, 1)
	go func() {
		r := func() result {
			defer c.mu.Unlock()
			s, err := fn()
			return result{s, err}
		}()
		// Release the slot before publishing completion; an immediate follow-up
		// read must not spuriously fail as busy after a successful operation.
		done <- r
	}()
	timer := time.NewTimer(c.timeout)
	defer timer.Stop()
	select {
	case r := <-done:
		return r.state, r.err
	case <-timer.C:
		return State{}, errors.New("native charge control timed out; state unknown, refresh before retrying")
	}
}

func (c *Controller) read() (State, error) {
	s, err := c.backend.Read()
	if err != nil {
		return State{}, err
	}
	if len(s.Limits) == 0 {
		return State{}, errors.New("no native charge limits available")
	}
	for _, v := range s.Limits {
		if v < 80 || v > 100 {
			return State{}, errors.New("invalid native charge limits")
		}
	}
	if !slices.Contains(s.Limits, s.Limit) {
		return State{}, errors.New("invalid native charge limit readback")
	}
	return s, nil
}

func (c *Controller) Read() (State, error) { return c.run(c.read) }

func (c *Controller) SetLimit(limit int) error {
	_, err := c.run(func() (State, error) {
		// Always refresh, including after an uncertain prior write. Never retry a
		// setter automatically, or restore historical configuration on reads.
		s, err := c.read()
		if err != nil {
			return State{}, err
		}
		if !slices.Contains(s.Limits, limit) {
			return State{}, fmt.Errorf("native charge limit must be one of %v", s.Limits)
		}
		if (limit < 100 && s.Enabled && s.Limit == limit) || (limit == 100 && !s.Enabled) {
			return s, nil
		}
		if err := c.backend.Set(limit); err != nil {
			return State{}, fmt.Errorf("native limit change uncertain: %w", err)
		}
		s, err = c.read()
		if err != nil {
			return State{}, fmt.Errorf("native limit readback failed: %w", err)
		}
		if s.EffectiveLimit() != limit || (limit == 100 && s.Enabled) {
			return State{}, errors.New("native limit readback disagrees; state unknown")
		}
		return s, nil
	})
	return err
}
