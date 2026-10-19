package main

import (
	"github.com/charlie0129/batt/pkg/thermalguard"
	"github.com/spf13/cobra"
)

func NewThermalGuardianCommand() *cobra.Command {
	var statePath string
	cmd := &cobra.Command{Use: "thermal-guardian", Hidden: true, Args: cobra.NoArgs,
		PersistentPreRunE: func(*cobra.Command, []string) error { return nil },
		RunE:              func(*cobra.Command, []string) error { return thermalguard.RunNative(statePath) }}
	cmd.Flags().StringVar(&statePath, "state-path", "/var/db/wattnook-thermal/adapter.json", "Private recovery state")
	return cmd
}
