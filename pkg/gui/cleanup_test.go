package gui

import (
	"context"
	"encoding/json"
	"github.com/charlie0129/batt/pkg/cleanup"
	"sync"
	"testing"
	"time"
)

func TestStorageAdapterCoalescesAndRejectsClosedGeneration(t *testing.T) {
	var mu sync.Mutex
	var queued []func()
	var delivered []uint64
	dispatch := func(f func()) { mu.Lock(); queued = append(queued, f); mu.Unlock() }
	started := make(chan struct{})
	release := make(chan struct{})
	done := make(chan struct{})
	a := newStorageAdapter(func(ctx context.Context, p func(cleanup.Progress)) cleanup.Report {
		close(started)
		<-release
		close(done)
		return cleanup.Report{State: "complete"}
	}, dispatch, func(g uint64, b []byte) { delivered = append(delivered, g) })
	a.action(1, 1)
	<-started
	a.action(1, 1)
	a.action(1, 3)
	a.action(2, 1)
	mu.Lock()
	batch := queued
	queued = nil
	mu.Unlock()
	for _, f := range batch {
		f()
	}
	if len(delivered) > 1 {
		t.Fatal(delivered)
	}
	for _, g := range delivered {
		if g != 2 {
			t.Fatal("stale delivery", g)
		}
	}
	close(release)
	<-done
	a.close()
	mu.Lock()
	batch = queued
	queued = nil
	mu.Unlock()
	for _, f := range batch {
		f()
	}
}
func TestStorageAdapterFinalStateAndShutdown(t *testing.T) {
	updates := make(chan []byte, 4)
	done := make(chan struct{})
	a := newStorageAdapter(func(ctx context.Context, p func(cleanup.Progress)) cleanup.Report {
		defer close(done)
		return cleanup.Report{State: "complete", Bytes: 8}
	}, func(f func()) { go f() }, func(g uint64, b []byte) { updates <- b })
	a.action(1, 1)
	<-done
	for {
		select {
		case b := <-updates:
			var r cleanup.Report
			if err := json.Unmarshal(b, &r); err != nil {
				t.Fatal(err)
			}
			if r.State == "complete" {
				if r.Bytes != 8 {
					t.Fatal(r)
				}
				a.close()
				a.action(2, 1)
				return
			}
		case <-time.After(5 * time.Second):
			t.Fatal("terminal report not delivered")
		}
	}
}

func TestStorageAdapterRejectsOldSessionInSameWindow(t *testing.T) {
	var queued []func()
	var states []string
	a := newStorageAdapter(nil, func(f func()) { queued = append(queued, f) }, func(g uint64, b []byte) {
		var r cleanup.Report
		_ = json.Unmarshal(b, &r)
		states = append(states, r.State)
	})
	old := cleanup.NewSession(nil, nil)
	current := cleanup.NewSession(nil, nil)
	a.generation = 1
	a.session = current
	a.offerSession(1, current, cleanup.Snapshot{Running: true})
	r := cleanup.Report{State: "complete"}
	a.offerSession(1, old, cleanup.Snapshot{Report: &r})
	for _, f := range queued {
		f()
	}
	if len(states) != 1 || states[0] != "running" {
		t.Fatal(states)
	}
}
