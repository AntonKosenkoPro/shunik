package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"testing"
	"time"

	"github.com/antonkosenko/time-of-life/backend/internal/auth"
	"github.com/antonkosenko/time-of-life/backend/internal/db"
	"github.com/antonkosenko/time-of-life/backend/internal/email"
	"github.com/antonkosenko/time-of-life/backend/internal/ratelimit"
)

// shortTTLHandler builds a Handler with the given refresh TTL so TTL
// boundaries are testable without sleeping. Access TTL stays 15m.
func shortTTLHandler(t *testing.T, store db.Store, sender email.Sender, refreshTTL time.Duration) *Handler {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelWarn}))
	return NewHandler(
		store,
		auth.NewTokenService(testJWTSecret, 15*time.Minute, refreshTTL),
		auth.NewOTPService(10*time.Minute, 5),
		sender,
		&RateLimiterGroup{
			OTPRequest: ratelimit.NewTokenBucket(100, 100, time.Minute),
			OTPVerify:  ratelimit.NewTokenBucket(100, 100, time.Minute),
		},
		nil,
		HandlerConfig{},
		logger,
		testRecoveryKeyring(),
	)
}

// backdateRefresh moves a refresh-token row's created_at back by minutes.
func backdateRefresh(t *testing.T, store *db.SQLiteStore, rawToken string, minutes int) {
	t.Helper()
	if _, err := store.DB().Exec(
		`UPDATE refresh_tokens SET created_at = datetime('now', ?) WHERE token_hash = ?`,
		fmt.Sprintf("-%d minutes", minutes), auth.HashToken(rawToken)); err != nil {
		t.Fatalf("backdate refresh token: %v", err)
	}
}

// TestRefresh_ReuseRevokesFamily pins reuse detection: presenting an already
// rotated (revoked) token revokes the whole device family, so even the live
// sibling token is dead afterwards.
func TestRefresh_ReuseRevokesFamily(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	sess := signInDevice(t, h, sender, "reuse@example.com", "device-R")

	w := refreshCall(h, sess.RefreshToken, "device-R")
	if w.Code != http.StatusOK {
		t.Fatalf("first refresh: expected 200, got %d (%s)", w.Code, w.Body.String())
	}
	var rotated authResponse
	if err := json.NewDecoder(w.Body).Decode(&rotated); err != nil {
		t.Fatalf("decode refresh: %v", err)
	}

	// Replay the old (now revoked) token: reuse is detected.
	w = refreshCall(h, sess.RefreshToken, "device-R")
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("replay: expected 401, got %d (%s)", w.Code, w.Body.String())
	}
	if code := errCode(t, w); code != "token_reuse" {
		t.Fatalf("expected token_reuse, got %q", code)
	}

	// The sibling token from the same family is revoked too.
	w = refreshCall(h, rotated.RefreshToken, "device-R")
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("sibling after reuse: expected 401, got %d (%s)", w.Code, w.Body.String())
	}
	if code := errCode(t, w); code != "token_reuse" {
		t.Errorf("expected sibling token_reuse after family revocation, got %q", code)
	}
}

// TestRefresh_TTLBoundary pins the refresh TTL: a token just inside the TTL
// rotates, a token just past it is rejected with refresh_expired (created_at
// is backdated; no sleeps, no flakiness).
func TestRefresh_TTLBoundary(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := shortTTLHandler(t, store, sender, time.Hour)

	sess := signInDevice(t, h, sender, "ttl@example.com", "device-T")

	backdateRefresh(t, store, sess.RefreshToken, 59)
	if w := refreshCall(h, sess.RefreshToken, "device-T"); w.Code != http.StatusOK {
		t.Errorf("inside TTL: expected 200, got %d (%s)", w.Code, w.Body.String())
	}

	sess2 := signInDevice(t, h, sender, "ttl2@example.com", "device-T2")
	backdateRefresh(t, store, sess2.RefreshToken, 61)
	w := refreshCall(h, sess2.RefreshToken, "device-T2")
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("past TTL: expected 401, got %d (%s)", w.Code, w.Body.String())
	}
	if code := errCode(t, w); code != "refresh_expired" {
		t.Errorf("expected refresh_expired, got %q", code)
	}
}

// TestRefresh_RevokedBeforeTTL pins the check ordering: a revoked token is
// token_reuse even when its created_at is also past the TTL (revocation is
// checked first, so replay always burns the family instead of returning
// refresh_expired and leaving live tokens intact).
func TestRefresh_RevokedBeforeTTL(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := shortTTLHandler(t, store, sender, time.Hour)

	sess := signInDevice(t, h, sender, "ordering@example.com", "device-O")

	stored, err := store.GetRefreshToken(context.Background(), auth.HashToken(sess.RefreshToken))
	if err != nil {
		t.Fatalf("GetRefreshToken: %v", err)
	}
	if err := store.RevokeRefreshToken(context.Background(), stored.ID); err != nil {
		t.Fatalf("RevokeRefreshToken: %v", err)
	}
	// Age it past the TTL as well: revocation must still win.
	backdateRefresh(t, store, sess.RefreshToken, 120)

	w := refreshCall(h, sess.RefreshToken, "device-O")
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d (%s)", w.Code, w.Body.String())
	}
	if code := errCode(t, w); code != "token_reuse" {
		t.Errorf("expected token_reuse (revocation first), got %q", code)
	}
}
