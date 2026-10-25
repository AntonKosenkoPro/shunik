// Package handlers provides HTTP handlers for the auth API endpoints.
package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/mail"
	"regexp"
	"strings"
	"time"

	"github.com/antonkosenko/shunik/backend/internal/apple"
	"github.com/antonkosenko/shunik/backend/internal/auth"
	"github.com/antonkosenko/shunik/backend/internal/db"
	"github.com/antonkosenko/shunik/backend/internal/email"
	"github.com/antonkosenko/shunik/backend/internal/observe"
	"github.com/antonkosenko/shunik/backend/internal/ratelimit"
	"github.com/antonkosenko/shunik/backend/internal/recovery"
)

// HandlerConfig holds configuration for the auth handler.
type HandlerConfig struct {
	TrustedProxies []*net.IPNet // CIDRs of trusted reverse proxies allowed to set forwarded IP headers
}

// Handler holds dependencies for all HTTP handlers.
type Handler struct {
	store           db.Store
	tokenService    *auth.TokenService
	otpService      *auth.OTPService
	emailSender     email.Sender
	rateLimiter     *RateLimiterGroup
	appleVerifier   apple.Verifier
	config          HandlerConfig
	logger          *slog.Logger
	recoveryKeyring *recovery.Keyring
	statusService   *auth.StatusService
	appleClient     apple.Client
	appleNotifs     apple.NotificationVerifier
	appleTokenKeys  *recovery.Keyring
	digestKey       []byte
	appleClientID   string
}

// RateLimiterGroup holds the rate limiters used by the handlers.
// Nil buckets disable that path's limiting (tests); production wires all.
type RateLimiterGroup struct {
	OTPRequest         *ratelimit.TokenBucket
	OTPVerify          *ratelimit.TokenBucket
	Apple              *ratelimit.TokenBucket
	Status             *ratelimit.TokenBucket
	AppleNotifications *ratelimit.TokenBucket
	// Invite limits household invitation creation per IP (it sends email).
	Invite *ratelimit.TokenBucket
}

// HandlerOption customizes a Handler after construction.
type HandlerOption func(*Handler)

// WithAccountDeletion wires explicit account deletion: status credentials,
// the Apple revoke client + notification verifier, the Apple token keyring,
// the rotation-stable HMAC digest key, and the Apple client ID recorded on
// revocation jobs. Any nil component degrades its endpoint to an explicit
// unavailable error (never a silent successful skip).
func WithAccountDeletion(status *auth.StatusService, client apple.Client, notifs apple.NotificationVerifier, tokenKeys *recovery.Keyring, digestKey []byte, appleClientID string) HandlerOption {
	return func(h *Handler) {
		h.statusService = status
		h.appleClient = client
		h.appleNotifs = notifs
		h.appleTokenKeys = tokenKeys
		h.digestKey = digestKey
		h.appleClientID = appleClientID
	}
}

// NewHandler creates a new Handler with the given dependencies. appleVerifier
// may be nil when Sign in with Apple is disabled; the registered route then
// returns apple_not_configured. recoveryKeyring may be nil, which disables
// response-loss recovery (refresh attempts are ignored — legacy behavior);
// production always configures it (REFRESH_RECOVERY_KEYS is required).
func NewHandler(
	store db.Store,
	tokenService *auth.TokenService,
	otpService *auth.OTPService,
	emailSender email.Sender,
	rateLimiter *RateLimiterGroup,
	appleVerifier apple.Verifier,
	config HandlerConfig,
	logger *slog.Logger,
	recoveryKeyring *recovery.Keyring,
	opts ...HandlerOption,
) *Handler {
	h := &Handler{
		store:           store,
		tokenService:    tokenService,
		otpService:      otpService,
		emailSender:     emailSender,
		rateLimiter:     rateLimiter,
		appleVerifier:   appleVerifier,
		config:          config,
		logger:          logger,
		recoveryKeyring: recoveryKeyring,
	}
	for _, opt := range opts {
		opt(h)
	}
	return h
}

// ---------- Request / Response types ----------

type otpRequestReq struct {
	Email string `json:"email"`
}

type otpVerifyReq struct {
	Email string `json:"email"`
	Code  string `json:"code"`
}

type refreshReq struct {
	RefreshToken string `json:"refresh_token"`
	// RefreshAttemptID is the client's durable identifier for one logical
	// rotation (fix-refresh-response-loss). Optional: absent keeps exact
	// legacy behavior with no response-loss recovery.
	RefreshAttemptID *string `json:"refresh_attempt_id"`
}

type appleSignInReq struct {
	IdentityToken string `json:"identity_token"`
	// AuthorizationCode is the single-use code from the native authorization.
	// Updated clients always send it; identity-token-only requests from prior
	// clients keep their legacy sign-in behaviour (without storing a
	// revocable credential — explicit deletion then requires fresh
	// same-subject authorization via the deletion-credential endpoint).
	AuthorizationCode string `json:"authorization_code,omitempty"`
}

// AppleSignIn handles POST /api/v1/auth/apple.
// It verifies Apple's identity-token JWT, upserts the user by Apple's stable
// `sub` identifier behind the revocation fence, and issues our own access +
// refresh tokens (the same issuance path as VerifyOTP). Apple users are
// considered email-verified. When an authorization code is presented it is
// validated with Apple and the returned revocable credential is sealed into
// the vault, enabling automatic unlinking on explicit deletion.
func (h *Handler) AppleSignIn(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	if h.appleVerifier == nil {
		writeError(w, http.StatusServiceUnavailable, "apple_not_configured",
			"Sign in with Apple is not configured", nil)
		return
	}

	deviceID, ok := requireDeviceID(w, r)
	if !ok {
		return
	}

	var req appleSignInReq
	if err := decodeJSON(r, &req); err != nil {
		h.logger.Warn("invalid apple sign-in body", "error", err)
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}

	if req.IdentityToken == "" {
		writeError(w, http.StatusBadRequest, "invalid_body", "Identity token is required", nil)
		return
	}

	// Rate limit per IP.
	ip := h.clientIP(r)
	if h.rateLimiter.Apple != nil && !h.rateLimiter.Apple.Allow(ip) {
		h.logger.Warn("apple sign-in rate limited", "ip", ip)
		writeError(w, http.StatusTooManyRequests, "rate_limited",
			"Too many requests. Please try again later.", nil)
		return
	}

	claims, err := h.appleVerifier.Verify(ctx, req.IdentityToken)
	if err != nil {
		h.logger.Warn("apple identity token verification failed", "error", err)
		writeError(w, http.StatusUnauthorized, "invalid_apple_token",
			"Invalid Apple identity token", nil)
		return
	}

	// Fenced upsert: a pending revocation job for this subject refuses the
	// signup with 503 before any session exists, so an old revoke can never
	// invalidate the new grant. The code is not consumed on this path.
	user, err := h.store.UpsertAppleUser(ctx, claims.Sub, claims.Email, h.subjectDigest(claims.Sub), time.Now())
	if err != nil {
		if errors.Is(err, db.ErrAppleRevocationPending) {
			h.logger.Warn("apple signup fenced by pending revocation", "sub", redactSubject(claims.Sub))
			writeError(w, http.StatusServiceUnavailable, "apple_revocation_pending",
				"Apple unlinking is still in progress. Please retry shortly.", nil)
			return
		}
		if errors.Is(err, db.ErrAppleEmailInUse) {
			h.logger.Warn("apple signup email already registered", "sub", redactSubject(claims.Sub))
			writeError(w, http.StatusConflict, "apple_email_in_use",
				"This email is already registered. Sign in with email instead.", nil)
			return
		}
		if errors.Is(err, db.ErrNotFound) {
			h.writeInternalError(w, r, "apple upsert lost the user row", err)
			return
		}
		h.writeInternalError(w, r, "failed to upsert apple user", err)
		return
	}

	// When an authorization code is presented, validate it with Apple now:
	// a successful exchange proves a fresh authorization and mints (or
	// confirms) the lineage. Exchange failures degrade to the legacy path
	// (no vault credential stored) except a hard Apple rejection of the
	// code, which fails the request.
	var exchanged *apple.TokenResponse
	if req.AuthorizationCode != "" {
		if h.appleClient == nil {
			h.logger.Warn("apple authorization code presented but revocation is unconfigured")
		} else if tr, xerr := h.appleClient.ExchangeCode(ctx, req.AuthorizationCode); xerr != nil {
			if errors.Is(xerr, apple.ErrInvalidGrant) {
				h.logger.Warn("apple authorization code rejected", "userID", user.ID)
				writeError(w, http.StatusUnauthorized, "invalid_apple_token",
					"Invalid Apple authorization code", nil)
				return
			}
			h.logger.Warn("apple token exchange unavailable; continuing without stored credential",
				"userID", user.ID, "error", xerr)
		} else {
			// Bind the token response to the verified identity: the
			// exchange must resolve to the same subject and audience, or
			// the credential is attached to nothing.
			if idClaims, verr := h.appleVerifier.Verify(ctx, tr.IDToken); verr != nil ||
				idClaims.Sub != claims.Sub {
				h.logger.Warn("apple exchange identity mismatch", "userID", user.ID)
				writeError(w, http.StatusUnauthorized, "invalid_apple_token",
					"Invalid Apple authorization code", nil)
				return
			}
			exchanged = &tr
		}
	}

	// Authorize the session lineage. A set consent cutoff ends every
	// pre-cutoff authorization: only a fresh proof past the cutoff mints a
	// new lineage — a live code exchange, or an identity token issued at/after
	// the cutoff. A stale pre-revocation token (identity-token-only legacy
	// path) cannot mint its way around Settings revocation and is rejected.
	// Without a cutoff the existing lineage is kept (minted when absent) so
	// one device's sign-in never kills another's sessions.
	//
	// Every sign-in stamps its OWN verified authorization time (a live code
	// exchange proves now; otherwise Apple's issued-at, falling back to now
	// when absent) and records it as the account's latest authorization.
	// Sessions carry that time into their tokens, and the consent cutoff
	// compares per-session times — reusing the first authorization's time
	// would wrongly kill a fresh grant authorized after a (delayed)
	// revocation event but before its callback arrives.
	lineage := ""
	if user.AppleAuthLineage != nil {
		lineage = *user.AppleAuthLineage
	}
	authTime := h.verifiedAuthTime(claims, exchanged != nil)
	switch {
	case user.AppleConsentCutoff != nil:
		if _, ferr := h.appleAuthorizationFresh(claims, exchanged != nil, *user.AppleConsentCutoff); ferr != nil {
			h.logger.Warn("stale apple authorization past cutoff", "userID", user.ID)
			writeError(w, http.StatusUnauthorized, "invalid_apple_token",
				"This Apple authorization predates revocation. Re-authorize with Apple.", nil)
			return
		}
		lineage = newLineageID()
	case lineage == "":
		lineage = newLineageID()
	default:
		// Existing lineage, no cutoff: keep the lineage for vault
		// stability, but the latest-authorization metadata still advances
		// to this sign-in so a later delayed revocation event can tell a
		// fresh grant from a superseded one.
	}
	// Every branch stamps the session: the invariant is that a completed
	// sign-in always records its latest authorization (never silently keep
	// stale lineage/auth-time metadata, which feeds cutoff enforcement).
	if err := h.store.SetAppleSession(ctx, user.ID, authTime, lineage); err != nil {
		h.writeInternalError(w, r, "failed to stamp apple session", err)
		return
	}

	// Seal a successfully exchanged credential into the vault under the
	// session lineage. A missing keyring cannot happen when Apple is
	// configured (startup preflight); without it this degrades to
	// no-stored-credential rather than a failed login.
	if exchanged != nil && exchanged.RefreshToken != "" {
		if h.appleTokenKeys == nil {
			h.logger.Warn("apple token keyring unconfigured; credential not stored", "userID", user.ID)
		} else if sealed, serr := h.appleTokenKeys.Seal([]byte(exchanged.RefreshToken),
			apple.VaultAAD(lineage, authTime)); serr != nil {
			h.logger.Error("failed to seal apple credential", "error", serr)
		} else if serr := h.store.SaveAppleCredential(ctx, db.AppleCredential{
			UserID: user.ID, SealedRefresh: sealed, AuthTime: authTime, LineageID: lineage,
		}); serr != nil {
			h.writeInternalError(w, r, "failed to store apple credential", serr)
			return
		}
	}

	// Issue tokens (same path as VerifyOTP). Apple users are email-verified.
	// A household always exists from the first sign-in.
	user.AppleAuthLineage = &lineage
	if _, err := h.store.EnsureHousehold(ctx, user.ID); err != nil {
		h.writeInternalError(w, r, "failed to resolve household", err)
		return
	}
	h.issueTokens(ctx, w, r, user, deviceID, authTime, lineage)
	h.logger.Info("apple user signed in", "userID", user.ID)
}

// verifiedAuthTime reports the authorization time this sign-in proves: a
// live code exchange proves now; otherwise Apple's verified issued-at is
// the only trustworthy time (same Apple-clock domain as revocation events),
// falling back to now when the token carries none. Sessions carry this
// time so a later consent cutoff can compare per-session freshness.
func (h *Handler) verifiedAuthTime(claims apple.Claims, exchanged bool) time.Time {
	if !exchanged && claims.IssuedAt != nil {
		return claims.IssuedAt.Time
	}
	return time.Now()
}

// appleAuthorizationFresh reports whether the presented Apple authorization
// is fresh past the consent cutoff: a live code exchange always is (the
// exchange itself proves a live grant even within the cutoff's second); an
// identity-token-only authorization is fresh only when its issued-at is
// strictly after the cutoff. Same-second iat equality is not reliable
// freshness — both claims and events are often integer seconds, so an iat
// equal to the cutoff cannot prove the authorization postdates the event
// and fails closed. A missing iat or a stale iat is an error.
func (h *Handler) appleAuthorizationFresh(claims apple.Claims, exchanged bool, cutoff time.Time) (bool, error) {
	if exchanged {
		return true, nil
	}
	if claims.IssuedAt == nil {
		return false, errors.New("apple identity token carries no issued-at")
	}
	if !claims.IssuedAt.After(cutoff) {
		return false, errors.New("apple identity token does not postdate consent revocation")
	}
	return true, nil
}

type userResponse struct {
	ID            string `json:"id"`
	Email         string `json:"email"`
	EmailVerified bool   `json:"email_verified"`
	// HasAppleIdentity is server truth for provider handling (the account
	// has an Apple subject) — never inferred from an email suffix.
	HasAppleIdentity bool `json:"has_apple_identity"`
	// AppleDeletionAuthorizationRequired reports an Apple account with no
	// stored revocable credential: explicit deletion must first obtain
	// same-subject authorization (or fail with apple_credential_required).
	AppleDeletionAuthorizationRequired bool `json:"apple_deletion_authorization_required"`
}

type authResponse struct {
	AccessToken  string       `json:"access_token"`
	RefreshToken string       `json:"refresh_token"`
	User         userResponse `json:"user"`
	// AccountStatusCredential is the narrow read-only deletion-evidence
	// credential (see auth.StatusService). Omitted when the server is
	// unconfigured (tests); production always issues it.
	AccountStatusCredential string `json:"account_status_credential,omitempty"`
	AccountStatusExpiresAt  string `json:"account_status_expires_at,omitempty"`
}

type errorDetail struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Details any    `json:"details,omitempty"`
}

type errorResponse struct {
	Error errorDetail `json:"error"`
}

// ---------- Helpers ----------

var emailRegex = regexp.MustCompile(`^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$`)

// validateEmail reports whether email is an acceptable account identifier.
// net/mail parses the address structure (RFC 5322); the legacy regex then
// applies on top (ASCII mailbox, dotted domain with a 2+ letter TLD, max 254
// chars). NOTE: the pair is an intersection — strictly narrower than the old
// regex alone for inputs like ".a@example.com" or "a..b@example.com", which
// now return 400. Pre-existing accounts with such addresses would be locked
// out; confirmation tracked in #95.
func validateEmail(email string) bool {
	if email == "" || len(email) > 254 {
		return false
	}
	addr, err := mail.ParseAddress(email)
	if err != nil || addr.Address != email {
		return false
	}
	return emailRegex.MatchString(email)
}

func validateCode(code string) bool {
	if len(code) != 6 {
		return false
	}
	for _, c := range code {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Error("failed to encode JSON response", "error", err)
	}
}

func writeError(w http.ResponseWriter, status int, code, message string, details any) {
	writeJSON(w, status, errorResponse{
		Error: errorDetail{
			Code:    code,
			Message: message,
			Details: details,
		},
	})
}

// writeInternalError handles a handled HTTP 500: it reports the underlying
// error to Sentry (a no-op unless reporting is enabled), logs it exactly as
// before, and writes the generic internal_error envelope. The client never
// sees error internals. msg is the stable log label (also the Sentry
// fingerprint), so keep it a short constant — never user data.
func (h *Handler) writeInternalError(w http.ResponseWriter, r *http.Request, msg string, err error) {
	observe.ReportError(r, msg, err)
	h.logger.Error(msg, "error", err)
	writeError(w, http.StatusInternalServerError, "internal_error", "An internal error occurred", nil)
}

// writeAccepted responds 202 with a uniform "accepted" envelope. Used by the
// OTP request path to close user enumeration (no per-error status leaks).
func writeAccepted(w http.ResponseWriter) {
	writeJSON(w, http.StatusAccepted, map[string]string{"status": "accepted"})
}

// writeNotificationAccepted responds 200 with the accepted envelope. Apple
// expects HTTP 200 for server-to-server deliveries (processed or idempotent
// no-op); it is distinct from OTP's enumeration-closing 202.
func writeNotificationAccepted(w http.ResponseWriter) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "accepted"})
}

// deviceIDFromRequest extracts the stable client device id sent as the
// X-Device-Id header on session endpoints (verify, apple, refresh, logout).
func deviceIDFromRequest(r *http.Request) string {
	return strings.TrimSpace(r.Header.Get("X-Device-Id"))
}

// requireDeviceID validates the X-Device-Id header is present. Every refresh
// token is issued against a concrete device family, so session endpoints
// reject requests without one.
func requireDeviceID(w http.ResponseWriter, r *http.Request) (string, bool) {
	deviceID := deviceIDFromRequest(r)
	if deviceID == "" {
		writeError(w, http.StatusBadRequest, "invalid_request", "X-Device-Id header is required", nil)
		return "", false
	}
	return deviceID, true
}

// issueTokens creates an access + refresh token pair for user, persists the
// refresh token hash bound to deviceID (per-device refresh family) plus the
// session's Apple auth pair, and writes the authResponse envelope (including
// the account-status credential and Apple deletion-readiness metadata). On
// any failure it writes an internal_error response. It returns nothing;
// callers return.
func (h *Handler) issueTokens(ctx context.Context, w http.ResponseWriter, r *http.Request, user db.User, deviceID string, authTime time.Time, authLineage string) {
	accessToken, err := h.tokenService.CreateAccessTokenWithAuth(user.ID, user.Email, authTime, authLineage)
	if err != nil {
		h.writeInternalError(w, r, "failed to create access token", err)
		return
	}

	rawRefresh, refreshHash, err := h.tokenService.GenerateRefreshToken()
	if err != nil {
		h.writeInternalError(w, r, "failed to generate refresh token", err)
		return
	}

	saveErr := error(nil)
	if authLineage != "" {
		saveErr = h.store.SaveRefreshTokenWithAuth(ctx, user.ID, refreshHash, deviceID, &authTime, authLineage)
	} else {
		saveErr = h.store.SaveRefreshToken(ctx, user.ID, refreshHash, deviceID)
	}
	if saveErr != nil {
		h.writeInternalError(w, r, "failed to save refresh token", saveErr)
		return
	}

	h.writeAuthResponse(w, r, user, accessToken, rawRefresh)
}

// writeAuthResponse writes the authenticated session envelope: the token
// pair, server-truth provider metadata, and (when configured) a fresh
// account-status credential. Status issuance failure is a service error, not
// an omitted field: clients must be able to rely on its presence.
func (h *Handler) writeAuthResponse(w http.ResponseWriter, r *http.Request, user db.User, accessToken, rawRefresh string) {
	hasApple, required := h.deletionReadiness(r.Context(), user)
	resp := authResponse{
		AccessToken:  accessToken,
		RefreshToken: rawRefresh,
		User: userResponse{
			ID:                                 user.ID,
			Email:                              user.Email,
			EmailVerified:                      user.EmailVerified,
			HasAppleIdentity:                   hasApple,
			AppleDeletionAuthorizationRequired: required,
		},
	}
	if h.statusService != nil {
		cred, exp, err := h.statusService.Mint(user.ID)
		if err != nil {
			h.writeInternalError(w, r, "failed to mint status credential", err)
			return
		}
		resp.AccountStatusCredential = cred
		resp.AccountStatusExpiresAt = exp.UTC().Format(time.RFC3339)
	}
	writeJSON(w, http.StatusOK, resp)
}

// deletionReadiness reports server-truth provider metadata for a user: the
// account has an Apple identity, and explicit deletion would need fresh
// same-subject authorization (no stored revocable credential). Provider
// handling is never inferred from an email suffix. A vault read failure
// degrades to required=true with a warning: re-acquiring a credential is
// always safe, while a 500 here would lose an already-completed
// auth/refresh response (rotation has already committed).
func (h *Handler) deletionReadiness(ctx context.Context, user db.User) (hasApple, required bool) {
	if user.AppleSubject == nil || *user.AppleSubject == "" {
		return false, false
	}
	if _, err := h.store.GetAppleCredential(ctx, user.ID); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			return true, true
		}
		h.logger.Warn("apple credential vault read failed; reporting required", "error", err, "userID", user.ID)
		return true, true
	}
	return true, false
}

// maxBodyBytes caps request bodies (64 KB). Oversized bodies are rejected
// with 400 invalid_body by the handler, matching the previous behavior.
const maxBodyBytes = 1 << 16

func decodeJSON(r *http.Request, v any) error {
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBodyBytes+1))
	if err != nil {
		return fmt.Errorf("read request body: %w", err)
	}
	if len(body) > maxBodyBytes {
		return errors.New("request body too large")
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	if err := dec.Decode(v); err != nil {
		var syntaxErr *json.SyntaxError
		if errors.As(err, &syntaxErr) {
			return fmt.Errorf("invalid JSON: %w", err)
		}
		return fmt.Errorf("decode request body: %w", err)
	}
	// Reject extra fields.
	if dec.More() {
		return errors.New("unexpected extra data in request body")
	}
	return nil
}

// RequestOTP handles POST /api/v1/auth/otp/request.
// It validates the email, rate-limits per IP+email, upserts the user,
// generates an OTP, and sends it via email. Always returns 202.
func (h *Handler) RequestOTP(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	var req otpRequestReq
	if err := decodeJSON(r, &req); err != nil {
		h.logger.Warn("invalid OTP request body", "error", err)
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}

	if !validateEmail(req.Email) {
		h.logger.Warn("invalid email in OTP request", "email", maskEmail(req.Email))
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid email address", nil)
		return
	}

	// Rate limit per IP+email.
	ip := h.clientIP(r)
	rateKey := fmt.Sprintf("%s:%s", ip, req.Email)
	if h.rateLimiter.OTPRequest != nil && !h.rateLimiter.OTPRequest.Allow(rateKey) {
		h.logger.Warn("OTP request rate limited", "ip", ip, "email", maskEmail(req.Email))
		writeError(w, http.StatusTooManyRequests, "rate_limited", "Too many requests. Please try again later.", nil)
		return
	}

	// Always return 202 to prevent user enumeration.
	// Upsert user, generate OTP, send email — all best-effort.
	user, err := h.store.UpsertUser(ctx, req.Email)
	if err != nil {
		h.logger.Error("failed to upsert user", "error", err)
		writeAccepted(w)
		return
	}

	code, hash, err := h.otpService.GenerateOTP()
	if err != nil {
		h.logger.Error("failed to generate OTP", "error", err)
		writeAccepted(w)
		return
	}

	expiresAt := time.Now().Add(h.otpService.Expiry)
	if err := h.store.SaveOTP(ctx, user.ID, hash, expiresAt, h.otpService.MaxAttempts); err != nil {
		h.logger.Error("failed to save OTP", "error", err)
		writeAccepted(w)
		return
	}

	msg := email.NewOTPMessage(req.Email, code)
	if err := h.emailSender.Send(ctx, msg); err != nil {
		h.logger.Error("failed to send OTP email", "error", err)
	}

	writeAccepted(w)
}

// VerifyOTP handles POST /api/v1/auth/otp/verify.
// It validates the email and code, checks expiry and attempts,
// verifies the code, marks the user verified, and returns tokens.
func (h *Handler) VerifyOTP(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	deviceID, ok := requireDeviceID(w, r)
	if !ok {
		return
	}

	var req otpVerifyReq
	if err := decodeJSON(r, &req); err != nil {
		h.logger.Warn("invalid OTP verify body", "error", err)
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}

	if !validateEmail(req.Email) || !validateCode(req.Code) {
		h.logger.Warn("invalid email or code in OTP verify", "email", maskEmail(req.Email))
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid email or code", nil)
		return
	}

	// Rate limit per IP+email.
	ip := h.clientIP(r)
	rateKey := fmt.Sprintf("%s:%s", ip, req.Email)
	if h.rateLimiter.OTPVerify != nil && !h.rateLimiter.OTPVerify.Allow(rateKey) {
		h.logger.Warn("OTP verify rate limited", "ip", ip, "email", maskEmail(req.Email))
		writeError(w, http.StatusTooManyRequests, "rate_limited", "Too many attempts. Please try again later.", nil)
		return
	}

	user, err := h.store.GetUserByEmail(ctx, req.Email)
	if err != nil {
		h.logger.Warn("user not found for OTP verify", "email", maskEmail(req.Email))
		writeError(w, http.StatusUnauthorized, "invalid_otp", "Invalid or expired code", nil)
		return
	}

	// A set Apple consent cutoff ends every lineageless session — including
	// email-OTP sessions for this Apple-registered account, which the
	// middleware and refresh would immediately 401 as dead ends. Reject up
	// front with the re-authorization instruction instead of minting
	// credentials that can never be used.
	if user.AppleSubject != nil && *user.AppleSubject != "" &&
		h.sessionCutByRevocation(nil, nil, user) {
		h.logger.Warn("otp sign-in fenced by apple consent cutoff", "userID", user.ID)
		writeError(w, http.StatusUnauthorized, "invalid_apple_token",
			"This Apple authorization predates revocation. Re-authorize with Apple.", nil)
		return
	}

	otp, err := h.store.GetValidOTP(ctx, user.ID)
	if err != nil {
		h.logger.Warn("no valid OTP found for user", "userID", user.ID)
		writeError(w, http.StatusUnauthorized, "invalid_otp", "Invalid or expired code", nil)
		return
	}

	if time.Now().After(otp.ExpiresAt) {
		h.logger.Warn("OTP expired", "userID", user.ID)
		writeError(w, http.StatusUnauthorized, "otp_expired", "Code has expired. Request a new one.", nil)
		return
	}

	if otp.Attempts >= otp.MaxAttempts {
		h.logger.Warn("OTP attempts exhausted", "userID", user.ID)
		writeError(w, http.StatusUnauthorized, "otp_attempts_exceeded", "Too many incorrect attempts. Request a new code.", nil)
		return
	}

	// Verify code using constant-time comparison.
	if !h.otpService.VerifyCode(req.Code, otp.CodeHash) {
		h.logger.Warn("invalid OTP code", "userID", user.ID)
		if err := h.store.IncrementOTPAttempts(ctx, otp.ID); err != nil {
			h.logger.Error("failed to increment OTP attempts", "error", err)
		}
		if otp.Attempts+1 >= otp.MaxAttempts {
			if err := h.store.MarkOTPExhausted(ctx, otp.ID); err != nil {
				h.logger.Error("failed to mark OTP exhausted", "error", err)
			}
		}
		writeError(w, http.StatusUnauthorized, "invalid_otp", "Invalid or expired code", nil)
		return
	}

	if err := h.store.SetUserVerified(ctx, user.ID); err != nil {
		h.writeInternalError(w, r, "failed to mark user verified", err)
		return
	}
	user.EmailVerified = true

	// A household always exists from the first sign-in: resolve or create
	// before any token issues so pet-scoped writes never lack a scope.
	if _, err := h.store.EnsureHousehold(ctx, user.ID); err != nil {
		h.writeInternalError(w, r, "failed to resolve household", err)
		return
	}

	h.issueTokens(ctx, w, r, user, deviceID, time.Time{}, "")
}

// RefreshToken handles POST /api/v1/auth/refresh.
// It validates the refresh token, checks revocation (per-device reuse
// detection), enforces the refresh TTL against created_at, and rotates the
// pair within the issuing device's family.
//
// With refresh_attempt_id (fix-refresh-response-loss), an eligible retry —
// same device, same revoked predecessor, same accepted pending attempt —
// recovers the committed successor plus a fresh access token without
// rotating again and without revocation. An attempt unknown to storage or
// bound to another account/device replays as token_reuse; an attempt bound
// to a different predecessor is a 409 conflict without revocation.
// Database, crypto, and receipt failures are service errors (never
// authentication rejections) and revoke nothing. Requests without the
// field keep exact legacy behavior.
func (h *Handler) RefreshToken(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	deviceID, ok := requireDeviceID(w, r)
	if !ok {
		return
	}

	var req refreshReq
	if err := decodeJSON(r, &req); err != nil {
		h.logger.Warn("invalid refresh body", "error", err)
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}

	if req.RefreshToken == "" {
		h.logger.Warn("empty refresh token")
		writeError(w, http.StatusBadRequest, "invalid_body", "Refresh token is required", nil)
		return
	}

	attempt, ok := normalizeRefreshAttempt(req.RefreshAttemptID)
	if !ok {
		h.logger.Warn("invalid refresh attempt id")
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid refresh attempt", nil)
		return
	}
	withRecovery := attempt != "" && h.recoveryKeyring != nil
	attemptHash := ""
	if withRecovery {
		attemptHash = auth.HashToken(attempt)
	}

	tokenHash := auth.HashToken(req.RefreshToken)
	storedToken, err := h.store.GetRefreshToken(ctx, tokenHash)
	if err != nil {
		// A failed lookup is a service failure, never proof the token does
		// not exist: report 5xx and preserve the family.
		if errors.Is(err, db.ErrNotFound) {
			h.logger.Warn("refresh token not found")
			writeError(w, http.StatusUnauthorized, "invalid_refresh", "Invalid refresh token", nil)
			return
		}
		h.writeInternalError(w, r, "refresh token lookup failed", err)
		return
	}

	// The token belongs to a concrete device family: a presentation from a
	// different device is rejected without revoking anything and without
	// recovery, so the real family's tokens stay intact.
	if deviceID != storedToken.DeviceID {
		h.logger.Warn("refresh token device mismatch", "userID", storedToken.UserID,
			"deviceID", deviceID, "tokenDeviceID", storedToken.DeviceID)
		writeError(w, http.StatusUnauthorized, "invalid_refresh", "Invalid refresh token", nil)
		return
	}

	// The account must still exist: a purged account's tokens authorize
	// nothing. Missing users map to an ordinary authentication failure
	// (invalid_refresh) — never to deletion proof, recovery, or revocation.
	user, err := h.store.GetUserByID(ctx, storedToken.UserID)
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			h.logger.Warn("refresh for purged account", "userID", storedToken.UserID)
			writeError(w, http.StatusUnauthorized, "invalid_refresh", "Invalid refresh token", nil)
			return
		}
		h.writeInternalError(w, r, "refresh user lookup failed", err)
		return
	}

	// A set Apple consent cutoff ends every pre-cutoff session lineage.
	// Only a completed fresh Apple authorization (matching current lineage)
	// passes; pre-lineage tokens cannot bypass. Ordinary failure, no
	// revocation, no recovery — the family is already dead.
	if h.sessionCutByRevocation(storedToken.AuthTime, storedToken.AuthLineage, user) {
		h.logger.Warn("refresh cut off by apple consent revocation", "userID", storedToken.UserID,
			"deviceID", storedToken.DeviceID)
		writeError(w, http.StatusUnauthorized, "invalid_refresh", "Invalid refresh token", nil)
		return
	}

	// Check if revoked FIRST — before the TTL check — so a replayed revoked
	// token always triggers per-device reuse revocation, even when its
	// created_at is older than the refresh TTL (otherwise it would return
	// refresh_expired and leave the live family tokens unrevoked).
	if storedToken.Revoked {
		if !withRecovery {
			h.revokeOnReuse(ctx, storedToken)
			writeError(w, http.StatusUnauthorized, "token_reuse", "Token has been revoked. Sign in again.", nil)
			return
		}
		h.recoverRefresh(ctx, w, r, tokenHash, storedToken, attemptHash)
		return
	}

	// Enforce the refresh TTL against created_at: an expired family is
	// rejected (lock-not-wipe — the client keeps local files and re-auths).
	if time.Since(storedToken.CreatedAt) > h.tokenService.RefreshTokenTTL {
		h.logger.Warn("refresh token expired", "userID", storedToken.UserID,
			"deviceID", storedToken.DeviceID, "createdAt", storedToken.CreatedAt)
		writeError(w, http.StatusUnauthorized, "refresh_expired", "Refresh token has expired. Please sign in again.", nil)
		return
	}

	if !withRecovery {
		// Legacy rotation: revoke the old token, then issue the pair.
		if err := h.store.RevokeRefreshToken(ctx, storedToken.ID); err != nil {
			h.writeInternalError(w, r, "failed to revoke old refresh token", err)
			return
		}

		// Re-check the account after the revocation write: a purge or consent
		// cutoff that landed between the pre-check and this write must not
		// mint a successor for a dead session.
		user, err := h.store.GetUserByID(ctx, storedToken.UserID)
		if err != nil {
			if errors.Is(err, db.ErrNotFound) {
				writeError(w, http.StatusUnauthorized, "invalid_refresh", "Invalid refresh token", nil)
				return
			}
			h.writeInternalError(w, r, "failed to get user for token refresh", err)
			return
		}
		if h.sessionCutByRevocation(storedToken.AuthTime, storedToken.AuthLineage, user) {
			writeError(w, http.StatusUnauthorized, "invalid_refresh", "Invalid refresh token", nil)
			return
		}

		// Generate new token pair; rotation stays within the device's family.
		// The successor inherits the predecessor's lineage (pre-lineage and
		// email sessions carry empty lineage, unaffected by Apple cutoffs).
		var authTime time.Time
		var authLineage string
		if storedToken.AuthTime != nil {
			authTime = *storedToken.AuthTime
		}
		if storedToken.AuthLineage != nil {
			authLineage = *storedToken.AuthLineage
		}
		h.issueTokens(ctx, w, r, user, storedToken.DeviceID, authTime, authLineage)
		return
	}

	h.rotateWithRecovery(ctx, w, r, deviceID, tokenHash, storedToken, attemptHash)
}

// sessionCutByRevocation reports whether an Apple consent cutoff ends the
// session that tokenAuth describes. No cutoff: always false (email sessions
// and pre-revocation Apple sessions pass). Cutoff set: the session's own
// original verified authorization time decides — a session authorized
// before the cutoff predates revocation and is dead; a session authorized
// at/after the event is a fresh re-authorization and survives, whatever the
// account's current lineage is (a second post-revocation device sign-in
// must not kill the first). Sessions without an Apple lineage (email-OTP or
// pre-lineage tokens on a cutoff account) and lineaged sessions with no
// recorded auth time fail closed: they cannot prove they postdate the event.
func (h *Handler) sessionCutByRevocation(tokenAuthTime *time.Time, tokenLineage *string, user db.User) bool {
	if user.AppleConsentCutoff == nil {
		return false
	}
	if tokenLineage == nil || *tokenLineage == "" {
		return true
	}
	if tokenAuthTime == nil {
		return true
	}
	return tokenAuthTime.Before(*user.AppleConsentCutoff)
}

// revokeOnReuse burns the offending device's family after genuine reuse.
// Revocation failure is logged, never fatal: the rejection stands.
func (h *Handler) revokeOnReuse(ctx context.Context, storedToken db.RefreshToken) {
	h.logger.Warn("refresh token reuse detected", "userID", storedToken.UserID, "deviceID", storedToken.DeviceID)
	if err := h.store.RevokeUserDeviceSessions(ctx, storedToken.UserID, storedToken.DeviceID); err != nil {
		h.logger.Error("failed to revoke device tokens after reuse", "error", err)
	}
}

// maxAttemptIDLen bounds the client attempt identifier (a UUIDv7 is 36
// chars); longer values are malformed requests, not attempts.
const maxAttemptIDLen = 128

// normalizeRefreshAttempt trims the optional attempt identifier. Empty or
// absent means legacy behavior (no recovery). Overlong values are rejected.
func normalizeRefreshAttempt(raw *string) (string, bool) {
	if raw == nil {
		return "", true
	}
	attempt := strings.TrimSpace(*raw)
	if attempt == "" {
		return "", true
	}
	if len(attempt) > maxAttemptIDLen {
		return "", false
	}
	return attempt, true
}

// recoverRefresh serves an eligible same-device retry of an accepted pending
// rotation: the identical successor refresh credential plus a newly minted
// valid access token, without rotating again and without revocation.
// Anything else on this path — unknown or rebound attempt, consumed or
// expired receipt, unavailable successor — follows the failure taxonomy:
// token_reuse burns the family, conflicts and expiry reject without
// revocation, and service failures return 5xx without revocation.
func (h *Handler) recoverRefresh(
	ctx context.Context, w http.ResponseWriter, r *http.Request,
	tokenHash string, storedToken db.RefreshToken, attemptHash string,
) {
	receipt, err := h.store.FindRecoveryReceipt(ctx, attemptHash)
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			// Unknown attempt replaying a revoked predecessor: genuine
			// reuse — burn only that device's family. The family dies
			// with the account anyway, so a purge-time race needs no
			// revocation side effect: skip the burn when the account is
			// gone.
			if _, uerr := h.store.GetUserByID(ctx, storedToken.UserID); uerr == nil {
				h.revokeOnReuse(ctx, storedToken)
			} else if !errors.Is(uerr, db.ErrNotFound) {
				h.writeInternalError(w, r, "recovery user lookup failed", uerr)
				return
			}
			writeError(w, http.StatusUnauthorized, "token_reuse", "Token has been revoked. Sign in again.", nil)
			return
		}
		h.writeInternalError(w, r, "recovery receipt lookup failed", err)
		return
	}

	if receipt.UserID != storedToken.UserID || receipt.DeviceID != storedToken.DeviceID {
		// The attempt belongs to another account or device: it cannot
		// authorize this predecessor. Treat as an unknown replay.
		h.revokeOnReuse(ctx, storedToken)
		writeError(w, http.StatusUnauthorized, "token_reuse", "Token has been revoked. Sign in again.", nil)
		return
	}
	if receipt.PredecessorHash != tokenHash {
		// The attempt identifier was rebound to a different predecessor:
		// a conflict, not theft. Reject without credentials, without
		// overwriting the original receipt, and without revocation.
		h.logger.Warn("refresh attempt rebound to another predecessor",
			"userID", storedToken.UserID, "deviceID", storedToken.DeviceID)
		writeError(w, http.StatusConflict, "refresh_attempt_conflict",
			"Refresh attempt does not match this token. Retry with the attempt bound to this token.", nil)
		return
	}

	h.serveRecovery(ctx, w, r, receipt, storedToken)
}

// serveRecovery returns the receipt's successor when it is still eligible:
// unconsumed, unexpired, live, and decryptable. A consumed or revoked
// successor closes recovery with 409 refresh_attempt_completed; an elapsed
// expiry with 401 refresh_expired; crypto and storage failures with 5xx.
// None of these revoke the family.
func (h *Handler) serveRecovery(
	ctx context.Context, w http.ResponseWriter, r *http.Request,
	receipt db.RecoveryReceipt, storedToken db.RefreshToken,
) {
	if receipt.Consumed {
		h.logger.Warn("refresh attempt already completed",
			"userID", storedToken.UserID, "deviceID", storedToken.DeviceID)
		writeError(w, http.StatusConflict, "refresh_attempt_completed",
			"Refresh attempt already completed. Use the current session token.", nil)
		return
	}

	// An expired receipt is dead from this rejection: close it so the
	// opportunistic sweep reclaims the row once it is long past expiry.
	// The verdict stays refresh_expired; only retention changes.
	if time.Now().After(receipt.ExpiresAt) {
		h.logger.Warn("refresh recovery expired",
			"userID", storedToken.UserID, "deviceID", storedToken.DeviceID)
		if err := h.store.ConsumeRecoveryReceipt(ctx, receipt.AttemptHash); err != nil {
			h.logger.Error("failed to close expired recovery receipt", "error", err)
		}
		writeError(w, http.StatusUnauthorized, "refresh_expired", "Refresh token has expired. Please sign in again.", nil)
		return
	}

	successor, err := h.store.GetRefreshToken(ctx, receipt.SuccessorHash)
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			h.logger.Warn("refresh recovery successor unknown",
				"userID", storedToken.UserID, "deviceID", storedToken.DeviceID)
			writeError(w, http.StatusConflict, "refresh_attempt_completed",
				"Refresh attempt already completed. Use the current session token.", nil)
			return
		}
		h.writeInternalError(w, r, "recovery successor lookup failed", err)
		return
	}
	if successor.Revoked {
		// Logout or genuine reuse ended the session after the receipt was
		// recorded: replaying the attempt cannot recreate or unlock it.
		h.logger.Warn("refresh recovery successor revoked",
			"userID", storedToken.UserID, "deviceID", storedToken.DeviceID)
		writeError(w, http.StatusConflict, "refresh_attempt_completed",
			"Refresh attempt already completed. Use the current session token.", nil)
		return
	}
	if time.Since(successor.CreatedAt) > h.tokenService.RefreshTokenTTL {
		h.logger.Warn("refresh recovery successor expired",
			"userID", storedToken.UserID, "deviceID", storedToken.DeviceID)
		if err := h.store.ConsumeRecoveryReceipt(ctx, receipt.AttemptHash); err != nil {
			h.logger.Error("failed to close expired recovery receipt", "error", err)
		}
		writeError(w, http.StatusUnauthorized, "refresh_expired", "Refresh token has expired. Please sign in again.", nil)
		return
	}

	rawSuccessor, err := h.recoveryKeyring.Open(
		receipt.SealedSuccessor, h.recoveryAAD(receipt, storedToken.UserID, storedToken.DeviceID))
	if err != nil {
		h.writeInternalError(w, r, "recovery successor decryption failed", err)
		return
	}

	// The account must still exist and the cutoff must not have passed
	// since rotation: no valid successor session for a deleted account, and
	// a post-rotation cutoff ends recovery without revocation or renewal.
	user, err := h.store.GetUserByID(ctx, storedToken.UserID)
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusUnauthorized, "invalid_refresh", "Invalid refresh token", nil)
			return
		}
		h.writeInternalError(w, r, "failed to get user for token recovery", err)
		return
	}
	if h.sessionCutByRevocation(storedToken.AuthTime, storedToken.AuthLineage, user) ||
		h.sessionCutByRevocation(successor.AuthTime, successor.AuthLineage, user) {
		writeError(w, http.StatusUnauthorized, "invalid_refresh", "Invalid refresh token", nil)
		return
	}

	// The access token inherits the successor's lineage so the cutoff keeps
	// applying to recovered sessions.
	var authTime time.Time
	var authLineage string
	if successor.AuthTime != nil {
		authTime = *successor.AuthTime
	}
	if successor.AuthLineage != nil {
		authLineage = *successor.AuthLineage
	}
	accessToken, err := h.tokenService.CreateAccessTokenWithAuth(user.ID, user.Email, authTime, authLineage)
	if err != nil {
		h.writeInternalError(w, r, "failed to create access token", err)
		return
	}

	h.logger.Info("refresh attempt recovered", "userID", storedToken.UserID, "deviceID", storedToken.DeviceID)
	h.writeAuthResponse(w, r, user, accessToken, string(rawSuccessor))
}

// rotateWithRecovery performs the first rotation of a logical attempt: it
// seals the fresh successor and commits predecessor revocation, successor
// insertion, and the recovery receipt in one transaction. A concurrent
// duplicate that already accepted the attempt converges on the winner's
// successor instead of rotating forward.
func (h *Handler) rotateWithRecovery(
	ctx context.Context, w http.ResponseWriter, r *http.Request,
	deviceID, tokenHash string, storedToken db.RefreshToken, attemptHash string,
) {
	if receipt, err := h.store.FindRecoveryReceipt(ctx, attemptHash); err == nil {
		if receipt.UserID == storedToken.UserID && receipt.DeviceID == storedToken.DeviceID &&
			receipt.PredecessorHash == tokenHash {
			// The receipt exists but our earlier read saw the predecessor
			// live: either a concurrent duplicate just committed (stale
			// read) or storage is inconsistent. Re-read to decide: a now
			// revoked predecessor means the other delivery won — serve
			// its successor.
			fresh, ferr := h.store.GetRefreshToken(ctx, tokenHash)
			if ferr != nil {
				h.writeInternalError(w, r, "refresh token re-read failed", ferr)
				return
			}
			if !fresh.Revoked {
				h.writeInternalError(w, r, "recovery receipt inconsistent with live predecessor",
					errors.New("receipt predecessor not revoked"))
				return
			}
			h.serveRecovery(ctx, w, r, receipt, storedToken)
			return
		}
		h.logger.Warn("refresh attempt rebound to another predecessor",
			"userID", storedToken.UserID, "deviceID", storedToken.DeviceID)
		writeError(w, http.StatusConflict, "refresh_attempt_conflict",
			"Refresh attempt does not match this token. Retry with the attempt bound to this token.", nil)
		return
	} else if !errors.Is(err, db.ErrNotFound) {
		h.writeInternalError(w, r, "recovery receipt lookup failed", err)
		return
	}

	rawSuccessor, successorHash, err := h.tokenService.GenerateRefreshToken()
	if err != nil {
		h.writeInternalError(w, r, "failed to generate refresh token", err)
		return
	}

	// The receipt expiry is the successor's fixed refresh expiry: retries
	// never extend it, and long suspension stays recoverable within it.
	expiresAt := time.Now().Add(h.tokenService.RefreshTokenTTL)
	sealed, err := h.recoveryKeyring.Seal([]byte(rawSuccessor), h.recoveryAADFor(
		storedToken.UserID, deviceID, tokenHash, attemptHash, expiresAt))
	if err != nil {
		h.writeInternalError(w, r, "recovery successor sealing failed", err)
		return
	}

	_, err = h.store.RotateRefreshToken(ctx, db.RotateArgs{
		UserID:              storedToken.UserID,
		DeviceID:            storedToken.DeviceID,
		PredecessorID:       storedToken.ID,
		PredecessorHash:     tokenHash,
		SuccessorHash:       successorHash,
		AttemptHash:         attemptHash,
		SealedSuccessor:     sealed,
		ExpiresAt:           expiresAt,
		PruneConsumedBefore: time.Now().Add(-h.tokenService.RefreshTokenTTL),
	})
	if err != nil {
		if errors.Is(err, db.ErrUserMissing) {
			// A purge removed the account between the pre-check and the
			// rotation write: ordinary authentication failure, no
			// revocation side effects, nothing minted.
			writeError(w, http.StatusUnauthorized, "invalid_refresh", "Invalid refresh token", nil)
			return
		}
		if errors.Is(err, db.ErrAttemptExists) {
			// A concurrent duplicate accepted the attempt first: serve
			// the winner's successor. Classified exactly like the
			// pre-check path (account/device mismatch burns, rebound
			// conflicts) so the four taxonomy sites cannot diverge.
			receipt, ferr := h.store.FindRecoveryReceipt(ctx, attemptHash)
			if ferr != nil {
				h.writeInternalError(w, r, "recovery receipt lookup failed", ferr)
				return
			}
			if receipt.UserID != storedToken.UserID || receipt.DeviceID != storedToken.DeviceID {
				h.revokeOnReuse(ctx, storedToken)
				writeError(w, http.StatusUnauthorized, "token_reuse", "Token has been revoked. Sign in again.", nil)
				return
			}
			if receipt.PredecessorHash != tokenHash {
				h.logger.Warn("refresh attempt rebound to another predecessor",
					"userID", storedToken.UserID, "deviceID", storedToken.DeviceID)
				writeError(w, http.StatusConflict, "refresh_attempt_conflict",
					"Refresh attempt does not match this token. Retry with the attempt bound to this token.", nil)
				return
			}
			h.serveRecovery(ctx, w, r, receipt, storedToken)
			return
		}
		if errors.Is(err, db.ErrPredecessorRevoked) {
			// A concurrent rotation already consumed the predecessor: if
			// our attempt was the accepted one, serve the winner's
			// successor; otherwise this is genuine reuse of a dead token.
			receipt, ferr := h.store.FindRecoveryReceipt(ctx, attemptHash)
			if ferr != nil {
				if errors.Is(ferr, db.ErrNotFound) {
					h.revokeOnReuse(ctx, storedToken)
					writeError(w, http.StatusUnauthorized, "token_reuse", "Token has been revoked. Sign in again.", nil)
					return
				}
				h.writeInternalError(w, r, "recovery receipt lookup failed", ferr)
				return
			}
			if receipt.UserID != storedToken.UserID || receipt.DeviceID != storedToken.DeviceID {
				h.revokeOnReuse(ctx, storedToken)
				writeError(w, http.StatusUnauthorized, "token_reuse", "Token has been revoked. Sign in again.", nil)
				return
			}
			if receipt.PredecessorHash != tokenHash {
				h.logger.Warn("refresh attempt rebound to another predecessor",
					"userID", storedToken.UserID, "deviceID", storedToken.DeviceID)
				writeError(w, http.StatusConflict, "refresh_attempt_conflict",
					"Refresh attempt does not match this token. Retry with the attempt bound to this token.", nil)
				return
			}
			h.serveRecovery(ctx, w, r, receipt, storedToken)
			return
		}
		// The transaction rolled back: the predecessor stays usable.
		h.writeInternalError(w, r, "failed to rotate refresh token", err)
		return
	}

	// Re-check the account after rotation: a purge or cutoff that landed
	// mid-rotation must not issue credentials for a dead session. The
	// rotation itself already committed; the successor row is harmless
	// (revoked-family semantics reject it on next use).
	user, err := h.store.GetUserByID(ctx, storedToken.UserID)
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusUnauthorized, "invalid_refresh", "Invalid refresh token", nil)
			return
		}
		h.writeInternalError(w, r, "failed to get user for token refresh", err)
		return
	}
	if h.sessionCutByRevocation(storedToken.AuthTime, storedToken.AuthLineage, user) {
		writeError(w, http.StatusUnauthorized, "invalid_refresh", "Invalid refresh token", nil)
		return
	}

	// The new access token inherits the predecessor's lineage (copied to
	// the successor in-transaction), so the cutoff keeps applying.
	var authTime time.Time
	var authLineage string
	if storedToken.AuthTime != nil {
		authTime = *storedToken.AuthTime
	}
	if storedToken.AuthLineage != nil {
		authLineage = *storedToken.AuthLineage
	}
	accessToken, err := h.tokenService.CreateAccessTokenWithAuth(user.ID, user.Email, authTime, authLineage)
	if err != nil {
		h.writeInternalError(w, r, "failed to create access token", err)
		return
	}

	h.writeAuthResponse(w, r, user, accessToken, rawSuccessor)
}

// recoveryAADFor binds a sealed successor to its account, device,
// predecessor, attempt, and fixed expiry. Only hashes and the expiry
// timestamp enter the associated data — never raw tokens or attempts.
func (h *Handler) recoveryAADFor(userID, deviceID, predecessorHash, attemptHash string, expiresAt time.Time) []byte {
	return recovery.AAD(userID, deviceID, predecessorHash, attemptHash, expiresAt.UTC().Format(time.RFC3339))
}

// recoveryAAD rebuilds the associated data for a stored receipt.
func (h *Handler) recoveryAAD(receipt db.RecoveryReceipt, userID, deviceID string) []byte {
	return h.recoveryAADFor(userID, deviceID, receipt.PredecessorHash, receipt.AttemptHash, receipt.ExpiresAt)
}

// Logout handles POST /api/v1/auth/logout.
// It revokes only the calling device's refresh family, identified by the
// request's X-Device-Id, leaving other devices' sessions intact.
func (h *Handler) Logout(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	userID, ok := UserIDFromContext(ctx)
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized", "Not authenticated", nil)
		return
	}

	deviceID, ok := requireDeviceID(w, r)
	if !ok {
		return
	}

	// Revoke only this device's refresh tokens.
	if err := h.store.RevokeUserDeviceSessions(ctx, userID, deviceID); err != nil {
		h.writeInternalError(w, r, "failed to revoke device tokens on logout", err)
		return
	}

	h.logger.Info("user logged out", "userID", userID, "deviceID", deviceID)
	w.WriteHeader(http.StatusNoContent)
}

// meResponse is the GET /auth/me envelope: the profile, the current
// account-status credential, and its expiry.
type meResponse struct {
	User                    userResponse `json:"user"`
	AccountStatusCredential string       `json:"account_status_credential,omitempty"`
	AccountStatusExpiresAt  string       `json:"account_status_expires_at,omitempty"`
}

// Me handles GET /api/v1/auth/me.
// It returns the authenticated user profile with deletion metadata.
func (h *Handler) Me(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	userID, ok := UserIDFromContext(ctx)
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized", "Not authenticated", nil)
		return
	}

	user, err := h.store.GetUserByID(ctx, userID)
	if err != nil {
		// The middleware normally rejects purged accounts first; this maps
		// the residual race to an ordinary authentication failure, never a
		// spurious internal error.
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusUnauthorized, "unauthorized", "Invalid or expired access token", nil)
			return
		}
		h.writeInternalError(w, r, "failed to get user for /me", err)
		return
	}

	hasApple, required := h.deletionReadiness(ctx, user)
	resp := meResponse{
		User: userResponse{
			ID:                                 user.ID,
			Email:                              user.Email,
			EmailVerified:                      user.EmailVerified,
			HasAppleIdentity:                   hasApple,
			AppleDeletionAuthorizationRequired: required,
		},
	}
	if h.statusService != nil {
		cred, exp, err := h.statusService.Mint(user.ID)
		if err != nil {
			h.writeInternalError(w, r, "failed to mint status credential", err)
			return
		}
		resp.AccountStatusCredential = cred
		resp.AccountStatusExpiresAt = exp.UTC().Format(time.RFC3339)
	}
	writeJSON(w, http.StatusOK, resp)
}

// extractIP returns the direct TCP peer address from r.RemoteAddr, stripping
// the port. It does NOT consult forwarded headers — see Handler.clientIP for
// the trusted-proxy-aware version used for rate limiting.
func extractIP(r *http.Request) string {
	// Strip the port from RemoteAddr. Use net.SplitHostPort so IPv6 literals
	// like "[::1]:1234" are handled correctly — strings.LastIndex(":") would
	// split inside the IPv6 address and return a truncated, bogus host.
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return host
	}
	return r.RemoteAddr
}

// clientIP returns the effective client IP used for rate limiting. Forwarded
// headers (X-Forwarded-For, X-Real-IP) are honoured only when the direct TCP
// peer is a configured trusted proxy; otherwise the direct peer is used. With
// no trusted proxies configured, forwarded headers are always ignored — the
// safe default that prevents rate-limit bypass via spoofed headers.
func (h *Handler) clientIP(r *http.Request) string {
	peer := extractIP(r)
	if !h.isTrustedProxy(peer) {
		return peer
	}
	if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
		parts := strings.SplitN(fwd, ",", 2)
		return strings.TrimSpace(parts[0])
	}
	if realIP := r.Header.Get("X-Real-IP"); realIP != "" {
		return strings.TrimSpace(realIP)
	}
	return peer
}

// isTrustedProxy reports whether ip matches one of the configured trusted
// proxy CIDRs. With no trusted proxies configured it always returns false.
func (h *Handler) isTrustedProxy(ip string) bool {
	if len(h.config.TrustedProxies) == 0 {
		return false
	}
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return false
	}
	for _, cidr := range h.config.TrustedProxies {
		if cidr.Contains(parsed) {
			return true
		}
	}
	return false
}

// ParseTrustedProxies parses a comma-separated list of IPs/CIDRs (e.g.
// "10.0.0.0/8,::1") into a list of IPNet networks. A bare IP is treated as a
// /32 (or /128 for IPv6). Returns an error for invalid entries. An empty input
// yields an empty slice (trust nobody).
func ParseTrustedProxies(raw string) ([]*net.IPNet, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	var nets []*net.IPNet
	for _, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		_, ipnet, err := net.ParseCIDR(part)
		if err == nil {
			nets = append(nets, ipnet)
			continue
		}
		// Bare IP → /32 or /128.
		ip := net.ParseIP(part)
		if ip == nil {
			return nil, fmt.Errorf("invalid trusted proxy entry %q: expected IP or CIDR", part)
		}
		if ip.To4() != nil {
			nets = append(nets, &net.IPNet{IP: ip, Mask: net.CIDRMask(32, 32)})
		} else {
			nets = append(nets, &net.IPNet{IP: ip, Mask: net.CIDRMask(128, 128)})
		}
	}
	return nets, nil
}

func maskEmail(email string) string {
	parts := strings.SplitN(email, "@", 2)
	if len(parts) != 2 {
		return "***"
	}
	local := parts[0]
	if len(local) <= 2 {
		return local[:1] + "***@" + parts[1]
	}
	return local[:1] + "***" + local[len(local)-1:] + "@" + parts[1]
}
