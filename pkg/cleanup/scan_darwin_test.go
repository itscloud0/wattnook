package cleanup

import (
	"context"
	"encoding/json"
	"golang.org/x/sys/unix"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fixture(t *testing.T) string {
	t.Helper()
	p, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return p
}
func put(t *testing.T, p, s string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(s), 0600); err != nil {
		t.Fatal(err)
	}
}
func scan(t *testing.T, p string, l Limits) Report {
	t.Helper()
	return Scan(context.Background(), []Root{{p, "User cache directory"}}, l, nil)
}
func TestAggregateAndDeduplicate(t *testing.T) {
	p := fixture(t)
	put(t, filepath.Join(p, "one", "a"), "abc")
	put(t, filepath.Join(p, "one", "b"), "12345")
	put(t, filepath.Join(p, "empty"), "")
	if err := os.Link(filepath.Join(p, "one", "a"), filepath.Join(p, "hard")); err != nil {
		t.Fatal(err)
	}
	r := scan(t, p, Limits{})
	if r.State != "complete" || r.Bytes != 8 || len(r.Observations) != 3 {
		t.Fatalf("%+v", r)
	}
	var total uint64
	for _, o := range r.Observations {
		total += o.Bytes
		if !o.Complete || o.Category != "User cache directory" {
			t.Fatal(o)
		}
	}
	if total != 8 {
		t.Fatal(total)
	}
}
func TestSymlinksAndSpecialFilesSkipped(t *testing.T) {
	p := fixture(t)
	outside := fixture(t)
	put(t, filepath.Join(outside, "secret"), "must not count")
	if err := os.Symlink(outside, filepath.Join(p, "link")); err != nil {
		t.Fatal(err)
	}
	r := scan(t, p, Limits{})
	if r.Bytes != 0 || r.Skipped != 1 {
		t.Fatalf("%+v", r)
	}
	r = scan(t, filepath.Join(p, "link"), Limits{})
	if r.State != "error" || r.Roots[0].State != "rejected" {
		t.Fatalf("%+v", r)
	}
}
func TestMissingAndMixedRoots(t *testing.T) {
	p := fixture(t)
	r := scan(t, filepath.Join(p, "absent"), Limits{})
	if r.State != "error" || r.Roots[0].State != "missing" {
		t.Fatal(r)
	}
	r = Scan(context.Background(), []Root{{p, "logs"}, {filepath.Join(p, "absent"), "cache"}}, Limits{}, nil)
	if r.State != "partial" {
		t.Fatal(r)
	}
}
func TestBoundsAndCancellation(t *testing.T) {
	p := fixture(t)
	for _, n := range []string{"a", "b", "c"} {
		put(t, filepath.Join(p, n, "f"), "abc")
	}
	for _, l := range []Limits{{MaxEntries: 2}, {MaxResults: 2}, {MaxDepth: 1}, {Timeout: time.Nanosecond}} {
		r := scan(t, p, l)
		if r.State != "partial" {
			t.Fatalf("limits %+v: %+v", l, r)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r := Scan(ctx, []Root{{p, "cache"}}, Limits{}, nil)
	if r.State != "canceled" {
		t.Fatal(r)
	}
	r = scan(t, p, Limits{MaxEntries: -1})
	if r.State != "error" {
		t.Fatal(r)
	}
}
func TestNoContentsOrWritesAndOrdering(t *testing.T) {
	p := fixture(t)
	put(t, filepath.Join(p, "b"), "123")
	put(t, filepath.Join(p, "a"), "123")
	put(t, filepath.Join(p, "big"), "12345")
	before, _ := os.ReadFile(filepath.Join(p, "big"))
	_ = os.Chmod(filepath.Join(p, "big"), 0000)
	r := scan(t, p, Limits{})
	if r.State != "complete" || r.Bytes != 11 {
		t.Fatal(r)
	}
	if filepath.Base(r.Observations[0].Path) != "big" || filepath.Base(r.Observations[1].Path) != "a" {
		t.Fatal(r.Observations)
	}
	_ = os.Chmod(filepath.Join(p, "big"), 0600)
	after, _ := os.ReadFile(filepath.Join(p, "big"))
	if string(before) != string(after) {
		t.Fatal("file changed")
	}
}
func TestPathEncodingAndUserRoots(t *testing.T) {
	p := fixture(t)
	name := "line\nname"
	put(t, filepath.Join(p, name), "x")
	r := scan(t, p, Limits{})
	b, err := json.Marshal(r)
	if err != nil || !json.Valid(b) {
		t.Fatal(err)
	}
	if r.Observations[0].Path != filepath.Join(p, name) || strings.Contains(r.Observations[0].DisplayPath, "\n") {
		t.Fatal(r)
	}
	_, encoded := pathPresentation("invalid\xff")
	if encoded == "" {
		t.Fatal("lossless identity missing")
	}
	roots, err := UserRoots(p)
	if err != nil || len(roots) != 2 || !strings.HasSuffix(roots[0].Path, "Library/Caches") {
		t.Fatal(roots, err)
	}
	if _, err := UserRoots("relative"); err == nil {
		t.Fatal("relative home accepted")
	}
}
func TestCheckedSize(t *testing.T) {
	if _, ok := addSize(^uint64(0), 1); ok {
		t.Fatal("overflow")
	}
	if v, ok := addSize(3, 5); !ok || v != 8 {
		t.Fatal(v, ok)
	}
}

func TestDirectoryReplacementNeverFollowsSymlink(t *testing.T) {
	p, outside := fixture(t), fixture(t)
	child := filepath.Join(p, "child")
	put(t, filepath.Join(child, "small"), "x")
	put(t, filepath.Join(outside, "outside"), "must not read")
	r := scanWithHooks(context.Background(), []Root{{p, "cache"}}, Limits{}, nil, nil, func(path string) {
		if path != child {
			return
		}
		if err := os.Rename(child, child+"-moved"); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(outside, child); err != nil {
			t.Fatal(err)
		}
	})
	if r.State != "partial" || r.Bytes != 0 || r.Errors == 0 {
		t.Fatalf("%+v", r)
	}
}

func TestDeviceBoundaryAndUnreadableDirectory(t *testing.T) {
	p := fixture(t)
	put(t, filepath.Join(p, "child", "f"), "123")
	r := scanWithHooks(context.Background(), []Root{{p, "cache"}}, Limits{}, nil, func(fd int, name string, st *unix.Stat_t, flags int) error {
		err := unix.Fstatat(fd, name, st, flags)
		st.Dev++
		return err
	}, nil)
	if r.State != "partial" || r.Bytes != 0 || r.Skipped != 1 {
		t.Fatalf("%+v", r)
	}
	if os.Geteuid() == 0 {
		t.Skip("permission fixture requires non-root")
	}
	child := filepath.Join(p, "child")
	if err := os.Chmod(child, 0000); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(child, 0700)
	r = scan(t, p, Limits{})
	if r.State != "partial" || r.Bytes != 0 || r.Errors == 0 || r.Observations[0].Complete {
		t.Fatalf("%+v", r)
	}
}

func TestSpecialFilesAndMidScanCancellation(t *testing.T) {
	p := fixture(t)
	if err := unix.Mkfifo(filepath.Join(p, "fifo"), 0600); err != nil {
		t.Fatal(err)
	}
	r := scan(t, p, Limits{})
	if r.State != "complete" || r.Skipped != 1 || r.Bytes != 0 {
		t.Fatal(r)
	}
	for _, n := range []string{"a", "b", "c"} {
		put(t, filepath.Join(p, n), "123")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	r = Scan(ctx, []Root{{p, "cache"}}, Limits{}, func(p Progress) {
		if p.Visited == 2 {
			cancel()
		}
	})
	if r.State != "canceled" || r.Visited != 2 || r.Bytes >= 9 {
		t.Fatalf("%+v", r)
	}
}
