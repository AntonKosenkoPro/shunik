// sentry.go: Sentry error reporting (observability Stage 0).
//
// Reporting is fully disabled when SENTRY_DSN is empty: InitSentry is a no-op,
// SentryEnabled stays false, and sentryMiddleware passes requests through
// untouched (zero behavior change). When a DSN is set, panics and HTTP 5xx
// are captured with context limited to the label allowlist (service,
// templated route, status class, operation) — never user identifiers, emails,
// tokens, entry text, or category names.

package server

import (
	"fmt"
	"net/http"
	"sync/atomic"
	"time"

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

// FlushSentry flushes buffered Sentry events, waiting up to timeout.
func FlushSentry(timeout time.Duration) bool {
	return sentry.Flush(timeout)
}

// sentryMiddleware captures panics and HTTP 5xx for Sentry. It must stay
// registered INSIDE (after) chi's Recoverer: on panic it captures the event
// and re-panics so Recoverer still renders the 500 response.
func sentryMiddleware(next http.Handler) http.Handler {
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
		if ww.Status() >= 500 {
			captureSentry5xx(r, ww.Status())
		}
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
// headers/cookies, server hostname). We never attach those in the first
// place; this guarantees they cannot reach Sentry even if SDK defaults change.
func sentryScrubEvent(event *sentry.Event, _ *sentry.EventHint) *sentry.Event {
	event.User = sentry.User{}
	event.Request = nil
	event.ServerName = ""
	return event
}
