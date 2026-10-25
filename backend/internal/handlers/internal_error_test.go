package handlers

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/antonkosenko/shunik/backend/internal/observe"
)

// TestInternalErrorEnvelopePreserved proves a store failure on an authed
// route still returns the generic 500 envelope — with Sentry disabled (the
// empty-DSN contract) and with Sentry enabled (reporting must never alter
// the client response). The closed SQLite store stands in for any production
// store outage (e.g. the SHUNIK-BACKEND-2/3 dependency failure); the outage
// surfaces at the AuthMiddleware account lookup, before Me runs.
func TestInternalErrorEnvelopePreserved(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		name := "disabled"
		if enabled {
			name = "enabled"
		}
		t.Run(name, func(t *testing.T) {
			if enabled {
				// Arm only the flag (restored by Cleanup): with no
				// initialized client, capture short-circuits as a no-op, so
				// this stays truly hermetic — no network I/O, no leftover
				// global client — while ReportError still runs its full
				// enabled branch (filter, tags, fingerprint, context).
				t.Cleanup(observe.SetEnabledForTest(true))
			}

			store := newTestStore(t)
			h := newTestHandler(t, store)
			_, tok := mintBearer(t, store, "internal-error@example.com")
			// Simulate a store outage after auth material exists.
			if err := store.Close(); err != nil {
				t.Fatalf("close store: %v", err)
			}

			req := httptest.NewRequest(http.MethodGet, "/api/v1/auth/me", nil)
			req.Header.Set("Authorization", "Bearer "+tok)
			w := httptest.NewRecorder()
			h.AuthMiddleware(http.HandlerFunc(h.Me)).ServeHTTP(w, req)
			if w.Code != http.StatusInternalServerError {
				t.Fatalf("expected 500, got %d (body=%s)", w.Code, w.Body.String())
			}
			if code := errCode(t, w); code != "internal_error" {
				t.Errorf("expected internal_error envelope, got %q", code)
			}
		})
	}
}
