package handlers

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/antonkosenko/shunik/backend/internal/apple"
	"github.com/antonkosenko/shunik/backend/internal/db"
)

// ---------- shared helpers ----------

// subjectDigest maps an Apple subject to the revocation fence digest. Without
// a configured digest key (tests) it returns "" and every fence lookup
// misses open — production always configures it.
func (h *Handler) subjectDigest(subject string) string {
	if len(h.digestKey) == 0 {
		return ""
	}
	return apple.SubjectDigest(h.digestKey, subject)
}

// redactSubject masks an Apple subject for logs (stable-prefix debuggability
// without retaining the identifier in cleartext beside other fields).
func redactSubject(sub string) string {
	if len(sub) <= 4 {
		return "***"
	}
	return sub[:2] + "***" + sub[len(sub)-2:]
}

// newLineageID mints an authorization lineage identifier (128-bit hex, not a
// Shunik session credential and never logged).
func newLineageID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		// crypto/rand essentially never fails; fall back to time-seeded
		// uniqueness rather than aborting session issuance.
		n := time.Now().UnixNano()
		for i := range b {
			b[i] = byte(n >> (8 * (i % 8)))
		}
	}
	return hex.EncodeToString(b[:])
}

// ---------- DELETE /api/v1/auth/account ----------

type accountDeletedPendingResponse struct {
	AccountDeleted         bool `json:"account_deleted"`
	AppleRevocationPending bool `json:"apple_revocation_pending"`
}

// DeleteAccount handles DELETE /api/v1/auth/account: explicit, permanent,
// self-only account deletion. It purges the authenticated account and all
// associated operational rows atomically, then unlinks Apple authorization
// for Apple accounts (immediately, or durably pending with an explicit 202).
//
//   - Email-only accounts with a committed purge: 204.
//   - Apple accounts with acknowledged revocation: 204.
//   - Apple accounts with committed purge but pending revocation: 202 with
//     account_deleted + apple_revocation_pending (both reliable deletion
//     acknowledgments; 202 never claims Apple unlinking completed).
//   - Apple accounts without a stored revocable credential: 409
//     apple_credential_required with NO purge — the client must first obtain
//     same-subject authorization via the deletion-credential endpoint.
//   - Apple accounts when revocation is unconfigured: 503
//     apple_not_configured with NO purge (deployment blocker, not a silent
//     skip).
//
// A purged-then-unreachable account (middleware race) maps to generic 401.
func (h *Handler) DeleteAccount(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	userID, ok := h.requireUserID(w, r)
	if !ok {
		return
	}
	deviceID, ok := requireDeviceID(w, r)
	if !ok {
		return
	}
	_ = deviceID // self-only targeting is enforced by the middleware subject; the header pins the device scope of the request.

	user, err := h.store.GetUserByID(ctx, userID)
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusUnauthorized, "unauthorized", "Invalid or expired access token", nil)
			return
		}
		h.writeInternalError(w, r, "failed to load user for account deletion", err)
		return
	}

	hasApple := user.AppleSubject != nil && *user.AppleSubject != ""
	if hasApple {
		// Required revocable material is checked BEFORE purge: absence is
		// an explicit precondition failure, never a silent skip.
		if h.appleClient == nil || h.appleTokenKeys == nil {
			h.logger.Error("apple revocation unconfigured; refusing account deletion without purge",
				"userID", user.ID)
			writeError(w, http.StatusServiceUnavailable, "apple_not_configured",
				"Apple unlinking is not configured; account deletion is unavailable", nil)
			return
		}
		if _, err := h.store.GetAppleCredential(ctx, user.ID); err != nil {
			if errors.Is(err, db.ErrNotFound) {
				writeError(w, http.StatusConflict, "apple_credential_required",
					"Fresh Apple authorization is required before deleting this account", nil)
				return
			}
			h.writeInternalError(w, r, "failed to read apple credential for deletion", err)
			return
		}
	}

	// Atomic operational purge. The middleware already proved the session;
	// a purge that won the race maps to generic 401, never deletion proof.
	res, err := h.store.PurgeUser(ctx, user.ID, h.appleClientID, h.subjectDigest)
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusUnauthorized, "unauthorized", "Invalid or expired access token", nil)
			return
		}
		if errors.Is(err, db.ErrAppleCredentialMissing) {
			// The vault vanished between the pre-check and the purge
			// (consent callback): the purge rolled back, the account is
			// intact, and deletion requires fresh same-subject
			// authorization first — identical to the pre-check verdict.
			writeError(w, http.StatusConflict, "apple_credential_required",
				"Fresh Apple authorization is required before deleting this account", nil)
			return
		}
		h.writeInternalError(w, r, "failed to purge account", err)
		return
	}

	// Best-effort orphan cleanup: the purge emptied a household whose
	// document rows cascaded, leaving bytes behind. Failures are logged
	// orphans for the GC sweep, never a purge failure.
	h.deleteOrphanedBlobs(ctx, res.OrphanedBlobKeys)

	if !hasApple || res.RevocationJobID == "" {
		// Email-only deletion. An Apple account always carries a
		// revocation job here: the purge transaction requires the vault
		// row under its lock (missing → 409 above, rolled back).
		h.logger.Info("account deleted", "userID", user.ID, "hadApple", hasApple)
		w.WriteHeader(http.StatusNoContent)
		return
	}

	// Attempt Apple revocation inline. Success completes the job and the
	// deletion acknowledges completion (204). Any failure keeps the durable
	// job and acknowledges committed deletion with pending unlinking (202).
	// Post-purge bookkeeping runs on a detached context: a client
	// disconnect must not turn a completed purge into a spurious failure.
	bookCtx, bookCancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer bookCancel()
	plain, err := h.appleTokenKeys.Open(res.SealedAppleRefresh, apple.VaultAAD(res.AuthLineage, res.AuthTime))
	if err != nil {
		h.failDeletionJob(bookCtx, res, "decrypt sealed apple credential: "+err.Error())
		h.logger.Warn("account purged; apple revocation pending (decrypt failed)",
			"userID", user.ID, "job_id", res.RevocationJobID)
		writeJSON(w, http.StatusAccepted, accountDeletedPendingResponse{AccountDeleted: true, AppleRevocationPending: true})
		return
	}
	if err := h.appleClient.RevokeToken(bookCtx, string(plain)); err != nil {
		h.failDeletionJob(bookCtx, res, "apple revoke: "+err.Error())
		h.logger.Warn("account purged; apple revocation pending",
			"userID", user.ID, "job_id", res.RevocationJobID, "error", err)
		writeJSON(w, http.StatusAccepted, accountDeletedPendingResponse{AccountDeleted: true, AppleRevocationPending: true})
		return
	}
	if err := h.store.CompleteRevocationJob(bookCtx, res.RevocationJobID); err != nil {
		// Revocation was acknowledged; the worker redrives completion.
		h.logger.Error("apple revocation acknowledged but job removal failed",
			"userID", user.ID, "job_id", res.RevocationJobID, "error", err)
	}
	h.logger.Info("account deleted with apple unlinking", "userID", user.ID)
	w.WriteHeader(http.StatusNoContent)
}

// failDeletionJob records a failed inline revoke and reschedules the durable
// job with bounded backoff. The purge already committed: this never restores
// the account and never claims unlinking completed.
func (h *Handler) failDeletionJob(ctx context.Context, res db.PurgeResult, msg string) {
	next := time.Now().Add(apple.RetryAfter(1))
	if err := h.store.FailRevocationJob(ctx, res.RevocationJobID, msg, next); err != nil {
		h.logger.Error("could not reschedule apple revocation job", "job_id", res.RevocationJobID, "error", err)
	}
}

// ---------- POST /api/v1/auth/account/status ----------

type accountStatusResponse struct {
	AccountID string `json:"account_id"`
	State     string `json:"state"` // active | deleted
}

// AccountStatus handles POST /api/v1/auth/account/status: the read-only,
// narrowly scoped deletion-evidence endpoint. Its ONLY authority is the
// dedicated account-status credential (never an access token, never a UUID
// from a body or URL — the UUID echoes the verified subject). Responses:
//
//   - 200 {account_id, state: active} — the account still exists (including
//     revoked-but-present accounts).
//   - 200 {account_id, state: deleted} — the user row is gone. Only this
//     scoped verdict authorizes another device's cleanup.
//   - Invalid/expired credentials: generic 401 unauthorized with no
//     existence disclosure. Storage failures: 5xx, never "deleted".
//
// Responses carry no-store and never renew the credential's lifetime.
func (h *Handler) AccountStatus(w http.ResponseWriter, r *http.Request) {
	// No-store first: every response from this endpoint carries deletion
	// evidence, including rate-limited ones intermediaries might reuse.
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Pragma", "no-cache")
	if h.rateLimiter.Status != nil {
		if !h.rateLimiter.Status.Allow(h.clientIP(r)) {
			writeError(w, http.StatusTooManyRequests, "rate_limited",
				"Too many requests. Please try again later.", nil)
			return
		}
	}

	if h.statusService == nil {
		h.writeInternalError(w, r, "account status service unconfigured", errors.New("nil status service"))
		return
	}

	tokenStr := bearerToken(r)
	if tokenStr == "" {
		writeError(w, http.StatusUnauthorized, "unauthorized", "Invalid or expired status credential", nil)
		return
	}
	userID, err := h.statusService.Validate(tokenStr)
	if err != nil {
		h.logger.Warn("invalid account status credential")
		writeError(w, http.StatusUnauthorized, "unauthorized", "Invalid or expired status credential", nil)
		return
	}

	_, err = h.store.GetUserByID(r.Context(), userID)
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeJSON(w, http.StatusOK, accountStatusResponse{AccountID: userID, State: "deleted"})
			return
		}
		h.writeInternalError(w, r, "account status lookup failed", err)
		return
	}
	writeJSON(w, http.StatusOK, accountStatusResponse{AccountID: userID, State: "active"})
}

// bearerToken extracts a Bearer credential without logging it. The scheme
// name is case-insensitive (RFC 7235), matching AuthMiddleware.
func bearerToken(r *http.Request) string {
	const prefixLen = len("Bearer ")
	auth := r.Header.Get("Authorization")
	if len(auth) <= prefixLen || !strings.EqualFold(auth[:prefixLen], "Bearer ") {
		return ""
	}
	return strings.TrimSpace(auth[prefixLen:])
}

// ---------- POST /api/v1/auth/apple/deletion-credential ----------

type appleDeletionCredentialReq struct {
	IdentityToken     string `json:"identity_token"`
	AuthorizationCode string `json:"authorization_code"`
}

// AppleDeletionCredential stores a revocable Apple credential for an
// existing Apple user that has none (identity-token-only history). It
// verifies the presented identity, requires the SAME Apple subject as the
// authenticated account, exchanges the code, and seals the refresh token —
// never creating a user, a Shunik session, or touching another account.
// Wrong identities fail safely; email-only accounts are rejected.
func (h *Handler) AppleDeletionCredential(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	userID, ok := h.requireUserID(w, r)
	if !ok {
		return
	}
	if _, ok := requireDeviceID(w, r); !ok {
		return
	}

	user, err := h.store.GetUserByID(ctx, userID)
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusUnauthorized, "unauthorized", "Invalid or expired access token", nil)
			return
		}
		h.writeInternalError(w, r, "failed to load user for deletion credential", err)
		return
	}
	if user.AppleSubject == nil || *user.AppleSubject == "" {
		writeError(w, http.StatusBadRequest, "invalid_request", "Account has no Apple identity", nil)
		return
	}
	if h.appleVerifier == nil || h.appleClient == nil {
		writeError(w, http.StatusServiceUnavailable, "apple_not_configured",
			"Sign in with Apple is not configured", nil)
		return
	}

	var req appleDeletionCredentialReq
	if err := decodeJSON(r, &req); err != nil {
		h.logger.Warn("invalid deletion credential body", "error", err)
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}
	if req.IdentityToken == "" || req.AuthorizationCode == "" {
		writeError(w, http.StatusBadRequest, "invalid_body", "Identity token and authorization code are required", nil)
		return
	}

	claims, err := h.appleVerifier.Verify(ctx, req.IdentityToken)
	if err != nil {
		h.logger.Warn("deletion credential identity verification failed", "error", err)
		writeError(w, http.StatusUnauthorized, "invalid_apple_token",
			"Invalid Apple identity token", nil)
		return
	}
	if claims.Sub != *user.AppleSubject {
		// A different Apple identity authorizes nothing here: no upsert, no
		// session, no deletion — the request simply fails.
		h.logger.Warn("deletion credential subject mismatch", "userID", user.ID)
		writeError(w, http.StatusUnauthorized, "invalid_apple_token",
			"Apple identity does not match this account", nil)
		return
	}

	tr, err := h.appleClient.ExchangeCode(ctx, req.AuthorizationCode)
	if err != nil {
		if errors.Is(err, apple.ErrInvalidGrant) {
			h.logger.Warn("deletion credential code rejected", "userID", user.ID)
			writeError(w, http.StatusUnauthorized, "invalid_apple_token",
				"Invalid Apple authorization code", nil)
			return
		}
		h.logger.Warn("deletion credential exchange unavailable", "userID", user.ID, "error", err)
		writeError(w, http.StatusServiceUnavailable, "apple_unavailable",
			"Apple is temporarily unavailable. Please retry.", nil)
		return
	}
	if idClaims, verr := h.appleVerifier.Verify(ctx, tr.IDToken); verr != nil || idClaims.Sub != claims.Sub {
		h.logger.Warn("deletion credential exchange identity mismatch", "userID", user.ID)
		writeError(w, http.StatusUnauthorized, "invalid_apple_token",
			"Invalid Apple authorization code", nil)
		return
	}

	lineage := ""
	if user.AppleAuthLineage != nil {
		lineage = *user.AppleAuthLineage
	}
	if lineage == "" {
		lineage = newLineageID()
		if err := h.store.SetAppleSession(ctx, user.ID, time.Now(), lineage); err != nil {
			h.writeInternalError(w, r, "failed to stamp apple session", err)
			return
		}
	}

	if h.appleTokenKeys == nil {
		h.writeInternalError(w, r, "apple token keyring unconfigured", errors.New("nil apple token keyring"))
		return
	}
	authTime := time.Now()
	sealed, err := h.appleTokenKeys.Seal([]byte(tr.RefreshToken), apple.VaultAAD(lineage, authTime))
	if err != nil {
		h.writeInternalError(w, r, "failed to seal apple credential", err)
		return
	}
	if err := h.store.SaveAppleCredential(ctx, db.AppleCredential{
		UserID: user.ID, SealedRefresh: sealed, AuthTime: authTime, LineageID: lineage,
	}); err != nil {
		h.writeInternalError(w, r, "failed to store apple credential", err)
		return
	}

	h.logger.Info("apple deletion credential stored", "userID", user.ID)
	writeJSON(w, http.StatusOK, map[string]bool{"stored": true})
}

// ---------- POST /api/v1/auth/apple/notifications ----------

type appleNotificationReq struct {
	Payload string `json:"payload"`
}

// AppleNotifications handles Apple's server-to-server notifications. The
// payload is a verified Apple-signed JWS (signature, issuer, configured
// audience, issued time, expiry when present); event dispatch follows the
// official contract:
//
//   - consent-revoked: ends pre-event Shunik sessions across devices and
//     closes their recoveries. The account, data, files, and cursors are
//     preserved; a later same-subject authorization returns to the existing
//     UUID. Idempotent; stale/duplicate events never touch a newer lineage.
//   - email-enabled/disabled, account-deleted, unknown types: verified
//     no-ops (account-deleted — permanent erasure of the whole Apple Account
//     — is explicitly out of scope).
//   - Missing users: idempotent no-ops, never upserts.
//   - Replays (duplicate jti): idempotent 200 no-ops.
//   - Invalid signatures/claims: 401 invalid_notification, no state change.
func (h *Handler) AppleNotifications(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	// Unauthenticated JWS intake is rate-limited before the expensive
	// signature verification. High ceiling: Apple's delivery retries must
	// never be throttled.
	if h.rateLimiter.AppleNotifications != nil {
		if !h.rateLimiter.AppleNotifications.Allow(h.clientIP(r)) {
			writeError(w, http.StatusTooManyRequests, "rate_limited",
				"Too many requests. Please try again later.", nil)
			return
		}
	}

	var req appleNotificationReq
	// Apple POSTs the signed JWS as a form value
	// (application/x-www-form-urlencoded). Accept that first, falling back
	// to JSON for test/tooling compatibility — the openapi contract
	// documents both media types.
	if strings.HasPrefix(r.Header.Get("Content-Type"), "application/x-www-form-urlencoded") {
		if err := r.ParseForm(); err != nil {
			writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
			return
		}
		req.Payload = r.PostFormValue("payload")
	} else if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}
	if req.Payload == "" {
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}
	if h.appleNotifs == nil {
		h.logger.Error("apple notification verifier unconfigured")
		h.writeInternalError(w, r, "apple notification verifier unconfigured", errors.New("nil notification verifier"))
		return
	}

	ev, err := h.appleNotifs.VerifyNotification(ctx, req.Payload)
	if err != nil {
		h.logger.Warn("invalid apple notification", "error", err)
		writeError(w, http.StatusUnauthorized, "invalid_notification",
			"Invalid Apple notification", nil)
		return
	}

	// Replay protection for effect-free events: a duplicate jti is an
	// idempotent no-op. (consent-revoked records its receipt only AFTER its
	// effect lands — see below — so a transient apply failure can never
	// poison the jti and lose the revocation on retry.)
	if ev.Type != apple.EventConsentRevoked {
		if err := h.store.RecordAppleNotification(ctx, ev.JTI); err != nil {
			if errors.Is(err, db.ErrNotificationReplay) {
				h.logger.Info("duplicate apple notification ignored", "jti", ev.JTI, "type", ev.Type)
				writeNotificationAccepted(w)
				return
			}
			h.writeInternalError(w, r, "failed to record apple notification", err)
			return
		}
		// email-enabled/disabled, account-deleted, and unknown future types:
		// verified no-ops. Never delete, never upsert, never end sessions.
		h.logger.Info("apple notification ignored (no state change)",
			"jti", ev.JTI, "type", ev.Type, "sub", redactSubject(ev.Sub))
		writeNotificationAccepted(w)
		return
	}

	// consent-revoked ends pre-event sessions (sign-out, never deletion).
	// The event time is required: without a trustworthy event time the
	// cutoff cannot be ordered against the current authorization, and
	// substituting arrival time could kill a newer reauthorization.
	// Missing event_time is rejected with no state change and no receipt.
	if !ev.HasEventTime {
		h.logger.Warn("consent-revoked without event_time", "jti", ev.JTI)
		writeError(w, http.StatusBadRequest, "invalid_body",
			"consent-revoked notification requires event_time", nil)
		return
	}
	// Apply BEFORE recording: the cutoff advance is idempotent (stale
	// events are no-ops), so a retry after a transient apply failure
	// re-applies instead of hitting a poisoned replay. Only an applied
	// (or idempotently re-applied) cutoff is ever acknowledged.
	userID, applied, err := h.store.ApplyAppleConsentCutoff(ctx, ev.Sub, ev.EventTime.UTC())
	if err != nil {
		h.writeInternalError(w, r, "failed to apply apple consent cutoff", err)
		return
	}
	if rerr := h.store.RecordAppleNotification(ctx, ev.JTI); rerr != nil && !errors.Is(rerr, db.ErrNotificationReplay) {
		h.writeInternalError(w, r, "failed to record apple notification", rerr)
		return
	}
	h.logger.Info("apple consent revoked processed",
		"apple_sub", redactSubject(ev.Sub), "userID", userID, "applied", applied)
	writeNotificationAccepted(w)
}
