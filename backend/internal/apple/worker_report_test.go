package apple

// Worker escalation wire-up: a stuck revocation job (attempts/age past the
// alert threshold) must file exactly one stable-fingerprint background
// issue carrying the job context and the sanitized failure — no HTTP
// request, no secrets.

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/getsentry/sentry-go"

	"github.com/antonkosenko/shunik/backend/internal/db"
	"github.com/antonkosenko/shunik/backend/internal/observe"
)

type wiretapTransport struct {
	events chan *sentry.Event
}

func (t *wiretapTransport) Configure(sentry.ClientOptions)        {}
func (t *wiretapTransport) Flush(time.Duration) bool              { return true }
func (t *wiretapTransport) FlushWithContext(context.Context) bool { return true }
func (t *wiretapTransport) Close()                                {}
func (t *wiretapTransport) SendEvent(e *sentry.Event)             { t.events <- e }

func TestWorker_StuckJobFilesBackgroundIssue(t *testing.T) {
	restore := observe.SetEnabledForTest(true)
	defer restore()
	wt := &wiretapTransport{events: make(chan *sentry.Event, 4)}
	client, err := sentry.NewClient(sentry.ClientOptions{
		Dsn: "https://public@example.com/1", Transport: wt,
	})
	if err != nil {
		t.Fatalf("sentry client: %v", err)
	}
	hub := sentry.CurrentHub()
	prev := hub.Client()
	hub.BindClient(client)
	defer hub.BindClient(prev)

	// Past the alert threshold on attempts (age stays young so the attempts
	// leg is what fires).
	keys := testKeyring()
	authTime := time.Now().Add(-time.Minute).UTC().Truncate(time.Second)
	sealed := sealForJob(t, keys, "apple-refresh-stuck", "lin-s", authTime)
	store := &stubDeletionStore{jobs: map[string]db.RevocationJob{
		"job-stuck": {ID: "job-stuck", SubjectDigest: "ds", SealedRefresh: sealed,
			ClientID: "com.test.app", AuthLineage: "lin-s", AuthTime: authTime,
			Attempts: 19, CreatedAt: time.Now().Add(-time.Minute),
			NextAttemptAt: time.Now().Add(-time.Second)},
	}, failed: map[string]time.Time{}}
	w := NewWorker(store, &stubAppleClient{err: ErrAppleUnavailable}, keys, nil, time.Minute)

	if _, err := w.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	select {
	case ev := <-wt.events:
		if len(ev.Fingerprint) != 2 || ev.Fingerprint[1] != "apple-revocation-stuck" {
			t.Fatalf("stable stuck-job fingerprint required, got %v", ev.Fingerprint)
		}
		if bg := ev.Contexts["background"]; bg["job_id"] != "job-stuck" {
			t.Fatalf("job context required, got %+v", bg)
		}
		if len(ev.Exception) == 0 || !strings.Contains(ev.Exception[0].Value, "apple service unavailable") {
			t.Fatalf("sanitized failure required, got %+v", ev.Exception)
		}
		if ev.Tags["service.name"] != "shunik-backend" {
			t.Fatalf("allowlisted tags required, got %v", ev.Tags)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("stuck job filed no background issue")
	}
}
