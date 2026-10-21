package handlers

import (
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/antonkosenko/time-of-life/backend/internal/auth"
	"github.com/antonkosenko/time-of-life/backend/internal/db"
	"github.com/antonkosenko/time-of-life/backend/internal/email"
	"github.com/antonkosenko/time-of-life/backend/internal/ratelimit"
)

// trustedTestHandler builds a Handler whose trusted-proxy set is parsed from
// raw (empty = trust nobody, the production default).
func trustedTestHandler(t *testing.T, store db.Store, raw string) *Handler {
	t.Helper()
	nets, err := ParseTrustedProxies(raw)
	if err != nil {
		t.Fatalf("ParseTrustedProxies(%q): %v", raw, err)
	}
	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelWarn}))
	return NewHandler(
		store,
		auth.NewTokenService(testJWTSecret, 15*time.Minute, 7*24*time.Hour),
		auth.NewOTPService(10*time.Minute, 5),
		email.NewConsoleSender(logger),
		&RateLimiterGroup{
			OTPRequest: ratelimit.NewTokenBucket(100, 100, time.Minute),
			OTPVerify:  ratelimit.NewTokenBucket(100, 100, time.Minute),
		},
		nil,
		HandlerConfig{TrustedProxies: nets},
		logger,
		testRecoveryKeyring(),
	)
}

// ipReq builds a request with the given TCP peer and optional forwarded
// headers.
func ipReq(peer, xff, xrip string) *http.Request {
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/otp/request", nil)
	req.RemoteAddr = peer
	if xff != "" {
		req.Header.Set("X-Forwarded-For", xff)
	}
	if xrip != "" {
		req.Header.Set("X-Real-IP", xrip)
	}
	return req
}

// TestMiddleware_ClientIP pins the trusted-proxy rules: forwarded headers
// are honored only from configured proxies, X-Forwarded-For wins over
// X-Real-IP and takes the leftmost entry, and IPv6 peers parse correctly.
func TestMiddleware_ClientIP(t *testing.T) {
	store := newTestStore(t)

	t.Run("untrusted peer ignores spoofed headers", func(t *testing.T) {
		h := trustedTestHandler(t, store, "")
		got := h.clientIP(ipReq("203.0.113.7:1234", "10.9.9.9", "10.8.8.8"))
		if got != "203.0.113.7" {
			t.Errorf("expected direct peer, got %q", got)
		}
	})

	t.Run("trusted peer honors X-Forwarded-For first entry", func(t *testing.T) {
		h := trustedTestHandler(t, store, "203.0.113.1")
		got := h.clientIP(ipReq("203.0.113.1:5678", "198.51.100.5, 203.0.113.1", "198.51.100.9"))
		if got != "198.51.100.5" {
			t.Errorf("expected leftmost forwarded IP, got %q", got)
		}
	})

	t.Run("trusted peer falls back to X-Real-IP", func(t *testing.T) {
		h := trustedTestHandler(t, store, "10.0.0.0/8")
		got := h.clientIP(ipReq("10.1.2.3:443", "", "198.51.100.6"))
		if got != "198.51.100.6" {
			t.Errorf("expected X-Real-IP, got %q", got)
		}
	})

	t.Run("trusted peer without headers uses peer", func(t *testing.T) {
		h := trustedTestHandler(t, store, "10.0.0.0/8")
		got := h.clientIP(ipReq("10.1.2.3:443", "", ""))
		if got != "10.1.2.3" {
			t.Errorf("expected peer, got %q", got)
		}
	})

	t.Run("IPv6 peer parses with brackets", func(t *testing.T) {
		h := trustedTestHandler(t, store, "")
		got := h.clientIP(ipReq("[::1]:1234", "198.51.100.7", ""))
		if got != "::1" {
			t.Errorf("expected ::1, got %q", got)
		}
	})

	t.Run("IPv6 trusted proxy honors headers", func(t *testing.T) {
		h := trustedTestHandler(t, store, "::1")
		got := h.clientIP(ipReq("[::1]:1234", "2001:db8::5", ""))
		if got != "2001:db8::5" {
			t.Errorf("expected forwarded IPv6, got %q", got)
		}
	})

	t.Run("malformed peer without port passes through", func(t *testing.T) {
		h := trustedTestHandler(t, store, "")
		got := h.clientIP(ipReq("not-an-addr", "198.51.100.7", ""))
		if got != "not-an-addr" {
			t.Errorf("expected passthrough, got %q", got)
		}
	})
}

// TestMiddleware_ParseTrustedProxies pins CIDR, bare-IP, IPv6, and error
// branches of the TRUSTED_PROXIES parser.
func TestMiddleware_ParseTrustedProxies(t *testing.T) {
	nets, err := ParseTrustedProxies("")
	if err != nil || len(nets) != 0 {
		t.Errorf("expected empty trust-nobody set, got %v, %v", nets, err)
	}
	nets, err = ParseTrustedProxies("10.0.0.0/8, 192.168.1.1, ::1")
	if err != nil {
		t.Fatalf("ParseTrustedProxies: %v", err)
	}
	if len(nets) != 3 {
		t.Fatalf("expected 3 networks, got %d", len(nets))
	}
	if _, err := ParseTrustedProxies("not-an-ip"); err == nil {
		t.Error("expected error for invalid entry, got nil")
	}
	if _, err := ParseTrustedProxies("10.0.0.0/8, garbage"); err == nil {
		t.Error("expected error when any entry is invalid, got nil")
	}
}
