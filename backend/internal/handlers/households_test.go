package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// authedRequest builds a request carrying the authenticated user id,
// mirroring AuthMiddleware for direct handler tests.
func authedRequest(t *testing.T, method, path string, body any, userID string) *http.Request {
	t.Helper()
	var reader *bytes.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("marshal body: %v", err)
		}
		reader = bytes.NewReader(raw)
	} else {
		reader = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, path, reader)
	req.Header.Set("Content-Type", "application/json")
	return req.WithContext(context.WithValue(req.Context(), ContextKeyUserID, userID))
}

func inviteTokenFromMail(t *testing.T, sender *captureSender) string {
	t.Helper()
	if len(sender.messages) != 1 {
		t.Fatalf("expected one invite email, got %d", len(sender.messages))
	}
	for _, line := range strings.Split(sender.messages[0].Text, "\n") {
		line = strings.TrimSpace(line)
		if len(line) == 64 && isHex(line) {
			return line
		}
	}
	t.Fatal("invite email did not contain a token")
	return ""
}

func isHex(s string) bool {
	if len(s) == 0 {
		return false
	}
	for _, c := range s {
		isDigit := c >= '0' && c <= '9'
		isLower := c >= 'a' && c <= 'f'
		isUpper := c >= 'A' && c <= 'F'
		if !isDigit && !isLower && !isUpper {
			return false
		}
	}
	return true
}

func TestHouseholdFlow_InviteAcceptShareHousehold(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	ownerID, _ := mintBearer(t, store, "owner@example.com")
	if _, err := store.EnsureHousehold(t.Context(), ownerID); err != nil {
		t.Fatalf("EnsureHousehold: %v", err)
	}

	// Unknown addresses get the same 202 (user-enumeration closed).
	for _, target := range []string{"guest@example.com", "nobody@example.com"} {
		w := httptest.NewRecorder()
		h.CreateInvite(w, authedRequest(t, http.MethodPost, "/api/v1/households/invites",
			map[string]string{"email": target}, ownerID))
		if w.Code != http.StatusAccepted {
			t.Fatalf("create invite for %s: expected 202, got %d (%s)", target, w.Code, w.Body.String())
		}
	}
	if len(sender.messages) != 2 {
		t.Fatalf("expected two invite emails, got %d", len(sender.messages))
	}
	token := inviteTokenFromMail(t, &captureSender{messages: sender.messages[:1]})

	guestID, _ := mintBearer(t, store, "guest@example.com")
	if _, err := store.EnsureHousehold(t.Context(), guestID); err != nil {
		t.Fatalf("EnsureHousehold guest: %v", err)
	}

	// A guest with their own household cannot join another.
	w := httptest.NewRecorder()
	h.AcceptInvite(w, authedRequest(t, http.MethodPost, "/api/v1/households/invites/accept",
		map[string]string{"token": token}, guestID))
	if w.Code != http.StatusConflict {
		t.Fatalf("expected 409 already_member, got %d (%s)", w.Code, w.Body.String())
	}
	if got := errCode(t, w); got != "already_member" {
		t.Fatalf("expected already_member, got %s", got)
	}

	// A fresh user joins and shares the household.
	freshID, _ := mintBearer(t, store, "fresh@example.com")
	w = httptest.NewRecorder()
	h.AcceptInvite(w, authedRequest(t, http.MethodPost, "/api/v1/households/invites/accept",
		map[string]string{"token": token}, freshID))
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d (%s)", w.Code, w.Body.String())
	}

	for _, uid := range []string{ownerID, freshID} {
		w = httptest.NewRecorder()
		h.GetMyHousehold(w, authedRequest(t, http.MethodGet, "/api/v1/households/mine", nil, uid))
		if w.Code != http.StatusOK {
			t.Fatalf("mine for %s: expected 200, got %d", uid, w.Code)
		}
		var resp struct {
			Household struct {
				ID string `json:"id"`
			} `json:"household"`
			Members []struct {
				Email string `json:"email"`
			} `json:"members"`
		}
		decodeBody(t, w, &resp)
		if len(resp.Members) != 2 {
			t.Fatalf("expected 2 members, got %+v", resp.Members)
		}
	}
}

func TestAcceptInvite_UnknownAndExpiredAre404(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandler(t, store)
	uid, _ := mintBearer(t, store, "guest@example.com")

	w := httptest.NewRecorder()
	h.AcceptInvite(w, authedRequest(t, http.MethodPost, "/api/v1/households/invites/accept",
		map[string]string{"token": strings.Repeat("a", 64)}, uid))
	if w.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", w.Code)
	}
	if got := errCode(t, w); got != "invite_not_found" {
		t.Fatalf("expected invite_not_found, got %s", got)
	}

	ownerID, _ := mintBearer(t, store, "owner@example.com")
	house, err := store.EnsureHousehold(t.Context(), ownerID)
	if err != nil {
		t.Fatalf("EnsureHousehold: %v", err)
	}
	if _, err := store.CreateInvite(t.Context(), house.ID, "guest@example.com", sha256Hex(strings.Repeat("b", 64)), ownerID, time.Now().Add(-time.Hour)); err != nil {
		t.Fatalf("CreateInvite expired: %v", err)
	}
	w = httptest.NewRecorder()
	h.AcceptInvite(w, authedRequest(t, http.MethodPost, "/api/v1/households/invites/accept",
		map[string]string{"token": strings.Repeat("b", 64)}, uid))
	if w.Code != http.StatusNotFound {
		t.Fatalf("expected 404 for expired, got %d", w.Code)
	}
}

func TestRemoveMember_RevokesThenRemoves(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandler(t, store)
	ctx := context.Background()

	ownerID, _ := mintBearer(t, store, "owner@example.com")
	house, err := store.EnsureHousehold(ctx, ownerID)
	if err != nil {
		t.Fatalf("EnsureHousehold: %v", err)
	}
	guestID, _ := mintBearer(t, store, "guest@example.com")
	inv, err := store.CreateInvite(ctx, house.ID, "guest@example.com", sha256Hex(strings.Repeat("c", 64)), ownerID, time.Now().Add(time.Hour))
	if err != nil {
		t.Fatalf("CreateInvite: %v", err)
	}
	if _, err := store.AcceptInvite(ctx, inv.ID, guestID); err != nil {
		t.Fatalf("AcceptInvite: %v", err)
	}
	if err := store.SaveRefreshToken(ctx, guestID, "guest-refresh-hash", "device-9"); err != nil {
		t.Fatalf("SaveRefreshToken: %v", err)
	}

	w := httptest.NewRecorder()
	h.RemoveMember(w, authedRequest(t, http.MethodDelete, "/api/v1/households/members",
		map[string]string{"user_id": guestID}, ownerID))
	if w.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d (%s)", w.Code, w.Body.String())
	}

	rt, err := store.GetRefreshToken(ctx, "guest-refresh-hash")
	if err != nil {
		t.Fatalf("GetRefreshToken: %v", err)
	}
	if !rt.Revoked {
		t.Fatal("expected removed member's refresh token revoked")
	}

	members, err := store.ListHouseholdMembers(ctx, house.ID)
	if err != nil {
		t.Fatalf("ListHouseholdMembers: %v", err)
	}
	if len(members) != 1 || members[0].UserID != ownerID {
		t.Fatalf("expected only owner left, got %+v", members)
	}

	// Removing a non-member 404s.
	w = httptest.NewRecorder()
	h.RemoveMember(w, authedRequest(t, http.MethodDelete, "/api/v1/households/members",
		map[string]string{"user_id": guestID}, ownerID))
	if w.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", w.Code)
	}
}

func TestCreateInvite_Validation(t *testing.T) {
	store := newTestStore(t)
	h := newTestHandler(t, store)
	ownerID, _ := mintBearer(t, store, "owner@example.com")

	w := httptest.NewRecorder()
	h.CreateInvite(w, authedRequest(t, http.MethodPost, "/api/v1/households/invites",
		map[string]string{"email": "not-an-email"}, ownerID))
	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", w.Code)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/v1/households/invites", nil)
	w = httptest.NewRecorder()
	h.CreateInvite(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", w.Code)
	}
}

func TestVerifyOTP_CreatesHousehold(t *testing.T) {
	store := newTestStore(t)
	sender := &captureSender{}
	h := newTestHandlerWithDependencies(t, store, nil, sender)

	const addr = "fresh@example.com"
	if w := requestOTP(t, h, addr); w.Code != http.StatusAccepted {
		t.Fatalf("requestOTP: expected 202, got %d", w.Code)
	}
	code := capturedOTP(t, sender)
	if w := verifyOTP(t, h, addr, code); w.Code != http.StatusOK {
		t.Fatalf("verifyOTP: expected 200, got %d (%s)", w.Code, w.Body.String())
	}

	user, err := store.GetUserByEmail(context.Background(), addr)
	if err != nil {
		t.Fatalf("GetUserByEmail: %v", err)
	}
	house, err := store.GetHouseholdForUser(context.Background(), user.ID)
	if err != nil {
		t.Fatalf("expected household after verify: %v", err)
	}
	members, err := store.ListHouseholdMembers(context.Background(), house.ID)
	if err != nil {
		t.Fatalf("ListHouseholdMembers: %v", err)
	}
	if len(members) != 1 || members[0].UserID != user.ID {
		t.Fatalf("expected sole owner member, got %+v", members)
	}
}
