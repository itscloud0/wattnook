package daemon

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// The WattNook helper is the privileged charging daemon the app talks to.
// It runs a root-owned copy of the app binary, so the app itself can be
// moved or updated without breaking launchd.
const (
	HelperLabel  = "io.iliasorokin.batt-thermal"
	HelperPlist  = "/Library/LaunchDaemons/" + HelperLabel + ".plist"
	HelperBinary = "/usr/local/libexec/batt-thermal/batt-thermal"
	HelperConfig = "/etc/batt-thermal.json"
	HelperSocket = "/var/run/batt-thermal.sock"
	HelperLog    = "/var/log/batt-thermal.log"
)

// HelperPlistContents is the launchd job for the helper.
func HelperPlistContents() string {
	return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>` + HelperLabel + `</string>
	<key>ProgramArguments</key>
	<array>
		<string>` + HelperBinary + `</string>
		<string>daemon</string>
		<string>--always-allow-non-root-access</string>
		<string>--config=` + HelperConfig + `</string>
		<string>--daemon-socket=` + HelperSocket + `</string>
	</array>
	<key>KeepAlive</key>
	<true/>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>` + HelperLog + `</string>
	<key>StandardErrorPath</key>
	<string>` + HelperLog + `</string>
</dict>
</plist>
`
}

// HelperInstalled reports whether the helper's launchd job is present.
func HelperInstalled() bool {
	_, err := os.Stat(HelperPlist)
	return err == nil
}

func copyExecutable(source, target string) error {
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	staged := target + ".new"
	out, err := os.OpenFile(staged, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
	if err != nil {
		return err
	}
	if _, err = io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(staged)
		return err
	}
	if err = errors.Join(out.Sync(), out.Close(), os.Chown(staged, 0, 0), os.Chmod(staged, 0o755)); err != nil {
		os.Remove(staged)
		return err
	}
	return os.Rename(staged, target)
}

func launchctl(args ...string) error {
	output, err := exec.Command("/bin/launchctl", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("launchctl %v: %w: %s", args, err, bytes.TrimSpace(output))
	}
	return nil
}

// InstallHelper installs or upgrades the helper from source (normally the
// running app binary). It must run as root. Existing settings in
// HelperConfig are kept; the daemon restores charge holds when it stops.
func InstallHelper(source string) error {
	if os.Geteuid() != 0 {
		return errors.New("installing the helper requires administrator rights")
	}
	// Stop the old helper first so it releases holds and frees its socket.
	stopHelper()
	if err := copyExecutable(source, HelperBinary); err != nil {
		return fmt.Errorf("copy helper: %w", err)
	}
	if err := os.WriteFile(HelperPlist, []byte(HelperPlistContents()), 0o644); err != nil {
		return fmt.Errorf("write %s: %w", HelperPlist, err)
	}
	if err := os.Chown(HelperPlist, 0, 0); err != nil {
		return err
	}
	_ = launchctl("enable", "system/"+HelperLabel)
	// launchd can still be tearing the old job down; retry briefly.
	var err error
	for attempt := 0; attempt < 5; attempt++ {
		if err = launchctl("bootstrap", "system", HelperPlist); err == nil || helperLoaded() {
			return nil
		}
		time.Sleep(time.Second)
	}
	return err
}

func helperLoaded() bool {
	return exec.Command("/bin/launchctl", "print", "system/"+HelperLabel).Run() == nil
}

// stopHelper boots the job out and waits until launchd has removed it.
func stopHelper() {
	_ = launchctl("bootout", "system/"+HelperLabel)
	for deadline := time.Now().Add(10 * time.Second); helperLoaded() && time.Now().Before(deadline); {
		time.Sleep(200 * time.Millisecond)
	}
}

// UninstallHelper stops and removes the helper. Stopping lets the daemon
// release any charge hold before it exits.
func UninstallHelper() error {
	if os.Geteuid() != 0 {
		return errors.New("removing the helper requires administrator rights")
	}
	stopHelper()
	return errors.Join(removeIfExists(HelperPlist), removeIfExists(HelperBinary))
}

func removeIfExists(path string) error {
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
