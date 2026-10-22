package handlers

// Consent-cutoff session-validity regression tests (per-session original
// authorization time, not current-lineage equality):
//
//   - A second post-revocation device sign-in must not kill the first
//     device's fresh session.
//   - A delayed revocation event must still end sessions authorized before
//     it, while a grant authorized after the event but before the delayed
//     callback survives.
//   - Legacy lineageless sessions (email-OTP on an Apple-cutoff account)
//     fail closed.
//   - Same-second legacy identity-token equality is not reliable freshness:
//     only a strictly-post-cutoff iat (or a live code exchange) reauthorizes.

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/antonkosenko/time-of-life/backend/internal/apple"
	"github.com/antonkosenko/time-of-life/backend/internal/db"
)

func doMe(t *testing.T, h *Handler, accessToken string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/auth/me", nil)
	req.Header.Set("Authorization", "Bearer "+accessToken)
	w := httptest.NewRecorder()
	h.AuthMiddleware(http.HandlerFunc(h.Me)).ServeHTTP(w, req)
	return w
}

func appleClaimsAt(sub string, iat time.Time) apple.Claims {
	return apple.Claims{
		Sub: sub, Email: "r@privaterelay.appleid.com",
		RegisteredClaims: jwt.RegisteredClaims{IssuedAt: jwt.NewNumericDate(iat)},
	}
}

// signInAppleAt signs in sub with an identity token issued at iat and
// returns the access token. A dedicated handler shares the store so each
// call models a separate device authorization.
func signInAppleAt(t *testing.T, store db.Store, client *fakeAppleClient, sub string, iat time.Time, device string) string {
	t.Helper()
	h := newTestDeletionHandler(t, store, fakeAppleVerifier{claims: appleClaimsAt(sub, iat)}, client, fakeAppleNotifs{})
	body, _ := json.Marshal(map[string]string{"identity_token": "id-token"})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/apple", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Device-Id", device)
	w := httptest.NewRecorder()
	h.AppleSignIn(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("apple sign-in: got %d: %s", w.Code, w.Body.String())
	}
	var resp authResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("decode session: %v", err)
	}
	return resp.AccessToken
}

func deliverConsentRevoked(t *testing.T, store db.Store, h *Handler, sub string, eventTime time.Time, jti string) {
	t.Helper()
	h.appleNotifs = fakeAppleNotifs{event: apple.NotificationEvent{
		Type: "consent-revoked", Sub: sub, JTI: jti,
		EventTime: eventTime, HasEventTime: true,
	}}
	if w := doNotifications(t, h, "signed-jws"); w.Code != http.StatusOK {
		t.Fatalf("notification: got %d: %s", w.Code, w.Body.String())
	}
	var _ = store
}

// TestCutoff_TwoFreshDevicesDelayedEvent is the core lineage regression:
// device A authorizes at T0, the revocation event fires at Te, device B
// authorizes at T1 (all before the delayed callback arrives). After the
// callback, A's pre-event session must be dead and B's post-event session
// must survive — a second sign-in must not kill the first fresh device,
// and the delayed first event must still end the older session.
func TestCutoff_TwoFreshDevicesDelayedEvent(t *testing.T) {
	store := newTestStore(t)
	client := &fakeAppleClient{}
	h := newTestDeletionHandler(t, store, fakeAppleVerifier{}, client, fakeAppleNotifs{})
	ctx := context.Background()

	base := time.Now().Add(-time.Hour).UTC().Truncate(time.Second)
	t0 := base
	te := base.Add(10 * time.Minute)
	t1 := base.Add(20 * time.Minute)

	tokenA := signInAppleAt(t, store, client, "apple-sub-2dev", t0, "device-A")
	// Model A having signed in at T0: the handler stamps verified times,
	// and the fake iat is the verified time under test.
	userA, err := store.GetUserByEmail(ctx, "r@privaterelay.appleid.com")
	if err != nil {
		t.Fatalf("GetUserByEmail: %v", err)
	}
	var lineage string
	if userA.AppleAuthLineage == nil {
		t.Fatal("expected lineage after signup")
	}
	lineage = *userA.AppleAuthLineage
	if err := store.SetAppleSession(ctx, userA.ID, t0, lineage); err != nil {
		t.Fatalf("backdate A: %v", err)
	}

	tokenB := signInAppleAt(t, store, client, "apple-sub-2dev", t1, "device-B")

	deliverConsentRevoked(t, store, h, "apple-sub-2dev", te, "jti-2dev")

	if w := doMe(t, h, tokenA); w.Code != http.StatusUnauthorized {
		t.Errorf("pre-event device session must die, got %d: %s", w.Code, w.Body.String())
	}
	if w := doMe(t, h, tokenB); w.Code != http.StatusOK {
		t.Errorf("post-event device session must survive, got %d: %s", w.Code, w.Body.String())
	}

	// The cutoff advanced to the delayed event while the newer session
	// metadata was preserved.
	stored, err := store.GetUserByID(ctx, userA.ID)
	if err != nil {
		t.Fatalf("GetUserByID: %v", err)
	}
	if stored.AppleConsentCutoff == nil || !stored.AppleConsentCutoff.Equal(te) {
		t.Errorf("cutoff must advance to the delayed event, got %+v", stored.AppleConsentCutoff)
	}
	if stored.AppleAuthLineage == nil {
		t.Error("newer lineage metadata must be preserved")
	}
}

// TestCutoff_LegacySessionFailsClosed covers lineageless sessions (email-OTP
// on an Apple-cutoff account): without an Apple authorization time they
// cannot prove they postdate revocation and must fail.
func TestCutoff_LegacySessionFailsClosed(t *testing.T) {
	store := newTestStore(t)
	client := &fakeAppleClient{}
	h := newTestDeletionHandler(t, store,
		fakeAppleVerifier{claims: appleClaimsAt("apple-sub-leg", time.Now().Add(-time.Hour))},
		client, fakeAppleNotifs{})

	sess, _ := appleUserWithSession(t, h, store, "apple-sub-leg", "leg@example.com", "")
	// Same email address as the Apple account: the OTP session below is
	// lineageless (no Apple authorization time) on the cutoff account.
	otpSess := signupEmail(t, h, store, "r@privaterelay.appleid.com")

	deliverConsentRevoked(t, store, h, "apple-sub-leg", time.Now(), "jti-leg")

	if w := doMe(t, h, otpSess.AccessToken); w.Code != http.StatusUnauthorized {
		t.Errorf("lineageless OTP session on a cutoff account must 401, got %d", w.Code)
	}
	// The Apple session (authorized an hour ago, cutoff now) is dead too.
	if w := doMe(t, h, sess.AccessToken); w.Code != http.StatusUnauthorized {
		t.Errorf("pre-event apple session must 401, got %d", w.Code)
	}
}

// TestCutoff_SameSecondLegacyCannotReauthorize pins the integer-second edge:
// an identity token issued in the SAME second as the cutoff cannot prove it
// postdates the event and fails closed; only a strictly-post-cutoff iat —
// or a live code exchange proving a grant within the same second —
// reauthorizes.
func TestCutoff_SameSecondLegacyCannotReauthorize(t *testing.T) {
	store := newTestStore(t)
	client := &fakeAppleClient{}
	te := time.Now().Add(time.Minute).UTC().Truncate(time.Second)
	h := newTestDeletionHandler(t, store,
		fakeAppleVerifier{claims: appleClaimsAt("apple-sub-ss", te.Add(-time.Hour))},
		client, fakeAppleNotifs{})

	appleUserWithSession(t, h, store, "apple-sub-ss", "r@privaterelay.appleid.com", "")
	if _, _, err := store.ApplyAppleConsentCutoff(context.Background(), "apple-sub-ss", te); err != nil {
		t.Fatalf("cutoff: %v", err)
	}

	trySignIn := func(_, device string, claims apple.Claims, code string, client *fakeAppleClient) *httptest.ResponseRecorder {
		t.Helper()
		hh := newTestDeletionHandler(t, store, fakeAppleVerifier{claims: claims}, client, fakeAppleNotifs{})
		bodyMap := map[string]string{"identity_token": "tok"}
		if code != "" {
			bodyMap["authorization_code"] = code
		}
		body, _ := json.Marshal(bodyMap)
		req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/apple", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Device-Id", device)
		w := httptest.NewRecorder()
		hh.AppleSignIn(w, req)
		return w
	}

	// Same-second legacy iat: not reliable freshness → 401.
	if w := trySignIn("same-second", "d-ss", appleClaimsAt("apple-sub-ss", te), "", client); w.Code != http.StatusUnauthorized {
		t.Errorf("same-second legacy iat must 401, got %d: %s", w.Code, w.Body.String())
	}
	// Pre-event legacy iat → 401.
	if w := trySignIn("pre-event", "d-pre", appleClaimsAt("apple-sub-ss", te.Add(-time.Second)), "", client); w.Code != http.StatusUnauthorized {
		t.Errorf("pre-event legacy iat must 401, got %d: %s", w.Code, w.Body.String())
	}
	// Strictly-post-cutoff legacy iat → 200.
	if w := trySignIn("post", "d-post", appleClaimsAt("apple-sub-ss", te.Add(time.Second)), "", client); w.Code != http.StatusOK {
		t.Errorf("strictly-post-cutoff iat must 200, got %d: %s", w.Code, w.Body.String())
	}

	// A live code exchange proves a live grant even within the cutoff's
	// own second.
	exchanger := &fakeAppleClient{
		exchange: func(code string) (apple.TokenResponse, error) {
			return apple.TokenResponse{RefreshToken: "apple-refresh-" + code, IDToken: "exchanged-id"}, nil
		},
	}
	if w := trySignIn("exchange", "d-ex", appleClaimsAt("apple-sub-ss", te), "code-ss", exchanger); w.Code != http.StatusOK {
		t.Errorf("same-second code exchange must 200, got %d: %s", w.Code, w.Body.String())
	}
}
