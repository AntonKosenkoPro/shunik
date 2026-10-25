package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/antonkosenko/shunik/backend/internal/auth"
)

// refreshCallWithAttempt performs POST /auth/refresh with a device id and an
// optional attempt: nil omits refresh_attempt_id (legacy behavior).
func refreshCallWithAttempt(h *Handler, refreshToken, deviceID string, attempt *string) *httptest.ResponseRecorder {
	bodyMap := map[string]any{"refresh_token": refreshToken}
	if attempt != nil {
		bodyMap["refresh_attempt_id"] = *attempt
	}
	body, _ := json.Marshal(bodyMap)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/refresh", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if deviceID != "" {
		req.Header.Set("X-Device-Id", deviceID)
	}
	w := httptest.NewRecorder()
	h.RefreshToken(w, req)
	return w
}

func attemptPtr(s string) *string { return &s }

// refreshWithAttempt rotates with an attempt and returns the issued pair.
func refreshWithAttempt(t *testing.T, h *Handler, refreshToken, deviceID, attempt string) authResponse {
	t.Helper()
	w := refreshCallWithAttempt(h, refreshToken, deviceID, attemptPtr(attempt))
	if w.Code != http.StatusOK {
		t.Fatalf("refresh with attempt: expected 200, got %d: %s", w.Code, w.Body.String())
	}
	var resp authResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("decode refresh response: %v", err)
	}
	return resp
}

// TestRecovery_LostResponseReplayReturnsSameSuccessor pins the core fix: a
// committed rotation whose response is lost is recovered by repeating the
// same predecessor and attempt — the identical successor plus a fresh
// access token, without rotating again and without revocation.
func TestRecovery_LostResponseReplayReturnsSameSuccessor(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	sess := signInDevice(t, h, sender, "lost@example.com", "device-A")

	first := refreshWithAttempt(t, h, sess.RefreshToken, "device-A", "attempt-1")

	// The response is "lost": retry with the same predecessor and attempt.
	second := refreshWithAttempt(t, h, sess.RefreshToken, "device-A", "attempt-1")

	if second.RefreshToken != first.RefreshToken {
		t.Error("recovery must return the same successor, not rotate forward")
	}
	if second.AccessToken == "" {
		t.Error("recovery must return a fresh access token")
	}

	// Repeated loss keeps returning the original successor.
	third := refreshWithAttempt(t, h, sess.RefreshToken, "device-A", "attempt-1")
	if third.RefreshToken != first.RefreshToken {
		t.Error("repeated recovery must keep returning the original successor")
	}

	// The family is alive: the recovered successor rotates forward with a
	// new attempt.
	fourth := refreshWithAttempt(t, h, first.RefreshToken, "device-A", "attempt-2")
	if fourth.RefreshToken == first.RefreshToken {
		t.Error("expected the successor to rotate forward with a new attempt")
	}
}

// TestRecovery_WrongAttemptKeepsReuse pins that a different (or missing)
// attempt replaying a revoked predecessor is genuine reuse: token_reuse and
// the family burns — only the eligible retry escapes it.
func TestRecovery_WrongAttemptKeepsReuse(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	sess := signInDevice(t, h, sender, "reuse-attempt@example.com", "device-A")
	rotated := refreshWithAttempt(t, h, sess.RefreshToken, "device-A", "attempt-1")

	// Same revoked predecessor, different attempt: token_reuse + family burn.
	w := refreshCallWithAttempt(h, sess.RefreshToken, "device-A", attemptPtr("attempt-other"))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", w.Code, w.Body.String())
	}
	if code := errCode(t, w); code != "token_reuse" {
		t.Fatalf("expected token_reuse, got %q", code)
	}
	if found, live := sessionState(t, store, rotated.RefreshToken); !found || live {
		t.Errorf("expected family burned after wrong-attempt replay, found=%v live=%v", found, live)
	}

	// Missing attempt on the same revoked predecessor: legacy token_reuse.
	sess2 := signInDevice(t, h, sender, "reuse-legacy@example.com", "device-B")
	rotated2 := refreshWithAttempt(t, h, sess2.RefreshToken, "device-B", "attempt-9")
	w = refreshCallWithAttempt(h, sess2.RefreshToken, "device-B", nil)
	if w.Code != http.StatusUnauthorized || errCode(t, w) != "token_reuse" {
		t.Fatalf("expected legacy token_reuse, got %d: %s", w.Code, w.Body.String())
	}
	if found, live := sessionState(t, store, rotated2.RefreshToken); !found || live {
		t.Errorf("expected family burned after legacy replay, found=%v live=%v", found, live)
	}
}

// TestRecovery_ReboundAttemptConflicts pins that an accepted attempt
// submitted for a different predecessor is a 409 conflict — no credentials,
// no receipt overwrite, no revocation.
func TestRecovery_ReboundAttemptConflicts(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	sess := signInDevice(t, h, sender, "rebind@example.com", "device-A")
	first := refreshWithAttempt(t, h, sess.RefreshToken, "device-A", "attempt-1")

	// The live successor presented with the predecessor's attempt: rebound.
	w := refreshCallWithAttempt(h, first.RefreshToken, "device-A", attemptPtr("attempt-1"))
	if w.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d: %s", w.Code, w.Body.String())
	}
	if code := errCode(t, w); code != "refresh_attempt_conflict" {
		t.Fatalf("expected refresh_attempt_conflict, got %q", code)
	}

	// Nothing was issued or revoked: the successor is still live.
	if found, live := sessionState(t, store, first.RefreshToken); !found || !live {
		t.Errorf("expected successor family intact, found=%v live=%v", found, live)
	}
	if w := refreshCallWithAttempt(h, first.RefreshToken, "device-A", attemptPtr("attempt-2")); w.Code != http.StatusOK {
		t.Errorf("expected successor still rotatable, got %d: %s", w.Code, w.Body.String())
	}
}

// TestRecovery_ConsumedAttemptCompleted pins that once the successor rotates
// forward, a delayed exact duplicate of the closed attempt returns 409
// refresh_attempt_completed without touching the family.
func TestRecovery_ConsumedAttemptCompleted(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	sess := signInDevice(t, h, sender, "completed@example.com", "device-A")
	first := refreshWithAttempt(t, h, sess.RefreshToken, "device-A", "attempt-1")
	second := refreshWithAttempt(t, h, first.RefreshToken, "device-A", "attempt-2")

	// Delayed duplicate of the closed attempt.
	w := refreshCallWithAttempt(h, sess.RefreshToken, "device-A", attemptPtr("attempt-1"))
	if w.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d: %s", w.Code, w.Body.String())
	}
	if code := errCode(t, w); code != "refresh_attempt_completed" {
		t.Fatalf("expected refresh_attempt_completed, got %q", code)
	}

	// The live family is untouched: the current successor still works.
	if w := refreshCallWithAttempt(h, second.RefreshToken, "device-A", attemptPtr("attempt-3")); w.Code != http.StatusOK {
		t.Errorf("expected live family after completed duplicate, got %d: %s", w.Code, w.Body.String())
	}
}

// TestRecovery_ExpiredReceipt pins that recovery past the successor's fixed
// refresh expiry returns refresh_expired without renewing the session.
func TestRecovery_ExpiredReceipt(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	sess := signInDevice(t, h, sender, "expired@example.com", "device-A")
	first := refreshWithAttempt(t, h, sess.RefreshToken, "device-A", "attempt-1")
	if first.RefreshToken == "" {
		t.Fatal("expected a successor")
	}

	// Age the receipt past the successor's refresh expiry.
	attemptHash := auth.HashToken("attempt-1")
	if _, err := store.DB().Exec(
		`UPDATE refresh_recovery_receipts SET expires_at = datetime('now', '-1 hour') WHERE attempt_hash = ?`,
		attemptHash); err != nil {
		t.Fatalf("backdate receipt expiry: %v", err)
	}

	w := refreshCallWithAttempt(h, sess.RefreshToken, "device-A", attemptPtr("attempt-1"))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", w.Code, w.Body.String())
	}
	if code := errCode(t, w); code != "refresh_expired" {
		t.Fatalf("expected refresh_expired, got %q", code)
	}

	// The expiry rejection closes the receipt, so the retention sweep
	// reclaims the row once it is long past expiry.
	receipt, err := store.FindRecoveryReceipt(context.Background(), attemptHash)
	if err != nil {
		t.Fatalf("FindRecoveryReceipt: %v", err)
	}
	if !receipt.Consumed {
		t.Error("expiry rejection must close the receipt for later sweeping")
	}
}

// TestRecovery_WrongDeviceNoRevocationNoRecovery pins that a different
// device presenting the token and attempt gets invalid_refresh with no
// credentials, no recovery, and no revocation of the legitimate family.
func TestRecovery_WrongDeviceNoRevocationNoRecovery(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	sess := signInDevice(t, h, sender, "wrongdev-rec@example.com", "device-A")

	w := refreshCallWithAttempt(h, sess.RefreshToken, "device-B", attemptPtr("attempt-1"))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", w.Code, w.Body.String())
	}
	if code := errCode(t, w); code != "invalid_refresh" {
		t.Fatalf("expected invalid_refresh, got %q", code)
	}
	if found, live := sessionState(t, store, sess.RefreshToken); !found || !live {
		t.Errorf("expected legitimate family intact, found=%v live=%v", found, live)
	}

	// The legitimate device recovers normally afterwards.
	if w := refreshCallWithAttempt(h, sess.RefreshToken, "device-A", attemptPtr("attempt-1")); w.Code != http.StatusOK {
		t.Errorf("expected legitimate recovery to succeed, got %d: %s", w.Code, w.Body.String())
	}
}

// TestRecovery_ConcurrentDuplicatesConverge pins that concurrent duplicate
// deliveries of one logical attempt all succeed with the same successor.
func TestRecovery_ConcurrentDuplicatesConverge(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	sess := signInDevice(t, h, sender, "concurrent@example.com", "device-A")

	const callers = 8
	type result struct {
		code    int
		refresh string
	}
	results := make([]result, callers)
	var wg sync.WaitGroup
	for i := 0; i < callers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			w := refreshCallWithAttempt(h, sess.RefreshToken, "device-A", attemptPtr("attempt-shared"))
			var resp authResponse
			if w.Code == http.StatusOK {
				_ = json.NewDecoder(w.Body).Decode(&resp)
			}
			results[i] = result{code: w.Code, refresh: resp.RefreshToken}
		}(i)
	}
	wg.Wait()

	for i, res := range results {
		if res.code != http.StatusOK {
			t.Fatalf("caller %d: expected 200, got %d", i, res.code)
		}
		if res.refresh == "" {
			t.Fatalf("caller %d: expected a successor", i)
		}
		if res.refresh != results[0].refresh {
			t.Fatalf("caller %d: duplicate deliveries must converge on one successor", i)
		}
	}
}

// TestRecovery_ServiceFailuresAre5xx pins that database, crypto, and receipt
// failures surface 5xx service errors — never invalid_refresh — and revoke
// nothing.
func TestRecovery_ServiceFailuresAre5xx(t *testing.T) {
	t.Run("store outage on first rotation", func(t *testing.T) {
		store := newTestStore(t)
		sender := &captureSender{}
		h := newTestHandlerWithDependencies(t, store, nil, sender)

		sess := signInDevice(t, h, sender, "outage@example.com", "device-A")
		if err := store.Close(); err != nil {
			t.Fatalf("close store: %v", err)
		}

		w := refreshCallWithAttempt(h, sess.RefreshToken, "device-A", attemptPtr("attempt-1"))
		if w.Code != http.StatusInternalServerError {
			t.Fatalf("expected 500, got %d: %s", w.Code, w.Body.String())
		}
		if code := errCode(t, w); code != "internal_error" {
			t.Fatalf("expected internal_error, got %q", code)
		}
	})

	t.Run("tampered receipt is a service error", func(t *testing.T) {
		store := newTestStore(t)
		sender := &captureSender{}
		h := newTestHandlerWithDependencies(t, store, nil, sender)

		sess := signInDevice(t, h, sender, "tamper@example.com", "device-A")
		first := refreshWithAttempt(t, h, sess.RefreshToken, "device-A", "attempt-1")
		if first.RefreshToken == "" {
			t.Fatal("expected a successor")
		}

		// Corrupt the sealed successor: authentication must fail and the
		// retry must be a service error, not an auth rejection.
		attemptHash := auth.HashToken("attempt-1")
		if _, err := store.DB().Exec(
			`UPDATE refresh_recovery_receipts SET sealed_successor = ? WHERE attempt_hash = ?`,
			[]byte("tampered-ciphertext"), attemptHash); err != nil {
			t.Fatalf("tamper receipt: %v", err)
		}

		w := refreshCallWithAttempt(h, sess.RefreshToken, "device-A", attemptPtr("attempt-1"))
		if w.Code != http.StatusInternalServerError {
			t.Fatalf("expected 500, got %d: %s", w.Code, w.Body.String())
		}
		if code := errCode(t, w); code != "internal_error" {
			t.Fatalf("expected internal_error, got %q", code)
		}
	})
}

// TestRecovery_MissingAttemptKeepsLegacyBehavior pins that requests without
// refresh_attempt_id rotate exactly as before, with no recovery receipt.
func TestRecovery_MissingAttemptKeepsLegacyBehavior(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	sess := signInDevice(t, h, sender, "legacy@example.com", "device-A")

	w := refreshCallWithAttempt(h, sess.RefreshToken, "device-A", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	var rotated authResponse
	if err := json.NewDecoder(w.Body).Decode(&rotated); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if rotated.RefreshToken == sess.RefreshToken {
		t.Fatal("expected rotation to mint a new refresh token")
	}

	// No receipt was recorded: presenting the revoked predecessor with an
	// attempt is an unknown replay → token_reuse.
	w = refreshCallWithAttempt(h, sess.RefreshToken, "device-A", attemptPtr("attempt-1"))
	if w.Code != http.StatusUnauthorized || errCode(t, w) != "token_reuse" {
		t.Fatalf("expected token_reuse, got %d: %s", w.Code, w.Body.String())
	}
}

// TestRecovery_LogoutClosesReceipt pins that logout revokes the successor
// and closes the receipt: replaying the attempt returns 409 without
// recreating the session.
func TestRecovery_LogoutClosesReceipt(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	sess := signInDevice(t, h, sender, "logout-rec@example.com", "device-A")
	first := refreshWithAttempt(t, h, sess.RefreshToken, "device-A", "attempt-1")

	if w := logoutCall(h, first, "device-A"); w.Code != http.StatusNoContent {
		t.Fatalf("logout: expected 204, got %d: %s", w.Code, w.Body.String())
	}

	w := refreshCallWithAttempt(h, sess.RefreshToken, "device-A", attemptPtr("attempt-1"))
	if w.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d: %s", w.Code, w.Body.String())
	}
	if code := errCode(t, w); code != "refresh_attempt_completed" {
		t.Fatalf("expected refresh_attempt_completed, got %q", code)
	}
}

// TestRecovery_InvalidAttemptRejected pins that a malformed attempt id is a
// 400 without touching the family.
func TestRecovery_InvalidAttemptRejected(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	sess := signInDevice(t, h, sender, "badattempt@example.com", "device-A")

	long := make([]byte, 200)
	for i := range long {
		long[i] = 'x'
	}
	w := refreshCallWithAttempt(h, sess.RefreshToken, "device-A", attemptPtr(string(long)))
	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", w.Code, w.Body.String())
	}
	if code := errCode(t, w); code != "invalid_body" {
		t.Fatalf("expected invalid_body, got %q", code)
	}
	if found, live := sessionState(t, store, sess.RefreshToken); !found || !live {
		t.Errorf("expected family intact, found=%v live=%v", found, live)
	}
}
