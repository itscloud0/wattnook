package cleanup

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLeftoverCandidatesMatchExactIdentifiers(t *testing.T) {
	home := t.TempDir()
	lib := filepath.Join(home, "Library")
	for _, dir := range []string{"LaunchAgents", "Group Containers/ABCDE12345.com.example.app", "Group Containers/ABCDE12345.com.example.application", "Preferences/ByHost"} {
		if err := os.MkdirAll(filepath.Join(lib, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, file := range []string{"LaunchAgents/com.example.app.helper.plist", "LaunchAgents/com.example.application.plist",
		"Preferences/ByHost/com.example.app.1234.plist"} {
		if err := os.WriteFile(filepath.Join(lib, file), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	got := map[string]leftoverCandidate{}
	for _, c := range leftoverCandidates(home, AppIdentity{BundleID: "com.example.app", Name: "Example"}) {
		got[c.path] = c
	}
	want := []string{"LaunchAgents/com.example.app.helper.plist", "Group Containers/ABCDE12345.com.example.app",
		"Preferences/ByHost/com.example.app.1234.plist", "Application Support/com.example.app", "Caches/com.example.app"}
	for _, w := range want {
		if c, ok := got[filepath.Join(lib, w)]; !ok || c.suggested {
			t.Fatalf("missing exact candidate %s: %+v", w, got)
		}
	}
	// A longer identifier sharing the prefix belongs to another app.
	for _, other := range []string{"LaunchAgents/com.example.application.plist", "Group Containers/ABCDE12345.com.example.application"} {
		if _, ok := got[filepath.Join(lib, other)]; ok {
			t.Fatalf("matched another app's %s", other)
		}
	}
	if c := got[filepath.Join(lib, "Application Support", "Example")]; !c.suggested {
		t.Fatal("name match must be suggested only")
	}
}
