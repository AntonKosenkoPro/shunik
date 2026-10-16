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

	"github.com/antonkosenko/time-of-life/backend/internal/apple"
	"github.com/antonkosenko/time-of-life/backend/internal/auth"
	"github.com/antonkosenko/time-of-life/backend/internal/db"
	"github.com/antonkosenko/time-of-life/backend/internal/email"
	"github.com/antonkosenko/time-of-life/backend/internal/ratelimit"
)

// HandlerConfig holds configuration for the auth handler.
type HandlerConfig struct {
	TrustedProxies []*net.IPNet // CIDRs of trusted reverse proxies allowed to set forwarded IP headers
}

// Handler holds dependencies for all HTTP handlers.
type Handler struct {
	store         db.Store
	tokenService  *auth.TokenService
	otpService    *auth.OTPService
	emailSender   email.Sender
	rateLimiter   *RateLimiterGroup
	appleVerifier apple.Verifier
	config        HandlerConfig
	logger        *slog.Logger
}

// RateLimiterGroup holds the rate limiters used by the handlers.
type RateLimiterGroup struct {
	OTPRequest *ratelimit.TokenBucket
	OTPVerify  *ratelimit.TokenBucket
	Apple      *ratelimit.TokenBucket
}

// NewHandler creates a new Handler with the given dependencies. appleVerifier
// may be nil when Sign in with Apple is disabled; the registered route then
// returns apple_not_configured.
func NewHandler(
	store db.Store,
	tokenService *auth.TokenService,
	otpService *auth.OTPService,
	emailSender email.Sender,
	rateLimiter *RateLimiterGroup,
	appleVerifier apple.Verifier,
	config HandlerConfig,
	logger *slog.Logger,
) *Handler {
	return &Handler{
		store:         store,
		tokenService:  tokenService,
		otpService:    otpService,
		emailSender:   emailSender,
		rateLimiter:   rateLimiter,
		appleVerifier: appleVerifier,
		config:        config,
		logger:        logger,
	}
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
}

type appleSignInReq struct {
	IdentityToken string `json:"identity_token"`
}

type userResponse struct {
	ID            string `json:"id"`
	Email         string `json:"email"`
	EmailVerified bool   `json:"email_verified"`
}

type authResponse struct {
	AccessToken  string       `json:"access_token"`
	RefreshToken string       `json:"refresh_token"`
	User         userResponse `json:"user"`
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

// writeAccepted responds 202 with a uniform "accepted" envelope. Used by the
// OTP request path to close user enumeration (no per-error status leaks).
func writeAccepted(w http.ResponseWriter) {
	writeJSON(w, http.StatusAccepted, map[string]string{"status": "accepted"})
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
// refresh token hash bound to deviceID (per-device refresh family), and
// writes the authResponse envelope. On any failure it writes an
// internal_error response. It returns nothing; callers return.
func (h *Handler) issueTokens(ctx context.Context, w http.ResponseWriter, user db.User, emailVerified bool, deviceID string) {
	accessToken, err := h.tokenService.CreateAccessToken(user.ID, user.Email)
	if err != nil {
		h.logger.Error("failed to create access token", "error", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "An internal error occurred", nil)
		return
	}

	rawRefresh, refreshHash, err := h.tokenService.GenerateRefreshToken()
	if err != nil {
		h.logger.Error("failed to generate refresh token", "error", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "An internal error occurred", nil)
		return
	}

	if err := h.store.SaveRefreshToken(ctx, user.ID, refreshHash, deviceID); err != nil {
		h.logger.Error("failed to save refresh token", "error", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "An internal error occurred", nil)
		return
	}

	writeJSON(w, http.StatusOK, authResponse{
		AccessToken:  accessToken,
		RefreshToken: rawRefresh,
		User: userResponse{
			ID:            user.ID,
			Email:         user.Email,
			EmailVerified: emailVerified,
		},
	})
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
		h.logger.Error("failed to mark user verified", "error", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "An internal error occurred", nil)
		return
	}

	h.issueTokens(ctx, w, user, true, deviceID)
}

// AppleSignIn handles POST /api/v1/auth/apple.
// It verifies Apple's identity-token JWT, upserts the user by Apple's stable
// `sub` identifier, and issues our own access + refresh tokens (the same
// issuance path as VerifyOTP). Apple users are considered email-verified.
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

	user, err := h.store.UpsertUserByAppleSubject(ctx, claims.Sub, claims.Email)
	if err != nil {
		h.logger.Error("failed to upsert apple user", "error", err)
		writeError(w, http.StatusInternalServerError, "internal_error",
			"An internal error occurred", nil)
		return
	}

	// Issue tokens (same path as VerifyOTP). Apple users are email-verified.
	h.issueTokens(ctx, w, user, true, deviceID)
	h.logger.Info("apple user signed in", "userID", user.ID)
}

// RefreshToken handles POST /api/v1/auth/refresh.
// It validates the refresh token, checks revocation (per-device reuse
// detection), enforces the refresh TTL against created_at, and rotates the
// pair within the issuing device's family.
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

	tokenHash := auth.HashToken(req.RefreshToken)
	storedToken, err := h.store.GetRefreshToken(ctx, tokenHash)
	if err != nil {
		h.logger.Warn("refresh token not found")
		writeError(w, http.StatusUnauthorized, "invalid_refresh", "Invalid refresh token", nil)
		return
	}

	// Check if revoked FIRST — before the TTL check — so a replayed revoked
	// token always triggers per-device reuse revocation, even when its
	// created_at is older than the refresh TTL (otherwise it would return
	// refresh_expired and leave the live family tokens unrevoked).
	if storedToken.Revoked {
		h.logger.Warn("refresh token reuse detected", "userID", storedToken.UserID, "deviceID", storedToken.DeviceID)
		if err := h.store.RevokeUserDeviceSessions(ctx, storedToken.UserID, storedToken.DeviceID); err != nil {
			h.logger.Error("failed to revoke device tokens after reuse", "error", err)
		}
		writeError(w, http.StatusUnauthorized, "token_reuse", "Token has been revoked. Sign in again.", nil)
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

	// The token belongs to a concrete device family: a presentation from a
	// different device is rejected without revoking anything, so the real
	// family's tokens stay intact.
	if deviceID != storedToken.DeviceID {
		h.logger.Warn("refresh token device mismatch", "userID", storedToken.UserID,
			"deviceID", deviceID, "tokenDeviceID", storedToken.DeviceID)
		writeError(w, http.StatusUnauthorized, "invalid_refresh", "Invalid refresh token", nil)
		return
	}

	// Revoke the old token.
	if err := h.store.RevokeRefreshToken(ctx, storedToken.ID); err != nil {
		h.logger.Error("failed to revoke old refresh token", "error", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "An internal error occurred", nil)
		return
	}

	// Look up user to get email.
	user, err := h.store.GetUserByID(ctx, storedToken.UserID)
	if err != nil {
		h.logger.Error("failed to get user for token refresh", "error", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "An internal error occurred", nil)
		return
	}

	// Generate new token pair; rotation stays within the device's family.
	h.issueTokens(ctx, w, user, user.EmailVerified, storedToken.DeviceID)
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
		h.logger.Error("failed to revoke device tokens on logout", "error", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "An internal error occurred", nil)
		return
	}

	h.logger.Info("user logged out", "userID", userID, "deviceID", deviceID)
	w.WriteHeader(http.StatusNoContent)
}

// Me handles GET /api/v1/auth/me.
// It returns the authenticated user profile.
func (h *Handler) Me(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	userID, ok := UserIDFromContext(ctx)
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized", "Not authenticated", nil)
		return
	}

	user, err := h.store.GetUserByID(ctx, userID)
	if err != nil {
		h.logger.Error("failed to get user for /me", "error", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "An internal error occurred", nil)
		return
	}

	writeJSON(w, http.StatusOK, map[string]userResponse{
		"user": {
			ID:            user.ID,
			Email:         user.Email,
			EmailVerified: user.EmailVerified,
		},
	})
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
