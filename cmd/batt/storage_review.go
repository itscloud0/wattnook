package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"time"

	"github.com/charlie0129/batt/pkg/cleanup"
	"github.com/spf13/cobra"
)

func NewStorageReviewCommand() *cobra.Command {
	return newStorageReviewCommand(func(ctx context.Context) cleanup.Report {
		home, err := os.UserHomeDir()
		var roots []cleanup.Root
		if err == nil {
			roots, err = cleanup.UserRoots(home)
		}
		if err != nil {
			return cleanup.Report{State: "error", Reason: "Home directory unavailable", StartedAt: time.Now(), FinishedAt: time.Now()}
		}
		return cleanup.Scan(ctx, roots, cleanup.Limits{}, nil)
	}, os.Geteuid)
}
func newStorageReviewCommand(scan func(context.Context) cleanup.Report, uid func() int) *cobra.Command {
	var jsonOutput bool
	cmd := &cobra.Command{Use: "storage-review", Short: "Inspect user cache/log sizes without deleting files", Args: cobra.NoArgs,
		SilenceUsage: true,
		// This is independent of the privileged charging daemon, even when nested.
		PersistentPreRunE: func(*cobra.Command, []string) error { return setupLogger() },
		RunE: func(cmd *cobra.Command, args []string) error {
			// Cobra Print defaults to stderr; report output belongs on stdout.
			cmd.SetOut(cmd.OutOrStdout())
			if uid() == 0 {
				return fmt.Errorf("storage review must run as your normal user, not root")
			}
			ctx, cancel := signal.NotifyContext(cmd.Context(), os.Interrupt)
			defer cancel()
			r := scan(ctx)
			if jsonOutput {
				if err := json.NewEncoder(cmd.OutOrStdout()).Encode(r); err != nil {
					return err
				}
			} else {
				cmd.Printf("Storage review: %s — observed %.1f MB\n", r.State, float64(r.Bytes)/1000000)
				for _, o := range r.Observations {
					cmd.Printf("%.1f MB\t%s\t%s", float64(o.Bytes)/1000000, o.Category, strconv.QuoteToGraphic(o.Path))
					if !o.Complete {
						cmd.Print(" [partial]")
					}
					cmd.Println()
				}
				for _, root := range r.Roots {
					if root.State != "complete" {
						cmd.Printf("Location %s: %s\n", strconv.QuoteToGraphic(root.Path), root.State)
					}
				}
				if r.Reason != "" {
					cmd.Println(r.Reason)
				}
				cmd.Println("Logical file sizes, non-atomic snapshot; not reclaimable space. Nothing was deleted.")
			}
			return r.Error()
		},
	}
	cmd.Flags().BoolVar(&jsonOutput, "json", false, "Output one JSON report")
	return cmd
}
