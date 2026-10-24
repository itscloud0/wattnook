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
		claude, claudeErr := usage.Claude().ClaudeLimits(ctx)
		codex, codexErr := usage.Codex().CodexLimits(ctx)
		claudeNote := describeLimits("Claude", claude, claudeErr, time.Now())
		codexNote := describeLimits("ChatGPT", codex, codexErr, time.Now())
		runOnMain(func() {
			withTwoCStrings(claudeNote, codexNote, func(cn, xn *C.char) {
				C.batt_menu_set_ai_usage(c.menu.ref,
					C.double(windowPercent(claude.Session, claudeErr)), C.double(windowPercent(claude.Week, claudeErr)), cn,
					C.double(windowPercent(codex.Session, codexErr)), C.double(windowPercent(codex.Week, codexErr)), xn)
			})
		})
	}()
}

// windowPercent is the used percentage, or -1 when there is nothing to show.
func windowPercent(w *usage.Window, err error) float64 {
	if err != nil || w == nil {
		return -1
	}
	return w.Percent
}

// describeLimits is the provider's tooltip line, e.g.
// "Claude: 5-hour 34% (resets 21:00), week 12% (resets Thu 08:00)".
func describeLimits(name string, limits usage.Limits, err error, now time.Time) string {
	switch {
	case errors.Is(err, usage.ErrNotSignedIn):
		return ""
	case errors.Is(err, usage.ErrTokenExpired):
		return name + ": login expired — open " + map[string]string{"Claude": "Claude Code", "ChatGPT": "Codex"}[name] + " to refresh it"
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
		part := fmt.Sprintf("%s %.0f%%", w.label, w.window.Percent)
		if !w.window.ResetsAt.IsZero() {
			part += " (resets " + resetTime(w.window.ResetsAt.Local(), now.Local()) + ")"
		}
		parts = append(parts, part)
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
