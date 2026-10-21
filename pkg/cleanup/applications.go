package cleanup

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

var ErrNotApplicationBundle = errors.New("not an application bundle")

// AppIdentity describes an observed bundle, not permission to remove it.
type AppIdentity struct {
	Path       string `json:"path"`
	BundleID   string `json:"bundleID"`
	Name       string `json:"name"`
	Device     uint64 `json:"device"`
	Inode      uint64 `json:"inode"`
	ThirdParty bool   `json:"thirdParty"`
	Running    bool   `json:"running"`
	Resolved   bool   `json:"resolved"`
	Protected  bool   `json:"protected"`
}
type AppEntry struct {
	Identity AppIdentity `json:"identity"`
	Size     Observation `json:"size"`
	Eligible bool        `json:"eligible"`
	Reason   string      `json:"reason,omitempty"`
}
type AppInventory struct {
	Entries []AppEntry `json:"entries"`
	Partial bool       `json:"partial"`
	Reason  string     `json:"reason,omitempty"`
	Visited uint64     `json:"visited"`
}

func DiscoverApplications(ctx context.Context, home string, limits Limits, inspect func(string) (AppIdentity, error)) AppInventory {
	if !filepath.IsAbs(home) || filepath.Clean(home) == "/" {
		return AppInventory{Entries: []AppEntry{}, Partial: true, Reason: "Home directory unavailable"}
	}
	return discoverApplications(ctx, []string{"/Applications", filepath.Join(home, "Applications")}, limits, inspect)
}

// Directory handles anchor discovery; path-based native metadata is checked
// against the opened directory before and after inspection. No files are read
// recursively or changed. This is deliberately not a mutation primitive.
func discoverApplications(ctx context.Context, roots []string, limits Limits, inspect func(string) (AppIdentity, error)) AppInventory {
	result := AppInventory{Entries: []AppEntry{}}
	defaults := DefaultLimits()
	if limits.Timeout < 0 || limits.MaxResults < 0 || limits.MaxEntries < 0 || inspect == nil {
		result.Partial = true
		result.Reason = "Invalid application discovery options"
		return result
	}
	if limits.Timeout == 0 {
		limits.Timeout = defaults.Timeout
	}
	if limits.MaxResults == 0 {
		limits.MaxResults = defaults.MaxResults
	}
	if limits.MaxEntries == 0 {
		limits.MaxEntries = defaults.MaxEntries
	}
	limits.MaxResults = min(limits.MaxResults, 200)
	limits.MaxEntries = min(limits.MaxEntries, defaults.MaxEntries)
	ctx, cancel := context.WithTimeout(ctx, min(limits.Timeout, 30*time.Second))
	defer cancel()
	visited := 0
	partial := func(reason string) {
		result.Partial = true
		if result.Reason == "" {
			result.Reason = reason
		}
	}
	check := func() bool {
		if ctx.Err() != nil {
			partial("Application discovery stopped")
			return false
		}
		if visited >= limits.MaxEntries {
			partial("Application discovery entry limit reached")
			return false
		}
		return true
	}
	var readDirectory func(*os.File, string, int, int32)
	readDirectory = func(dir *os.File, path string, depth int, dev int32) {
		for check() {
			entries, err := dir.ReadDir(64)
			if err != nil && !errors.Is(err, io.EOF) {
				partial("Some application folders were inaccessible")
				return
			}
			for _, entry := range entries {
				if !check() {
					return
				}
				visited++
				var st unix.Stat_t
				if unix.Fstatat(int(dir.Fd()), entry.Name(), &st, unix.AT_SYMLINK_NOFOLLOW) != nil {
					partial("Some application entries changed")
					continue
				}
				if st.Mode&unix.S_IFMT != unix.S_IFDIR || st.Dev != dev {
					continue
				}
				app := strings.EqualFold(filepath.Ext(entry.Name()), ".app")
				if !app && depth >= 1 {
					continue
				}
				full := filepath.Join(path, entry.Name())
				fd, e := unix.Openat(int(dir.Fd()), entry.Name(), unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
				if e != nil {
					partial("Some application folders were inaccessible")
					continue
				}
				child := os.NewFile(uintptr(fd), full)
				var opened unix.Stat_t
				if unix.Fstat(fd, &opened) != nil || opened.Dev != st.Dev || opened.Ino != st.Ino {
					child.Close()
					partial("An application changed during discovery")
					continue
				}
				if app {
					if len(result.Entries) >= limits.MaxResults {
						child.Close()
						partial("Application result limit reached")
						return
					}
					a, e := inspect(full)
					// Reopen the full path to catch substitution of an ancestor as well as
					// the final entry while the metadata provider was reading it.
					current, actual, pathErr := openRoot(full)
					if current != nil {
						current.Close()
					}
					child.Close()
					if pathErr != nil || actual.Dev != st.Dev || actual.Ino != st.Ino {
						partial("An application changed during discovery")
						continue
					}
					if e != nil {
						if !errors.Is(e, ErrNotApplicationBundle) {
							partial("Some application identities could not be inspected")
						}
						continue
					}
					a.Path = full
					a.Device = uint64(st.Dev)
					a.Inode = st.Ino
					if a.Name == "" {
						a.Name = strings.TrimSuffix(entry.Name(), filepath.Ext(entry.Name()))
					}
					why := appIneligibleReason(a)
					result.Entries = append(result.Entries, AppEntry{Identity: a, Size: Observation{Path: full, DisplayPath: full}, Eligible: why == "", Reason: why})
				} else {
					readDirectory(child, full, depth+1, dev)
					child.Close()
				}
			}
			if errors.Is(err, io.EOF) {
				return
			}
		}
	}
	for _, root := range roots {
		if !check() {
			break
		}
		dir, st, err := openRoot(root)
		if errors.Is(err, unix.ENOENT) {
			continue
		}
		if err != nil {
			partial("An application location was inaccessible or a symlink")
			continue
		}
		readDirectory(dir, root, 0, st.Dev)
		dir.Close()
	}
	counts := map[string]int{}
	for _, e := range result.Entries {
		counts[e.Identity.BundleID]++
	}
	for i := range result.Entries {
		e := &result.Entries[i]
		if e.Identity.BundleID != "" && counts[e.Identity.BundleID] > 1 {
			e.Eligible = false
			e.Reason = "More than one application has this identifier"
		}
	}
	result.Visited = uint64(visited)
	return result
}

// ScanApplicationStorage observes only app bundles and exact caches mapped to
// unique third-party identifiers. It does not determine reclaimable space and
// has no mutation operations. The command-line read-only scanner is unchanged.
func ScanApplicationStorage(ctx context.Context, home string, limits Limits, inspect func(string) (AppIdentity, error), progress func(Progress)) Report {
	return scanApplicationStorage(ctx, home, []string{"/Applications", filepath.Join(home, "Applications")}, limits, inspect, progress)
}

func scanApplicationStorage(ctx context.Context, home string, roots []string, limits Limits, inspect func(string) (AppIdentity, error), progress func(Progress)) Report {
	start := time.Now()
	invalid := limits.Timeout < 0 || limits.MaxEntries < 0 || limits.MaxDepth < 0 || limits.MaxResults < 0 || !filepath.IsAbs(home) || filepath.Clean(home) == "/"
	if invalid {
		return Report{State: "error", Reason: "Invalid application scan options", StartedAt: start, FinishedAt: time.Now()}
	}
	d := ApplicationLimits()
	if limits.Timeout == 0 {
		limits.Timeout = d.Timeout
	}
	if limits.MaxEntries == 0 {
		limits.MaxEntries = d.MaxEntries
	}
	if limits.MaxDepth == 0 {
		limits.MaxDepth = d.MaxDepth
	}
	if limits.MaxResults == 0 {
		limits.MaxResults = d.MaxResults
	}
	limits.Timeout = min(limits.Timeout, d.Timeout)
	limits.MaxEntries = min(limits.MaxEntries, d.MaxEntries)
	limits.MaxDepth = min(limits.MaxDepth, d.MaxDepth)
	limits.MaxResults = min(limits.MaxResults, d.MaxResults)
	ctx, cancel := context.WithTimeout(ctx, limits.Timeout)
	defer cancel()
	inventory := discoverApplications(ctx, roots, limits, inspect)
	ownershipKnown := !inventory.Partial
	w := walker{ctx: ctx, limits: limits, report: Report{State: "complete", StartedAt: start, Observations: []Observation{}, Visited: inventory.Visited}, seen: map[identity]bool{}, progress: progress, statEntry: unix.Fstatat}
	measure := func(path, category string, expected *AppIdentity) Observation {
		// Each listed item has its own logical size. Cross-item hard links do
		// not make later bundles/caches empty; aggregate bytes are not disk use.
		clear(w.seen)
		o := Observation{Path: path, DisplayPath: path, Category: category}
		if !w.check() || w.report.Visited >= uint64(limits.MaxEntries) {
			w.stop = "Application scan budget reached"
			return o
		}
		dir, st, err := openRoot(path)
		if err != nil {
			o.Errors++
			return o
		}
		defer dir.Close()
		if expected != nil && (expected.Device != uint64(st.Dev) || expected.Inode != st.Ino) {
			o.Errors++
			return o
		}
		o.Complete = true
		w.walk(dir, path, category, st.Dev, 0, &o)
		// Keep size observations tied to the discovered path identity, not a renamed
		// directory whose open handle still succeeds.
		final, actual, e := openRoot(path)
		if final != nil {
			final.Close()
		}
		if e != nil || actual.Dev != st.Dev || actual.Ino != st.Ino {
			o.Complete = false
			o.Errors++
		}
		return o
	}
	apps := make([]AppIdentity, 0, len(inventory.Entries))
	for _, entry := range inventory.Entries {
		apps = append(apps, entry.Identity)
	}
	for i := range inventory.Entries {
		entry := &inventory.Entries[i]
		entry.Size = measure(entry.Identity.Path, "Application", &entry.Identity)
		if !entry.Size.Complete {
			inventory.Partial = true
		}
		// Ownership mapping does not depend on an app being currently stopped: a
		// running app's cache can be measured, but will remain ineligible to clean.
		app := entry.Identity
		app.Running = false
		if !ownershipKnown || appIneligibleReason(app) != "" || !uniqueBundleID(apps, app.BundleID) {
			continue
		}
		path := filepath.Join(home, "Library/Caches", app.BundleID)
		if strings.ContainsAny(app.BundleID, "/\\") || app.BundleID == "." || app.BundleID == ".." {
			continue
		}
		cache, _, err := openRoot(path)
		if errors.Is(err, unix.ENOENT) {
			continue
		}
		if cache != nil {
			cache.Close()
		}
		if err != nil {
			inventory.Partial = true
			continue
		}
		observation := measure(path, "Application cache", nil)
		if !observation.Complete {
			inventory.Partial = true
		}
		w.report.Observations = append(w.report.Observations, observation)
	}
	w.report.Applications = &inventory
	if inventory.Partial || w.stop != "" {
		w.report.State = "partial"
		w.report.Reason = inventory.Reason
	}
	if w.stop != "" {
		w.report.Reason = w.stop
	}
	if ctx.Err() != nil {
		w.report.State = "partial"
		w.report.Reason = "Application scan deadline reached"
	}
	if errors.Is(ctx.Err(), context.Canceled) {
		w.report.State = "canceled"
		w.report.Reason = "Application scan canceled"
	}
	w.report.FinishedAt = time.Now()
	return w.report
}

func uniqueBundleID(apps []AppIdentity, id string) bool {
	count := 0
	for _, app := range apps {
		if app.BundleID == id {
			count++
		}
	}
	return count == 1
}

func appIneligibleReason(app AppIdentity) string {
	switch {
	case !app.Resolved || app.BundleID == "":
		return "Application identity could not be verified"
	case app.Protected:
		return "This application is protected"
	case !app.ThirdParty || strings.HasPrefix(strings.ToLower(app.BundleID), "com.apple."):
		return "System applications are excluded"
	case app.Running:
		return "Quit the application normally before removing it"
	default:
		return ""
	}
}

// EligibleCache evaluates a previously anchored observation. The mutation
// boundary must independently revalidate it; this function never authorizes IO.
func EligibleCache(apps []AppIdentity, home, bundleID string, observation Observation) (bool, string) {
	if !filepath.IsAbs(home) || filepath.Clean(home) == "/" || bundleID == "" || strings.ContainsAny(bundleID, "/\\") || bundleID == "." || bundleID == ".." {
		return false, "Invalid application cache identity"
	}
	expected := filepath.Join(home, "Library", "Caches", bundleID)
	if observation.Path != expected {
		return false, "Only an exact application cache directory is eligible"
	}
	if !observation.Complete || observation.Errors != 0 || observation.Skipped != 0 {
		return false, "Incomplete cache observations are review-only"
	}
	var match AppIdentity
	count := 0
	for _, app := range apps {
		if app.BundleID == bundleID {
			match = app
			count++
		}
	}
	if count != 1 {
		return false, "Cache ownership is unknown or ambiguous"
	}
	if why := appIneligibleReason(match); why != "" {
		return false, why
	}
	return true, ""
}
