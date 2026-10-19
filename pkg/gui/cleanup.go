package gui

import (
	"context"
	"encoding/json"
	"github.com/charlie0129/batt/pkg/cleanup"
	"os"
	"sync"
	"time"
)

type storageUpdate struct {
	generation uint64
	snapshot   cleanup.Snapshot
}
type storageAdapter struct {
	mu                   sync.Mutex
	scan                 func(context.Context, func(cleanup.Progress)) cleanup.Report
	dispatch             func(func())
	deliver              func(uint64, []byte)
	session              *cleanup.Session
	busy, closed, queued bool
	generation, active   uint64
	pending              *storageUpdate
}

func newStorageAdapter(scan func(context.Context, func(cleanup.Progress)) cleanup.Report, dispatch func(func()), deliver func(uint64, []byte)) *storageAdapter {
	return &storageAdapter{scan: scan, dispatch: dispatch, deliver: deliver}
}
func (a *storageAdapter) offer(g uint64, s cleanup.Snapshot) {
	a.offerSession(g, nil, s)
}
func (a *storageAdapter) offerSession(g uint64, source *cleanup.Session, s cleanup.Snapshot) {
	a.mu.Lock()
	if a.closed || g != a.generation || (source != nil && source != a.session) {
		a.mu.Unlock()
		return
	}
	a.pending = &storageUpdate{g, s}
	schedule := !a.queued
	a.queued = true
	a.mu.Unlock()
	if schedule {
		a.dispatch(a.flush)
	}
}
func (a *storageAdapter) flush() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.queued = false
	v := a.pending
	a.pending = nil
	if a.closed || v == nil || v.generation != a.generation {
		return
	}
	var payload any = v.snapshot.Report
	if v.snapshot.Running {
		payload = struct {
			State   string `json:"state"`
			Visited uint64 `json:"visited"`
		}{"running", v.snapshot.Progress.Visited}
	}
	b, err := json.Marshal(payload)
	if err == nil {
		a.deliver(v.generation, b)
	}
}
func (a *storageAdapter) action(g uint64, action int) {
	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		return
	}
	if action == 2 || action == 3 {
		s := a.session
		valid := g == a.generation
		if action == 3 && valid {
			a.generation = 0
			a.pending = nil
		}
		a.mu.Unlock()
		if valid && s != nil {
			if action == 3 {
				s.Close()
			} else {
				s.Cancel()
			}
		}
		return
	}
	if action != 1 || g == 0 {
		a.mu.Unlock()
		return
	}
	a.generation = g
	if a.busy {
		other := a.active != g
		a.mu.Unlock()
		if other {
			r := cleanup.Report{State: "error", Reason: "Previous scan is stopping. Try Rescan shortly."}
			a.offer(g, cleanup.Snapshot{Report: &r})
		}
		return
	}
	a.busy = true
	a.active = g
	a.pending = nil
	var s *cleanup.Session
	s = cleanup.NewSession(func(ctx context.Context, p func(cleanup.Progress)) cleanup.Report {
		defer func() {
			a.mu.Lock()
			if a.session == s {
				a.busy = false
			}
			a.mu.Unlock()
		}()
		return a.scan(ctx, p)
	}, func(v cleanup.Snapshot) { a.offerSession(g, s, v) })
	a.session = s
	a.mu.Unlock()
	if !s.Start() {
		a.mu.Lock()
		if a.session == s {
			a.busy = false
		}
		a.mu.Unlock()
	}
}
func (a *storageAdapter) close() {
	a.mu.Lock()
	a.closed = true
	a.pending = nil
	s := a.session
	a.mu.Unlock()
	if s != nil {
		s.Close()
	}
}

func userStorageScan(ctx context.Context, p func(cleanup.Progress)) cleanup.Report {
	errorReport := func(reason string) cleanup.Report {
		return cleanup.Report{State: "error", Reason: reason, StartedAt: time.Now(), FinishedAt: time.Now()}
	}
	if os.Geteuid() == 0 {
		return errorReport("Run WattNook as your normal user, not root.")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return errorReport("Home directory unavailable")
	}
	return cleanup.ScanApplicationStorage(ctx, home, cleanup.Limits{}, inspectStorageApplication, p)
}
