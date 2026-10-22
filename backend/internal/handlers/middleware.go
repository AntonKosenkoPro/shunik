package handlers

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/antonkosenko/time-of-life/backend/internal/auth"
	"github.com/antonkosenko/time-of-life/backend/internal/db"
)

// contextKey is a private type used for context keys to avoid collisions.
type contextKey string

const (
	// ContextKeyUserID is the context key for the authenticated user's ID.
	ContextKeyUserID contextKey = "userID"
)

// AuthMiddleware returns an HTTP middleware that validates JWT Bearer tokens
// from the Authorization header. On success, the userID and email are stored
// in the request context. On failure, a 401 response is returned.
func (h *Handler) AuthMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authHeader := r.Header.Get("Authorization")
		if authHeader == "" {
			h.logger.Warn("missing authorization header")
			writeError(w, http.StatusUnauthorized, "unauthorized", "Missing authorization header", nil)
			return
		}

		parts := strings.SplitN(authHeader, " ", 2)
		if len(parts) != 2 || !strings.EqualFold(parts[0], "bearer") {
			h.logger.Warn("malformed authorization header")
			writeError(w, http.StatusUnauthorized, "unauthorized", "Invalid authorization header format", nil)
			return
		}

		tokenStr := parts[1]
		claims, err := h.tokenService.ValidateAccessTokenDetailed(tokenStr)
		if err != nil {
			h.logger.Warn("invalid access token", "error", err)
			writeError(w, http.StatusUnauthorized, "unauthorized", "Invalid or expired access token", nil)
			return
		}

		// The account must still exist: signature-only validity is not
		// enough. A purged account's old tokens authorize nothing (generic
		// 401, never a wipe instruction), and a storage failure stays a
		// 5xx — never a deletion verdict.
		user, err := h.store.GetUserByID(r.Context(), claims.Subject)
		if err != nil {
			if isNotFound(err) {
				h.logger.Warn("access token for purged account")
				writeError(w, http.StatusUnauthorized, "unauthorized", "Invalid or expired access token", nil)
				return
			}
			h.writeInternalError(w, r, "access account lookup failed", err)
			return
		}

		// A set Apple consent cutoff ends pre-event sessions. Only sessions
		// whose own authorization time is at/after the cutoff pass — the
		// access claim carries that time, so a second post-revocation device
		// never kills the first. Lineageless claims (email, pre-lineage)
		// fail closed once a cutoff exists.
		if h.sessionCutByRevocation(accessAuthTime(claims), lineagePtr(claims.AuthLineage), user) {
			h.logger.Warn("access cut off by apple consent revocation", "userID", user.ID)
			writeError(w, http.StatusUnauthorized, "unauthorized", "Invalid or expired access token", nil)
			return
		}

		ctx := context.WithValue(r.Context(), ContextKeyUserID, claims.Subject)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// lineagePtr normalizes an access claim lineage for the cutoff check: empty
// means pre-lineage (nil), which can never pass a set cutoff.
func lineagePtr(lineage string) *string {
	if lineage == "" {
		return nil
	}
	return &lineage
}

// accessAuthTime recovers the session's original verified authorization time
// from an access claim for the cutoff check: nil when the claim carries
// none (email-OTP and pre-lineage sessions fail closed under a cutoff).
func accessAuthTime(claims *auth.AccessTokenClaims) *time.Time {
	if claims.AuthTimeUnix == nil {
		return nil
	}
	t := time.Unix(*claims.AuthTimeUnix, 0)
	return &t
}

// isNotFound reports the store's missing-resource error across engines.
func isNotFound(err error) bool { return errors.Is(err, db.ErrNotFound) }

// UserIDFromContext extracts the authenticated user's ID from the request context.
func UserIDFromContext(ctx context.Context) (string, bool) {
	id, ok := ctx.Value(ContextKeyUserID).(string)
	return id, ok
}
