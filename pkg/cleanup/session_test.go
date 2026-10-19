package cleanup

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

func TestSessionSingleFlightCancelAndTerminal(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	updates := make(chan Snapshot, 10)
	s := NewSession(func(ctx context.Context, p func(Progress)) Report {
		close(started)
		p(Progress{1})
		<-ctx.Done()
		<-release
		return Report{State: "canceled"}
	}, func(v Snapshot) { updates <- v })
	if !s.Start() {
		t.Fatal("start")
	}
	<-started
	if s.Start() {
		t.Fatal("overlap")
	}
	s.Cancel()
	if s.Start() {
		t.Fatal("canceled worker still running")
	}
	close(release)
	timeout := time.After(time.Second)
	for {
		select {
		case v := <-updates:
			if !v.Running {
				if v.Report == nil || v.Report.State != "canceled" {
					t.Fatal(v)
				}
				s.Close()
				return
			}
		case <-timeout:
			t.Fatal("no terminal state")
		}
	}
}
func TestSessionCloseDropsLateResults(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	done := make(chan struct{})
	var delivered atomic.Int32
	s := NewSession(func(ctx context.Context, p func(Progress)) Report {
		close(started)
		<-release
		close(done)
		return Report{State: "complete"}
	}, func(v Snapshot) { delivered.Add(1) })
	s.Start()
	<-started
	s.Close()
	before := delivered.Load()
	close(release)
	<-done
	if s.Start() {
		t.Fatal("closed restart")
	}
	s.Close()
	if delivered.Load() != before {
		t.Fatal("late callback")
	}
}
func TestSessionProgressIsBounded(t *testing.T) {
	done := make(chan struct{})
	var updates atomic.Int32
	s := NewSession(func(ctx context.Context, p func(Progress)) Report {
		for i := 0; i < 10000; i++ {
			p(Progress{uint64(i)})
		}
		return Report{State: "complete"}
	}, func(v Snapshot) {
		updates.Add(1)
		if !v.Running {
			close(done)
		}
	})
	s.Start()
	<-done
	s.Close()
	if updates.Load() > 3 {
		t.Fatal(updates.Load())
	}
}
