// Package config loads application configuration from environment variables.
package config

import (
	"encoding/hex"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/joho/godotenv"
)

// Config holds all application configuration.
type Config struct {
	DatabaseURL          string
	JWTSecret            string
	EmailBackend         string
	Port                 int
	OTPExpiry            time.Duration
	OTPMaxAttempts       int
	OTPEmailTemplate     string
	OTPEmailHTMLTemplate string
	// Token TTLs (unset = compiled defaults; explicit values must be positive).
	AccessTokenTTL  time.Duration
	RefreshTokenTTL time.Duration
	// HTTP timeouts (unset = compiled defaults; explicit values must be positive).
	ReadTimeout     time.Duration
	WriteTimeout    time.Duration
	IdleTimeout     time.Duration
	RequestTimeout  time.Duration
	ShutdownTimeout time.Duration
	// AWS SES (real mail sender). Required when EMAIL_BACKEND=ses.
	AWSAccessKeyID     string
	AWSSecretAccessKey string
	AWSRegion          string
	SESFrom            string
	// Sign in with Apple (F2). Optional: empty AppleClientID disables the
	// /auth/apple route and the iOS button. When set, it must be the app's
	// Bundle ID — the `aud` claim Apple puts in the identity token for a
	// native iOS app.
	AppleClientID string
	AppleJWKSURL  string
	// TrustedProxies is a comma-separated list of IPs/CIDRs of reverse proxies
	// that are allowed to set the X-Forwarded-For / X-Real-IP headers used for
	// per-client rate limiting. Empty (default) = trust nobody: forwarded
	// headers are ignored and the direct TCP peer is used. This prevents
	// rate-limit bypass via spoofed headers. (FURPS R1/S5)
	TrustedProxies string
	// CORSAllowedOrigins is a comma-separated allowlist of exact origins
	// (scheme://host[:port]) echoed for credentialed browser calls.
	// Empty (default) = deny all: no Origin is reflected and no
	// Access-Control-Allow-Credentials is ever sent.
	CORSAllowedOrigins string
	// SentryDSN enables Sentry error reporting (observability Stage 0).
	// Empty (default) = fully disabled, zero behavior change.
	SentryDSN string
	// RecoveryKeys holds the parsed REFRESH_RECOVERY_KEYS keyring: AES-256
	// keys sealing pending refresh successors for response-loss recovery.
	// Keys[0] is the primary sealing key; the rest are retired keys kept
	// for decrypting receipts sealed before rotation.
	RecoveryKeys [][]byte
}

// Load reads configuration from the environment (.env first, non-fatal if missing).
func Load() (*Config, error) {
	_ = godotenv.Load()

	cfg := &Config{}

	// Required: DATABASE_URL
	cfg.DatabaseURL = os.Getenv("DATABASE_URL")
	if cfg.DatabaseURL == "" {
		return nil, requiredFieldError("DATABASE_URL")
	}

	// Required: JWT_SECRET
	cfg.JWTSecret = os.Getenv("JWT_SECRET")
	if cfg.JWTSecret == "" {
		return nil, requiredFieldError("JWT_SECRET")
	}
	if len(cfg.JWTSecret) < 32 {
		return nil, &configError{msg: "JWT_SECRET must be at least 32 bytes long"}
	}

	// Required: EMAIL_BACKEND
	cfg.EmailBackend = os.Getenv("EMAIL_BACKEND")
	if cfg.EmailBackend == "" {
		return nil, requiredFieldError("EMAIL_BACKEND")
	}
	cfg.EmailBackend = strings.ToLower(cfg.EmailBackend)
	if cfg.EmailBackend != "console" && cfg.EmailBackend != "ses" {
		return nil, invalidFieldError("EMAIL_BACKEND", "console or ses")
	}

	// Optional: PORT (default 8080)
	portStr := os.Getenv("PORT")
	if portStr == "" {
		cfg.Port = 8080
	} else {
		p, err := strconv.Atoi(portStr)
		if err != nil {
			return nil, invalidFieldError("PORT", "valid integer")
		}
		cfg.Port = p
	}

	// Optional: OTP_EXPIRY (default 10m)
	expiryStr := os.Getenv("OTP_EXPIRY")
	if expiryStr == "" {
		cfg.OTPExpiry = 10 * time.Minute
	} else {
		d, err := time.ParseDuration(expiryStr)
		if err != nil {
			return nil, invalidFieldError("OTP_EXPIRY", "valid duration (e.g. 10m)")
		}
		cfg.OTPExpiry = d
	}

	// Optional: OTP_MAX_ATTEMPTS (default 5)
	attemptsStr := os.Getenv("OTP_MAX_ATTEMPTS")
	if attemptsStr == "" {
		cfg.OTPMaxAttempts = 5
	} else {
		a, err := strconv.Atoi(attemptsStr)
		if err != nil || a < 1 {
			return nil, invalidFieldError("OTP_MAX_ATTEMPTS", "positive integer")
		}
		cfg.OTPMaxAttempts = a
	}

	// Optional: OTP_EMAIL_TEMPLATE (text body) and OTP_EMAIL_HTML_TEMPLATE (HTML body).
	// When empty, package-level defaults are used.
	cfg.OTPEmailTemplate = os.Getenv("OTP_EMAIL_TEMPLATE")
	cfg.OTPEmailHTMLTemplate = os.Getenv("OTP_EMAIL_HTML_TEMPLATE")

	// Optional: token TTLs (defaults 15m access / 168h refresh).
	var err error
	if cfg.AccessTokenTTL, err = durationOrDefault("ACCESS_TOKEN_TTL", 15*time.Minute); err != nil {
		return nil, err
	}
	if cfg.RefreshTokenTTL, err = durationOrDefault("REFRESH_TOKEN_TTL", 7*24*time.Hour); err != nil {
		return nil, err
	}

	// Optional: HTTP timeouts (defaults match the previous hardcoded values).
	if cfg.ReadTimeout, err = durationOrDefault("HTTP_READ_TIMEOUT", 15*time.Second); err != nil {
		return nil, err
	}
	if cfg.WriteTimeout, err = durationOrDefault("HTTP_WRITE_TIMEOUT", 30*time.Second); err != nil {
		return nil, err
	}
	if cfg.IdleTimeout, err = durationOrDefault("HTTP_IDLE_TIMEOUT", 60*time.Second); err != nil {
		return nil, err
	}
	if cfg.RequestTimeout, err = durationOrDefault("HTTP_REQUEST_TIMEOUT", 30*time.Second); err != nil {
		return nil, err
	}
	if cfg.ShutdownTimeout, err = durationOrDefault("SHUTDOWN_TIMEOUT", 30*time.Second); err != nil {
		return nil, err
	}

	// Optional: AWS SES. Required when EMAIL_BACKEND=ses.
	cfg.AWSAccessKeyID = os.Getenv("AWS_ACCESS_KEY_ID")
	cfg.AWSSecretAccessKey = os.Getenv("AWS_SECRET_ACCESS_KEY")
	cfg.AWSRegion = os.Getenv("AWS_REGION")
	cfg.SESFrom = os.Getenv("SES_FROM")
	if cfg.EmailBackend == "ses" {
		var missing []string
		if cfg.AWSAccessKeyID == "" {
			missing = append(missing, "AWS_ACCESS_KEY_ID")
		}
		if cfg.AWSSecretAccessKey == "" {
			missing = append(missing, "AWS_SECRET_ACCESS_KEY")
		}
		if cfg.AWSRegion == "" {
			missing = append(missing, "AWS_REGION")
		}
		if cfg.SESFrom == "" {
			missing = append(missing, "SES_FROM")
		}
		if len(missing) > 0 {
			return nil, requiredFieldError(strings.Join(missing, ", "))
		}
	}

	// Optional: Sign in with Apple. Empty APPLE_CLIENT_ID leaves verification
	// disabled; the registered /auth/apple route returns 503. When enabled, the
	// Apple identity token's `aud` claim for a native iOS app is the Bundle ID.
	cfg.AppleClientID = os.Getenv("APPLE_CLIENT_ID")
	cfg.AppleJWKSURL = os.Getenv("APPLE_JWKS_URL")
	if cfg.AppleJWKSURL == "" {
		cfg.AppleJWKSURL = "https://appleid.apple.com/auth/keys"
	}

	// Optional: TRUSTED_PROXIES — comma-separated IPs/CIDRs allowed to set
	// forwarded IP headers for rate limiting. Empty = trust nobody.
	cfg.TrustedProxies = os.Getenv("TRUSTED_PROXIES")

	// Optional: CORS_ALLOWED_ORIGINS — comma-separated exact origins
	// (scheme://host[:port]) allowed for credentialed browser calls. Empty
	// (default) = deny all: no Origin is echoed and no credentials are
	// advertised. Localhost dev origins work only via explicit listing.
	cfg.CORSAllowedOrigins = os.Getenv("CORS_ALLOWED_ORIGINS")

	// Optional: SENTRY_DSN — Sentry error reporting. Empty = disabled.
	cfg.SentryDSN = os.Getenv("SENTRY_DSN")

	// Required: REFRESH_RECOVERY_KEYS — the stable server-side keyring
	// sealing pending refresh successors (fix-refresh-response-loss).
	// Recovery is always enabled, so startup fails fast without keys rather
	// than running a relay that cannot recover lost refresh responses.
	// Format: comma-separated hex-encoded 32-byte (AES-256) keys; the first
	// is the primary sealing key, the rest are retired keys retained for
	// decrypting older receipts. Generate with `openssl rand -hex 32`.
	keys, err := ParseRecoveryKeys(os.Getenv("REFRESH_RECOVERY_KEYS"))
	if err != nil {
		return nil, err
	}
	if len(keys) == 0 {
		return nil, requiredFieldError("REFRESH_RECOVERY_KEYS")
	}
	cfg.RecoveryKeys = keys

	return cfg, nil
}

// ParseRecoveryKeys parses a comma-separated list of hex-encoded 32-byte
// (AES-256) keys into raw key bytes. The first key is the primary sealing
// key; the rest are retired keys. Empty entries are ignored; an empty input
// yields no keys. Any malformed entry (non-hex or wrong length) is an error.
func ParseRecoveryKeys(raw string) ([][]byte, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	var keys [][]byte
	for i, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		key, err := parseRecoveryKey(i+1, part)
		if err != nil {
			return nil, err
		}
		keys = append(keys, key)
	}
	return keys, nil
}

// parseRecoveryKey decodes one keyring entry: exactly 32 bytes of hex. The
// 1-based index names the failing entry without ever logging the key
// material itself. The all-zero key is rejected: it is a plausible
// placeholder mistake, and sealing under a guessable key would defeat the
// confidentiality the receipts exist to protect (`openssl rand -hex 32`
// never emits it, so there is no false-positive risk).
func parseRecoveryKey(index int, hexKey string) ([]byte, error) {
	key, err := hex.DecodeString(hexKey)
	if err != nil || len(key) != 32 {
		return nil, fmt.Errorf("invalid REFRESH_RECOVERY_KEYS entry %d: expected 64 hex chars: %w", index, errOrLength(err, len(key)))
	}
	if isZeroKey(key) {
		return nil, invalidFieldError("REFRESH_RECOVERY_KEYS", "non-trivial 32-byte key (all-zero key rejected; generate with `openssl rand -hex 32`)")
	}
	return key, nil
}

func errOrLength(err error, n int) error {
	if err != nil {
		return err
	}
	return fmt.Errorf("decoded to %d bytes, want 32", n)
}

func isZeroKey(key []byte) bool {
	for _, b := range key {
		if b != 0 {
			return false
		}
	}
	return true
}

// ParseCORSAllowedOrigins parses a comma-separated allowlist of exact
// origins (e.g. "https://app.example.com,http://localhost:3000") into a
// list of origins. Entries are trimmed; empty entries are ignored. An empty
// input yields an empty slice (deny all). Matching is exact on the full
// origin string — no wildcards or subdomain expansion.
func ParseCORSAllowedOrigins(raw string) []string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}
	var out []string
	for _, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		out = append(out, part)
	}
	return out
}

func requiredFieldError(name string) error {
	return &configError{msg: "required environment variable is not set: " + name}
}

func invalidFieldError(name, expected string) error {
	return &configError{msg: "invalid " + name + ": expected " + expected}
}

// durationOrDefault reads an optional duration env var, falling back to
// def when unset. A present-but-unparseable or non-positive value is a
// config error: zero disables net/http timeouts (rather than defaulting)
// and negatives/zero break TTLs and shutdown deadlines, so fail fast here
// instead of letting them reach http.Server or context.WithTimeout.
func durationOrDefault(name string, def time.Duration) (time.Duration, error) {
	raw := os.Getenv(name)
	if raw == "" {
		return def, nil
	}
	d, err := time.ParseDuration(raw)
	if err != nil {
		return 0, invalidFieldError(name, "valid duration (e.g. 15m)")
	}
	if d <= 0 {
		return 0, invalidFieldError(name, "positive duration (e.g. 15m)")
	}
	return d, nil
}

type configError struct {
	msg string
}

func (e *configError) Error() string { return e.msg }
