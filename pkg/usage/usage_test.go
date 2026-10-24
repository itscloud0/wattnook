package usage

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"
)

var now = time.Date(2026, 10, 24, 19, 0, 0, 0, time.UTC)

func fixture(t *testing.T, login string, status int, body string, check func(*http.Request)) Source {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if check != nil {
			check(r)
		}
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(server.Close)
	return Source{
		Client:      server.Client(),
		Credentials: func(context.Context) ([]byte, error) { return []byte(login), nil },
		Now:         func() time.Time { return now },
		URL:         server.URL,
	}
}

func TestClaudeReadsFiveHourAndWeek(t *testing.T) {
	login := `{"claudeAiOauth":{"accessToken":"tok","expiresAt":` +
		"1793037600000" + `}}` // 2026-10-26
	s := fixture(t, login, 200, `{"five_hour":{"utilization":34.0,"resets_at":"2026-10-24T21:00:00Z"},
		"seven_day":{"utilization":12.5,"resets_at":"2026-10-29T08:00:00Z"},"seven_day_opus":null}`,
		func(r *http.Request) {
			if r.Header.Get("Authorization") != "Bearer tok" || r.Header.Get("anthropic-beta") == "" {
				t.Errorf("headers %v", r.Header)
			}
		})
	limits, err := s.ClaudeLimits(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if limits.Session.Percent != 34 || limits.Week.Percent != 12.5 ||
		!limits.Session.ResetsAt.Equal(time.Date(2026, 10, 24, 21, 0, 0, 0, time.UTC)) {
		t.Fatalf("%+v %+v", limits.Session, limits.Week)
	}
}

func TestClaudeNeverUsesAnExpiredLogin(t *testing.T) {
	login := `{"claudeAiOauth":{"accessToken":"tok","expiresAt":1700000000000}}`
	s := fixture(t, login, 200, `{}`, func(*http.Request) { t.Error("requested with an expired token") })
	if _, err := s.ClaudeLimits(context.Background()); !errors.Is(err, ErrTokenExpired) {
		t.Fatalf("err = %v", err)
	}
}

func TestCodexSortsWindowsByLength(t *testing.T) {
	login := `{"tokens":{"access_token":"tok","account_id":"acct"}}`
	// Weekly listed first: the order must not decide which is which.
	s := fixture(t, login, 200, `{"plan_type":"plus","rate_limit":{
		"primary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_after_seconds":3600},
		"secondary_window":{"used_percent":7,"limit_window_seconds":18000,"reset_at":1793041200}}}`,
		func(r *http.Request) {
			if r.Header.Get("ChatGPT-Account-Id") != "acct" {
				t.Errorf("headers %v", r.Header)
			}
		})
	limits, err := s.CodexLimits(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if limits.Week.Percent != 40 || !limits.Week.ResetsAt.Equal(now.Add(time.Hour)) ||
		limits.Session.Percent != 7 || limits.Session.ResetsAt.Unix() != 1793041200 {
		t.Fatalf("%+v %+v", limits.Session, limits.Week)
	}
}

func TestRejectedLoginReadsAsExpired(t *testing.T) {
	s := fixture(t, `{"tokens":{"access_token":"tok"}}`, 401, `{}`, nil)
	if _, err := s.CodexLimits(context.Background()); !errors.Is(err, ErrTokenExpired) {
		t.Fatalf("err = %v", err)
	}
	s = fixture(t, `{"tokens":{}}`, 200, `{}`, nil)
	if _, err := s.CodexLimits(context.Background()); !errors.Is(err, ErrNotSignedIn) {
		t.Fatalf("err = %v", err)
	}
}

func grokFixture(t *testing.T, cache string) Source {
	t.Helper()
	dir := t.TempDir()
	write := func(key, body string) {
		if err := os.WriteFile(grokSliceFile(dir, key), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write("sand.client.slice.client-meta.account-slot", `{"schemaVersion":1,"value":"google-oauth2|user_1"}`)
	if cache != "" {
		write("sand.client.slice.account.google-oauth2%7Cuser_1.weekly-usage.cache", cache)
	}
	return Source{Dir: dir, Now: func() time.Time { return now }}
}

func TestGrokReadsItsOwnCache(t *testing.T) {
	// 2026-10-28 and 2026-10-24 18:00 UTC.
	s := grokFixture(t, `{"schemaVersion":2,"value":{"kind":"present","reading":{"usage":
		{"percentUsed":40.2,"nextResetMs":1793224800000},"readAtMs":1792864800000},"expiresAtMs":0}}`)
	limits, err := s.GrokLimits(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if limits.Session != nil || limits.Week.Percent != 40.2 || limits.Week.ResetsAt.UnixMilli() != 1793224800000 ||
		limits.AsOf.UnixMilli() != 1792864800000 {
		t.Fatalf("%+v %+v", limits, limits.Week)
	}
	if grokSliceFile("", "sand.client.slice.client-meta.account-slot") !=
		"onqw4zbomnwgszlooqxhg3djmnss4y3mnfsw45bnnvsxiyjomfrwg33vnz2c243mn52a.blob" {
		t.Fatal("slice file name differs from Grok Bot's")
	}
}

func TestGrokForgetsAWindowThatReset(t *testing.T) {
	s := grokFixture(t, `{"schemaVersion":2,"value":{"kind":"present","reading":{"usage":
		{"percentUsed":40,"nextResetMs":1792800000000},"readAtMs":1792700000000}}}`)
	if limits, err := s.GrokLimits(context.Background()); err != nil || limits.Week != nil {
		t.Fatalf("%+v %v", limits, err)
	}
	s = grokFixture(t, "")
	if _, err := s.GrokLimits(context.Background()); !errors.Is(err, ErrNotSignedIn) {
		t.Fatalf("err = %v", err)
	}
	s = grokFixture(t, `{"schemaVersion":3,"value":{}}`)
	if _, err := s.GrokLimits(context.Background()); err == nil {
		t.Fatal("accepted an unknown cache version")
	}
}
