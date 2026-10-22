package observe

// Background-reporter tests: ReportBackground must file one stable-fingerprint
// Sentry issue for a stuck background job without any HTTP request in scope —
// allowlisted tags only, job identity in context (never in the fingerprint),
// bounded error strings.

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/getsentry/sentry-go"
)

type captureTransport struct {
	mu     sync.Mutex
	events []*sentry.Event
}

func (t *captureTransport) Configure(sentry.ClientOptions)        {}
func (t *captureTransport) Flush(time.Duration) bool              { return true }
func (t *captureTransport) FlushWithContext(context.Context) bool { return true }
func (t *captureTransport) Close()                                {}
func (t *captureTransport) SendEvent(e *sentry.Event) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.events = append(t.events, e)
}

func (t *captureTransport) all() []*sentry.Event {
	t.mu.Lock()
	defer t.mu.Unlock()
	return append([]*sentry.Event(nil), t.events...)
}

// withCapturedSentry binds a capturing client to the current hub for the
// test and restores the previous client afterwards.
func withCapturedSentry(t *testing.T) *captureTransport {
	t.Helper()
	restore := SetEnabledForTest(true)
	ct := &captureTransport{}
	client, err := sentry.NewClient(sentry.ClientOptions{
		Dsn:        "https://public@example.com/1",
		Transport:  ct,
		BeforeSend: sentryScrubEvent,
	})
	if err != nil {
		t.Fatalf("sentry client: %v", err)
	}
	hub := sentry.CurrentHub()
	prev := hub.Client()
	hub.BindClient(client)
	t.Cleanup(func() {
		hub.BindClient(prev)
		restore()
	})
	return ct
}

func waitForEvents(t *testing.T, ct *captureTransport, n int) []*sentry.Event {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if got := ct.all(); len(got) >= n {
			return got
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %d events, got %d", n, len(ct.all()))
	return nil
}

func TestReportBackgroundFilesStableIssue(t *testing.T) {
	ct := withCapturedSentry(t)

	ReportBackground("apple-revocation-stuck", errors.New("apple revoke: invalid_grant"), map[string]string{
		"job_id": "job-1", "attempts": "21",
	})
	ReportBackground("apple-revocation-stuck", errors.New("apple revoke: invalid_grant"), map[string]string{
		"job_id": "job-2", "attempts": "22",
	})

	got := waitForEvents(t, ct, 2)
	for i, ev := range got {
		if len(ev.Fingerprint) != 2 || ev.Fingerprint[1] != "apple-revocation-stuck" {
			t.Errorf("event %d: fingerprint must be stable per op class, got %v", i, ev.Fingerprint)
		}
		if ev.Tags["service.name"] != sentryServiceName || ev.Tags["operation"] != "apple-revocation-stuck" {
			t.Errorf("event %d: allowlisted tags only, got %v", i, ev.Tags)
		}
		if ev.Request != nil || ev.User.ID != "" || ev.User.Email != "" {
			t.Errorf("event %d: no request/user may attach, got %+v %+v", i, ev.Request, ev.User)
		}
		if len(ev.Exception) == 0 || !strings.Contains(ev.Exception[0].Value, "invalid_grant") {
			t.Errorf("event %d: exception must carry the bounded error, got %+v", i, ev.Exception)
		}
	}
	// Job identity rides in context, never in the fingerprint: two jobs,
	// one issue class.
	bg0 := got[0].Contexts["background"]
	if bg0["job_id"] != "job-1" {
		t.Errorf("expected job context on event 0, got %+v", bg0)
	}
}

func TestReportBackgroundBoundsLongErrors(t *testing.T) {
	ct := withCapturedSentry(t)
	ReportBackground("op", errors.New(strings.Repeat("x", 4*1024)), nil)
	got := waitForEvents(t, ct, 1)
	if len(got[0].Exception) == 0 {
		t.Fatal("expected an exception")
	}
	if len(got[0].Exception[0].Value) > maxSentryErrorMessageLen+32 {
		t.Errorf("exception value must be bounded, got %d chars", len(got[0].Exception[0].Value))
	}
}

func TestReportBackgroundDisabledIsNoop(_ *testing.T) {
	restore := SetEnabledForTest(false)
	defer restore()
	// Must not panic and must not touch the network with no client bound.
	ReportBackground("op", errors.New("boom"), map[string]string{"k": "v"})
}
