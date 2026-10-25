package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/antonkosenko/shunik/backend/internal/apple"
	"github.com/antonkosenko/shunik/backend/internal/ratelimit"
)

// fakeAppleVerifier returns fixed claims (or an error) regardless of input.
type fakeAppleVerifier struct {
	claims apple.Claims
	err    error
}

func (f fakeAppleVerifier) Verify(_ context.Context, _ string) (apple.Claims, error) {
	return f.claims, f.err
}

func doAppleSignIn(t *testing.T, h *Handler, identityToken string) *httptest.ResponseRecorder {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"identity_token": identityToken})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/apple", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Device-Id", "test-device")
	w := httptest.NewRecorder()
	h.AppleSignIn(w, req)
	return w
}

func TestAppleSignIn_Returns200WithTokens(t *testing.T) {
	store := newTestStore(t)
	verifier := fakeAppleVerifier{
		claims: apple.Claims{Sub: "apple-sub-1", Email: "r@privaterelay.appleid.com"},
	}
	h := newTestHandlerWithApple(t, store, verifier)

	w := doAppleSignIn(t, h, "valid-apple-id-token")
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var resp authResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.AccessToken == "" || resp.RefreshToken == "" {
		t.Fatal("expected non-empty tokens")
	}
	if resp.User.Email != "r@privaterelay.appleid.com" {
		t.Errorf("expected relay email, got %q", resp.User.Email)
	}
	if !resp.User.EmailVerified {
		t.Error("expected email_verified true for Apple user")
	}
}

func TestAppleSignIn_IdempotentForSameSubject(t *testing.T) {
	store := newTestStore(t)
	verifier := fakeAppleVerifier{
		claims: apple.Claims{Sub: "apple-sub-2", Email: "real@example.com"},
	}
	h := newTestHandlerWithApple(t, store, verifier)

	w1 := doAppleSignIn(t, h, "token")
	if w1.Code != http.StatusOK {
		t.Fatalf("first call: expected 200, got %d", w1.Code)
	}
	var resp1 authResponse
	_ = json.NewDecoder(w1.Body).Decode(&resp1)

	// Second sign-in with the same subject (no email this time).
	h2 := newTestHandlerWithApple(t, store, fakeAppleVerifier{claims: apple.Claims{Sub: "apple-sub-2"}})
	w2 := doAppleSignIn(t, h2, "token")
	if w2.Code != http.StatusOK {
		t.Fatalf("second call: expected 200, got %d", w2.Code)
	}
	var resp2 authResponse
	_ = json.NewDecoder(w2.Body).Decode(&resp2)

	if resp1.User.ID != resp2.User.ID {
		t.Errorf("expected same user ID across sign-ins: %q vs %q", resp1.User.ID, resp2.User.ID)
	}
	if resp2.User.Email != "real@example.com" {
		t.Errorf("expected retained email, got %q", resp2.User.Email)
	}
}

func TestAppleSignIn_InvalidBody(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandlerWithApple(t, store, fakeAppleVerifier{})

	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/apple", bytes.NewReader([]byte(`{bad`)))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.AppleSignIn(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", w.Code)
	}
}

func TestAppleSignIn_MissingIdentityToken(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandlerWithApple(t, store, fakeAppleVerifier{})

	w := doAppleSignIn(t, h, "")
	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for empty identity token, got %d", w.Code)
	}
}

func TestAppleSignIn_InvalidTokenReturns401(t *testing.T) {
	store := newTestStore(t)
	verifier := fakeAppleVerifier{err: apple.ErrInvalidToken}
	h := newTestHandlerWithApple(t, store, verifier)

	w := doAppleSignIn(t, h, "bad-token")
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for invalid apple token, got %d", w.Code)
	}
}

func TestAppleSignIn_NotConfiguredReturns503(t *testing.T) {
	store := newTestStore(t)
	// nil verifier → feature disabled.
	h := newTestHandlerWithApple(t, store, nil)

	w := doAppleSignIn(t, h, "any-token")
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 when apple not configured, got %d", w.Code)
	}
}

func TestAppleSignIn_RateLimited(t *testing.T) {
	store := newTestStore(t)
	verifier := fakeAppleVerifier{claims: apple.Claims{Sub: "apple-sub-rl"}}
	h := newTestHandlerWithApple(t, store, verifier)
	// burst=1 with no refill: the first request consumes the only token; the
	// second is rejected.
	h.rateLimiter.Apple = ratelimit.NewTokenBucket(0, 1, time.Minute)

	if w := doAppleSignIn(t, h, "token"); w.Code != http.StatusOK {
		t.Fatalf("first call: expected 200, got %d", w.Code)
	}
	if w := doAppleSignIn(t, h, "token"); w.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429 on second call, got %d", w.Code)
	}
}
