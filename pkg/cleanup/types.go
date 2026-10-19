// Package cleanup implements read-only, bounded storage observations. It has no
// removal operations and does not determine whether data is disposable.
package cleanup

import (
	"fmt"
	"path/filepath"
	"time"
)

type Root struct {
	Path     string `json:"path"`
	Category string `json:"category"`
}
type Limits struct {
	Timeout                          time.Duration
	MaxEntries, MaxDepth, MaxResults int
}

func DefaultLimits() Limits { return Limits{30 * time.Second, 100000, 32, 200} }

type Progress struct {
	Visited uint64 `json:"visited"`
}
type Observation struct {
	Path        string `json:"path"`
	PathBase64  string `json:"pathBase64,omitempty"`
	DisplayPath string `json:"displayPath"`
	Category    string `json:"category"`
	Bytes       uint64 `json:"bytes"`
	Complete    bool   `json:"complete"`
	Skipped     uint64 `json:"skipped"`
	Errors      uint64 `json:"errors"`
}
type RootStatus struct {
	Path   string `json:"path"`
	State  string `json:"state"`
	Reason string `json:"reason,omitempty"`
}
type Report struct {
	Applications *AppInventory `json:"applications,omitempty"`
	State        string        `json:"state"`
	Reason       string        `json:"reason,omitempty"`
	Observations []Observation `json:"observations"`
	Roots        []RootStatus  `json:"roots"`
	Bytes        uint64        `json:"bytes"`
	Visited      uint64        `json:"visited"`
	Skipped      uint64        `json:"skipped"`
	Errors       uint64        `json:"errors"`
	StartedAt    time.Time     `json:"startedAt"`
	FinishedAt   time.Time     `json:"finishedAt"`
}

func UserRoots(home string) ([]Root, error) {
	if !filepath.IsAbs(home) || filepath.Clean(home) == "/" {
		return nil, fmt.Errorf("a non-root absolute home directory is required")
	}
	return []Root{{filepath.Join(home, "Library/Caches"), "User cache directory"}, {filepath.Join(home, "Library/Logs"), "User log directory"}}, nil
}
func addSize(a, b uint64) (uint64, bool) {
	if ^uint64(0)-a < b {
		return a, false
	}
	return a + b, true
}
