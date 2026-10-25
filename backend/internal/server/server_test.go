package server

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/antonkosenko/shunik/backend/internal/auth"
	"github.com/antonkosenko/shunik/backend/internal/config"
	"github.com/antonkosenko/shunik/backend/internal/db"
	"github.com/antonkosenko/shunik/backend/internal/email"
	"github.com/antonkosenko/shunik/backend/internal/handlers"
	"github.com/antonkosenko/shunik/backend/internal/migrations"
	"github.com/antonkosenko/shunik/backend/internal/ratelimit"
)

func newTestServer(t *testing.T) *Server {
	t.Helper()
	return newTestServerWithAllowlist(t, nil)
}

func newTestServerWithAllowlist(t *testing.T, allowed []string) *Server {
	t.Helper()

	store, err := db.NewSQLiteStore(":memory:")
	if err != nil {
		t.Fatalf("failed to create SQLite store: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	ctx := context.Background()
	if err := migrations.RunSQLite(ctx, store.DB()); err != nil {
		t.Fatalf("failed to run migrations: %v", err)
	}

	cfg := &config.Config{
		JWTSecret:      "test-secret-key-at-least-32-bytes!!",
		OTPExpiry:      10 * time.Minute,
		OTPMaxAttempts: 5,
	}

	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelWarn}))
	tokenService := auth.NewTokenService(cfg.JWTSecret, 15*time.Minute, 7*24*time.Hour)
	otpService := auth.NewOTPService(cfg.OTPExpiry, cfg.OTPMaxAttempts)
	emailSender := email.NewConsoleSender(logger)
	rateLimiter := &handlers.RateLimiterGroup{
		OTPRequest: ratelimit.NewTokenBucket(100, 100, time.Minute),
		OTPVerify:  ratelimit.NewTokenBucket(100, 100, time.Minute),
		Apple:      ratelimit.NewTokenBucket(100, 100, time.Minute),
		Status:     ratelimit.NewTokenBucket(100, 100, time.Minute),
	}
	handlerCfg := handlers.HandlerConfig{}

	deps := Dependencies{
		Store:              store,
		TokenService:       tokenService,
		OTPService:         otpService,
		EmailSender:        emailSender,
		RateLimiter:        rateLimiter,
		HandlerCfg:         handlerCfg,
		CORSAllowedOrigins: allowed,
	}

	return New(deps)
}

func TestHealthEndpoint(t *testing.T) {
	s := newTestServer(t)

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}

	var resp map[string]string
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}
	if resp["status"] != "ok" {
		t.Errorf("expected status 'ok', got %q", resp["status"])
	}
}

func TestOTPRequestRoute(t *testing.T) {
	s := newTestServer(t)

	// A valid request through the real route must return 202 (always, to
	// prevent user enumeration).
	body := `{"email":"test@example.com"}`
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/otp/request", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)

	if w.Code != http.StatusAccepted {
		t.Errorf("expected 202 for valid OTP request, got %d", w.Code)
	}

	// An empty body must fail validation with 400.
	req = httptest.NewRequest(http.MethodPost, "/api/v1/auth/otp/request", http.NoBody)
	req.Header.Set("Content-Type", "application/json")
	w = httptest.NewRecorder()
	s.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("expected 400 for empty body, got %d", w.Code)
	}
}

func TestAppleRouteReturnsConfiguredErrorWhenDisabled(t *testing.T) {
	s := newTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/apple", strings.NewReader(`{"identity_token":"token"}`))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)

	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 when Apple sign-in is disabled, got %d", w.Code)
	}
	var response struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.NewDecoder(w.Body).Decode(&response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Error.Code != "apple_not_configured" {
		t.Errorf("expected apple_not_configured, got %q", response.Error.Code)
	}
}

func TestCORSHeaders(t *testing.T) {
	s := newTestServerWithAllowlist(t, []string{"http://localhost:3000"})

	req := httptest.NewRequest(http.MethodOptions, "/health", nil)
	req.Header.Set("Origin", "http://localhost:3000")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)

	if w.Code != http.StatusNoContent {
		t.Errorf("expected 204 for OPTIONS, got %d", w.Code)
	}

	if origin := w.Header().Get("Access-Control-Allow-Origin"); origin != "http://localhost:3000" {
		t.Errorf("expected allowlisted origin echo, got %q", origin)
	}
	if creds := w.Header().Get("Access-Control-Allow-Credentials"); creds != "true" {
		t.Errorf("expected Allow-Credentials true for allowlisted origin, got %q", creds)
	}
	if vary := w.Header().Get("Vary"); !strings.Contains(vary, "Origin") {
		t.Errorf("expected Vary: Origin on allowlisted echo, got %q", vary)
	}
	if methods := w.Header().Get("Access-Control-Allow-Methods"); strings.Contains(methods, "PUT") {
		t.Errorf("expected no PUT in allowed methods, got %q", methods)
	} else if methods != "GET, POST, PATCH, DELETE, OPTIONS" {
		t.Errorf("expected methods GET, POST, PATCH, DELETE, OPTIONS, got %q", methods)
	}
	if headers := w.Header().Get("Access-Control-Allow-Headers"); headers != "Content-Type, Authorization" {
		t.Errorf("expected headers Content-Type, Authorization, got %q", headers)
	}
}

func TestCORSNonAllowlistedOriginDenied(t *testing.T) {
	s := newTestServerWithAllowlist(t, []string{"https://app.example.com"})

	req := httptest.NewRequest(http.MethodOptions, "/health", nil)
	req.Header.Set("Origin", "https://evil.example.com")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)

	if w.Code != http.StatusNoContent {
		t.Errorf("expected 204 for OPTIONS, got %d", w.Code)
	}
	if origin := w.Header().Get("Access-Control-Allow-Origin"); origin != "" {
		t.Errorf("expected no origin echo for non-allowlisted origin, got %q", origin)
	}
	if creds := w.Header().Get("Access-Control-Allow-Credentials"); creds != "" {
		t.Errorf("expected no credentials for non-allowlisted origin, got %q", creds)
	}
}

func TestCORSMissingOriginNoCredentials(t *testing.T) {
	s := newTestServerWithAllowlist(t, []string{"https://app.example.com"})

	req := httptest.NewRequest(http.MethodOptions, "/health", nil)
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)

	if w.Code != http.StatusNoContent {
		t.Errorf("expected 204 for OPTIONS, got %d", w.Code)
	}
	if creds := w.Header().Get("Access-Control-Allow-Credentials"); creds != "" {
		t.Errorf("expected no credentials for missing origin, got %q", creds)
	}
	if origin := w.Header().Get("Access-Control-Allow-Origin"); origin != "" {
		t.Errorf("expected no origin header for missing origin, got %q", origin)
	}
}

func TestCORSEmptyAllowlistDeniesAll(t *testing.T) {
	s := newTestServer(t) // nil allowlist = deny all

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	req.Header.Set("Origin", "http://localhost:3000")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}
	if origin := w.Header().Get("Access-Control-Allow-Origin"); origin != "" {
		t.Errorf("expected no origin echo under empty allowlist, got %q", origin)
	}
	if creds := w.Header().Get("Access-Control-Allow-Credentials"); creds != "" {
		t.Errorf("expected no credentials under empty allowlist, got %q", creds)
	}
}

func TestAuthRoutesProtected(t *testing.T) {
	s := newTestServer(t)

	// Logout without auth should return 401
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/logout", nil)
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401 for unauthenticated logout, got %d", w.Code)
	}

	// Me without auth should return 401
	req = httptest.NewRequest(http.MethodGet, "/api/v1/auth/me", nil)
	w = httptest.NewRecorder()
	s.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401 for unauthenticated /me, got %d", w.Code)
	}
}

func TestServerContentType(t *testing.T) {
	s := newTestServer(t)

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)

	ct := w.Header().Get("Content-Type")
	if ct != "application/json" {
		t.Errorf("expected Content-Type application/json, got %q", ct)
	}
}

func TestHealthExcludedFromAccessLogs(t *testing.T) {
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))
	defer slog.SetDefault(prev)

	s := newTestServer(t)
	buf.Reset() // drop setup logs so only request logs are asserted on

	before := HealthCheckCount()
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	s.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200 for /health, got %d", w.Code)
	}
	if got := HealthCheckCount(); got != before+1 {
		t.Errorf("expected health-check counter to increment by 1, got %d -> %d", before, got)
	}
	if out := buf.String(); strings.Contains(out, "/health") {
		t.Errorf("expected no access-log line for /health, got %q", out)
	}

	// Other routes must still log.
	buf.Reset()
	req = httptest.NewRequest(http.MethodGet, "/api/v1/auth/me", nil)
	w = httptest.NewRecorder()
	s.ServeHTTP(w, req)

	if out := buf.String(); !strings.Contains(out, "/api/v1/auth/me") {
		t.Errorf("expected access-log line for non-health route, got %q", out)
	}
}
