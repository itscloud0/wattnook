package gui

import (
	"testing"
	"time"

	"github.com/charlie0129/batt/pkg/usage"
)

func TestUsageShowsWhatIsLeft(t *testing.T) {
	now := time.Date(2026, 10, 25, 12, 0, 0, 0, time.Local)
	limits := usage.Limits{
		Session: &usage.Window{Percent: 34, ResetsAt: now.Add(2 * time.Hour)},
		Week:    &usage.Window{Percent: 12},
	}
	if got := describeLimits("Claude", limits, nil, now); got != "Claude: 5-hour 66% left (resets 14:00), week 88% left" {
		t.Fatalf("note = %q", got)
	}
	if windowLeft(limits.Session, nil) != 66 || windowLeft(nil, nil) != -1 || windowLeft(limits.Week, usage.ErrTokenExpired) != -1 {
		t.Fatal("windowLeft")
	}
}
