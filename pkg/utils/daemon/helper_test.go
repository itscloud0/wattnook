package daemon

import (
	"strings"
	"testing"
)

func TestHelperPlistMatchesAppSocket(t *testing.T) {
	plist := HelperPlistContents()
	for _, want := range []string{HelperLabel, HelperBinary, "--daemon-socket=" + HelperSocket,
		"--config=" + HelperConfig, "--always-allow-non-root-access", "<key>KeepAlive</key>"} {
		if !strings.Contains(plist, want) {
			t.Fatalf("plist missing %q", want)
		}
	}
	if HelperSocket != "/var/run/batt-thermal.sock" {
		t.Fatal("the app connects to /var/run/batt-thermal.sock")
	}
}
