package thermalguard

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"
)

type processFixtureHardware struct {
	fixtureHardware
	path string
}

func (h *processFixtureHardware) SetHeld(held bool) error {
	if err := h.fixtureHardware.SetHeld(held); err != nil {
		return err
	}
	return os.WriteFile(h.path, []byte(strconv.FormatBool(held)), 0600)
}

// Real detached processes exercise SIGKILL/pipe recovery against a file-backed
// fake actuator. No child in this test opens SMC or changes host power settings.
func TestDetachedRecoveryProcess(t *testing.T) {
	role := os.Getenv("WATT_THERMAL_FIXTURE_ROLE")
	dir := os.Getenv("WATT_THERMAL_FIXTURE_DIR")
	if role == "guard" {
		g := &Guard{Hardware: &processFixtureHardware{path: filepath.Join(dir, "held")}, Journal: fileJournal{path: filepath.Join(dir, "journal.json")}}
		if err := Serve(os.Stdin, os.Stdout, g, time.Second); err != nil {
			os.Exit(2)
		}
		os.Exit(0)
	}
	if role == "parent" {
		cmd := exec.Command(os.Args[0], "-test.run=^TestDetachedRecoveryProcess$")
		cmd.Env = append(os.Environ(), "WATT_THERMAL_FIXTURE_ROLE=guard")
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		input, err := cmd.StdinPipe()
		if err != nil {
			os.Exit(3)
		}
		output, err := cmd.StdoutPipe()
		if err != nil {
			os.Exit(4)
		}
		if err = cmd.Start(); err != nil {
			os.Exit(5)
		}
		_ = os.WriteFile(filepath.Join(dir, "guard-pid"), []byte(strconv.Itoa(cmd.Process.Pid)), 0600)
		decoder := json.NewDecoder(output)
		var reply Reply
		if decoder.Decode(&reply) != nil {
			os.Exit(6)
		}
		if _, err = fmt.Fprintln(input, "hold"); err != nil {
			os.Exit(7)
		}
		if decoder.Decode(&reply) != nil || !reply.Owned || reply.Observed != "held" {
			os.Exit(8)
		}
		if os.WriteFile(filepath.Join(dir, "ready"), []byte("yes"), 0600) != nil {
			os.Exit(9)
		}
		time.Sleep(time.Minute)
		os.Exit(10)
	}
	dir = t.TempDir()
	cmd := exec.Command(os.Args[0], "-test.run=^TestDetachedRecoveryProcess$")
	cmd.Env = append(os.Environ(), "WATT_THERMAL_FIXTURE_ROLE=parent", "WATT_THERMAL_FIXTURE_DIR="+dir)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill() })
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(dir, "ready")); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("fixture parent failed to reach held state")
		}
		time.Sleep(10 * time.Millisecond)
	}
	pidBytes, err := os.ReadFile(filepath.Join(dir, "guard-pid"))
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(string(pidBytes))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = syscall.Kill(pid, syscall.SIGKILL) })
	if err = cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	_ = cmd.Wait()
	deadline = time.Now().Add(5 * time.Second)
	for {
		owned, recovered, err := (fileJournal{path: filepath.Join(dir, "journal.json")}).Load()
		held, readErr := os.ReadFile(filepath.Join(dir, "held"))
		if err == nil && readErr == nil && !owned && recovered && string(held) == "false" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("detached recovery failed: owned=%t recovered=%t held=%q err=%v", owned, recovered, held, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}
