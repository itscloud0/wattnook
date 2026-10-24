// Package usage reads the rate limits of the Claude and ChatGPT (Codex)
// subscriptions signed in on this Mac, as their own CLIs report them.
//
// It reuses the logins Claude Code and Codex already keep and only reads
// them: tokens are never refreshed or written back, so WattNook cannot sign
// either tool out. An expired token is reported as such until the tool next
// refreshes it.
package usage

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// Window is one rate-limit window. Percent is how much of it is used, 0–100.
type Window struct {
	Percent  float64
	ResetsAt time.Time
}

// Limits are a provider's short (session) and weekly windows; nil when the
// provider does not report one.
type Limits struct {
	Session *Window
	Week    *Window
}

var (
	ErrNotSignedIn  = errors.New("not signed in")
	ErrTokenExpired = errors.New("login expired; open the app to refresh it")
)

// Source reads one provider's limits.
type Source struct {
	Client *http.Client
	// Credentials returns the stored login; tests replace it.
	Credentials func(context.Context) ([]byte, error)
	Now         func() time.Time
	// URL overrides the provider endpoint in tests.
	URL string
}

const (
	claudeUsageURL = "https://api.anthropic.com/api/oauth/usage"
	codexUsageURL  = "https://chatgpt.com/backend-api/wham/usage"
	userAgent      = "WattNook"
)

// Claude returns a source for Claude Code's login (Keychain item
// "Claude Code-credentials", or ~/.claude/.credentials.json).
func Claude() Source {
	return Source{Client: http.DefaultClient, Credentials: claudeCredentials, Now: time.Now}
}

// Codex returns a source for the Codex CLI's ChatGPT login ($CODEX_HOME or
// ~/.codex/auth.json).
func Codex() Source {
	return Source{Client: http.DefaultClient, Credentials: codexCredentials, Now: time.Now}
}

func claudeCredentials(ctx context.Context) ([]byte, error) {
	// /usr/bin/security created the item for Claude Code, so it can read it
	// without asking; WattNook itself would need a Keychain prompt.
	out, err := exec.CommandContext(ctx, "/usr/bin/security", "find-generic-password",
		"-s", "Claude Code-credentials", "-w").Output()
	if err == nil && len(out) > 0 {
		return out, nil
	}
	home, _ := os.UserHomeDir()
	data, ferr := os.ReadFile(filepath.Join(home, ".claude", ".credentials.json"))
	if ferr != nil {
		return nil, ErrNotSignedIn
	}
	return data, nil
}

func codexCredentials(context.Context) ([]byte, error) {
	dir := os.Getenv("CODEX_HOME")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".codex")
	}
	data, err := os.ReadFile(filepath.Join(dir, "auth.json"))
	if err != nil {
		return nil, ErrNotSignedIn
	}
	return data, nil
}

// ClaudeLimits reads the 5-hour and weekly windows.
func (s Source) ClaudeLimits(ctx context.Context) (Limits, error) {
	raw, err := s.Credentials(ctx)
	if err != nil {
		return Limits{}, err
	}
	var login struct {
		OAuth struct {
			AccessToken string `json:"accessToken"`
			ExpiresAt   int64  `json:"expiresAt"` // Unix milliseconds
		} `json:"claudeAiOauth"`
	}
	if json.Unmarshal(raw, &login) != nil || login.OAuth.AccessToken == "" {
		return Limits{}, ErrNotSignedIn
	}
	if login.OAuth.ExpiresAt > 0 && s.Now().After(time.UnixMilli(login.OAuth.ExpiresAt)) {
		return Limits{}, ErrTokenExpired
	}
	var body struct {
		FiveHour *claudeWindow `json:"five_hour"`
		SevenDay *claudeWindow `json:"seven_day"`
	}
	err = s.get(ctx, s.endpoint(claudeUsageURL), map[string]string{
		"Authorization":  "Bearer " + login.OAuth.AccessToken,
		"anthropic-beta": "oauth-2025-04-20",
	}, &body)
	if err != nil {
		return Limits{}, err
	}
	return Limits{Session: body.FiveHour.window(), Week: body.SevenDay.window()}, nil
}

type claudeWindow struct {
	Utilization *float64 `json:"utilization"`
	ResetsAt    string   `json:"resets_at"`
}

func (w *claudeWindow) window() *Window {
	if w == nil || w.Utilization == nil {
		return nil
	}
	resets, _ := time.Parse(time.RFC3339, w.ResetsAt)
	return &Window{Percent: clampPercent(*w.Utilization), ResetsAt: resets}
}

// CodexLimits reads the primary (5-hour) and secondary (weekly) windows.
func (s Source) CodexLimits(ctx context.Context) (Limits, error) {
	raw, err := s.Credentials(ctx)
	if err != nil {
		return Limits{}, err
	}
	var login struct {
		Tokens struct {
			AccessToken string `json:"access_token"`
			AccountID   string `json:"account_id"`
		} `json:"tokens"`
	}
	if json.Unmarshal(raw, &login) != nil || login.Tokens.AccessToken == "" {
		return Limits{}, ErrNotSignedIn
	}
	headers := map[string]string{"Authorization": "Bearer " + login.Tokens.AccessToken}
	if login.Tokens.AccountID != "" {
		headers["ChatGPT-Account-Id"] = login.Tokens.AccountID
	}
	var body struct {
		RateLimit struct {
			Primary   *codexWindow `json:"primary_window"`
			Secondary *codexWindow `json:"secondary_window"`
		} `json:"rate_limit"`
	}
	if err := s.get(ctx, s.endpoint(codexUsageURL), headers, &body); err != nil {
		return Limits{}, err
	}
	now := s.Now()
	var limits Limits
	// Sort by window length rather than trusting primary/secondary order.
	for _, w := range []*codexWindow{body.RateLimit.Primary, body.RateLimit.Secondary} {
		if w == nil || w.UsedPercent == nil {
			continue
		}
		window := &Window{Percent: clampPercent(*w.UsedPercent)}
		switch {
		case w.ResetAt > 0:
			window.ResetsAt = time.Unix(w.ResetAt, 0)
		case w.ResetAfterSeconds > 0:
			window.ResetsAt = now.Add(time.Duration(w.ResetAfterSeconds) * time.Second)
		}
		if w.LimitWindowSeconds >= 24*60*60 {
			limits.Week = window
		} else {
			limits.Session = window
		}
	}
	return limits, nil
}

type codexWindow struct {
	UsedPercent        *float64 `json:"used_percent"`
	LimitWindowSeconds int64    `json:"limit_window_seconds"`
	ResetAfterSeconds  int64    `json:"reset_after_seconds"`
	ResetAt            int64    `json:"reset_at"`
}

func (s Source) endpoint(fallback string) string {
	if s.URL != "" {
		return s.URL
	}
	return fallback
}

func (s Source) get(ctx context.Context, url string, headers map[string]string, into any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", "application/json")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := s.Client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return err
	}
	switch {
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return ErrTokenExpired
	case resp.StatusCode != http.StatusOK:
		return fmt.Errorf("usage request: HTTP %d", resp.StatusCode)
	}
	return json.Unmarshal(data, into)
}

func clampPercent(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 100 {
		return 100
	}
	return v
}
