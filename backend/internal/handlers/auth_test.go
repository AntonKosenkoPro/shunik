package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/antonkosenko/time-of-life/backend/internal/apple"
	"github.com/antonkosenko/time-of-life/backend/internal/auth"
	"github.com/antonkosenko/time-of-life/backend/internal/db"
	"github.com/antonkosenko/time-of-life/backend/internal/email"
	"github.com/antonkosenko/time-of-life/backend/internal/migrations"
	"github.com/antonkosenko/time-of-life/backend/internal/ratelimit"
	"github.com/antonkosenko/time-of-life/backend/internal/recovery"
)

func newTestStore(t *testing.T) *db.SQLiteStore {
	t.Helper()
	store, err := db.NewSQLiteStore(":memory:")
	if err != nil {
		t.Fatalf("failed to create SQLite store: %v", err)
	}
	ctx := context.Background()
	if err := migrations.RunSQLite(ctx, store.DB()); err != nil {
		t.Fatalf("failed to run migrations: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return store
}

type captureSender struct {
	messages []email.Message
}

func (s *captureSender) Send(_ context.Context, message email.Message) error {
	s.messages = append(s.messages, message)
	return nil
}

func newTestHandler(t *testing.T, store db.Store) *Handler {
	t.Helper()
	return newTestHandlerWithDependencies(t, store, nil, nil)
}

// newTestHandlerWithApple is like newTestHandler but injects an Apple
// identity-token verifier (nil disables the Apple endpoint).
func newTestHandlerWithApple(t *testing.T, store db.Store, verifier apple.Verifier) *Handler {
	t.Helper()
	return newTestHandlerWithDependencies(t, store, verifier, nil)
}

func newTestHandlerWithDependencies(
	t *testing.T,
	store db.Store,
	verifier apple.Verifier,
	emailSender email.Sender,
) *Handler {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelWarn}))
	tokenService := auth.NewTokenService("test-secret-key-at-least-32-bytes!!", 15*time.Minute, 7*24*time.Hour)
	otpService := auth.NewOTPService(10*time.Minute, 5)
	if emailSender == nil {
		emailSender = email.NewConsoleSender(logger)
	}
	rateLimiter := &RateLimiterGroup{
		OTPRequest: ratelimit.NewTokenBucket(100, 100, time.Minute),
		OTPVerify:  ratelimit.NewTokenBucket(100, 100, time.Minute),
		Apple:      ratelimit.NewTokenBucket(100, 100, time.Minute),
		Status:     ratelimit.NewTokenBucket(100, 100, time.Minute),
	}
	config := HandlerConfig{}
	return NewHandler(store, tokenService, otpService, emailSender, rateLimiter, verifier, config, logger, testRecoveryKeyring())
}

// testRecoveryKeyring returns a fixed test keyring so handler tests exercise
// the recovery path. Production keys come from REFRESH_RECOVERY_KEYS.
func testRecoveryKeyring() *recovery.Keyring {
	return recovery.NewKeyring([][]byte{bytes.Repeat([]byte{0x07}, recovery.KeySize)})
}

func capturedOTP(t *testing.T, sender *captureSender) string {
	t.Helper()
	if len(sender.messages) != 1 {
		t.Fatalf("expected one OTP email, got %d", len(sender.messages))
	}
	for _, line := range strings.Split(sender.messages[0].Text, "\n") {
		code := strings.TrimSpace(line)
		if validateCode(code) {
			return code
		}
	}
	t.Fatal("OTP email did not contain a six-digit code")
	return ""
}

func requestOTP(t *testing.T, h *Handler, email string) *httptest.ResponseRecorder {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"email": email})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/otp/request", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.RequestOTP(w, req)
	return w
}

func verifyOTP(t *testing.T, h *Handler, email, code string) *httptest.ResponseRecorder {
	t.Helper()
	return verifyOTPWithDevice(t, h, email, code, "test-device")
}

func verifyOTPWithDevice(t *testing.T, h *Handler, email, code, deviceID string) *httptest.ResponseRecorder {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"email": email, "code": code})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/otp/verify", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Device-Id", deviceID)
	w := httptest.NewRecorder()
	h.VerifyOTP(w, req)
	return w
}

func TestRequestOTP_Returns202ForValidEmail(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandler(t, store)

	w := requestOTP(t, h, "test@example.com")
	if w.Code != http.StatusAccepted {
		t.Errorf("expected 202, got %d", w.Code)
	}
}

func TestRequestOTP_Returns400ForInvalidEmail(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandler(t, store)

	w := requestOTP(t, h, "invalid-email")
	if w.Code != http.StatusBadRequest {
		t.Errorf("expected 400, got %d", w.Code)
	}
}

func TestRequestOTP_Returns400ForEmptyEmail(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandler(t, store)

	w := requestOTP(t, h, "")
	if w.Code != http.StatusBadRequest {
		t.Errorf("expected 400, got %d", w.Code)
	}
}

func TestVerifyOTP_ReturnsTokensForEmailedCode(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	w := requestOTP(t, h, "test@example.com")
	if w.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d", w.Code)
	}

	w = verifyOTP(t, h, "test@example.com", capturedOTP(t, sender))
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	var response authResponse
	if err := json.NewDecoder(w.Body).Decode(&response); err != nil {
		t.Fatalf("decode auth response: %v", err)
	}
	if response.AccessToken == "" || response.RefreshToken == "" {
		t.Fatal("expected non-empty access and refresh tokens")
	}
	if response.User.Email != "test@example.com" || !response.User.EmailVerified {
		t.Errorf("unexpected verified user: %+v", response.User)
	}
}

func TestVerifyOTP_Returns401ForInvalidCode(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandler(t, store)

	requestOTP(t, h, "test@example.com")
	w := verifyOTP(t, h, "test@example.com", "000000")
	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", w.Code)
	}
}

func TestVerifyOTP_Returns401ForNonexistentUser(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandler(t, store)

	w := verifyOTP(t, h, "nonexistent@example.com", "123456")
	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", w.Code)
	}
}

func TestRefreshToken_Returns401ForInvalidToken(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandler(t, store)

	body, _ := json.Marshal(map[string]string{"refresh_token": "invalid-token"})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/refresh", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Device-Id", "test-device")
	w := httptest.NewRecorder()
	h.RefreshToken(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", w.Code)
	}
}

func TestLogout_Returns401WithoutAuth(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandler(t, store)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/logout", nil)
	w := httptest.NewRecorder()
	h.Logout(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", w.Code)
	}
}

func TestMe_Returns401WithoutAuth(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandler(t, store)

	req := httptest.NewRequest(http.MethodGet, "/api/v1/auth/me", nil)
	w := httptest.NewRecorder()
	h.Me(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", w.Code)
	}
}

func TestRequestOTP_AlwaysReturns202(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandler(t, store)

	// Even with invalid data, the handler should return 202 for the upsert case
	// Actually, invalid email returns 400, but valid email always returns 202
	w := requestOTP(t, h, "valid@example.com")
	if w.Code != http.StatusAccepted {
		t.Errorf("expected 202, got %d", w.Code)
	}
}

func TestRequestOTP_ResponseBody(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandler(t, store)

	w := requestOTP(t, h, "user@example.com")
	var resp map[string]string
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}
	if resp["status"] != "accepted" {
		t.Errorf("expected status 'accepted', got %q", resp["status"])
	}
}

func TestVerifyOTP_ErrorResponseFormat(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandler(t, store)

	w := verifyOTP(t, h, "nonexistent@example.com", "123456")
	var resp map[string]interface{}
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}
	errObj, ok := resp["error"].(map[string]interface{})
	if !ok {
		t.Fatalf("expected error object in response, got: %v", resp)
	}
	if errObj["code"] == "" {
		t.Errorf("expected error code to be non-empty")
	}
	if errObj["message"] == "" {
		t.Errorf("expected error message to be non-empty")
	}
}

func TestRequestOTP_InvalidJSON(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandler(t, store)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/otp/request", strings.NewReader("invalid json"))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.RequestOTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("expected 400, got %d", w.Code)
	}
}

func TestVerifyOTP_InvalidJSON(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandler(t, store)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/otp/verify", strings.NewReader("invalid json"))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.VerifyOTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("expected 400, got %d", w.Code)
	}
}

func TestRefreshToken_EmptyToken(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandler(t, store)

	body, _ := json.Marshal(map[string]string{"refresh_token": ""})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/refresh", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.RefreshToken(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("expected 400, got %d", w.Code)
	}
}

func TestExtractIP_FromRemoteAddr(t *testing.T) {
	tests := []struct {
		name       string
		remoteAddr string
		want       string
	}{
		{"ipv4 with port", "127.0.0.1:1234", "127.0.0.1"},
		{"ipv6 loopback with port", "[::1]:1234", "::1"},
		{"ipv6 full with port", "[2001:db8::1]:443", "2001:db8::1"},
		{"bare host no port", "203.0.113.7", "203.0.113.7"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/", nil)
			req.RemoteAddr = tc.remoteAddr
			if got := extractIP(req); got != tc.want {
				t.Errorf("extractIP(%q) = %q, want %q", tc.remoteAddr, got, tc.want)
			}
		})
	}
}

// extractIP must NOT consult forwarded headers — that is Handler.clientIP's
// job, gated behind the trusted-proxy allowlist.
func TestExtractIP_IgnoresForwardedHeaders(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/", nil)
	req.RemoteAddr = "127.0.0.1:1234"
	req.Header.Set("X-Forwarded-For", "203.0.113.9")
	req.Header.Set("X-Real-IP", "198.51.100.1")
	if got := extractIP(req); got != "127.0.0.1" {
		t.Errorf("extractIP read forwarded header: got %q, want direct peer 127.0.0.1", got)
	}
}

func TestParseTrustedProxies(t *testing.T) {
	t.Run("empty trusts nobody", func(t *testing.T) {
		got, err := ParseTrustedProxies("")
		if err != nil || len(got) != 0 {
			t.Fatalf("got %v, %v; want empty, nil", got, err)
		}
	})
	t.Run("cidr and bare ip", func(t *testing.T) {
		got, err := ParseTrustedProxies("10.0.0.0/8, ::1, 203.0.113.7")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if len(got) != 3 {
			t.Fatalf("got %d networks, want 3", len(got))
		}
		if !got[0].Contains(net.ParseIP("10.5.5.5")) {
			t.Error("10.0.0.0/8 should contain 10.5.5.5")
		}
		if !got[2].Contains(net.ParseIP("203.0.113.7")) {
			t.Error("bare 203.0.113.7 should contain itself")
		}
	})
	t.Run("invalid entry errors", func(t *testing.T) {
		if _, err := ParseTrustedProxies("not-an-ip"); err == nil {
			t.Error("want error for invalid entry")
		}
	})
}

func newHandlerWithProxies(t *testing.T, store db.Store, proxies string) *Handler {
	t.Helper()
	h := newTestHandler(t, store)
	nets, err := ParseTrustedProxies(proxies)
	if err != nil {
		t.Fatalf("parse trusted proxies: %v", err)
	}
	h.config.TrustedProxies = nets
	return h
}

func TestClientIP_TrustedProxyGate(t *testing.T) {
	store := newTestStore(t)

	t.Run("no trusted proxies: forwarded header ignored", func(t *testing.T) {
		h := newTestHandler(t, store) // default: no trusted proxies
		req := httptest.NewRequest(http.MethodPost, "/", nil)
		req.RemoteAddr = "203.0.113.9:5555" // direct peer is a public IP
		req.Header.Set("X-Forwarded-For", "198.51.100.1")
		if got := h.clientIP(req); got != "203.0.113.9" {
			t.Errorf("got %q, want direct peer (header must be ignored)", got)
		}
	})

	t.Run("trusted proxy: X-Forwarded-For honoured", func(t *testing.T) {
		h := newHandlerWithProxies(t, store, "10.0.0.0/8")
		req := httptest.NewRequest(http.MethodPost, "/", nil)
		req.RemoteAddr = "10.0.0.1:5555" // direct peer is a trusted proxy
		req.Header.Set("X-Forwarded-For", "198.51.100.1")
		if got := h.clientIP(req); got != "198.51.100.1" {
			t.Errorf("got %q, want forwarded client IP", got)
		}
	})

	t.Run("untrusted peer: forwarded header ignored even with proxies configured", func(t *testing.T) {
		h := newHandlerWithProxies(t, store, "10.0.0.0/8")
		req := httptest.NewRequest(http.MethodPost, "/", nil)
		req.RemoteAddr = "203.0.113.9:5555" // direct peer is NOT a trusted proxy
		req.Header.Set("X-Forwarded-For", "198.51.100.1")
		if got := h.clientIP(req); got != "203.0.113.9" {
			t.Errorf("got %q, want direct peer (spoofer must not bypass)", got)
		}
	})

	t.Run("trusted proxy: X-Real-IP fallback", func(t *testing.T) {
		h := newHandlerWithProxies(t, store, "127.0.0.1/32")
		req := httptest.NewRequest(http.MethodPost, "/", nil)
		req.RemoteAddr = "127.0.0.1:5555"
		req.Header.Set("X-Real-IP", "198.51.100.2")
		if got := h.clientIP(req); got != "198.51.100.2" {
			t.Errorf("got %q, want X-Real-IP value", got)
		}
	})
}

// TestRequestOTP_SpoofedHeaderDoesNotBypassRateLimit verifies the security
// property end-to-end: with no trusted proxy configured, a client that varies
// X-Forwarded-For on every request cannot escape the per-IP rate limit.
func TestRequestOTP_SpoofedHeaderDoesNotBypassRateLimit(t *testing.T) {
	store := newTestStore(t)
	// Tight limiter: 2 requests per minute per key.
	h := newTestHandler(t, store)
	h.rateLimiter.OTPRequest = ratelimit.NewTokenBucket(2, 2, time.Minute)

	email := "spoof@example.com"
	for i := 0; i < 2; i++ {
		req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/otp/request", nil)
		req.RemoteAddr = "203.0.113.9:5555" // same real peer every time
		// Vary the spoofed header to try to get a fresh key each request.
		req.Header.Set("X-Forwarded-For", fmt.Sprintf("10.0.0.%d", i+1))
		req.Header.Set("Content-Type", "application/json")
		body, _ := json.Marshal(map[string]string{"email": email})
		req.Body = io.NopCloser(bytes.NewReader(body))
		w := httptest.NewRecorder()
		h.RequestOTP(w, req)
		if w.Code != http.StatusAccepted {
			t.Fatalf("request %d: expected 202, got %d", i, w.Code)
		}
	}

	// Third request from the same real peer must be limited despite a new
	// spoofed forwarded IP.
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/otp/request", nil)
	req.RemoteAddr = "203.0.113.9:5555"
	req.Header.Set("X-Forwarded-For", "10.0.0.99")
	req.Header.Set("Content-Type", "application/json")
	body, _ := json.Marshal(map[string]string{"email": email})
	req.Body = io.NopCloser(bytes.NewReader(body))
	w := httptest.NewRecorder()
	h.RequestOTP(w, req)
	if w.Code != http.StatusTooManyRequests {
		t.Errorf("expected 429 (spoofed header must not bypass), got %d", w.Code)
	}
}

// testJWTSecret is the shared HMAC secret for test-minted bearer tokens
// (mintBearer) and test handlers (newTestHandlerWithDependencies): both
// sides must agree or auth fails.
const testJWTSecret = "test-secret-key-at-least-32-bytes!!"

// mintBearer creates a user and a valid access token for it.
func mintBearer(t *testing.T, store db.Store, email string) (userID, token string) {
	t.Helper()
	user, err := store.UpsertUser(context.Background(), email)
	if err != nil {
		t.Fatalf("UpsertUser: %v", err)
	}
	ts := auth.NewTokenService(testJWTSecret, 15*time.Minute, 7*24*time.Hour)
	tok, err := ts.CreateAccessToken(user.ID, user.Email)
	if err != nil {
		t.Fatalf("CreateAccessToken: %v", err)
	}
	return user.ID, tok
}

// decodeBody decodes a JSON response body into v.
func decodeBody(t *testing.T, w *httptest.ResponseRecorder, v any) {
	t.Helper()
	if err := json.NewDecoder(w.Body).Decode(v); err != nil {
		t.Fatalf("decode response: %v (body=%s)", err, w.Body.String())
	}
}

// errCode decodes the error envelope and returns its code.
func errCode(t *testing.T, w *httptest.ResponseRecorder) string {
	t.Helper()
	var resp struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
			Details any    `json:"details"`
		} `json:"error"`
	}
	decodeBody(t, w, &resp)
	return resp.Error.Code
}
