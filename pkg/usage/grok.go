package usage

import (
	"context"
	"encoding/base32"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// GrokBot returns a source for Grok Bot's weekly usage pool. Grok Bot has no
// 5-hour window, so its Limits carry only Week.
//
// Its login is encrypted with a Keychain key WattNook cannot read without a
// prompt, and refreshing it would rotate the token and sign Grok Bot out. So
// this reads the plaintext reading Grok Bot caches for its own UI instead:
// no token, no request. The reading is as fresh as Grok Bot's last refresh
// (every few minutes while it runs), and Limits.AsOf says when that was.
func GrokBot() Source {
	home, _ := os.UserHomeDir()
	return Source{Dir: filepath.Join(home, "Library", "Application Support", "Grok Bot",
		"sand-client-persistence"), Now: time.Now}
}

// Grok Bot names each persisted slice by its key in lowercase unpadded base32.
func grokSliceFile(dir, key string) string {
	name := base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString([]byte(key))
	return filepath.Join(dir, strings.ToLower(name)+".blob")
}

var errGrokFormat = errors.New("unrecognised Grok Bot usage cache")

// GrokLimits reads the weekly window Grok Bot last saw. Once that window has
// reset, the old reading says nothing about the new one, so Week is nil.
func (s Source) GrokLimits(context.Context) (Limits, error) {
	var slot struct {
		SchemaVersion int    `json:"schemaVersion"`
		Value         string `json:"value"`
	}
	data, err := os.ReadFile(grokSliceFile(s.Dir, "sand.client.slice.client-meta.account-slot"))
	if err != nil || json.Unmarshal(data, &slot) != nil || slot.Value == "" {
		return Limits{}, ErrNotSignedIn
	}
	if slot.SchemaVersion != 1 {
		return Limits{}, errGrokFormat
	}
	key := "sand.client.slice.account." + strings.ReplaceAll(slot.Value, "|", "%7C") + ".weekly-usage.cache"
	var cache struct {
		SchemaVersion int `json:"schemaVersion"`
		Value         struct {
			Kind    string `json:"kind"`
			Reading struct {
				Usage *struct {
					PercentUsed *float64 `json:"percentUsed"`
					NextResetMs int64    `json:"nextResetMs"`
				} `json:"usage"`
				ReadAtMs int64 `json:"readAtMs"`
			} `json:"reading"`
		} `json:"value"`
	}
	data, err = os.ReadFile(grokSliceFile(s.Dir, key))
	if err != nil {
		return Limits{}, ErrNotSignedIn
	}
	if json.Unmarshal(data, &cache) != nil || cache.SchemaVersion != 2 {
		return Limits{}, errGrokFormat
	}
	usage := cache.Value.Reading.Usage
	if cache.Value.Kind != "present" || usage == nil || usage.PercentUsed == nil {
		return Limits{}, ErrNotSignedIn
	}
	limits := Limits{AsOf: time.UnixMilli(cache.Value.Reading.ReadAtMs)}
	resets := time.UnixMilli(usage.NextResetMs)
	if usage.NextResetMs > 0 && s.Now().Before(resets) {
		limits.Week = &Window{Percent: clampPercent(*usage.PercentUsed), ResetsAt: resets}
	}
	return limits, nil
}
