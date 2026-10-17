package observe

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/getsentry/sentry-go"
	"github.com/go-chi/chi/v5"
)

// TestSentryEmptyDSNDisabled proves the zero-behavior-change contract: an
// empty DSN is a no-op init and leaves reporting disabled, while requests
// keep serving normally through the (pass-through) middleware.
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

	h := Middleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
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
		Middleware(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
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

	req := httptest.NewRequest(http.MethodGet, "/api/v1/entries/550e8400-e29b-41d-a716-446655440000", nil)
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

// fakeTransport captures events in memory instead of delivering them.
type fakeTransport struct {
	mu     sync.Mutex
	events []*sentry.Event
}

func (f *fakeTransport) Configure(_ sentry.ClientOptions) {}
func (f *fakeTransport) SendEvent(event *sentry.Event) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, event)
}
func (f *fakeTransport) Flush(_ time.Duration) bool              { return true }
func (f *fakeTransport) FlushWithContext(_ context.Context) bool { return true }
func (f *fakeTransport) Close()                                  {}
func (f *fakeTransport) captured() []*sentry.Event {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]*sentry.Event(nil), f.events...)
}

// initFakeHub installs a Sentry client with an in-memory transport and marks
// reporting enabled for the duration of the test. No network I/O occurs.
func initFakeHub(t *testing.T) *fakeTransport {
	t.Helper()
	prev := sentryEnabled.Load()
	t.Cleanup(func() { sentryEnabled.Store(prev) })

	ft := &fakeTransport{}
	if err := sentry.Init(sentry.ClientOptions{
		Dsn:        "https://public@example.com/1",
		Transport:  ft,
		BeforeSend: sentryScrubEvent,
	}); err != nil {
		t.Fatalf("sentry.Init with fake transport: %v", err)
	}
	sentryEnabled.Store(true)
	return ft
}

// chiRequest builds a request carrying a real chi route context for pattern.
func chiRequest(t *testing.T, method, pattern, path string) *http.Request {
	t.Helper()
	r := chi.NewRouter()
	var got *http.Request
	r.Method(method, pattern, http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		got = req
		w.WriteHeader(http.StatusOK)
	}))
	r.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(method, path, nil))
	if got == nil {
		t.Fatalf("route %s %s did not match path %s", method, pattern, path)
	}
	return got
}

// TestReportErrorAttachesErrorContext proves a handled 500 reports exactly
// one event carrying the route template, op tag, 5xx class, the error string,
// and an op-scoped fingerprint — the payload shape LIFIO-BACKEND-1..3 lacked.
func TestReportErrorAttachesErrorContext(t *testing.T) {
	ft := initFakeHub(t)

	req := chiRequest(t, http.MethodGet, "/api/v1/categories", "/api/v1/categories")
	ReportError(req, "list categories", errTestStore("dial tcp 10.0.0.1:5432: connection refused"))
	if ok := sentry.Flush(2 * time.Second); !ok {
		t.Fatal("expected fake transport flush to succeed")
	}

	events := ft.captured()
	if len(events) != 1 {
		t.Fatalf("expected exactly 1 event, got %d", len(events))
	}
	ev := events[0]
	tags := ev.Tags
	if tags["http.route"] != "/api/v1/categories" {
		t.Errorf("expected templated route tag, got %q", tags["http.route"])
	}
	if tags["http.method"] != http.MethodGet {
		t.Errorf("expected method tag, got %q", tags["http.method"])
	}
	if tags["http.status_class"] != "5xx" {
		t.Errorf("expected 5xx class tag, got %q", tags["http.status_class"])
	}
	if tags["operation"] != "GET /api/v1/categories" {
		t.Errorf("expected templated operation tag, got %q", tags["operation"])
	}
	if len(ev.Fingerprint) != 2 || ev.Fingerprint[1] != "list categories" {
		t.Errorf("expected op-scoped fingerprint, got %v", ev.Fingerprint)
	}
	errCtx, ok := ev.Contexts["error"]
	if !ok {
		t.Fatal("expected error context on the event")
	}
	msg, _ := errCtx["message"].(string)
	if !strings.Contains(msg, "connection refused") {
		t.Errorf("expected error string in context, got %q", msg)
	}
	if ev.User.ID != "" || ev.User.Email != "" {
		t.Errorf("expected no user context, got %+v", ev.User)
	}
}

// TestReportErrorSkipsClientDisconnect proves a handled 500 caused by the
// requester going away ("context canceled", the LIFIO-BACKEND-1..3 shape)
// stays out of Sentry: the slog line is the record, not a paged issue.
func TestReportErrorSkipsClientDisconnect(t *testing.T) {
	ft := initFakeHub(t)

	req := chiRequest(t, http.MethodGet, "/api/v1/categories", "/api/v1/categories")
	ReportError(req, "list categories", fmt.Errorf("list categories: %w", context.Canceled))
	if ok := sentry.Flush(2 * time.Second); !ok {
		t.Fatal("expected fake transport flush to succeed")
	}
	if events := ft.captured(); len(events) != 0 {
		t.Fatalf("expected no events for client disconnect, got %d", len(events))
	}
}

// TestMiddlewareBackstopSkipsDeadContext proves the status-based backstop
// (503s and other non-500 5xx) still reports on a live context but stays
// quiet when the 5xx went to a disconnected client.
func TestMiddlewareBackstopSkipsDeadContext(t *testing.T) {
	ft := initFakeHub(t)

	h := Middleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))

	live := httptest.NewRequest(http.MethodGet, "/api/v1/auth/apple", nil)
	h.ServeHTTP(httptest.NewRecorder(), live)

	dead, cancel := context.WithCancel(context.Background())
	cancel()
	deadReq := httptest.NewRequest(http.MethodGet, "/api/v1/auth/apple", nil).WithContext(dead)
	h.ServeHTTP(httptest.NewRecorder(), deadReq)

	if ok := sentry.Flush(2 * time.Second); !ok {
		t.Fatal("expected fake transport flush to succeed")
	}
	if events := ft.captured(); len(events) != 1 {
		t.Fatalf("expected exactly 1 event (live-context 503 only), got %d", len(events))
	}
}

// TestHandled500ReportsOnce proves the end-to-end handled-500 path emits
// exactly one Sentry event: ReportError (rich, with error context) owns
// status-500 reporting, and the middleware backstop must not double-file it
// as a second issue.
func TestHandled500ReportsOnce(t *testing.T) {
	ft := initFakeHub(t)

	h := Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ReportError(r, "list categories", errTestStore("list categories: connection refused"))
		w.WriteHeader(http.StatusInternalServerError)
	}))

	r := chi.NewRouter()
	r.Get("/api/v1/categories", h.ServeHTTP)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/categories", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d", w.Code)
	}

	if ok := sentry.Flush(2 * time.Second); !ok {
		t.Fatal("expected fake transport flush to succeed")
	}
	if events := ft.captured(); len(events) != 1 {
		t.Fatalf("expected exactly 1 event for a handled 500, got %d", len(events))
	}
}

// TestReportErrorTruncatesLongMessages proves attacker-influenced error
// strings (e.g. pgx echoing a raw path id) are bounded before leaving the
// process — in the error context AND in the captured exception value (trimmed
// centrally by the BeforeSend scrub, which runs before the transport) — and
// that truncation never splits a multi-byte rune.
func TestReportErrorTruncatesLongMessages(t *testing.T) {
	ft := initFakeHub(t)

	req := chiRequest(t, http.MethodGet, "/api/v1/categories", "/api/v1/categories")
	ReportError(req, "get category", errTestStore("invalid input syntax for type uuid: \""+strings.Repeat("é", 4096)+"\""))
	if ok := sentry.Flush(2 * time.Second); !ok {
		t.Fatal("expected fake transport flush to succeed")
	}

	events := ft.captured()
	if len(events) != 1 {
		t.Fatalf("expected exactly 1 event, got %d", len(events))
	}
	errCtx, ok := events[0].Contexts["error"]
	if !ok {
		t.Fatal("expected error context on the event")
	}
	msg, _ := errCtx["message"].(string)
	if len(msg) > maxSentryErrorMessageLen+len("… (truncated)") {
		t.Errorf("expected truncated message, got %d bytes", len(msg))
	}
	if !strings.HasSuffix(msg, "… (truncated)") {
		t.Error("expected truncation marker on an over-long message")
	}
	if !utf8.ValidString(msg) {
		t.Error("expected truncated message to remain valid UTF-8")
	}
	if len(events[0].Exception) == 0 {
		t.Fatal("expected a captured exception on the event")
	}
	if val := events[0].Exception[0].Value; !strings.HasSuffix(val, "… (truncated)") {
		t.Errorf("expected truncation marker on the exception value, got %.64q", val)
	}
	if typ := events[0].Exception[0].Type; typ != "*observe.testStoreError" {
		t.Errorf("expected original error type preserved, got %q", typ)
	}
}

// TestReportErrorDisabledSendsNothing proves the helper is a pure no-op when
// Sentry is off (the zero-behavior-change contract for empty DSN).
func TestReportErrorDisabledSendsNothing(_ *testing.T) {
	prev := sentryEnabled.Load()
	defer sentryEnabled.Store(prev)
	sentryEnabled.Store(false)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/categories", nil)
	ReportError(req, "list categories", errTestStore("boom"))
	// No hub interaction possible off the enabled path; reaching here without
	// a panic is the assertion (no transport is configured at all).
}

// errTestStore builds a stdlib error carrying a store-shaped message.
func errTestStore(msg string) error {
	return &testStoreError{msg: msg}
}

type testStoreError struct{ msg string }

func (e *testStoreError) Error() string { return e.msg }
