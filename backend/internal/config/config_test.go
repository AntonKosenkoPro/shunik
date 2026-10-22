package config

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"testing"
	"time"
)

// TestConfig_Load_Branches pins the Load branch matrix. Each case sets the
// full required set explicitly so no ambient environment (or a stray .env)
// leaks in. t.Setenv restores the environment after each test.
func TestConfig_Load_Branches(t *testing.T) {
	required := map[string]string{
		"DATABASE_URL":  "postgres://localhost:5432/test",
		"JWT_SECRET":    "test-secret-key-at-least-32-bytes!!",
		"EMAIL_BACKEND": "console",
		// 32-byte test key, hex-encoded (`openssl rand -hex 32` shape).
		"REFRESH_RECOVERY_KEYS": "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
		// Status secret: distinct from JWT_SECRET, same length class.
		"ACCOUNT_STATUS_SECRET": "status-secret-key-at-least-32-bytes!",
	}

	setRequired := func(t *testing.T) {
		t.Helper()
		for k, v := range required {
			t.Setenv(k, v)
		}
	}

	t.Run("defaults", func(t *testing.T) {
		setRequired(t)
		cfg, err := Load()
		if err != nil {
			t.Fatalf("Load: %v", err)
		}
		if cfg.Port != 8080 {
			t.Errorf("expected default port 8080, got %d", cfg.Port)
		}
		if cfg.OTPExpiry != 10*time.Minute {
			t.Errorf("expected default OTP expiry 10m, got %v", cfg.OTPExpiry)
		}
		if cfg.OTPMaxAttempts != 5 {
			t.Errorf("expected default OTP max attempts 5, got %d", cfg.OTPMaxAttempts)
		}
		if cfg.AccessTokenTTL != 15*time.Minute {
			t.Errorf("expected default access TTL 15m, got %v", cfg.AccessTokenTTL)
		}
		if cfg.RefreshTokenTTL != 7*24*time.Hour {
			t.Errorf("expected default refresh TTL 168h, got %v", cfg.RefreshTokenTTL)
		}
		if cfg.ReadTimeout != 15*time.Second || cfg.WriteTimeout != 30*time.Second {
			t.Errorf("expected default read/write timeouts 15s/30s, got %v/%v", cfg.ReadTimeout, cfg.WriteTimeout)
		}
		if cfg.IdleTimeout != 60*time.Second {
			t.Errorf("expected default idle timeout 60s, got %v", cfg.IdleTimeout)
		}
		if cfg.RequestTimeout != 30*time.Second {
			t.Errorf("expected default request timeout 30s, got %v", cfg.RequestTimeout)
		}
		if cfg.ShutdownTimeout != 30*time.Second {
			t.Errorf("expected default shutdown timeout 30s, got %v", cfg.ShutdownTimeout)
		}
		if cfg.AppleJWKSURL != "https://appleid.apple.com/auth/keys" {
			t.Errorf("expected default Apple JWKS URL, got %q", cfg.AppleJWKSURL)
		}
	})

	t.Run("overrides", func(t *testing.T) {
		setRequired(t)
		t.Setenv("PORT", "9000")
		t.Setenv("OTP_EXPIRY", "5m")
		t.Setenv("OTP_MAX_ATTEMPTS", "3")
		t.Setenv("ACCESS_TOKEN_TTL", "1h")
		t.Setenv("REFRESH_TOKEN_TTL", "24h")
		t.Setenv("HTTP_READ_TIMEOUT", "5s")
		t.Setenv("HTTP_WRITE_TIMEOUT", "10s")
		t.Setenv("HTTP_IDLE_TIMEOUT", "20s")
		t.Setenv("HTTP_REQUEST_TIMEOUT", "45s")
		t.Setenv("SHUTDOWN_TIMEOUT", "5s")
		t.Setenv("EMAIL_BACKEND", "SES") // case-insensitive
		t.Setenv("AWS_ACCESS_KEY_ID", "AKIAEXAMPLE")
		t.Setenv("AWS_SECRET_ACCESS_KEY", "secret")
		t.Setenv("AWS_REGION", "eu-west-1")
		t.Setenv("SES_FROM", "noreply@example.com")
		t.Setenv("TRUSTED_PROXIES", "10.0.0.0/8")
		cfg, err := Load()
		if err != nil {
			t.Fatalf("Load: %v", err)
		}
		if cfg.Port != 9000 || cfg.OTPExpiry != 5*time.Minute || cfg.OTPMaxAttempts != 3 {
			t.Errorf("overrides not applied: %+v", cfg)
		}
		if cfg.AccessTokenTTL != time.Hour || cfg.RefreshTokenTTL != 24*time.Hour {
			t.Errorf("TTL overrides not applied: %+v", cfg)
		}
		if cfg.ReadTimeout != 5*time.Second || cfg.WriteTimeout != 10*time.Second ||
			cfg.IdleTimeout != 20*time.Second || cfg.RequestTimeout != 45*time.Second ||
			cfg.ShutdownTimeout != 5*time.Second {
			t.Errorf("timeout overrides not applied: %+v", cfg)
		}
		if cfg.EmailBackend != "ses" {
			t.Errorf("expected lowercased ses backend, got %q", cfg.EmailBackend)
		}
	})

	t.Run("missing required", func(t *testing.T) {
		for _, missing := range []string{"DATABASE_URL", "JWT_SECRET", "EMAIL_BACKEND", "REFRESH_RECOVERY_KEYS", "ACCOUNT_STATUS_SECRET"} {
			setRequired(t)
			t.Setenv(missing, "")
			// godotenv.Load does not override set (even empty) vars, so the
			// empty value reads as missing.
			if _, err := Load(); err == nil {
				t.Errorf("expected error with %s unset, got nil", missing)
			}
		}
	})

	t.Run("invalid values", func(t *testing.T) {
		cases := []struct{ key, bad string }{
			{"PORT", "notaport"},
			{"OTP_EXPIRY", "notaduration"},
			{"OTP_MAX_ATTEMPTS", "0"},
			{"EMAIL_BACKEND", "smtp"},
			{"ACCESS_TOKEN_TTL", "soon"},
			{"ACCESS_TOKEN_TTL", "0s"},
			{"REFRESH_TOKEN_TTL", "-5"},
			{"REFRESH_TOKEN_TTL", "-1m"},
			{"HTTP_READ_TIMEOUT", "huge"},
			{"HTTP_READ_TIMEOUT", "0"},
			{"HTTP_WRITE_TIMEOUT", "x"},
			{"HTTP_IDLE_TIMEOUT", "x"},
			{"HTTP_REQUEST_TIMEOUT", "x"},
			{"SHUTDOWN_TIMEOUT", "x"},
			{"SHUTDOWN_TIMEOUT", "-1m"},
		}
		for _, c := range cases {
			setRequired(t)
			t.Setenv(c.key, c.bad)
			if _, err := Load(); err == nil {
				t.Errorf("expected error for %s=%q, got nil", c.key, c.bad)
			}
		}
	})

	t.Run("short JWT secret", func(t *testing.T) {
		setRequired(t)
		t.Setenv("JWT_SECRET", "too-short")
		if _, err := Load(); err == nil {
			t.Error("expected error for short JWT_SECRET, got nil")
		}
	})

	t.Run("apple all or nothing", func(t *testing.T) {
		p8 := testApplePrivateKey(t)
		full := map[string]string{
			"APPLE_CLIENT_ID":   "com.example.app",
			"APPLE_TEAM_ID":     "TEAMID1234",
			"APPLE_KEY_ID":      "KEYID12345",
			"APPLE_PRIVATE_KEY": p8,
			"APPLE_TOKEN_KEYS":  "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
		}
		setAll := func(t *testing.T, vars map[string]string) {
			t.Helper()
			setRequired(t)
			for _, name := range []string{"APPLE_CLIENT_ID", "APPLE_TEAM_ID", "APPLE_KEY_ID", "APPLE_PRIVATE_KEY", "APPLE_TOKEN_KEYS", "APPLE_REDIRECT_URI"} {
				t.Setenv(name, "")
			}
			for k, v := range vars {
				t.Setenv(k, v)
			}
		}
		// Each single variable alone must fail (partial config fails fast).
		for name, val := range full {
			setAll(t, map[string]string{name: val})
			if _, err := Load(); err == nil {
				t.Errorf("expected error for partial apple config (%s only), got nil", name)
			}
		}
		// APPLE_REDIRECT_URI alone must NOT enable the all-or-nothing set:
		// it stays optional even though it is an APPLE_* variable.
		setAll(t, map[string]string{"APPLE_REDIRECT_URI": "https://example.com/callback"})
		redirectCfg, redirectErr := Load()
		if redirectErr != nil {
			t.Errorf("redirect-only apple config should keep Apple disabled, got error: %v", redirectErr)
		} else if redirectCfg.AppleClientID != "" || len(redirectCfg.AppleTokenKeys) != 0 || redirectCfg.AppleRedirectURI != "https://example.com/callback" {
			t.Errorf("redirect-only apple config misapplied: %+v", redirectCfg)
		}
		// The redirect URI is optional: the full five pass with or without it.
		setAll(t, full)
		cfg, err := Load()
		if err != nil {
			t.Fatalf("full apple config: %v", err)
		}
		if cfg.AppleClientID != "com.example.app" || cfg.AppleRedirectURI != "" || len(cfg.AppleTokenKeys) != 1 {
			t.Errorf("apple config not applied: %+v", cfg)
		}
		vars := map[string]string{}
		for k, v := range full {
			vars[k] = v
		}
		vars["APPLE_REDIRECT_URI"] = "https://example.com/callback"
		setAll(t, vars)
		cfg, err = Load()
		if err != nil {
			t.Fatalf("full apple config with redirect: %v", err)
		}
		if cfg.AppleRedirectURI != "https://example.com/callback" {
			t.Errorf("redirect URI not applied, got %q", cfg.AppleRedirectURI)
		}
		// Malformed key material fails fast without logging the key.
		setAll(t, full)
		t.Setenv("APPLE_PRIVATE_KEY", "not-a-pem")
		if _, err := Load(); err == nil {
			t.Error("expected error for malformed APPLE_PRIVATE_KEY, got nil")
		}
		setAll(t, full)
		t.Setenv("APPLE_TOKEN_KEYS", "too-short")
		if _, err := Load(); err == nil {
			t.Error("expected error for malformed APPLE_TOKEN_KEYS, got nil")
		}
	})

	t.Run("status secret rules", func(t *testing.T) {
		setRequired(t)
		t.Setenv("ACCOUNT_STATUS_SECRET", "too-short")
		if _, err := Load(); err == nil {
			t.Error("expected error for short ACCOUNT_STATUS_SECRET, got nil")
		}
		setRequired(t)
		t.Setenv("ACCOUNT_STATUS_SECRET", "test-secret-key-at-least-32-bytes!!")
		if _, err := Load(); err == nil {
			t.Error("expected error for ACCOUNT_STATUS_SECRET equal to JWT_SECRET, got nil")
		}
	})

	t.Run("ses requires credentials", func(t *testing.T) {
		setRequired(t)
		t.Setenv("EMAIL_BACKEND", "ses")
		// No AWS_* / SES_FROM set.
		if _, err := Load(); err == nil {
			t.Error("expected error for ses backend without credentials, got nil")
		}
	})

	t.Run("cors allowlist", func(t *testing.T) {
		setRequired(t)
		// Empty default = deny (nil).
		cfg, err := Load()
		if err != nil {
			t.Fatalf("Load: %v", err)
		}
		if cfg.CORSAllowedOrigins != "" {
			t.Errorf("expected empty default CORS allowlist, got %q", cfg.CORSAllowedOrigins)
		}
		if got := ParseCORSAllowedOrigins(cfg.CORSAllowedOrigins); len(got) != 0 {
			t.Errorf("expected nil parse of empty allowlist, got %+v", got)
		}
		// CSV with whitespace and empty entries.
		setRequired(t)
		t.Setenv("CORS_ALLOWED_ORIGINS", " https://app.example.com,, http://localhost:3000 , ")
		cfg, err = Load()
		if err != nil {
			t.Fatalf("Load: %v", err)
		}
		got := ParseCORSAllowedOrigins(cfg.CORSAllowedOrigins)
		if len(got) != 2 || got[0] != "https://app.example.com" || got[1] != "http://localhost:3000" {
			t.Errorf("expected trimmed 2-origin allowlist, got %+v", got)
		}
	})
}

func TestParseCORSAllowedOrigins(t *testing.T) {
	if got := ParseCORSAllowedOrigins(""); len(got) != 0 {
		t.Errorf("expected empty for empty input, got %+v", got)
	}
	if got := ParseCORSAllowedOrigins(" , ,"); len(got) != 0 {
		t.Errorf("expected empty for blank entries, got %+v", got)
	}
}

// testApplePrivateKey generates a fresh P-256 .p8 for Apple-config tests.
// The key is minted per test (never a fixture, never committed).
func testApplePrivateKey(t *testing.T) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate test apple key: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal test apple key: %v", err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
}

func TestParseRecoveryKeys(t *testing.T) {
	key1 := "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
	key2 := "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"

	if got, err := ParseRecoveryKeys(""); err != nil || len(got) != 0 {
		t.Errorf("empty input: expected no keys, got %d (%v)", len(got), err)
	}
	if got, err := ParseRecoveryKeys(" , ,"); err != nil || len(got) != 0 {
		t.Errorf("blank entries: expected no keys, got %d (%v)", len(got), err)
	}

	got, err := ParseRecoveryKeys(" " + key1 + ",," + key2 + " ")
	if err != nil {
		t.Fatalf("ParseRecoveryKeys: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 keys, got %d", len(got))
	}
	for i, k := range got {
		if len(k) != 32 {
			t.Errorf("key %d: expected 32 bytes, got %d", i, len(k))
		}
	}
	if got[0][0] != 0x01 || got[1][0] != 0x20 {
		t.Error("key order must be preserved (first = primary)")
	}

	for _, bad := range []string{
		"not-hex",
		"0102",      // too short
		key1 + "00", // too long
		key1 + ", zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", // non-hex
	} {
		if _, err := ParseRecoveryKeys(bad); err == nil {
			t.Errorf("expected error for %q, got nil", bad)
		}
	}
}

// Recovery is always enabled, so Load fails fast on malformed keys rather
// than running a relay that cannot recover lost refresh responses.
func TestConfig_Load_InvalidRecoveryKeys(t *testing.T) {
	required := map[string]string{
		"DATABASE_URL":  "postgres://localhost:5432/test",
		"JWT_SECRET":    "test-secret-key-at-least-32-bytes!!",
		"EMAIL_BACKEND": "console",
	}
	for k, v := range required {
		t.Setenv(k, v)
	}
	t.Setenv("REFRESH_RECOVERY_KEYS", "too-short")
	if _, err := Load(); err == nil {
		t.Error("expected error for malformed REFRESH_RECOVERY_KEYS, got nil")
	}
}
