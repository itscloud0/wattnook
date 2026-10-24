package gui

/*
#include <stdlib.h>
#include "native.h"
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync/atomic"
	"time"
	"unsafe"

	"github.com/charlie0129/batt/pkg/usage"
	"github.com/sirupsen/logrus"
)

var aiUsageBusy atomic.Bool

//export battAIUsageRequested
func battAIUsageRequested(handle C.uintptr_t) {
	defer recoverNativeCallback("battAIUsageRequested")
	c := controllerForHandle(handle)
	if !aiUsageBusy.CompareAndSwap(false, true) {
		return
	}
	go func() {
		defer aiUsageBusy.Store(false)
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		// In WattAIProviderIDs() order.
		providers := []struct {
			name string
			read func(context.Context) (usage.Limits, error)
		}{
			{"Claude", usage.Claude().ClaudeLimits},
			{"ChatGPT", usage.Codex().CodexLimits},
			{"Grok", usage.GrokBot().GrokLimits},
		}
		var left [C.WATT_AI_PROVIDERS * 2]C.double
		notes := make([]string, len(providers))
		for i, p := range providers {
			limits, err := p.read(ctx)
			left[i*2] = C.double(windowLeft(limits.Session, err))
			left[i*2+1] = C.double(windowLeft(limits.Week, err))
			notes[i] = describeLimits(p.name, limits, err, time.Now())
		}
		joined := C.CString(strings.Join(notes, "\n"))
		runOnMain(func() {
			defer C.free(unsafe.Pointer(joined))
			C.batt_menu_set_ai_usage(c.menu.ref, &left[0], joined)
		})
	}()
}

// windowLeft is the percentage still available, or -1 when there is nothing to show.
func windowLeft(w *usage.Window, err error) float64 {
	if err != nil || w == nil {
		return -1
	}
	return 100 - w.Percent
}

// usageApp is the app that keeps each provider's login or reading fresh.
var usageApp = map[string]string{"Claude": "Claude Code", "ChatGPT": "Codex", "Grok": "Grok Bot"}

// describeLimits is the provider's tooltip line, e.g.
// "Claude: 5-hour 66% left (resets 21:00), week 88% left (resets Thu 08:00)".
func describeLimits(name string, limits usage.Limits, err error, now time.Time) string {
	switch {
	case errors.Is(err, usage.ErrNotSignedIn):
		return ""
	case errors.Is(err, usage.ErrTokenExpired):
		return name + ": login expired — open " + usageApp[name] + " to refresh it"
	case err != nil:
		logrus.WithError(err).WithField("provider", name).Debug("usage unavailable")
		return name + ": usage unavailable"
	}
	var parts []string
	for _, w := range []struct {
		label  string
		window *usage.Window
	}{{"5-hour", limits.Session}, {"week", limits.Week}} {
		if w.window == nil {
			continue
		}
		part := fmt.Sprintf("%s %.0f%% left", w.label, 100-w.window.Percent)
		if !w.window.ResetsAt.IsZero() {
			part += " (resets " + resetTime(w.window.ResetsAt.Local(), now.Local()) + ")"
		}
		parts = append(parts, part)
	}
	if !limits.AsOf.IsZero() {
		// A cached reading: say how old it is, or that it predates the reset.
		if len(parts) == 0 {
			return name + ": weekly limit reset — open " + usageApp[name] + " to refresh it"
		}
		parts = append(parts, "as of "+resetTime(limits.AsOf.Local(), now.Local()))
	}
	if len(parts) == 0 {
		return ""
	}
	return name + ": " + strings.Join(parts, ", ")
}

func resetTime(at, now time.Time) string {
	y1, m1, d1 := at.Date()
	y2, m2, d2 := now.Date()
	if y1 == y2 && m1 == m2 && d1 == d2 {
		return at.Format("15:04")
	}
	return at.Format("Mon 15:04")
}
