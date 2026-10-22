package apple

// Apple 400 error bodies may echo request material (tokens, codes), and
// postForm error strings flow into operator logs and revocation-job
// last_error. These tests pin the redaction contract: only allowlisted
// machine-readable error codes may appear — never raw response bytes.

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/antonkosenko/time-of-life/backend/internal/db"
)

const echoCanary = "CANARY-SECRET-abcdef-123456"

// echo400Server returns Apple's 400 with a body echoing the canary, proving
// whether client errors carry raw response bytes.
func echo400Server() *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":"invalid_grant","error_description":"token ` + echoCanary + ` echoed"}`))
	}))
}

func TestAppleErrorBodyNeverEchoesSecret(t *testing.T) {
	srv := echo400Server()
	defer srv.Close()
	c := newTestClient(t, srv)

	if _, err := c.ExchangeCode(t.Context(), "code"); err == nil {
		t.Fatal("expected error")
	} else {
		if !errors.Is(err, ErrInvalidGrant) {
			t.Fatalf("expected ErrInvalidGrant, got %v", err)
		}
		if strings.Contains(err.Error(), echoCanary) {
			t.Fatalf("LEAK: 400 echo reached ExchangeCode error: %v", err)
		}
	}

	if err := c.RevokeToken(t.Context(), "refresh"); err == nil {
		t.Fatal("expected error")
	} else {
		if !errors.Is(err, ErrInvalidGrant) {
			t.Fatalf("expected ErrInvalidGrant, got %v", err)
		}
		if strings.Contains(err.Error(), echoCanary) {
			t.Fatalf("LEAK: 400 echo reached RevokeToken error: %v", err)
		}
	}
}

func TestAppleErrorCodeAllowlisted(t *testing.T) {
	if got := appleErrorCode([]byte(`{"error":"invalid_grant"}`)); got != "invalid_grant" {
		t.Errorf("allowlisted apple code must surface verbatim, got %q", got)
	}
	for _, body := range []string{"not-json", `{"error":"some_unlisted_code"}`, `{"error_description":"no code key"}`, ``} {
		if got := appleErrorCode([]byte(body)); got != "invalid_request" {
			t.Errorf("unallowlisted body %q must map to invalid_request, got %q", body, got)
		}
	}
}

// capturingStore records the failure strings the worker persists into
// revocation-job last_error (the stub in worker_test.go drops them).
type capturingStore struct {
	stubDeletionStore
	lastErr map[string]string
}

func (s *capturingStore) FailRevocationJob(_ context.Context, id, msg string, next time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.lastErr == nil {
		s.lastErr = map[string]string{}
	}
	s.lastErr[id] = msg
	j := s.jobs[id]
	j.NextAttemptAt = next
	s.jobs[id] = j
	return nil
}

// TestWorkerLastErrorNeverEchoesSecret proves the persisted last_error (and
// therefore the escalated operator log that echoes it) carries only the
// allowlisted code when Apple 400s with an echoing body.
func TestWorkerLastErrorNeverEchoesSecret(t *testing.T) {
	srv := echo400Server()
	defer srv.Close()
	client := newTestClient(t, srv)

	keys := testKeyring()
	authTime := time.Now().Add(-time.Minute).UTC().Truncate(time.Second)
	sealed := sealForJob(t, keys, "apple-refresh-echo", "lin-e", authTime)
	store := &capturingStore{stubDeletionStore: stubDeletionStore{jobs: map[string]db.RevocationJob{
		"job-e": {SubjectDigest: "de", SealedRefresh: sealed, ClientID: "com.test.app",
			AuthLineage: "lin-e", AuthTime: authTime, NextAttemptAt: time.Now().Add(-time.Minute)},
	}}}
	w := NewWorker(store, client, keys, nil, time.Minute)

	if _, err := w.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	if len(store.completed) != 0 {
		t.Fatal("echo-400 job must not complete")
	}
	msg, ok := store.lastErr["job-e"]
	if !ok {
		t.Fatal("failed job must persist last_error")
	}
	if strings.Contains(msg, echoCanary) {
		t.Fatalf("LEAK: canary reached persisted last_error: %q", msg)
	}
	if !strings.Contains(msg, "invalid_grant") {
		t.Fatalf("expected allowlisted code in last_error, got %q", msg)
	}
}
