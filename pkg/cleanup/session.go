package cleanup

import (
	"context"
	"sync"
	"time"
)

type Snapshot struct {
	ID       uint64
	Running  bool
	Progress Progress
	Report   *Report
}

// Session admits one worker, with no queued starts. Notify must be quick and
// non-reentrant (GUI adapters only enqueue a coalesced main-thread delivery).
type Session struct {
	mu              sync.Mutex
	scan            func(context.Context, func(Progress)) Report
	notify          func(Snapshot)
	cancel          context.CancelFunc
	running, closed bool
	id              uint64
	last            time.Time
}

func NewSession(scan func(context.Context, func(Progress)) Report, notify func(Snapshot)) *Session {
	return &Session{scan: scan, notify: notify}
}
func (s *Session) Start() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.running {
		return false
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	s.running = true
	s.id++
	id := s.id
	s.last = time.Now()
	if s.notify != nil {
		s.notify(Snapshot{ID: id, Running: true})
	}
	go func() {
		defer cancel()
		report := s.scan(ctx, func(p Progress) {
			s.mu.Lock()
			defer s.mu.Unlock()
			if !s.closed && s.id == id && time.Since(s.last) >= 200*time.Millisecond {
				s.last = time.Now()
				if s.notify != nil {
					s.notify(Snapshot{ID: id, Running: true, Progress: p})
				}
			}
		})
		s.mu.Lock()
		defer s.mu.Unlock()
		s.running = false
		s.cancel = nil
		if !s.closed && s.notify != nil {
			s.notify(Snapshot{ID: id, Report: &report})
		}
	}()
	return true
}
func (s *Session) Cancel() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cancel != nil {
		s.cancel()
	}
}
func (s *Session) Close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closed = true
	if s.cancel != nil {
		s.cancel()
	}
}
