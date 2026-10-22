// Package observe provides Sentry error reporting (observability Stage 0).
//
// Reporting is fully disabled when SENTRY_DSN is empty: InitSentry is a no-op,
// SentryEnabled stays false, and Middleware passes requests through untouched
// (zero behavior change). When a DSN is set, panics and HTTP 5xx are captured
// with context limited to the label allowlist (service, templated route,
// status class, operation) plus the underlying error string for handled 500s
// — never user identifiers, emails, tokens, entry text, or category names.
//
// It lives in its own leaf package (below server and handlers) so handlers
// can report the error object they hold at the 500 site without an import
// cycle: server imports handlers, and both import observe.
package observe

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/getsentry/sentry-go"
	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"
)

// sentryServiceName is the allowlisted service label attached to Sentry events.
const sentryServiceName = "lifio-backend"

// sentryEnabled reports whether Sentry reporting is active (DSN was provided
// and sentry.Init succeeded).
var sentryEnabled atomic.Bool

// InitSentry initializes Sentry reporting. An empty DSN leaves reporting fully
// disabled and returns nil. A non-empty DSN initializes the SDK; on failure
// the error is returned so the caller can log it and continue without Sentry.
func InitSentry(dsn string) error {
	if dsn == "" {
		return nil
	}
	err := sentry.Init(sentry.ClientOptions{
		Dsn:        dsn,
		BeforeSend: sentryScrubEvent,
	})
	if err != nil {
		return err
	}
	sentryEnabled.Store(true)
	return nil
}

// SentryEnabled reports whether Sentry reporting is active.
func SentryEnabled() bool {
	return sentryEnabled.Load()
}

// SetEnabledForTest flips the reporting flag from tests in other packages
// and returns a restore function the caller must invoke (e.g. via
// t.Cleanup). Production code must use InitSentry. It takes no *testing.T
// so the testing framework stays out of the shipped binary.
func SetEnabledForTest(enabled bool) (restore func()) {
	prev := sentryEnabled.Load()
	sentryEnabled.Store(enabled)
	return func() { sentryEnabled.Store(prev) }
}

// FlushSentry flushes buffered Sentry events, waiting up to timeout.
func FlushSentry(timeout time.Duration) bool {
	return sentry.Flush(timeout)
}

// Middleware captures panics and HTTP 5xx for Sentry. It must stay registered
// INSIDE (after) chi's Recoverer: on panic it captures the event and
// re-panics so Recoverer still renders the 500 response.
func Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !sentryEnabled.Load() {
			next.ServeHTTP(w, r)
			return
		}
		defer func() {
			if rec := recover(); rec != nil {
				captureSentryPanic(r, rec)
				panic(rec)
			}
		}()
		ww := chimw.NewWrapResponseWriter(w, r.ProtoMajor)
		next.ServeHTTP(ww, r)
		// A 5xx on a dead request context means the client went away mid-flight
		// (nginx logs 499): nobody waited for the response, so there is no
		// server fault to page. The handler's slog line is the record.
		// Status 500 is excluded on purpose: handlers report those via
		// ReportError (with the error object attached), so capturing them here
		// too would file every handled failure as two separate Sentry issues.
		// This path backstops the rest: 503s, timeout 504s, and any future
		// 5xx written outside the helper.
		if ww.Status() > 500 && !errors.Is(r.Context().Err(), context.Canceled) {
			captureSentry5xx(r, ww.Status())
		}
	})
}

// ReportError captures a handled HTTP 500 with the underlying error attached.
// It is a no-op unless Sentry is enabled, so handlers call it unconditionally
// next to their slog line; the client envelope is written by the caller and
// stays generic. A nil err degrades to a message-only event rather than a
// misleading empty exception.
func ReportError(r *http.Request, op string, err error) {
	if !sentryEnabled.Load() {
		return
	}
	// Client-gone 500s are not server faults: when the requester disconnects
	// (or the server is shutting down), the context dies mid-query and the
	// handler returns 500 for work nobody waits for. The slog line stays
	// (prod-log lifeline, written by the caller); Sentry stays quiet so
	// client disconnects never page as server issues (precedent:
	// LIFIO-BACKEND-1..3, all "context canceled" behind nginx 499s).
	// DeadlineExceeded still reports — a saturated server is actionable.
	if errors.Is(err, context.Canceled) {
		return
	}
	hub := sentry.CurrentHub().Clone()
	hub.WithScope(func(scope *sentry.Scope) {
		applySentryTags(scope, r, http.StatusInternalServerError)
		scope.SetLevel(sentry.LevelError)
		scope.SetFingerprint([]string{"{{ default }}", op})
		if err == nil {
			hub.CaptureMessage(fmt.Sprintf("server error: %s %s", r.Method, routeTemplate(r)))
			return
		}
		// Bound the error string: store/driver errors can echo request input
		// (e.g. pgx "invalid input syntax for type uuid" quotes the raw path
		// id, which is attacker-controlled and unbounded). Capture the
		// original error so the SDK still records its concrete type and wrap
		// chain; the exception value is bounded centrally in sentryScrubEvent
		// (BeforeSend), which runs after extraction.
		msg := truncateSentryMessage(err.Error())
		scope.SetContext("error", map[string]any{"message": msg, "op": op})
		hub.CaptureException(err)
	})
}

// maxSentryErrorMessageLen caps error strings attached to Sentry events.
const maxSentryErrorMessageLen = 1024

// truncateSentryMessage bounds an error string before it leaves the process,
// backing up to a rune boundary so multi-byte input is never split.
func truncateSentryMessage(msg string) string {
	if len(msg) <= maxSentryErrorMessageLen {
		return msg
	}
	cut := maxSentryErrorMessageLen
	for cut > 0 && !utf8.RuneStart(msg[cut]) {
		cut--
	}
	return msg[:cut] + "… (truncated)"
}

// ReportBackground captures a background-worker failure (no HTTP request
// in scope) with the underlying error attached. It is a no-op unless Sentry
// is enabled, so workers call it unconditionally next to their slog line.
// The event carries only allowlisted tags (service, operation) plus the
// caller-supplied PII-free details — never request data, user identifiers,
// tokens, or secrets. The fingerprint is the stable op segment, so one
// stuck-job class files one Sentry issue however many jobs queue behind it;
// the job id rides in context, never in the fingerprint. Error strings are
// bounded by the same central truncation as ReportError.
// Do not pass a fabricated *http.Request to ReportError to reuse it: it
// dereferences the request (method, route context) and would panic on nil.
func ReportBackground(op string, err error, details map[string]string) {
	if !sentryEnabled.Load() {
		return
	}
	if op == "" {
		op = "background"
	}
	hub := sentry.CurrentHub().Clone()
	hub.WithScope(func(scope *sentry.Scope) {
		scope.SetTag("service.name", sentryServiceName)
		scope.SetTag("operation", op)
		scope.SetLevel(sentry.LevelError)
		scope.SetFingerprint([]string{"{{ default }}", op})
		bg := make(map[string]any, len(details)+1)
		bg["op"] = op
		for k, v := range details {
			bg[k] = v
		}
		scope.SetContext("background", bg)
		if err == nil {
			hub.CaptureMessage("background failure: " + op)
			return
		}
		msg := truncateSentryMessage(err.Error())
		scope.SetContext("error", map[string]any{"message": msg, "op": op})
		hub.CaptureException(err)
	})
}

// captureSentryPanic captures a recovered panic value as a fatal event.
func captureSentryPanic(r *http.Request, rec any) {
	err, ok := rec.(error)
	if !ok {
		err = fmt.Errorf("panic: %v", rec)
	}
	hub := sentry.CurrentHub().Clone()
	hub.WithScope(func(scope *sentry.Scope) {
		applySentryTags(scope, r, http.StatusInternalServerError)
		hub.CaptureException(err)
	})
}

// captureSentry5xx captures an HTTP 5xx response as an error event.
func captureSentry5xx(r *http.Request, status int) {
	hub := sentry.CurrentHub().Clone()
	hub.WithScope(func(scope *sentry.Scope) {
		applySentryTags(scope, r, status)
		scope.SetLevel(sentry.LevelError)
		hub.CaptureMessage(fmt.Sprintf("server error: %s %s -> %d", r.Method, routeTemplate(r), status))
	})
}

// applySentryTags sets only allowlisted tags: service, HTTP method, templated
// route, status class, and operation. No user identifiers, emails, tokens,
// entry text, or category names — those must never become tags.
func applySentryTags(scope *sentry.Scope, r *http.Request, status int) {
	pattern := routeTemplate(r)
	scope.SetTag("service.name", sentryServiceName)
	scope.SetTag("http.method", r.Method)
	scope.SetTag("http.route", pattern)
	scope.SetTag("http.status_class", statusClass(status))
	scope.SetTag("operation", operationForRoute(r.Method, pattern))
}

// routeTemplate returns the chi route pattern (e.g. /api/v1/entries/{id}),
// never the raw path with IDs. Requests that matched no route report
// "unknown" rather than leaking raw path segments into tags.
func routeTemplate(r *http.Request) string {
	if rc := chi.RouteContext(r.Context()); rc != nil {
		if p := rc.RoutePattern(); p != "" {
			return p
		}
	}
	return "unknown"
}

// statusClass maps a status code to its class label (2xx/4xx/5xx).
func statusClass(status int) string {
	return fmt.Sprintf("%dxx", status/100)
}

// sentryOperations maps known method+route-template pairs to operation names.
var sentryOperations = map[string]string{
	"POST /api/v1/auth/otp/request": "otp_request",
	"POST /api/v1/auth/otp/verify":  "otp_verify",
	"POST /api/v1/auth/refresh":     "token_refresh",
	"POST /api/v1/auth/apple":       "apple_signin",
	"POST /api/v1/auth/logout":      "logout",
}

// operationForRoute maps a method + route template to an operation label.
// Unknown combinations fall back to "METHOD template" (still templated, so
// PII-free); unmatched requests fall back to "http".
func operationForRoute(method, pattern string) string {
	if op, ok := sentryOperations[method+" "+pattern]; ok {
		return op
	}
	if pattern == "unknown" {
		return "http"
	}
	return method + " " + pattern
}

// sentryScrubEvent is the BeforeSend backstop: it strips anything that could
// carry PII or infra details (user context, the full HTTP request with
// headers/cookies, server hostname) and bounds exception values (driver
// errors can echo unbounded request input). We never attach those in the
// first place; this guarantees they cannot reach Sentry even if SDK defaults
// change. It runs after exception extraction, so concrete error types and
// wrap chains survive — only the rendered value strings are trimmed.
func sentryScrubEvent(event *sentry.Event, _ *sentry.EventHint) *sentry.Event {
	event.User = sentry.User{}
	event.Request = nil
	event.ServerName = ""
	for i := range event.Exception {
		event.Exception[i].Value = truncateSentryMessage(event.Exception[i].Value)
	}
	return event
}
