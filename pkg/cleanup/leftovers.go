package cleanup

import (
	"os"
	"path/filepath"
	"strings"
)

type leftoverCandidate struct {
	path, category string
	suggested      bool
}

func validLeftoverName(name string) bool {
	return name != "" && name != "." && name != ".." && !strings.ContainsAny(name, "/\\:") && len(name) <= 255
}

// leftoverCandidates lists where macOS applications keep per-user data, keyed
// by the exact bundle identifier. Locations matched only by the application's
// display name are Suggested: a vendor folder can be shared by several apps.
func leftoverCandidates(home string, app AppIdentity) []leftoverCandidate {
	id, lib := app.BundleID, filepath.Join(home, "Library")
	var out []leftoverCandidate
	add := func(category string, suggested bool, parts ...string) {
		out = append(out, leftoverCandidate{filepath.Join(append([]string{lib}, parts...)...), category, suggested})
	}
	add("Application Support", false, "Application Support", id)
	add("Caches", false, "Caches", id)
	add("Container", false, "Containers", id)
	add("Preferences", false, "Preferences", id+".plist")
	add("Saved state", false, "Saved Application State", id+".savedState")
	add("Logs", false, "Logs", id)
	add("Web data", false, "WebKit", id)
	add("Web data", false, "HTTPStorages", id)
	add("Cookies", false, "HTTPStorages", id+".binarycookies")
	add("Cookies", false, "Cookies", id+".binarycookies")
	add("Scripts", false, "Application Scripts", id)
	// Prefix matches inside folders that hold one file per identifier.
	scan := func(dir, category string, match func(string) bool) {
		entries, err := os.ReadDir(filepath.Join(lib, dir))
		if err != nil {
			return
		}
		for _, e := range entries {
			if match(e.Name()) {
				add(category, false, dir, e.Name())
			}
		}
	}
	scan(filepath.Join("Preferences", "ByHost"), "Preferences", func(n string) bool {
		return strings.HasPrefix(n, id+".") && strings.HasSuffix(n, ".plist")
	})
	scan("LaunchAgents", "Launch agent", func(n string) bool {
		return n == id+".plist" || (strings.HasPrefix(n, id+".") && strings.HasSuffix(n, ".plist"))
	})
	// Group containers are named "<team or group>.<identifier>".
	scan("Group Containers", "Group container", func(n string) bool {
		return strings.HasSuffix(n, "."+id)
	})
	if name := app.Name; validLeftoverName(name) && len(name) >= 3 && !strings.EqualFold(name, id) {
		add("Application Support", true, "Application Support", name)
		add("Caches", true, "Caches", name)
		add("Logs", true, "Logs", name)
	}
	return out
}
