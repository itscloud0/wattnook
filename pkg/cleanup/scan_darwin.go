package cleanup

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/sys/unix"
)

type identity struct {
	dev int32
	ino uint64
}
type walker struct {
	ctx        context.Context
	limits     Limits
	report     Report
	seen       map[identity]bool
	progress   func(Progress)
	stop       string
	canceled   bool
	statEntry  func(int, string, *unix.Stat_t, int) error
	beforeOpen func(string)
}

func Scan(ctx context.Context, roots []Root, limits Limits, progress func(Progress)) Report {
	return scanWithHooks(ctx, roots, limits, progress, nil, nil)
}

// Narrow per-scan seams exercise metadata races without global hooks or mounts.
func scanWithHooks(ctx context.Context, roots []Root, limits Limits, progress func(Progress), statEntry func(int, string, *unix.Stat_t, int) error, beforeOpen func(string)) Report {
	start := time.Now()
	w := walker{limits: limits, report: Report{StartedAt: start, Observations: []Observation{}, Roots: []RootStatus{}}, seen: make(map[identity]bool), progress: progress}
	w.statEntry = statEntry
	if w.statEntry == nil {
		w.statEntry = unix.Fstatat
	}
	w.beforeOpen = beforeOpen
	defer func() { clear(w.seen) }()
	if limits.Timeout < 0 || limits.MaxEntries < 0 || limits.MaxDepth < 0 || limits.MaxResults < 0 || len(roots) > 2 {
		w.report.State = "error"
		w.report.Reason = "Invalid scan limits or roots"
		w.report.FinishedAt = time.Now()
		return w.report
	}
	d := DefaultLimits()
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
	w.limits = limits
	// Hard ceilings keep even internal callers from accidentally unbounding a scan.
	w.limits.MaxEntries = min(limits.MaxEntries, d.MaxEntries)
	w.limits.MaxDepth = min(limits.MaxDepth, d.MaxDepth)
	w.limits.MaxResults = min(limits.MaxResults, d.MaxResults)
	ctx, cancel := context.WithTimeout(ctx, min(limits.Timeout, d.Timeout))
	defer cancel()
	w.ctx = ctx
	roots = append([]Root(nil), roots...)
	sort.Slice(roots, func(i, j int) bool { return roots[i].Path < roots[j].Path })
	opened := 0
	for _, root := range roots {
		rs := RootStatus{Path: root.Path, State: "partial"}
		if !w.check() {
			rs.Reason = w.stop
			w.report.Roots = append(w.report.Roots, rs)
			continue
		}
		f, st, err := openRoot(root.Path)
		if err != nil {
			rs.State = "inaccessible"
			if errors.Is(err, unix.ENOENT) {
				rs.State = "missing"
			}
			if errors.Is(err, unix.ELOOP) || errors.Is(err, unix.ENOTDIR) || !filepath.IsAbs(root.Path) {
				rs.State = "rejected"
			}
			rs.Reason = "Root unavailable; symlinks are not followed"
			w.report.Errors++
			w.report.Roots = append(w.report.Roots, rs)
			continue
		}
		opened++
		errorsBefore := w.report.Errors
		w.walk(f, root.Path, root.Category, st.Dev, 0, nil)
		f.Close()
		if w.stop == "" && w.report.Errors == errorsBefore {
			rs.State = "complete"
		} else {
			rs.Reason = "Some entries were not measured"
		}
		w.report.Roots = append(w.report.Roots, rs)
	}
	w.report.State = "complete"
	for _, r := range w.report.Roots {
		if r.State != "complete" {
			w.report.State = "partial"
		}
	}
	if opened == 0 || len(roots) == 0 {
		w.report.State = "error"
		w.report.Reason = "No scan locations were accessible"
	}
	if w.stop != "" {
		w.report.State = "partial"
		w.report.Reason = w.stop
	}
	if w.canceled {
		w.report.State = "canceled"
	}
	sort.Slice(w.report.Observations, func(i, j int) bool {
		a, b := w.report.Observations[i], w.report.Observations[j]
		if a.Bytes != b.Bytes {
			return a.Bytes > b.Bytes
		}
		return a.Path < b.Path
	})
	w.report.FinishedAt = time.Now()
	return w.report
}

// Open every root component relative to an already-open directory. O_NOFOLLOW
// applies to each component, not just the last string in an absolute path.
func openRoot(path string) (*os.File, unix.Stat_t, error) {
	var st unix.Stat_t
	if !filepath.IsAbs(path) || filepath.Clean(path) == "/" {
		return nil, st, unix.ENOTDIR
	}
	fd, err := unix.Open("/", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, st, err
	}
	for _, part := range strings.Split(filepath.Clean(path), "/") {
		if part == "" {
			continue
		}
		next, e := unix.Openat(fd, part, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		unix.Close(fd)
		if e != nil {
			return nil, st, e
		}
		fd = next
	}
	if err = unix.Fstat(fd, &st); err != nil {
		unix.Close(fd)
		return nil, st, err
	}
	return os.NewFile(uintptr(fd), path), st, nil
}
func (w *walker) check() bool {
	if w.stop != "" {
		return false
	}
	if err := w.ctx.Err(); err != nil {
		w.canceled = errors.Is(err, context.Canceled)
		w.stop = "Scan deadline reached"
		if w.canceled {
			w.stop = "Scan canceled"
		}
		return false
	}
	return true
}
func (w *walker) fail(o *Observation) {
	w.report.Errors++
	if o != nil {
		o.Errors++
		o.Complete = false
	}
}
func (w *walker) skip(o *Observation) {
	w.report.Skipped++
	if o != nil {
		o.Skipped++
	}
}
func (w *walker) walk(f *os.File, path, category string, device int32, depth int, o *Observation) {
	for w.check() {
		entries, err := f.ReadDir(64)
		if err != nil && err != io.EOF {
			w.fail(o)
			return
		}
		for _, entry := range entries {
			if !w.check() {
				if o != nil {
					o.Complete = false
				}
				return
			}
			if w.report.Visited >= uint64(w.limits.MaxEntries) {
				w.stop = "Entry limit reached"
				if o != nil {
					o.Complete = false
				}
				return
			}
			w.report.Visited++
			if w.progress != nil {
				w.progress(Progress{w.report.Visited})
			}
			name := entry.Name()
			full := filepath.Join(path, name)
			var st unix.Stat_t
			if e := w.statEntry(int(f.Fd()), name, &st, unix.AT_SYMLINK_NOFOLLOW); e != nil {
				w.fail(o)
				continue
			}
			mode := st.Mode & unix.S_IFMT
			if mode != unix.S_IFDIR && mode != unix.S_IFREG {
				w.skip(o)
				continue
			}
			if st.Dev != device {
				w.skip(o)
				w.fail(o)
				continue
			}
			current := o
			index := -1
			if current == nil {
				if len(w.report.Observations) >= w.limits.MaxResults {
					w.stop = "Result limit reached"
					return
				}
				v := Observation{Path: full, Category: category, Complete: true}
				v.DisplayPath, v.PathBase64 = pathPresentation(full)
				w.report.Observations = append(w.report.Observations, v)
				index = len(w.report.Observations) - 1
				current = &w.report.Observations[index]
			}
			if mode == unix.S_IFREG {
				key := identity{st.Dev, st.Ino}
				if !w.seen[key] {
					w.seen[key] = true
					if st.Size < 0 {
						w.fail(current)
						continue
					}
					sum, ok := addSize(current.Bytes, uint64(st.Size))
					total, ok2 := addSize(w.report.Bytes, uint64(st.Size))
					if !ok || !ok2 {
						w.fail(current)
						w.stop = "Size overflow"
						return
					}
					current.Bytes = sum
					w.report.Bytes = total
				}
			} else {
				if depth+1 >= w.limits.MaxDepth {
					w.fail(current)
					w.skip(current)
					continue
				}
				if w.beforeOpen != nil {
					w.beforeOpen(full)
				}
				fd, e := unix.Openat(int(f.Fd()), name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
				if e != nil {
					w.fail(current)
					continue
				}
				var actual unix.Stat_t
				e = unix.Fstat(fd, &actual)
				if e != nil || actual.Dev != st.Dev || actual.Ino != st.Ino {
					unix.Close(fd)
					w.fail(current)
					continue
				}
				child := os.NewFile(uintptr(fd), full)
				w.walk(child, full, category, device, depth+1, current)
				child.Close()
			}
			if index >= 0 && w.stop != "" {
				w.report.Observations[index].Complete = false
			}
		}
		if err == io.EOF {
			return
		}
	}
	if o != nil {
		o.Complete = false
	}
}

func (r Report) Error() error {
	if r.State == "complete" {
		return nil
	}
	return fmt.Errorf("storage review %s: %s", r.State, r.Reason)
}

func pathPresentation(path string) (string, string) {
	display := strconv.QuoteToGraphic(path)
	display = display[1 : len(display)-1]
	encoded := ""
	if !utf8.ValidString(path) {
		encoded = base64.StdEncoding.EncodeToString([]byte(path))
	}
	return display, encoded
}
