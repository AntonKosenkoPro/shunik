package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/antonkosenko/shunik/backend/internal/apple"
	"github.com/antonkosenko/shunik/backend/internal/auth"
	"github.com/antonkosenko/shunik/backend/internal/db"
	"github.com/antonkosenko/shunik/backend/internal/email"
)

// refreshCall performs POST /auth/refresh with the given token and device id.
func refreshCall(h *Handler, refreshToken, deviceID string) *httptest.ResponseRecorder {
	body, _ := json.Marshal(map[string]string{"refresh_token": refreshToken})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/refresh", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if deviceID != "" {
		req.Header.Set("X-Device-Id", deviceID)
	}
	w := httptest.NewRecorder()
	h.RefreshToken(w, req)
	return w
}

// logoutCall performs POST /auth/logout for the authResponse's user with the
// given device id. AuthMiddleware is bypassed by injecting the userID into
// the request context directly.
func logoutCall(h *Handler, sess authResponse, deviceID string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/logout", nil)
	req.Header.Set("X-Device-Id", deviceID)
	ctx := context.WithValue(req.Context(), ContextKeyUserID, sess.User.ID)
	w := httptest.NewRecorder()
	h.Logout(w, req.WithContext(ctx))
	return w
}

// sessionState reports whether a raw refresh token still resolves to a live
// (present, non-revoked) row in the store.
func sessionState(t *testing.T, store *db.SQLiteStore, refreshToken string) (found, live bool) {
	t.Helper()
	stored, err := store.GetRefreshToken(t.Context(), auth.HashToken(refreshToken))
	if err != nil {
		if strings.Contains(err.Error(), "not found") {
			return false, false
		}
		t.Fatalf("GetRefreshToken: %v", err)
	}
	return true, !stored.Revoked
}

// deviceIDOf returns the device_id persisted on the refresh-token row.
func deviceIDOf(t *testing.T, store *db.SQLiteStore, refreshToken string) string {
	t.Helper()
	stored, err := store.GetRefreshToken(t.Context(), auth.HashToken(refreshToken))
	if err != nil {
		t.Fatalf("GetRefreshToken: %v", err)
	}
	return stored.DeviceID
}

// signInDevice runs the OTP flow for email from deviceID and returns the
// issued token pair.
func signInDevice(t *testing.T, h *Handler, sender *captureSender, email, deviceID string) authResponse {
	t.Helper()
	sent := len(sender.messages)
	w := requestOTP(t, h, email)
	if w.Code != http.StatusAccepted {
		t.Fatalf("otp request: expected 202, got %d", w.Code)
	}
	w = verifyOTPWithDevice(t, h, email, otpFromMessage(t, sender.messages[sent]), deviceID)
	if w.Code != http.StatusOK {
		t.Fatalf("otp verify [%s]: expected 200, got %d: %s", deviceID, w.Code, w.Body.String())
	}
	var resp authResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("decode auth response: %v", err)
	}
	return resp
}

// otpFromMessage extracts the six-digit code from one captured OTP email.
func otpFromMessage(t *testing.T, message email.Message) string {
	t.Helper()
	for _, line := range strings.Split(message.Text, "\n") {
		code := strings.TrimSpace(line)
		if validateCode(code) {
			return code
		}
	}
	t.Fatal("OTP email did not contain a six-digit code")
	return ""
}

func TestDeviceSessions_RotationStaysInFamily(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	sess := signInDevice(t, h, sender, "rotate@example.com", "device-A")

	if got := deviceIDOf(t, store, sess.RefreshToken); got != "device-A" {
		t.Fatalf("expected refresh row device_id device-A, got %q", got)
	}

	w := refreshCall(h, sess.RefreshToken, "device-A")
	if w.Code != http.StatusOK {
		t.Fatalf("refresh: expected 200, got %d: %s", w.Code, w.Body.String())
	}
	var rotated authResponse
	if err := json.NewDecoder(w.Body).Decode(&rotated); err != nil {
		t.Fatalf("decode refresh response: %v", err)
	}

	if rotated.RefreshToken == sess.RefreshToken {
		t.Fatal("expected rotation to mint a new refresh token")
	}
	if got := deviceIDOf(t, store, rotated.RefreshToken); got != "device-A" {
		t.Errorf("expected rotated token in same family (device-A), got %q", got)
	}
	if found, live := sessionState(t, store, sess.RefreshToken); !found || live {
		t.Errorf("expected old token revoked, found=%v live=%v", found, live)
	}
}

func TestDeviceSessions_VerifyRejectsMissingDeviceID(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	w := requestOTP(t, h, "nodevice@example.com")
	if w.Code != http.StatusAccepted {
		t.Fatalf("otp request: expected 202, got %d", w.Code)
	}
	w = verifyOTPWithDevice(t, h, "nodevice@example.com", capturedOTP(t, sender), "")
	if w.Code != http.StatusBadRequest {
		t.Errorf("expected 400 for missing X-Device-Id, got %d", w.Code)
	}
}

func TestDeviceSessions_ReuseKillsOnlyItsFamily(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	// Two devices sign in for the same user.
	sessA := signInDevice(t, h, sender, "reuse@example.com", "device-A")
	sessB := signInDevice(t, h, sender, "reuse@example.com", "device-B")

	// Device A rotates once, then replays the original (stale) token.
	if w := refreshCall(h, sessA.RefreshToken, "device-A"); w.Code != http.StatusOK {
		t.Fatalf("first refresh: expected 200, got %d", w.Code)
	}
	if w := refreshCall(h, sessA.RefreshToken, "device-A"); w.Code != http.StatusUnauthorized {
		t.Fatalf("replayed refresh: expected 401, got %d", w.Code)
	}

	// Device A's family is dead — a second replay is rejected too.
	if w := refreshCall(h, sessA.RefreshToken, "device-A"); w.Code != http.StatusUnauthorized {
		t.Errorf("expected repeated replay rejected, got %d", w.Code)
	}
	if found, live := sessionState(t, store, sessA.RefreshToken); !found || live {
		t.Errorf("expected reused token revoked, found=%v live=%v", found, live)
	}

	// Device B's session keeps working.
	if w := refreshCall(h, sessB.RefreshToken, "device-B"); w.Code != http.StatusOK {
		t.Errorf("expected device-B session to survive reuse, got %d: %s", w.Code, w.Body.String())
	}
}

// TestDeviceSessions_RevokedReplayBeyondTTLKillsFamily covers the
// revoked-before-TTL ordering: a replayed revoked token whose created_at is
// older than the refresh TTL must still report token_reuse (not
// refresh_expired) and revoke the live family tokens.
func TestDeviceSessions_RevokedReplayBeyondTTLKillsFamily(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	sess := signInDevice(t, h, sender, "stale-reuse@example.com", "device-A")

	// Rotate once: the original token is now revoked, the new one is live.
	w := refreshCall(h, sess.RefreshToken, "device-A")
	if w.Code != http.StatusOK {
		t.Fatalf("first refresh: expected 200, got %d: %s", w.Code, w.Body.String())
	}
	var rotated authResponse
	if err := json.NewDecoder(w.Body).Decode(&rotated); err != nil {
		t.Fatalf("decode refresh response: %v", err)
	}

	// Age the revoked original beyond the 7-day refresh TTL.
	oldHash := auth.HashToken(sess.RefreshToken)
	if _, err := store.DB().Exec(`UPDATE refresh_tokens SET created_at = datetime('now', '-8 days') WHERE token_hash = ?`, oldHash); err != nil {
		t.Fatalf("backdate created_at: %v", err)
	}

	// Replay the stale revoked token: must be token_reuse, not refresh_expired.
	w = refreshCall(h, sess.RefreshToken, "device-A")
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("replayed refresh: expected 401, got %d: %s", w.Code, w.Body.String())
	}
	var errResp errorResponse
	if err := json.NewDecoder(w.Body).Decode(&errResp); err != nil {
		t.Fatalf("decode error response: %v", err)
	}
	if errResp.Error.Code != "token_reuse" {
		t.Errorf("expected token_reuse code, got %q", errResp.Error.Code)
	}

	// The live family token was revoked by the reuse detection.
	if found, live := sessionState(t, store, rotated.RefreshToken); !found || live {
		t.Errorf("expected rotated token revoked after reuse, found=%v live=%v", found, live)
	}
	if w := refreshCall(h, rotated.RefreshToken, "device-A"); w.Code != http.StatusUnauthorized {
		t.Errorf("expected rotated token rejected after family revocation, got %d: %s", w.Code, w.Body.String())
	}
}

func TestDeviceSessions_LogoutRevokesOnlyCaller(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	sessA := signInDevice(t, h, sender, "logout@example.com", "device-A")
	sessB := signInDevice(t, h, sender, "logout@example.com", "device-B")

	if w := logoutCall(h, sessA, "device-A"); w.Code != http.StatusNoContent {
		t.Fatalf("logout A: expected 204, got %d: %s", w.Code, w.Body.String())
	}

	if found, live := sessionState(t, store, sessA.RefreshToken); !found || live {
		t.Errorf("expected caller family revoked, found=%v live=%v", found, live)
	}

	// Other device survives: it can still refresh.
	if w := refreshCall(h, sessB.RefreshToken, "device-B"); w.Code != http.StatusOK {
		t.Errorf("expected device-B session to survive logout, got %d: %s", w.Code, w.Body.String())
	}
}

func TestDeviceSessions_ExpiredTTLRejected(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	sess := signInDevice(t, h, sender, "ttl@example.com", "device-A")

	// Backdate the family's created_at beyond the 7-day refresh TTL.
	hash := auth.HashToken(sess.RefreshToken)
	if _, err := store.DB().Exec(`UPDATE refresh_tokens SET created_at = datetime('now', '-8 days') WHERE token_hash = ?`, hash); err != nil {
		t.Fatalf("backdate created_at: %v", err)
	}

	w := refreshCall(h, sess.RefreshToken, "device-A")
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for expired family, got %d: %s", w.Code, w.Body.String())
	}
	var errResp errorResponse
	if err := json.NewDecoder(w.Body).Decode(&errResp); err != nil {
		t.Fatalf("decode error response: %v", err)
	}
	if errResp.Error.Code != "refresh_expired" {
		t.Errorf("expected refresh_expired code, got %q", errResp.Error.Code)
	}

	// Lock-not-wipe: the row stays (client keeps local files; server just
	// rejects).
	if found, _ := sessionState(t, store, sess.RefreshToken); !found {
		t.Error("expected expired token row to remain in store")
	}
}

func TestDeviceSessions_ApplePathStoresDeviceID(t *testing.T) {
	store := newTestStore(t)
	verifier := fakeAppleVerifier{claims: apple.Claims{Sub: "apple-sub-dev", Email: "appledev@example.com"}}
	h := newTestHandlerWithApple(t, store, verifier)

	body, _ := json.Marshal(map[string]string{"identity_token": "valid-apple-id-token"})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/apple", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Device-Id", "device-fruit")
	w := httptest.NewRecorder()
	h.AppleSignIn(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("apple sign-in: expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var resp authResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if got := deviceIDOf(t, store, resp.RefreshToken); got != "device-fruit" {
		t.Errorf("expected apple-issued refresh row device_id device-fruit, got %q", got)
	}

	// Rotation on the apple-issued family stays in the family.
	w = refreshCall(h, resp.RefreshToken, "device-fruit")
	if w.Code != http.StatusOK {
		t.Fatalf("apple-family refresh: expected 200, got %d", w.Code)
	}
	var rotated authResponse
	if err := json.NewDecoder(w.Body).Decode(&rotated); err != nil {
		t.Fatalf("decode refresh response: %v", err)
	}
	if got := deviceIDOf(t, store, rotated.RefreshToken); got != "device-fruit" {
		t.Errorf("expected rotated apple-family token device-fruit, got %q", got)
	}
}

func TestDeviceSessions_RefreshRequiresDeviceID(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	sess := signInDevice(t, h, sender, "refreshdev@example.com", "device-A")

	w := refreshCall(h, sess.RefreshToken, "")
	if w.Code != http.StatusBadRequest {
		t.Errorf("expected 400 for missing X-Device-Id on refresh, got %d", w.Code)
	}
	var errResp errorResponse
	if err := json.NewDecoder(w.Body).Decode(&errResp); err != nil {
		t.Fatalf("decode error response: %v", err)
	}
	if errResp.Error.Code != "invalid_request" {
		t.Errorf("expected invalid_request code, got %q", errResp.Error.Code)
	}

	// The family stays intact: the token still refreshes with the header.
	if w := refreshCall(h, sess.RefreshToken, "device-A"); w.Code != http.StatusOK {
		t.Errorf("expected refresh with correct header to succeed, got %d: %s", w.Code, w.Body.String())
	}
}

func TestDeviceSessions_RefreshWrongDeviceRejected(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	sess := signInDevice(t, h, sender, "wrongdev@example.com", "device-A")

	// Wrong device id: 401, nothing revoked.
	w := refreshCall(h, sess.RefreshToken, "device-B")
	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401 for wrong X-Device-Id, got %d", w.Code)
	}
	var errResp errorResponse
	if err := json.NewDecoder(w.Body).Decode(&errResp); err != nil {
		t.Fatalf("decode error response: %v", err)
	}
	if errResp.Error.Code != "invalid_refresh" {
		t.Errorf("expected invalid_refresh code, got %q", errResp.Error.Code)
	}
	if found, live := sessionState(t, store, sess.RefreshToken); !found || !live {
		t.Errorf("expected original family intact after wrong-device attempt, found=%v live=%v", found, live)
	}

	// The real family still refreshes with the correct header.
	if w := refreshCall(h, sess.RefreshToken, "device-A"); w.Code != http.StatusOK {
		t.Errorf("expected refresh with correct header to succeed after wrong-device attempt, got %d: %s", w.Code, w.Body.String())
	}
}

func TestDeviceSessions_LogoutRequiresDeviceID(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandler(t, store)

	userID, token := mintBearer(t, store, "logoutdev@example.com")

	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/logout", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	// Put the userID in context the way AuthMiddleware does.
	ctx := context.WithValue(req.Context(), ContextKeyUserID, userID)
	req = req.WithContext(ctx)
	w := httptest.NewRecorder()
	h.Logout(w, req)
	if w.Code != http.StatusBadRequest {
		t.Errorf("expected 400 for missing X-Device-Id on logout, got %d", w.Code)
	}
}
