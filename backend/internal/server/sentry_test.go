package server

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/getsentry/sentry-go"
	"github.com/go-chi/chi/v5"
)

// TestSentryEmptyDSNDisabled proves the zero-behavior-change contract: an
// empty DSN is a no-op init and leaves reporting disabled, while the server
// keeps serving normally through the (pass-through) middleware.
func TestSentryEmptyDSNDisabled(t *testing.T) {
	prev := sentryEnabled.Load()
	defer sentryEnabled.Store(prev)
	sentryEnabled.Store(false)

	if err := InitSentry(""); err != nil {
		t.Fatalf("InitSentry(\"\") returned error: %v", err)
	}
	if SentryEnabled() {
		t.Error("expected Sentry to stay disabled with empty DSN")
	}

	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Errorf("expected 200 with Sentry disabled, got %d", w.Code)
	}
}

// TestSentryInitEnablesWithDSN proves a configured DSN flips reporting on.
// sentry.Init performs no network I/O, so a dummy DSN keeps this hermetic;
// no event is captured here, so nothing is ever sent.
func TestSentryInitEnablesWithDSN(t *testing.T) {
	prev := sentryEnabled.Load()
	defer sentryEnabled.Store(prev)
	sentryEnabled.Store(false)

	if err := InitSentry("https://public@example.com/1"); err != nil {
		t.Fatalf("InitSentry(dummy DSN) returned error: %v", err)
	}
	if !SentryEnabled() {
		t.Error("expected Sentry to be enabled with a DSN set")
	}
}

// TestSentryMiddlewareRepanicsForRecoverer proves panic capture composes with
// chi's Recoverer rather than replacing it: the panic must propagate outward
// (where Recoverer renders the 500) instead of being swallowed.
func TestSentryMiddlewareRepanicsForRecoverer(t *testing.T) {
	prev := sentryEnabled.Load()
	defer sentryEnabled.Store(prev)
	sentryEnabled.Store(false)

	if err := InitSentry("https://public@example.com/1"); err != nil {
		t.Fatalf("InitSentry(dummy DSN) returned error: %v", err)
	}

	var outerRecovered any
	outer := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() { outerRecovered = recover() }()
		sentryMiddleware(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
			panic("boom")
		})).ServeHTTP(w, r)
	})

	outer.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/", nil))
	if outerRecovered != "boom" {
		t.Errorf("expected panic to propagate to the outer Recoverer, got %v", outerRecovered)
	}
}

// TestSentryRouteTemplateUsesPattern proves tags carry the route TEMPLATE
// (e.g. /api/v1/entries/{id}), never raw IDs from the request path.
func TestSentryRouteTemplateUsesPattern(t *testing.T) {
	r := chi.NewRouter()
	r.Get("/api/v1/entries/{id}", func(w http.ResponseWriter, r *http.Request) {
		if got := routeTemplate(r); got != "/api/v1/entries/{id}" {
			t.Errorf("expected templated route, got %q", got)
		}
		w.WriteHeader(http.StatusOK)
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/entries/550e8400-e29b-41d4-a716-446655440000", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
}

// TestSentryRouteTemplateUnknownForUnmatched proves unmatched requests never
// leak raw path segments into tags.
func TestSentryRouteTemplateUnknownForUnmatched(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/api/v1/entries/some-raw-id", nil)
	if got := routeTemplate(req); got != "unknown" {
		t.Errorf("expected \"unknown\" without a chi route context, got %q", got)
	}
	if got := operationForRoute("GET", "unknown"); got != "http" {
		t.Errorf("expected \"http\" operation fallback, got %q", got)
	}
}

func TestSentryStatusClassAndOperations(t *testing.T) {
	for status, want := range map[int]string{200: "2xx", 404: "4xx", 500: "5xx", 503: "5xx"} {
		if got := statusClass(status); got != want {
			t.Errorf("statusClass(%d) = %q, want %q", status, got, want)
		}
	}
	if got := operationForRoute("POST", "/api/v1/auth/otp/verify"); got != "otp_verify" {
		t.Errorf("expected otp_verify, got %q", got)
	}
	if got := operationForRoute("GET", "/api/v1/entries/{id}"); got != "GET /api/v1/entries/{id}" {
		t.Errorf("expected templated fallback, got %q", got)
	}
}

// TestSentryScrubRemovesPII proves the BeforeSend backstop strips user
// context, the full HTTP request (headers/cookies), and the server hostname,
// even if an event somehow carries them.
func TestSentryScrubRemovesPII(t *testing.T) {
	event := &sentry.Event{
		User:       sentry.User{ID: "user-123", Email: "someone@example.com"},
		Request:    &sentry.Request{URL: "https://api.example.com/me", Headers: map[string]string{"Cookie": "session=abc"}},
		ServerName: "prod-vm-host",
	}

	got := sentryScrubEvent(event, &sentry.EventHint{})
	if got == nil {
		t.Fatal("expected event to be kept, got nil")
	}
	if got.User.ID != "" || got.User.Email != "" {
		t.Errorf("expected user context stripped, got %+v", got.User)
	}
	if got.Request != nil {
		t.Errorf("expected request stripped, got %+v", got.Request)
	}
	if got.ServerName != "" {
		t.Errorf("expected server name stripped, got %q", got.ServerName)
	}
}
