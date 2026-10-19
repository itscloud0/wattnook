package cleanup

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func appFixture(t *testing.T, root, name string) string {
	t.Helper()
	p := filepath.Join(root, name)
	if err := os.MkdirAll(p, 0700); err != nil {
		t.Fatal(err)
	}
	return p
}

func applicationTempDir(t *testing.T) string {
	t.Helper()
	p, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return p
}
func fixtureInspector(path string) (AppIdentity, error) {
	return AppIdentity{Path: path, BundleID: "test." + filepath.Base(path), Name: filepath.Base(path), ThirdParty: true, Resolved: true}, nil
}

// Catches following symlinks, unbounded vendor recursion and exceeding result caps.
func TestDiscoverApplicationsBoundaries(t *testing.T) {
	root := applicationTempDir(t)
	appFixture(t, root, "A.app")
	appFixture(t, root, "Vendor/B.app")
	appFixture(t, root, "Vendor/Other/C.app")
	outside := appFixture(t, applicationTempDir(t), "Outside.app")
	if err := os.Symlink(outside, filepath.Join(root, "Link.app")); err != nil {
		t.Fatal(err)
	}
	got := discoverApplications(context.Background(), []string{root}, Limits{}, fixtureInspector)
	if got.Partial || len(got.Entries) != 2 {
		t.Fatalf("inventory: %+v", got)
	}
	for _, entry := range got.Entries {
		if entry.Identity.Inode == 0 || entry.Size.Complete {
			t.Fatalf("identity/unknown size: %+v", entry)
		}
	}
	got = discoverApplications(context.Background(), []string{root}, Limits{MaxResults: 1}, fixtureInspector)
	if !got.Partial || len(got.Entries) != 1 {
		t.Fatalf("cap: %+v", got)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	got = discoverApplications(ctx, []string{root}, Limits{}, fixtureInspector)
	if !got.Partial || len(got.Entries) != 0 {
		t.Fatalf("canceled: %+v", got)
	}
	linked := filepath.Join(applicationTempDir(t), "Applications")
	if err := os.Symlink(root, linked); err != nil {
		t.Fatal(err)
	}
	got = discoverApplications(context.Background(), []string{linked}, Limits{}, fixtureInspector)
	if !got.Partial || len(got.Entries) != 0 {
		t.Fatalf("root symlink: %+v", got)
	}
}

// Catches trusting .app suffixes, Apple identity, duplicates and replacements.
func TestDiscoverApplicationsIdentity(t *testing.T) {
	root := applicationTempDir(t)
	for _, name := range []string{"Apple.app", "Self.app", "Unknown.app", "Fake.app", "One.app", "Two.app"} {
		appFixture(t, root, name)
	}
	inspect := func(path string) (AppIdentity, error) {
		a, _ := fixtureInspector(path)
		switch filepath.Base(path) {
		case "Apple.app":
			a.ThirdParty = false
		case "Self.app":
			a.Protected = true
		case "Unknown.app":
			a.Resolved = false
		case "Fake.app":
			return AppIdentity{}, fmt.Errorf("not an application bundle")
		case "One.app", "Two.app":
			a.BundleID = "test.duplicate"
		}
		return a, nil
	}
	got := discoverApplications(context.Background(), []string{root}, Limits{}, inspect)
	if len(got.Entries) != 5 {
		t.Fatalf("not a metadata inventory: %+v", got)
	}
	for _, entry := range got.Entries {
		if entry.Eligible || entry.Reason == "" {
			t.Fatalf("unsafe candidate: %+v", entry)
		}
	}
	replacement := func(path string) (AppIdentity, error) {
		a, _ := fixtureInspector(path)
		if err := os.Rename(path, path+".old"); err != nil {
			return a, err
		}
		if err := os.Mkdir(path, 0700); err != nil {
			return a, err
		}
		return a, nil
	}
	root2 := applicationTempDir(t)
	appFixture(t, root2, "Changed.app")
	got = discoverApplications(context.Background(), []string{root2}, Limits{}, replacement)
	if len(got.Entries) != 0 || !got.Partial {
		t.Fatalf("replacement accepted: %+v", got)
	}
}

// Catches partial cache authorization, path escapes and ambiguous ownership.
func TestEligibleCache(t *testing.T) {
	home := t.TempDir()
	apps := []AppIdentity{{BundleID: "test.safe", ThirdParty: true, Resolved: true}}
	base := Observation{Path: filepath.Join(home, "Library/Caches/test.safe"), Complete: true}
	ok, why := EligibleCache(apps, home, "test.safe", base)
	if !ok {
		t.Fatalf("valid cache rejected: %s", why)
	}
	cases := []struct {
		name string
		apps []AppIdentity
		obs  Observation
	}{
		{"partial", apps, Observation{Path: base.Path, Complete: false}},
		{"system", apps, Observation{Path: "/System/Library/Caches/test.safe", Complete: true}},
		{"nested", apps, Observation{Path: base.Path + "/child", Complete: true}},
		{"duplicate", append(append([]AppIdentity{}, apps...), apps[0]), base},
		{"running", []AppIdentity{{BundleID: "test.safe", ThirdParty: true, Resolved: true, Running: true}}, base},
		{"apple", []AppIdentity{{BundleID: "test.safe", Resolved: true}}, base},
		{"unknown", nil, base},
	}
	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			if ok, reason := EligibleCache(tt.apps, home, "test.safe", tt.obs); ok || reason == "" {
				t.Fatalf("eligible=%v reason=%q", ok, reason)
			}
		})
	}
}

// Catches silently measuring the entire Caches folder or reporting a partial
// application size as complete. Fixtures are real files; metadata is injected.
func TestScanApplicationStorage(t *testing.T) {
	home := applicationTempDir(t)
	root := appFixture(t, home, "Applications")
	app := appFixture(t, root, "A.app")
	if err := os.WriteFile(filepath.Join(app, "data"), []byte("12345"), 0600); err != nil {
		t.Fatal(err)
	}
	cache := appFixture(t, home, "Library/Caches/test.A.app")
	if err := os.WriteFile(filepath.Join(cache, "data"), []byte("1234567"), 0600); err != nil {
		t.Fatal(err)
	}
	unknown := appFixture(t, home, "Library/Caches/unknown")
	if err := os.WriteFile(filepath.Join(unknown, "keep"), []byte("unrelated"), 0600); err != nil {
		t.Fatal(err)
	}
	report := scanApplicationStorage(context.Background(), home, []string{root}, Limits{}, fixtureInspector, nil)
	if report.Applications == nil || len(report.Applications.Entries) != 1 {
		t.Fatalf("inventory: %+v", report)
	}
	entry := report.Applications.Entries[0]
	if !entry.Size.Complete || entry.Size.Bytes != 5 {
		t.Fatalf("app size: %+v", entry)
	}
	if len(report.Observations) != 1 || report.Observations[0].Path != cache || report.Observations[0].Bytes != 7 {
		t.Fatalf("cache scope: %+v", report)
	}
	if _, err := os.Stat(filepath.Join(unknown, "keep")); err != nil {
		t.Fatal("unrelated data changed", err)
	}
	partial := scanApplicationStorage(context.Background(), home, []string{root}, Limits{MaxEntries: 1}, fixtureInspector, nil)
	if partial.State != "partial" {
		t.Fatalf("budget not reported: %+v", partial)
	}
}

func TestDiscoverApplicationsMetadataFailure(t *testing.T) {
	root := applicationTempDir(t)
	appFixture(t, root, "Valid.app")
	got := discoverApplications(context.Background(), []string{root}, Limits{}, func(string) (AppIdentity, error) { return AppIdentity{}, os.ErrPermission })
	if !got.Partial || got.Reason == "" {
		t.Fatalf("failed read reported complete: %+v", got)
	}
}

func TestScanApplicationStorageHardLinks(t *testing.T) {
	home := applicationTempDir(t)
	root := appFixture(t, home, "Applications")
	first := appFixture(t, root, "One.app")
	second := appFixture(t, root, "Two.app")
	cache := appFixture(t, home, "Library/Caches/test.One.app")
	source := filepath.Join(first, "shared")
	if err := os.WriteFile(source, []byte("123456789"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{filepath.Join(second, "linked"), filepath.Join(cache, "linked")} {
		if err := os.Link(source, p); err != nil {
			t.Fatal(err)
		}
	}
	report := scanApplicationStorage(context.Background(), home, []string{root}, Limits{}, fixtureInspector, nil)
	if len(report.Applications.Entries) != 2 || len(report.Observations) != 1 {
		t.Fatalf("missing observations: %+v", report)
	}
	for _, entry := range report.Applications.Entries {
		if !entry.Size.Complete || entry.Size.Bytes != 9 {
			t.Fatalf("per-app size: %+v", entry.Size)
		}
	}
	if got := report.Observations[0]; !got.Complete || got.Bytes != 9 {
		t.Fatalf("cache size: %+v", got)
	}
}

func TestScanApplicationStoragePartialOwnership(t *testing.T) {
	home := applicationTempDir(t)
	root := appFixture(t, home, "Applications")
	appFixture(t, root, "One.app")
	appFixture(t, root, "Two.app")
	cache := appFixture(t, home, "Library/Caches/test.duplicate")
	if err := os.WriteFile(filepath.Join(cache, "keep"), []byte("123"), 0600); err != nil {
		t.Fatal(err)
	}
	report := scanApplicationStorage(context.Background(), home, []string{root}, Limits{MaxResults: 1}, func(path string) (AppIdentity, error) {
		a, _ := fixtureInspector(path)
		a.BundleID = "test.duplicate"
		return a, nil
	}, nil)
	if !report.Applications.Partial || len(report.Observations) != 0 {
		t.Fatalf("partial ownership trusted: %+v", report)
	}
}
