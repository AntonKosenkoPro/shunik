package handlers

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/antonkosenko/shunik/backend/internal/db"
	"github.com/antonkosenko/shunik/backend/internal/email"
)

// Household sharing (day-1): one household per user, every member an equal
// owner. Pets, events, and documents will scope to household_id; until
// then these endpoints own the sharing contract alone.

// inviteTTL is how long an invitation token stays acceptable.
const inviteTTL = 7 * 24 * time.Hour

type createInviteReq struct {
	Email string `json:"email"`
}

type acceptInviteReq struct {
	Token string `json:"token"`
}

type removeMemberReq struct {
	UserID string `json:"user_id"`
}

// sha256Hex digests a token for persistence (R1: only hashes at rest).
func sha256Hex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// newInviteToken mints a random invitation token (32 bytes, hex).
func newInviteToken() (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}

// GetMyHousehold handles GET /api/v1/households/mine: the caller's
// household with its owners. Auto-creates the household (caller as owner)
// when the caller has none — sign-in normally ensures one, this heals the
// self-leave edge without a round trip.
func (h *Handler) GetMyHousehold(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	userID, ok := h.requireUserID(w, r)
	if !ok {
		return
	}

	household, err := h.store.EnsureHousehold(ctx, userID)
	if err != nil {
		h.writeInternalError(w, r, "failed to resolve household", err)
		return
	}

	members, err := h.store.ListHouseholdMembers(ctx, household.ID)
	if err != nil {
		h.writeInternalError(w, r, "failed to list household members", err)
		return
	}

	writeJSON(w, 200, map[string]any{
		"household": household,
		"members":   members,
	})
}

// CreateInvite handles POST /api/v1/households/invites: records an email
// invitation and emails the token. Always 202 — the response never reveals
// whether the address has an account (user-enumeration closed, R1).
func (h *Handler) CreateInvite(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	userID, ok := h.requireUserID(w, r)
	if !ok {
		return
	}

	var req createInviteReq
	if err := decodeJSON(r, &req); err != nil {
		h.logger.Warn("invalid invite body")
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}

	invitee := strings.ToLower(strings.TrimSpace(req.Email))
	if !validateEmail(invitee) {
		h.logger.Warn("invalid email in invite", "email", maskEmail(invitee))
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid email address", nil)
		return
	}

	// Rate limit per IP (invite creation sends email — abuse vector).
	ip := h.clientIP(r)
	if h.rateLimiter.Invite != nil && !h.rateLimiter.Invite.Allow(ip) {
		h.logger.Warn("invite rate limited", "ip", ip)
		writeError(w, http.StatusTooManyRequests, "rate_limited", "Too many requests. Please try again later.", nil)
		return
	}

	household, err := h.store.EnsureHousehold(ctx, userID)
	if err != nil {
		h.writeInternalError(w, r, "failed to resolve household", err)
		return
	}

	token, err := newInviteToken()
	if err != nil {
		h.writeInternalError(w, r, "failed to mint invite token", err)
		return
	}

	if _, err := h.store.CreateInvite(ctx, household.ID, invitee, sha256Hex(token), userID, time.Now().Add(inviteTTL)); err != nil {
		h.writeInternalError(w, r, "failed to record invite", err)
		return
	}

	msg := email.NewInviteMessage(invitee, token)
	if err := h.emailSender.Send(ctx, msg); err != nil {
		// The row stays (a retry replaces it); the caller retries.
		h.logger.Error("failed to send invite email", "error", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "Failed to send invitation. Please try again.", nil)
		return
	}

	writeJSON(w, 202, map[string]any{"message": "Invitation sent if the address can receive mail"})
}

// AcceptInvite handles POST /api/v1/households/invites/accept: joins the
// caller to the invite's household. Unknown, consumed, and expired tokens
// are indistinguishable (404 invite_not_found); callers already in a
// household get 409 already_member.
func (h *Handler) AcceptInvite(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	userID, ok := h.requireUserID(w, r)
	if !ok {
		return
	}

	var req acceptInviteReq
	if err := decodeJSON(r, &req); err != nil || len(strings.TrimSpace(req.Token)) != 64 {
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid invitation token", nil)
		return
	}

	invite, err := h.store.GetInviteByTokenHash(ctx, sha256Hex(strings.TrimSpace(req.Token)))
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusNotFound, "invite_not_found", "Invitation not found or expired", nil)
			return
		}
		h.writeInternalError(w, r, "failed to look up invite", err)
		return
	}

	household, err := h.store.AcceptInvite(ctx, invite.ID, userID)
	if err != nil {
		switch {
		case errors.Is(err, db.ErrNotFound):
			writeError(w, http.StatusNotFound, "invite_not_found", "Invitation not found or expired", nil)
		case errors.Is(err, db.ErrAlreadyMember):
			writeError(w, http.StatusConflict, "already_member", "You already belong to a household", nil)
		default:
			h.writeInternalError(w, r, "failed to accept invite", err)
		}
		return
	}

	members, err := h.store.ListHouseholdMembers(ctx, household.ID)
	if err != nil {
		h.writeInternalError(w, r, "failed to list household members", err)
		return
	}

	writeJSON(w, 200, map[string]any{
		"household": household,
		"members":   members,
	})
}

// RemoveMember handles DELETE /api/v1/households/members: removes one
// membership (any member may remove any member, including self — leaving
// ends the household for the leaver). The removed user's refresh tokens
// are revoked BEFORE the membership row goes: a failed removal leaves a
// locked-but-member user who re-authenticates cleanly, while a failed
// revocation after removal would strand valid tokens outside.
func (h *Handler) RemoveMember(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	userID, ok := h.requireUserID(w, r)
	if !ok {
		return
	}

	var req removeMemberReq
	if err := decodeJSON(r, &req); err != nil || strings.TrimSpace(req.UserID) == "" {
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}
	target := strings.TrimSpace(req.UserID)

	household, err := h.store.GetHouseholdForUser(ctx, userID)
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusNotFound, "household_not_found", "No household found", nil)
			return
		}
		h.writeInternalError(w, r, "failed to resolve household", err)
		return
	}

	members, err := h.store.ListHouseholdMembers(ctx, household.ID)
	if err != nil {
		h.writeInternalError(w, r, "failed to list household members", err)
		return
	}
	found := false
	for _, m := range members {
		if m.UserID == target {
			found = true
			break
		}
	}
	if !found {
		writeError(w, http.StatusNotFound, "household_not_found", "Member is not in your household", nil)
		return
	}

	if err := h.store.RevokeAllUserSessions(ctx, target); err != nil {
		h.writeInternalError(w, r, "failed to revoke member sessions", err)
		return
	}
	if err := h.store.RemoveMember(ctx, household.ID, target); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusNotFound, "household_not_found", "Member is not in your household", nil)
			return
		}
		h.writeInternalError(w, r, "failed to remove member", err)
		return
	}

	w.WriteHeader(204)
}
