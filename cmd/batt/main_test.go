package main

import (
	"os"
	"testing"

	"github.com/spf13/cobra"

	"github.com/charlie0129/batt/pkg/compatibility"
)

func TestNativeAppLaunchDefaults(t *testing.T) {
	oldArgs, oldSocket := os.Args, unixSocketPath
	t.Cleanup(func() { os.Args, unixSocketPath = oldArgs, oldSocket })
	t.Setenv("BATT_RUN_GUI", "")
	os.Args = []string{"/Applications/WattNook.app/Contents/MacOS/WattNook"}
	unixSocketPath = "/var/run/batt.sock"
	cmd := NewCommand()
	if cmd.Run == nil {
		t.Fatal("native app executable must open the GUI without a shell launcher")
	}
	if got := cmd.Flag("daemon-socket").DefValue; got != "/var/run/batt-thermal.sock" {
		t.Fatalf("app socket = %q", got)
	}
	if err := cmd.ParseFlags([]string{"--daemon-socket=/tmp/wattnook-test.sock"}); err != nil {
		t.Fatal(err)
	}
	if unixSocketPath != "/tmp/wattnook-test.sock" {
		t.Fatal("explicit socket override must be preserved")
	}
}

func TestRequiredCapabilityInheritedFromParentCommand(t *testing.T) {
	root := &cobra.Command{Use: "batt"}
	parent := annotateCapability(&cobra.Command{Use: "adapter"}, compatibility.FeatureAdapterControl)
	child := &cobra.Command{Use: "disable"}
	parent.AddCommand(child)
	root.AddCommand(parent)

	got, ok := requiredCapability(child)
	if !ok || got != compatibility.FeatureAdapterControl {
		t.Fatalf("requiredCapability() = %q, %t", got, ok)
	}
}

func TestHideUnsupportedCommands(t *testing.T) {
	root := NewCommand()
	hideUnsupportedCommands(root, compatibility.Capabilities{
		ChargingControl:   true,
		ChargeControlMode: compatibility.ChargeControlFirmware,
	})

	tests := map[string]bool{
		"limit":                      false,
		"lower-limit-delta":          false,
		"status":                     false,
		"adapter":                    true,
		"prevent-idle-sleep":         true,
		"disable-charging-pre-sleep": true,
		"prevent-system-sleep":       true,
		"magsafe-led":                true,
		"calibration":                true,
		"schedule":                   true,
	}
	for name, wantHidden := range tests {
		cmd, _, err := root.Find([]string{name})
		if err != nil {
			t.Fatalf("find %s: %v", name, err)
		}
		if cmd.Hidden != wantHidden {
			t.Errorf("%s hidden = %t, want %t", name, cmd.Hidden, wantHidden)
		}
	}
}
