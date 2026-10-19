package main

import (
	"bytes"
	"context"
	"encoding/json"
	"github.com/charlie0129/batt/pkg/cleanup"
	"github.com/spf13/cobra"
	"strings"
	"testing"
)

func TestStorageReviewWithoutDaemonAndJSON(t *testing.T) {
	root := NewCommand()
	found, _, err := root.Find([]string{"storage-review"})
	if err != nil || found == root {
		t.Fatal("missing command", err)
	}
	root.RemoveCommand(found)
	cmd := newStorageReviewCommand(func(context.Context) cleanup.Report {
		return cleanup.Report{State: "complete", Observations: []cleanup.Observation{{DisplayPath: "a\\n", Bytes: 8}}}
	}, func() int { return 501 })
	root.AddCommand(cmd)
	root.PersistentPreRunE = func(*cobra.Command, []string) error { t.Fatal("daemon initialization"); return nil }
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&out)
	root.SetArgs([]string{"storage-review", "--json"})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	if !json.Valid(out.Bytes()) {
		t.Fatal(out.String())
	}
}
func TestStorageReviewRejectsRootAndReportsPartial(t *testing.T) {
	calls := 0
	factory := func(context.Context) cleanup.Report {
		calls++
		return cleanup.Report{State: "partial", Reason: "Entry limit reached"}
	}
	cmd := newStorageReviewCommand(factory, func() int { return 0 })
	if err := cmd.Execute(); err == nil || calls != 0 {
		t.Fatal(err, calls)
	}
	cmd = newStorageReviewCommand(factory, func() int { return 501 })
	var out bytes.Buffer
	cmd.SetOut(&out)
	if err := cmd.Execute(); err == nil || !strings.Contains(out.String(), "partial") {
		t.Fatal(err, out.String())
	}
}

func TestStorageReviewTerminalReportsAndEscapes(t *testing.T) {
	for _, state := range []string{"complete", "partial", "canceled", "error"} {
		t.Run(state, func(t *testing.T) {
			cmd := newStorageReviewCommand(func(context.Context) cleanup.Report {
				return cleanup.Report{State: state, Reason: "fixture", Observations: []cleanup.Observation{{Path: "line\n\x1bname", Category: "cache", Bytes: 8, Complete: state == "complete"}}}
			}, func() int { return 501 })
			var out, diagnostics bytes.Buffer
			cmd.SetOut(&out)
			cmd.SetErr(&diagnostics)
			err := cmd.Execute()
			if (err == nil) != (state == "complete") {
				t.Fatal(state, err)
			}
			text := out.String()
			if !strings.Contains(text, state) || strings.Contains(text, "\x1b") || !strings.Contains(text, `line\n\x1bname`) {
				t.Fatal(text)
			}
		})
	}
}
