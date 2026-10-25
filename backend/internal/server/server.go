// Package server provides the HTTP server with chi router and middleware.
package server

import (
	"context"
	"log/slog"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"

	"github.com/antonkosenko/shunik/backend/internal/apple"
	"github.com/antonkosenko/shunik/backend/internal/auth"
	"github.com/antonkosenko/shunik/backend/internal/config"
	"github.com/antonkosenko/shunik/backend/internal/db"
	"github.com/antonkosenko/shunik/backend/internal/email"
	"github.com/antonkosenko/shunik/backend/internal/handlers"
	"github.com/antonkosenko/shunik/backend/internal/observe"
	"github.com/antonkosenko/shunik/backend/internal/ratelimit"
	"github.com/antonkosenko/shunik/backend/internal/recovery"
)

// Dependencies holds all dependencies for the server.
type Dependencies struct {
	Store          db.Store
	TokenService   *auth.TokenService
	OTPService     *auth.OTPService
	EmailSender    email.Sender
	RateLimiter    *handlers.RateLimiterGroup
	AppleVerifier  apple.Verifier
	HandlerCfg     handlers.HandlerConfig
	RequestTimeout time.Duration
	// RecoveryKeyring seals pending refresh successors for response-loss
	// recovery. Nil disables recovery (refresh attempts are ignored);
	// NewDefaultDependencies builds it from config.
	RecoveryKeyring *recovery.Keyring
	// CORSAllowedOrigins is the exact-match allowlist of origins echoed
	// for credentialed browser calls. Empty (default) = deny all.
	CORSAllowedOrigins []string
	// StatusService mints account-status evidence. Built from
	// ACCOUNT_STATUS_SECRET; nil disables the status endpoint's issuance
	// (production always configures it).
	StatusService *auth.StatusService
	// AppleClient exchanges codes and revokes Apple tokens. Nil when Apple
	// revocation is unconfigured (explicit Apple deletion then 503s without
	// purging — never a silent skip).
	AppleClient apple.Client
	// AppleNotifications verifies server-to-server notifications. Nil when
	// Apple is unconfigured.
	AppleNotifications apple.NotificationVerifier
	// AppleTokenKeyring seals stored Apple credentials and revocation jobs.
	// Nil when Apple revocation is unconfigured.
	AppleTokenKeyring *recovery.Keyring
	// AppleDigestKey is the rotation-stable HMAC key for subject digests.
	AppleDigestKey []byte
	// AppleClientID is the Bundle ID referenced by revocation jobs.
	AppleClientID string
}

// defaultAccessTokenTTL and defaultRefreshTokenTTL mirror the config defaults
// so a literally-constructed Config (tests) behaves like a loaded one.
const (
	defaultAccessTokenTTL  = 15 * time.Minute
	defaultRefreshTokenTTL = 7 * 24 * time.Hour
	defaultRequestTimeout  = 30 * time.Second
)

// NewDefaultDependencies creates a default set of dependencies from config and store.
func NewDefaultDependencies(ctx context.Context, cfg *config.Config, store db.Store) Dependencies {
	logger := slog.Default()

	accessTTL := cfg.AccessTokenTTL
	if accessTTL <= 0 {
		accessTTL = defaultAccessTokenTTL
	}
	refreshTTL := cfg.RefreshTokenTTL
	if refreshTTL <= 0 {
		refreshTTL = defaultRefreshTokenTTL
	}
	tokenService := auth.NewTokenService(cfg.JWTSecret, accessTTL, refreshTTL)

	otpService := auth.NewOTPService(
		cfg.OTPExpiry,
		cfg.OTPMaxAttempts,
	)

	emailSender, err := email.NewSender(email.SenderConfig{
		Backend:              cfg.EmailBackend,
		AWSAccessKeyID:       cfg.AWSAccessKeyID,
		AWSSecretAccessKey:   cfg.AWSSecretAccessKey,
		AWSRegion:            cfg.AWSRegion,
		SESFrom:              cfg.SESFrom,
		OTPEmailTextTemplate: cfg.OTPEmailTemplate,
		OTPEmailHTMLTemplate: cfg.OTPEmailHTMLTemplate,
		Logger:               logger,
	})
	if err != nil {
		// Explicit fallback: the service stays up on console delivery, but
		// the misconfiguration is surfaced here instead of inside the
		// factory. Fail fast (return error) is the follow-up once
		// EMAIL_BACKEND=ses misconfigurations are proven loud enough.
		logger.Error("email sender misconfigured, using console fallback", "error", err)
	}

	rateLimiter := &handlers.RateLimiterGroup{
		OTPRequest: ratelimit.OTPRequestLimit,
		OTPVerify:  ratelimit.OTPVerifyLimit,
		Status:     ratelimit.NewTokenBucket(10, 10, time.Minute),
		Invite:     ratelimit.InviteLimit,
		// Apple server-to-server deliveries are unauthenticated: blunt
		// floods before JWS verification, with a ceiling high enough that
		// Apple's own delivery retries never throttle.
		AppleNotifications: ratelimit.NewTokenBucket(60, 60, time.Minute),
	}

	trustedProxies, err := handlers.ParseTrustedProxies(cfg.TrustedProxies)
	if err != nil {
		// Explicit continue with the safe default (trust nobody): forwarded
		// headers are ignored, so a typo here fails closed for rate
		// limiting rather than open. The raw value is not secret.
		logger.Error("invalid TRUSTED_PROXIES, ignoring forwarded headers",
			"error", err, "value", cfg.TrustedProxies)
	}

	handlerCfg := handlers.HandlerConfig{
		TrustedProxies: trustedProxies,
	}

	// Explicit account deletion is always issued: the status signer needs
	// only ACCOUNT_STATUS_SECRET (required, distinct from JWT_SECRET).
	statusService := auth.NewStatusService(cfg.AccountStatusSecret)

	// Apple revocation material (all-or-nothing at config load): when none
	// of the APPLE_* variables is set, Sign in with Apple stays disabled
	// (the registered route returns 503) and explicit Apple deletion is
	// unavailable — the OTP path keeps working.
	var appleVerifier apple.Verifier
	var appleNotifs apple.NotificationVerifier
	var appleClient apple.Client
	var appleTokenKeyring *recovery.Keyring
	var digestKey []byte
	if cfg.AppleClientID != "" {
		kf, kerr := apple.NewSharedKeyfunc(ctx, cfg.AppleJWKSURL)
		if kerr != nil {
			logger.Error("failed to create apple JWKS keyfunc; feature disabled", "error", kerr)
		} else {
			appleVerifier = apple.NewIdentityVerifier(cfg.AppleClientID, kf)
			appleNotifs = apple.NewNotificationVerifier(cfg.AppleClientID, kf)
			rateLimiter.Apple = ratelimit.AppleLimit
		}
		privKey, perr := apple.ParsePrivateKey([]byte(cfg.ApplePrivateKey))
		if perr != nil {
			// Config preflight validates this; a runtime mismatch fails
			// closed to revocation-unavailable (explicit 503s, never silent
			// skips) instead of crashing the relay.
			logger.Error("failed to parse apple private key; revocation unavailable", "error", perr)
		} else {
			appleClient = apple.NewRESTClient(cfg.AppleClientID, cfg.AppleTeamID, cfg.AppleKeyID,
				privKey, "", cfg.AppleRedirectURI, nil)
			appleTokenKeyring = recovery.NewKeyring(cfg.AppleTokenKeys)
			digestKey = apple.SubjectDigestKey([]byte(cfg.AccountStatusSecret))
		}
	}

	return Dependencies{
		Store:              store,
		TokenService:       tokenService,
		OTPService:         otpService,
		EmailSender:        emailSender,
		RateLimiter:        rateLimiter,
		AppleVerifier:      appleVerifier,
		HandlerCfg:         handlerCfg,
		RequestTimeout:     cfg.RequestTimeout,
		RecoveryKeyring:    recovery.NewKeyring(cfg.RecoveryKeys),
		CORSAllowedOrigins: config.ParseCORSAllowedOrigins(cfg.CORSAllowedOrigins),
		StatusService:      statusService,
		AppleClient:        appleClient,
		AppleNotifications: appleNotifs,
		AppleTokenKeyring:  appleTokenKeyring,
		AppleDigestKey:     digestKey,
		AppleClientID:      cfg.AppleClientID,
	}
}

// Server holds the HTTP server and its dependencies.
type Server struct {
	router http.Handler
	worker *apple.Worker
}

// StartWorkers runs the Apple revocation worker until ctx ends. A missing
// worker (unconfigured Apple) is a no-op.
func (s *Server) StartWorkers(ctx context.Context) {
	if s.worker == nil {
		return
	}
	go s.worker.Start(ctx)
}

// New creates a new Server with all routes configured.
func New(deps Dependencies) *Server {
	logger := slog.Default()

	h := handlers.NewHandler(
		deps.Store,
		deps.TokenService,
		deps.OTPService,
		deps.EmailSender,
		deps.RateLimiter,
		deps.AppleVerifier,
		deps.HandlerCfg,
		logger,
		deps.RecoveryKeyring,
		handlers.WithAccountDeletion(
			deps.StatusService,
			deps.AppleClient,
			deps.AppleNotifications,
			deps.AppleTokenKeyring,
			deps.AppleDigestKey,
			deps.AppleClientID,
		),
	)

	s := &Server{
		worker: apple.NewWorker(deps.Store, deps.AppleClient, deps.AppleTokenKeyring, logger, time.Minute),
	}

	r := chi.NewRouter()

	// Middleware
	r.Use(chimw.Recoverer)
	// Sentry panic/5xx capture sits inside Recoverer: it re-panics so
	// Recoverer still renders the 500 (observability Stage 0).
	r.Use(observe.Middleware)
	r.Use(chimw.RequestID)
	r.Use(requestLogger)
	r.Use(chimw.Timeout(deps.requestTimeout()))
	r.Use(corsMiddlewareWithAllowlist(deps.CORSAllowedOrigins))

	// Health check
	r.Get("/health", s.handleHealth)

	// API v1 routes
	r.Route("/api/v1", func(r chi.Router) {
		r.Route("/auth", func(r chi.Router) {
			r.Post("/otp/request", h.RequestOTP)
			r.Post("/otp/verify", h.VerifyOTP)
			r.Post("/refresh", h.RefreshToken)
			// Sign in with Apple is always registered: the handler returns
			// 503 (apple_not_configured) when the verifier is nil, surfacing
			// the contract instead of a 404.
			r.Post("/apple", h.AppleSignIn)
			// Server-to-server Apple notifications (verified JWS payload, no
			// bearer): consent-revoked signs out, never deletes.
			r.Post("/apple/notifications", h.AppleNotifications)
			r.With(h.AuthMiddleware).Post("/logout", h.Logout)
			r.With(h.AuthMiddleware).Get("/me", h.Me)
			// Explicit account deletion (self-only) + read-only status
			// evidence (status-only credential, no access token accepted).
			r.With(h.AuthMiddleware).Delete("/account", h.DeleteAccount)
			r.Post("/account/status", h.AccountStatus)
			r.With(h.AuthMiddleware).Post("/apple/deletion-credential", h.AppleDeletionCredential)
		})
		// Household sharing (day-1: one household per user, equal owners).
		// All protected — membership is proven by the bearer account.
		r.Route("/households", func(r chi.Router) {
			r.Use(h.AuthMiddleware)
			r.Get("/mine", h.GetMyHousehold)
			r.Post("/invites", h.CreateInvite)
			r.Post("/invites/accept", h.AcceptInvite)
			r.Delete("/members", h.RemoveMember)
		})
	})

	s.router = r
	return s
}

// ServeHTTP implements http.Handler.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.router.ServeHTTP(w, r)
}

// requestTimeout resolves the chi request timeout, defaulting for a
// literally-constructed Dependencies (tests) the same way config.Load does.
func (d Dependencies) requestTimeout() time.Duration {
	if d.RequestTimeout <= 0 {
		return defaultRequestTimeout
	}
	return d.RequestTimeout
}

// healthCheckCount counts /health requests served since process start.
// Uptime pings hit /health every minute, so they increment this counter
// instead of emitting per-request access log lines (observability Stage 0).
// Exposed for future metrics; read via HealthCheckCount.
var healthCheckCount atomic.Int64

// HealthCheckCount returns the number of /health requests served.
func HealthCheckCount() int64 {
	return healthCheckCount.Load()
}

// requestLogger logs each request using slog, except /health (quiet health
// endpoint: uptime-ping traffic must not emit access-log lines).
func requestLogger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		ww := chimw.NewWrapResponseWriter(w, r.ProtoMajor)

		defer func() {
			if r.URL.Path == "/health" {
				healthCheckCount.Add(1)
				return
			}
			slog.Info("request",
				"method", r.Method,
				"path", r.URL.Path,
				"status", ww.Status(),
				"duration", time.Since(start).String(),
				"remote", r.RemoteAddr,
				"request_id", chimw.GetReqID(r.Context()),
			)
		}()

		next.ServeHTTP(ww, r)
	})
}

// corsMiddlewareWithAllowlist enforces the CORS origin allowlist (issue #93).
//
// A presented Origin is echoed with Allow-Credentials only on exact match
// against the allowlist (empty default = deny all). Non-allowlisted and
// missing origins receive no origin/credentials headers — never
// Allow-Credentials with a wildcard or a reflected origin. The
// methods/headers advertisement and the OPTIONS 204 preflight status are
// preserved in all cases (absent headers enforce); Vary: Origin is set on
// echoes so caches don't poison one origin's echo for another.
func corsMiddlewareWithAllowlist(allowedOrigins []string) func(http.Handler) http.Handler {
	allowed := make(map[string]struct{}, len(allowedOrigins))
	for _, o := range allowedOrigins {
		o = strings.TrimSpace(o)
		if o == "" {
			continue
		}
		allowed[o] = struct{}{}
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if origin := r.Header.Get("Origin"); origin != "" {
				if _, ok := allowed[origin]; ok {
					w.Header().Set("Access-Control-Allow-Origin", origin)
					w.Header().Set("Access-Control-Allow-Credentials", "true")
					w.Header().Add("Vary", "Origin")
				}
			}
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")

			if r.Method == http.MethodOptions {
				w.WriteHeader(http.StatusNoContent)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(`{"status":"ok"}`))
}
