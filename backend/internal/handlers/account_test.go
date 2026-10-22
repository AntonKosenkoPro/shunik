package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/antonkosenko/time-of-life/backend/internal/apple"
	"github.com/antonkosenko/time-of-life/backend/internal/auth"
	"github.com/antonkosenko/time-of-life/backend/internal/db"
	"github.com/antonkosenko/time-of-life/backend/internal/ratelimit"
	"github.com/antonkosenko/time-of-life/backend/internal/recovery"
)

const (
	testStatusSecret = "test-status-secret-at-least-32-bytes!"
	testDevice       = "test-device"
)

// fakeAppleClient implements apple.Client with per-test behavior.
type fakeAppleClient struct {
	exchange  func(code string) (apple.TokenResponse, error)
	revoke    func(token string) error
	revoked   []string
	exchanged []string
}

func (f *fakeAppleClient) ExchangeCode(_ context.Context, code string) (apple.TokenResponse, error) {
	f.exchanged = append(f.exchanged, code)
	if f.exchange != nil {
		return f.exchange(code)
	}
	return apple.TokenResponse{}, apple.ErrAppleUnavailable
}

func (f *fakeAppleClient) RevokeToken(_ context.Context, token string) error {
	f.revoked = append(f.revoked, token)
	if f.revoke != nil {
		return f.revoke(token)
	}
	return nil
}

// fakeAppleNotifs implements apple.NotificationVerifier with fixed output.
type fakeAppleNotifs struct {
	event apple.NotificationEvent
	err   error
}

func (f fakeAppleNotifs) VerifyNotification(_ context.Context, _ string) (apple.NotificationEvent, error) {
	return f.event, f.err
}

func testStatusService() *auth.StatusService {
	return auth.NewStatusService(testStatusSecret)
}

func testAppleTokenKeyring() *recovery.Keyring {
	return recovery.NewKeyring([][]byte{bytes.Repeat([]byte{0x09}, recovery.KeySize)})
}

func testDigestKey() []byte {
	return apple.SubjectDigestKey([]byte(testStatusSecret))
}

// newTestDeletionHandler wires full account-deletion dependencies: a status
// service, fake Apple client + notification verifier, a token keyring, and
// the rotation-stable digest key.
func newTestDeletionHandler(t *testing.T, store db.Store, verifier apple.Verifier, client *fakeAppleClient, notifs apple.NotificationVerifier) *Handler {
	t.Helper()
	h := newTestHandlerWithApple(t, store, verifier)
	h.statusService = testStatusService()
	h.appleClient = client
	h.appleNotifs = notifs
	h.appleTokenKeys = testAppleTokenKeyring()
	h.digestKey = testDigestKey()
	h.appleClientID = "com.test.app"
	return h
}

// signupEmail creates an email user via OTP and returns the session.
func signupEmail(t *testing.T, h *Handler, store db.Store, emailAddr string) authResponse {
	t.Helper()
	sender := &captureSender{}
	h2 := newTestHandlerWithDependencies(t, store, nil, sender)
	if w := requestOTP(t, h2, emailAddr); w.Code != http.StatusAccepted {
		t.Fatalf("otp request: got %d", w.Code)
	}
	code := capturedOTP(t, sender)
	w := verifyOTP(t, h, emailAddr, code)
	if w.Code != http.StatusOK {
		t.Fatalf("otp verify: got %d: %s", w.Code, w.Body.String())
	}
	var resp authResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("decode session: %v", err)
	}
	return resp
}

func doDeleteAccount(t *testing.T, h *Handler, accessToken, deviceID string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodDelete, "/api/v1/auth/account", nil)
	req.Header.Set("Authorization", "Bearer "+accessToken)
	if deviceID != "" {
		req.Header.Set("X-Device-Id", deviceID)
	}
	w := httptest.NewRecorder()
	// Route through the middleware like production: the gate proves the
	// session (and its account lifecycle) before the handler runs.
	h.AuthMiddleware(http.HandlerFunc(h.DeleteAccount)).ServeHTTP(w, req)
	return w
}

func doStatus(t *testing.T, h *Handler, cred string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/account/status", nil)
	if cred != "" {
		req.Header.Set("Authorization", "Bearer "+cred)
	}
	w := httptest.NewRecorder()
	h.AccountStatus(w, req)
	return w
}

func doNotifications(t *testing.T, h *Handler, payload string) *httptest.ResponseRecorder {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"payload": payload})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/apple/notifications", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.AppleNotifications(w, req)
	return w
}

func doDeletionCredential(t *testing.T, h *Handler, accessToken, idToken, code string) *httptest.ResponseRecorder {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"identity_token": idToken, "authorization_code": code})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/apple/deletion-credential", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("X-Device-Id", testDevice)
	w := httptest.NewRecorder()
	h.AuthMiddleware(http.HandlerFunc(h.AppleDeletionCredential)).ServeHTTP(w, req)
	return w
}

func decodeStatus(t *testing.T, w *httptest.ResponseRecorder) accountStatusResponse {
	t.Helper()
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	var out accountStatusResponse
	if err := json.NewDecoder(w.Body).Decode(&out); err != nil {
		t.Fatalf("decode status: %v", err)
	}
	return out
}

// appleUserWithSession signs in an Apple user through the handler and returns
// the session plus the stored user row.
func appleUserWithSession(t *testing.T, h *Handler, store db.Store, sub, _ /* emailAddr */, code string) (authResponse, db.User) {
	t.Helper()
	bodyMap := map[string]string{"identity_token": "id-token-for-" + sub}
	if code != "" {
		bodyMap["authorization_code"] = code
	}
	body, _ := json.Marshal(bodyMap)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/apple", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Device-Id", testDevice)
	w := httptest.NewRecorder()
	h.AppleSignIn(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("apple sign-in: got %d: %s", w.Code, w.Body.String())
	}
	var resp authResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("decode session: %v", err)
	}
	user, err := store.GetUserByID(context.Background(), resp.User.ID)
	if err != nil {
		t.Fatalf("GetUserByID: %v", err)
	}
	return resp, user
}

func TestDeleteAccount_EmailFlow(t *testing.T) {
	store := newTestStore(t)
	h := newTestDeletionHandler(t, store, nil, &fakeAppleClient{}, fakeAppleNotifs{})

	sess := signupEmail(t, h, store, "gone@example.com")
	if sess.AccountStatusCredential == "" || sess.AccountStatusExpiresAt == "" {
		t.Fatal("expected status credential + expiry on signup")
	}
	if sess.User.HasAppleIdentity || sess.User.AppleDeletionAuthorizationRequired {
		t.Errorf("email user must not carry apple metadata: %+v", sess.User)
	}

	// Missing device header is a 400, not a deletion.
	if w := doDeleteAccount(t, h, sess.AccessToken, ""); w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 without device header, got %d", w.Code)
	}

	w := doDeleteAccount(t, h, sess.AccessToken, testDevice)
	if w.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", w.Code, w.Body.String())
	}

	// The account is gone: tokens, recovery, and status prove nothing usable.
	if _, err := store.GetUserByID(context.Background(), sess.User.ID); !errors.Is(err, db.ErrNotFound) {
		t.Fatalf("expected user gone, got %v", err)
	}
	if w := doStatus(t, h, sess.AccountStatusCredential); decodeStatus(t, w).State != "deleted" {
		t.Errorf("expected deleted status, got %s", w.Body.String())
	}

	// Fresh signup with the same email creates a NEW uuid with no old data.
	sess2 := signupEmail(t, h, store, "gone@example.com")
	if sess2.User.ID == sess.User.ID {
		t.Error("expected a fresh account UUID after deletion")
	}
}

func TestDeleteAccount_AppleRequiresCredential(t *testing.T) {
	store := newTestStore(t)
	client := &fakeAppleClient{}
	h := newTestDeletionHandler(t, store,
		fakeAppleVerifier{claims: apple.Claims{Sub: "apple-sub-9", Email: "r@privaterelay.appleid.com"}},
		client, fakeAppleNotifs{})

	sess, _ := appleUserWithSession(t, h, store, "apple-sub-9", "r@privaterelay.appleid.com", "")
	if !sess.User.HasAppleIdentity || !sess.User.AppleDeletionAuthorizationRequired {
		t.Fatalf("apple user without vault must flag required: %+v", sess.User)
	}

	// No revocable credential: 409 with NO purge — the account survives.
	w := doDeleteAccount(t, h, sess.AccessToken, testDevice)
	if w.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d: %s", w.Code, w.Body.String())
	}
	if _, err := store.GetUserByID(context.Background(), sess.User.ID); err != nil {
		t.Fatalf("409 must not purge: %v", err)
	}
	if len(client.revoked) != 0 {
		t.Errorf("no apple call may happen on 409, got %v", client.revoked)
	}
}

func TestDeleteAccount_AppleRevokesInline(t *testing.T) {
	store := newTestStore(t)
	client := &fakeAppleClient{
		exchange: func(code string) (apple.TokenResponse, error) {
			return apple.TokenResponse{RefreshToken: "apple-refresh-" + code, IDToken: "exchanged-id"}, nil
		},
	}
	verifier := fakeAppleVerifier{claims: apple.Claims{Sub: "apple-sub-7", Email: "r@privaterelay.appleid.com"}}
	h := newTestDeletionHandler(t, store, verifier, client, fakeAppleNotifs{})

	// Sign in WITH a code so the vault holds a revocable credential.
	sess, _ := appleUserWithSession(t, h, store, "apple-sub-7", "r@privaterelay.appleid.com", "code-1")
	if sess.User.AppleDeletionAuthorizationRequired {
		t.Fatalf("vault-backed user must not flag required: %+v", sess.User)
	}
	if len(client.exchanged) != 1 || client.exchanged[0] != "code-1" {
		t.Fatalf("expected one code exchange, got %v", client.exchanged)
	}

	w := doDeleteAccount(t, h, sess.AccessToken, testDevice)
	if w.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", w.Code, w.Body.String())
	}
	if len(client.revoked) != 1 || client.revoked[0] != "apple-refresh-code-1" {
		t.Fatalf("expected inline revoke of the vault credential, got %v", client.revoked)
	}
	if _, err := store.GetUserByID(context.Background(), sess.User.ID); !errors.Is(err, db.ErrNotFound) {
		t.Fatalf("expected user purged, got %v", err)
	}
}

func TestDeleteAccount_ApplePendingOnRevokeFailure(t *testing.T) {
	store := newTestStore(t)
	client := &fakeAppleClient{
		exchange: func(_ string) (apple.TokenResponse, error) {
			return apple.TokenResponse{RefreshToken: "apple-refresh-x", IDToken: "exchanged-id"}, nil
		},
		revoke: func(_ string) error {
			return errors.New("apple down")
		},
	}
	verifier := fakeAppleVerifier{claims: apple.Claims{Sub: "apple-sub-8", Email: "r@privaterelay.appleid.com"}}
	h := newTestDeletionHandler(t, store, verifier, client, fakeAppleNotifs{})

	sess, _ := appleUserWithSession(t, h, store, "apple-sub-8", "r@privaterelay.appleid.com", "code-2")

	w := doDeleteAccount(t, h, sess.AccessToken, testDevice)
	if w.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d: %s", w.Code, w.Body.String())
	}
	var out accountDeletedPendingResponse
	if err := json.NewDecoder(w.Body).Decode(&out); err != nil {
		t.Fatalf("decode 202: %v", err)
	}
	if !out.AccountDeleted || !out.AppleRevocationPending {
		t.Fatalf("202 must confirm deletion with pending unlink, got %+v", out)
	}
	if _, err := store.GetUserByID(context.Background(), sess.User.ID); !errors.Is(err, db.ErrNotFound) {
		t.Fatalf("202 still means purged, got %v", err)
	}

	// Status proves the deletion even though the revoke acknowledgment was lost.
	if st := decodeStatus(t, doStatus(t, h, sess.AccountStatusCredential)); st.State != "deleted" || st.AccountID != sess.User.ID {
		t.Fatalf("expected deleted verdict echoing the UUID, got %+v", st)
	}

	// A same-subject signup is fenced while the job is pending: the code is
	// not consumed and no session is created.
	body, _ := json.Marshal(map[string]string{"identity_token": "tok", "authorization_code": "fresh-code"})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/apple", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Device-Id", testDevice)
	w2 := httptest.NewRecorder()
	h.AppleSignIn(w2, req)
	if w2.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected fenced 503, got %d: %s", w2.Code, w2.Body.String())
	}
	if len(client.exchanged) != 1 {
		t.Errorf("fenced signup must not consume the code, exchanges: %v", client.exchanged)
	}
}

func TestDeleteAccount_UnconfiguredAppleRefusesWithoutPurge(t *testing.T) {
	store := newTestStore(t)
	// No deletion deps wired (legacy constructor): Apple user, no revocation.
	h := newTestHandlerWithApple(t, store,
		fakeAppleVerifier{claims: apple.Claims{Sub: "apple-sub-z", Email: "r@privaterelay.appleid.com"}})
	sess, _ := appleUserWithSession(t, h, store, "apple-sub-z", "r@privaterelay.appleid.com", "")

	w := doDeleteAccount(t, h, sess.AccessToken, testDevice)
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 without purge, got %d: %s", w.Code, w.Body.String())
	}
	if _, err := store.GetUserByID(context.Background(), sess.User.ID); err != nil {
		t.Fatalf("unconfigured apple must not purge: %v", err)
	}
}

func TestAccountStatus_VerdictsAndMisuse(t *testing.T) {
	store := newTestStore(t)
	h := newTestDeletionHandler(t, store, nil, &fakeAppleClient{}, fakeAppleNotifs{})
	sess := signupEmail(t, h, store, "status@example.com")

	// Active account: exact UUID echo, active verdict.
	st := decodeStatus(t, doStatus(t, h, sess.AccountStatusCredential))
	if st.State != "active" || st.AccountID != sess.User.ID {
		t.Fatalf("expected active verdict echoing the UUID, got %+v", st)
	}

	// An access token is NOT a status credential.
	if w := doStatus(t, h, sess.AccessToken); w.Code != http.StatusUnauthorized {
		t.Fatalf("access token on status endpoint must 401, got %d", w.Code)
	}
	// Missing bearer.
	if w := doStatus(t, h, ""); w.Code != http.StatusUnauthorized {
		t.Fatalf("missing bearer must 401, got %d", w.Code)
	}
	// Wrong-purpose credential (access-shaped claims under the status key).
	bad, _, err := h.statusService.Mint("someone-else")
	if err != nil {
		t.Fatalf("mint: %v", err)
	}
	_ = bad
	tampered := craftStatusToken(t, testStatusSecret, "login", sess.User.ID, time.Now().Add(time.Hour))
	if w := doStatus(t, h, tampered); w.Code != http.StatusUnauthorized {
		t.Fatalf("wrong-purpose credential must 401, got %d", w.Code)
	}
	// Expired credential.
	expired := craftStatusToken(t, testStatusSecret, auth.StatusPurpose, sess.User.ID, time.Now().Add(-time.Hour))
	if w := doStatus(t, h, expired); w.Code != http.StatusUnauthorized {
		t.Fatalf("expired credential must 401, got %d", w.Code)
	}
	// Status credential on a normal endpoint: rejected, no data.
	req := httptest.NewRequest(http.MethodGet, "/api/v1/auth/me", nil)
	req.Header.Set("Authorization", "Bearer "+sess.AccountStatusCredential)
	w := httptest.NewRecorder()
	h.AuthMiddleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})).ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status credential as access must 401, got %d", w.Code)
	}
	// Purge then check: deleted verdict, and the old access token is dead.
	if w := doDeleteAccount(t, h, sess.AccessToken, testDevice); w.Code != http.StatusNoContent {
		t.Fatalf("delete: got %d", w.Code)
	}
	if st := decodeStatus(t, doStatus(t, h, sess.AccountStatusCredential)); st.State != "deleted" {
		t.Fatalf("expected deleted, got %+v", st)
	}
	req2 := httptest.NewRequest(http.MethodGet, "/api/v1/auth/me", nil)
	req2.Header.Set("Authorization", "Bearer "+sess.AccessToken)
	w2 := httptest.NewRecorder()
	h.AuthMiddleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})).ServeHTTP(w2, req2)
	if w2.Code != http.StatusUnauthorized {
		t.Fatalf("purged access token must 401, got %d", w2.Code)
	}
}

// craftStatusToken mints a status-shaped token with a chosen purpose/expiry
// for negative tests.
func craftStatusToken(t *testing.T, secret, purpose, subject string, exp time.Time) string {
	t.Helper()
	claims := auth.StatusClaims{
		Purpose: purpose,
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    auth.StatusIssuer,
			Audience:  jwt.ClaimStrings{auth.StatusAudience},
			Subject:   subject,
			IssuedAt:  jwt.NewNumericDate(time.Now().Add(-time.Minute)),
			ExpiresAt: jwt.NewNumericDate(exp),
		},
	}
	signed, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(secret))
	if err != nil {
		t.Fatalf("sign test token: %v", err)
	}
	return signed
}

func TestRefresh_AfterPurgeIsOrdinaryFailure(t *testing.T) {
	store := newTestStore(t)
	h := newTestDeletionHandler(t, store, nil, &fakeAppleClient{}, fakeAppleNotifs{})
	sess := signupEmail(t, h, store, "refresh@example.com")

	if w := doDeleteAccount(t, h, sess.AccessToken, testDevice); w.Code != http.StatusNoContent {
		t.Fatalf("delete: got %d", w.Code)
	}

	body, _ := json.Marshal(map[string]string{"refresh_token": sess.RefreshToken})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/refresh", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Device-Id", testDevice)
	w := httptest.NewRecorder()
	h.RefreshToken(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("post-purge refresh must 401, got %d: %s", w.Code, w.Body.String())
	}
	var errBody map[string]any
	if err := json.NewDecoder(w.Body).Decode(&errBody); err != nil {
		t.Fatalf("decode: %v", err)
	}
	code, _ := errBody["error"].(map[string]any)["code"].(string)
	if code != "invalid_refresh" {
		t.Fatalf("expected invalid_refresh (never a deletion verdict), got %q", code)
	}
}

func TestDeletionCredential_HappyPath(t *testing.T) {
	store := newTestStore(t)
	client := &fakeAppleClient{
		exchange: func(_ string) (apple.TokenResponse, error) {
			return apple.TokenResponse{RefreshToken: "vault-refresh", IDToken: "exchanged-id"}, nil
		},
	}
	verifier := fakeAppleVerifier{claims: apple.Claims{Sub: "apple-sub-dc", Email: "r@privaterelay.appleid.com"}}
	h := newTestDeletionHandler(t, store, verifier, client, fakeAppleNotifs{})

	sess, _ := appleUserWithSession(t, h, store, "apple-sub-dc", "r@privaterelay.appleid.com", "")
	if !sess.User.AppleDeletionAuthorizationRequired {
		t.Fatal("expected required=true before credential acquisition")
	}

	w := doDeletionCredential(t, h, sess.AccessToken, "id-token", "fresh-code")
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	if _, err := store.GetAppleCredential(context.Background(), sess.User.ID); err != nil {
		t.Fatalf("expected vault credential stored: %v", err)
	}

	// Deletion now proceeds to inline revocation and completion.
	w = doDeleteAccount(t, h, sess.AccessToken, testDevice)
	if w.Code != http.StatusNoContent {
		t.Fatalf("expected 204 after credential acquisition, got %d: %s", w.Code, w.Body.String())
	}
	if len(client.revoked) != 1 || client.revoked[0] != "vault-refresh" {
		t.Fatalf("expected revoke of the acquired credential, got %v", client.revoked)
	}
}

func TestDeletionCredential_Rejects(t *testing.T) {
	newAppleHandler := func(t *testing.T, store db.Store, client *fakeAppleClient, sub string) (*Handler, authResponse) {
		t.Helper()
		h := newTestDeletionHandler(t, store,
			fakeAppleVerifier{claims: apple.Claims{Sub: sub, Email: "r@privaterelay.appleid.com"}},
			client, fakeAppleNotifs{})
		sess, _ := appleUserWithSession(t, h, store, sub, "", "")
		return h, sess
	}

	t.Run("wrong identity", func(t *testing.T) {
		store := newTestStore(t)
		client := &fakeAppleClient{}
		// Account is sub-B; present an identity for sub-A through a second
		// handler sharing the store (same JWT, different Apple identity).
		hB := newTestDeletionHandler(t, store,
			fakeAppleVerifier{claims: apple.Claims{Sub: "sub-B"}},
			client, fakeAppleNotifs{})
		sess, _ := appleUserWithSession(t, hB, store, "sub-B", "r@privaterelay.appleid.com", "")
		hA := newTestDeletionHandler(t, store,
			fakeAppleVerifier{claims: apple.Claims{Sub: "sub-A"}},
			client, fakeAppleNotifs{})
		if w := doDeletionCredential(t, hA, sess.AccessToken, "id", "code"); w.Code != http.StatusUnauthorized {
			t.Fatalf("subject mismatch must 401, got %d: %s", w.Code, w.Body.String())
		}
		if len(client.exchanged) != 0 {
			t.Errorf("mismatched identity must not reach Apple, got %v", client.exchanged)
		}
	})

	t.Run("invalid grant", func(t *testing.T) {
		store := newTestStore(t)
		client := &fakeAppleClient{
			exchange: func(_ string) (apple.TokenResponse, error) {
				return apple.TokenResponse{}, apple.ErrInvalidGrant
			},
		}
		h, sess := newAppleHandler(t, store, client, "apple-sub-ig")
		if w := doDeletionCredential(t, h, sess.AccessToken, "id", "bad-code"); w.Code != http.StatusUnauthorized {
			t.Fatalf("invalid grant must 401, got %d: %s", w.Code, w.Body.String())
		}
	})

	t.Run("apple down", func(t *testing.T) {
		store := newTestStore(t)
		client := &fakeAppleClient{
			exchange: func(_ string) (apple.TokenResponse, error) {
				return apple.TokenResponse{}, apple.ErrAppleUnavailable
			},
		}
		h, sess := newAppleHandler(t, store, client, "apple-sub-dn")
		if w := doDeletionCredential(t, h, sess.AccessToken, "id", "code"); w.Code != http.StatusServiceUnavailable {
			t.Fatalf("apple outage must 503, got %d: %s", w.Code, w.Body.String())
		}
	})

	t.Run("email-only account", func(t *testing.T) {
		store := newTestStore(t)
		h := newTestDeletionHandler(t, store, nil, &fakeAppleClient{}, fakeAppleNotifs{})
		sess := signupEmail(t, h, store, "plain@example.com")
		if w := doDeletionCredential(t, h, sess.AccessToken, "id", "code"); w.Code != http.StatusBadRequest {
			t.Fatalf("email-only account must 400, got %d: %s", w.Code, w.Body.String())
		}
	})
}

func TestNotifications_ConsentRevokedSignsOutPreservesData(t *testing.T) {
	store := newTestStore(t)
	verifier := fakeAppleVerifier{claims: apple.Claims{Sub: "apple-sub-n", Email: "r@privaterelay.appleid.com"}}
	h := newTestDeletionHandler(t, store, verifier, &fakeAppleClient{}, fakeAppleNotifs{})

	sess, user := appleUserWithSession(t, h, store, "apple-sub-n", "r@privaterelay.appleid.com", "")
	if user.AppleAuthLineage == nil {
		t.Fatal("expected a lineage after signup")
	}

	// The revocation genuinely postdates the recorded authorization.
	h.appleNotifs = fakeAppleNotifs{event: apple.NotificationEvent{
		Type: "consent-revoked", Sub: "apple-sub-n", JTI: "jti-1",
		EventTime: time.Now().Add(time.Minute), HasEventTime: true,
	}}

	if w := doNotifications(t, h, "signed-jws"); w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	// Sessions die across devices (ordinary failure, files intact).
	body, _ := json.Marshal(map[string]string{"refresh_token": sess.RefreshToken})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/refresh", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Device-Id", testDevice)
	w := httptest.NewRecorder()
	h.RefreshToken(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("post-revoke refresh must 401, got %d: %s", w.Code, w.Body.String())
	}
	req2 := httptest.NewRequest(http.MethodGet, "/api/v1/auth/me", nil)
	req2.Header.Set("Authorization", "Bearer "+sess.AccessToken)
	w2 := httptest.NewRecorder()
	h.AuthMiddleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})).ServeHTTP(w2, req2)
	if w2.Code != http.StatusUnauthorized {
		t.Fatalf("post-revoke access must 401, got %d", w2.Code)
	}

	// The account and its data survive: user row present, status active.
	stored, err := store.GetUserByID(context.Background(), sess.User.ID)
	if err != nil {
		t.Fatalf("account must survive consent-revoked: %v", err)
	}
	if stored.AppleConsentCutoff == nil || stored.AppleAuthLineage != nil {
		t.Errorf("expected cutoff set + lineage nulled, got %+v", stored)
	}
	if w := doStatus(t, h, sess.AccountStatusCredential); decodeStatus(t, w).State != "active" {
		t.Errorf("revoked-but-present account must report active, got %s", w.Body.String())
	}

	// Duplicate delivery is an idempotent 200 no-op.
	h.appleNotifs = fakeAppleNotifs{event: apple.NotificationEvent{
		Type: "consent-revoked", Sub: "apple-sub-n", JTI: "jti-1",
		EventTime: time.Now(), HasEventTime: true,
	}}
	if w := doNotifications(t, h, "signed-jws"); w.Code != http.StatusOK {
		t.Fatalf("replay must 200, got %d", w.Code)
	}
}

func TestNotifications_NonRevocationTypesAreNoOps(t *testing.T) {
	for _, typ := range []string{"email-enabled", "email-disabled", "account-deleted", "future-type"} {
		t.Run(typ, func(t *testing.T) {
			store := newTestStore(t)
			verifier := fakeAppleVerifier{claims: apple.Claims{Sub: "apple-sub-o", Email: "r@privaterelay.appleid.com"}}
			h := newTestDeletionHandler(t, store, verifier, &fakeAppleClient{},
				fakeAppleNotifs{event: apple.NotificationEvent{Type: typ, Sub: "apple-sub-o", JTI: "jti-" + typ}})
			sess, _ := appleUserWithSession(t, h, store, "apple-sub-o", "r@privaterelay.appleid.com", "")
			if w := doNotifications(t, h, "signed-jws"); w.Code != http.StatusOK {
				t.Fatalf("expected 200 no-op, got %d", w.Code)
			}
			// Sessions keep working; no cutoff recorded.
			stored, err := store.GetUserByID(context.Background(), sess.User.ID)
			if err != nil {
				t.Fatalf("user must survive: %v", err)
			}
			if stored.AppleConsentCutoff != nil || stored.AppleAuthLineage == nil {
				t.Errorf("no state change expected, got %+v", stored)
			}
		})
	}
}

func TestNotifications_MissingUserAndBadPayload(t *testing.T) {
	store := newTestStore(t)
	h := newTestDeletionHandler(t, store, nil, &fakeAppleClient{},
		fakeAppleNotifs{event: apple.NotificationEvent{Type: "consent-revoked", Sub: "ghost-sub", JTI: "jti-ghost", EventTime: time.Now(), HasEventTime: true}})

	// Missing user: idempotent 200, never an upsert.
	if w := doNotifications(t, h, "signed-jws"); w.Code != http.StatusOK {
		t.Fatalf("missing user must 200, got %d", w.Code)
	}
	if _, err := store.GetUserByEmail(context.Background(), "ghost@example.com"); !errors.Is(err, db.ErrNotFound) {
		t.Fatalf("notification must never upsert, got %v", err)
	}

	// Invalid signature/claims: 401, no jti recorded.
	h.appleNotifs = fakeAppleNotifs{err: errors.New("bad signature")}
	if w := doNotifications(t, h, "bogus"); w.Code != http.StatusUnauthorized {
		t.Fatalf("invalid payload must 401, got %d", w.Code)
	}

	// Malformed body: 400.
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/apple/notifications", bytes.NewReader([]byte(`{}`)))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	h.AppleNotifications(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("empty body must 400, got %d", w.Code)
	}
}

func TestAppleSignIn_EmailCollision409(t *testing.T) {
	store := newTestStore(t)
	h := newTestDeletionHandler(t, store,
		fakeAppleVerifier{claims: apple.Claims{Sub: "apple-sub-fresh", Email: "taken@example.com"}},
		&fakeAppleClient{}, fakeAppleNotifs{})

	// The email already belongs to an email-OTP account.
	signupEmail(t, h, store, "taken@example.com")

	body, _ := json.Marshal(map[string]string{"identity_token": "id-token-fresh"})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/apple", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Device-Id", testDevice)
	w := httptest.NewRecorder()
	h.AppleSignIn(w, req)
	if w.Code != http.StatusConflict {
		t.Fatalf("email collision must 409, got %d: %s", w.Code, w.Body.String())
	}
	var env map[string]map[string]string
	if err := json.NewDecoder(w.Body).Decode(&env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if env["error"]["code"] != "apple_email_in_use" {
		t.Fatalf("expected apple_email_in_use, got %s", w.Body.String())
	}
	// Neither account was touched: the OTP user keeps its row with no
	// Apple subject, and no Apple-subject row was created.
	u, err := store.GetUserByEmail(context.Background(), "taken@example.com")
	if err != nil {
		t.Fatalf("otp user must survive: %v", err)
	}
	if u.AppleSubject != nil {
		t.Errorf("otp user must not gain an apple subject: %+v", u)
	}
}

func TestVerifyOTP_CutoffFenced(t *testing.T) {
	store := newTestStore(t)
	h := newTestDeletionHandler(t, store, nil, &fakeAppleClient{}, fakeAppleNotifs{})

	sess := signupEmail(t, h, store, "fenced-otp@example.com")
	// Bind the OTP account to an Apple subject, then revoke consent: the
	// account-wide cutoff ends every lineageless session on it.
	if _, err := store.DB().ExecContext(context.Background(),
		`UPDATE users SET apple_subject = ? WHERE id = ?`, "apple-sub-otp", sess.User.ID); err != nil {
		t.Fatalf("attach subject: %v", err)
	}
	if _, _, err := store.ApplyAppleConsentCutoff(context.Background(), "apple-sub-otp", time.Now()); err != nil {
		t.Fatalf("cutoff: %v", err)
	}

	// A fresh OTP sign-in is rejected up front with the re-authorization
	// instruction instead of minting tokens the middleware would kill.
	sender := &captureSender{}
	h2 := newTestHandlerWithDependencies(t, store, nil, sender)
	if w := requestOTP(t, h2, "fenced-otp@example.com"); w.Code != http.StatusAccepted {
		t.Fatalf("otp request: got %d", w.Code)
	}
	w := verifyOTPWithDevice(t, h, "fenced-otp@example.com", capturedOTP(t, sender), testDevice)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("cutoff OTP sign-in must 401, got %d: %s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "invalid_apple_token") {
		t.Fatalf("expected invalid_apple_token, got %s", w.Body.String())
	}
}

func TestAccountStatus_LowercaseBearerScheme(t *testing.T) {
	store := newTestStore(t)
	h := newTestDeletionHandler(t, store, nil, &fakeAppleClient{}, fakeAppleNotifs{})

	sess := signupEmail(t, h, store, "case@example.com")
	// RFC 7235: the scheme name is case-insensitive; the middleware
	// accepts it, so the status endpoint must too.
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/account/status", nil)
	req.Header.Set("Authorization", "bearer "+sess.AccountStatusCredential)
	w := httptest.NewRecorder()
	h.AccountStatus(w, req)
	if decodeStatus(t, w).State != "active" {
		t.Errorf("lowercase bearer must authenticate, got %s", w.Body.String())
	}
}

func TestNotifications_FormEncoded(t *testing.T) {
	store := newTestStore(t)
	verifier := fakeAppleVerifier{claims: apple.Claims{Sub: "apple-sub-f", Email: "r@privaterelay.appleid.com"}}
	h := newTestDeletionHandler(t, store, verifier, &fakeAppleClient{}, fakeAppleNotifs{})
	sess, _ := appleUserWithSession(t, h, store, "apple-sub-f", "r@privaterelay.appleid.com", "")

	// Apple delivers form-encoded, not JSON: the handler must accept it.
	h.appleNotifs = fakeAppleNotifs{event: apple.NotificationEvent{
		Type: "consent-revoked", Sub: "apple-sub-f", JTI: "jti-form",
		EventTime: time.Now().Add(time.Minute), HasEventTime: true,
	}}
	form := strings.NewReader("payload=signed-jws-form")
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/apple/notifications", form)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	w := httptest.NewRecorder()
	h.AppleNotifications(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("form-encoded delivery must 200, got %d: %s", w.Code, w.Body.String())
	}
	stored, err := store.GetUserByID(context.Background(), sess.User.ID)
	if err != nil {
		t.Fatalf("account must survive: %v", err)
	}
	if stored.AppleConsentCutoff == nil {
		t.Error("form delivery must apply the cutoff")
	}
}

func TestNotifications_RateLimited(t *testing.T) {
	store := newTestStore(t)
	h := newTestDeletionHandler(t, store, nil, &fakeAppleClient{},
		fakeAppleNotifs{event: apple.NotificationEvent{Type: "consent-revoked", Sub: "apple-sub-rl", JTI: "jti-rl-1", EventTime: time.Now(), HasEventTime: true}})
	// Burst 1 with no refill: first delivery passes, the immediate retry
	// is limited before any verification work happens.
	h.rateLimiter.AppleNotifications = ratelimit.NewTokenBucket(1, 1, time.Hour)
	if w := doNotifications(t, h, "signed-jws"); w.Code != http.StatusOK {
		t.Fatalf("first delivery must 200, got %d", w.Code)
	}
	h.appleNotifs = fakeAppleNotifs{event: apple.NotificationEvent{Type: "consent-revoked", Sub: "apple-sub-rl", JTI: "jti-rl-2", EventTime: time.Now(), HasEventTime: true}}
	w := doNotifications(t, h, "signed-jws")
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("second immediate delivery must 429, got %d: %s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "rate_limited") {
		t.Fatalf("expected rate_limited code, got %s", w.Body.String())
	}
}

func TestAppleSignIn_StaleTokenCannotBypassCutoff(t *testing.T) {
	store := newTestStore(t)
	client := &fakeAppleClient{}
	issuedAt := time.Now().Add(-time.Hour)
	verifier := fakeAppleVerifier{claims: apple.Claims{
		Sub: "apple-sub-cut", Email: "r@privaterelay.appleid.com",
		RegisteredClaims: jwt.RegisteredClaims{IssuedAt: jwt.NewNumericDate(issuedAt)},
	}}
	h := newTestDeletionHandler(t, store, verifier, client, fakeAppleNotifs{})

	sess, _ := appleUserWithSession(t, h, store, "apple-sub-cut", "r@privaterelay.appleid.com", "")
	// The revocation genuinely postdates the recorded authorization.
	cutoff := time.Now().Add(time.Minute)
	if _, _, err := store.ApplyAppleConsentCutoff(context.Background(), "apple-sub-cut", cutoff); err != nil {
		t.Fatalf("cutoff: %v", err)
	}

	// Legacy identity-token-only login with a pre-cutoff token is rejected:
	// it cannot mint its way around Settings revocation.
	body, _ := json.Marshal(map[string]string{"identity_token": "stale"})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/apple", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Device-Id", "device-2")
	w := httptest.NewRecorder()
	h.AppleSignIn(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("stale pre-cutoff token must 401, got %d: %s", w.Code, w.Body.String())
	}

	// A fresh identity token (iat past the cutoff) reconnects to the SAME
	// uuid with a new lineage.
	freshAt := cutoff.Add(time.Minute)
	verifier2 := fakeAppleVerifier{claims: apple.Claims{
		Sub: "apple-sub-cut", Email: "r@privaterelay.appleid.com",
		RegisteredClaims: jwt.RegisteredClaims{IssuedAt: jwt.NewNumericDate(freshAt)},
	}}
	h2 := newTestDeletionHandler(t, store, verifier2, client, fakeAppleNotifs{})
	body2, _ := json.Marshal(map[string]string{"identity_token": "fresh"})
	req2 := httptest.NewRequest(http.MethodPost, "/api/v1/auth/apple", bytes.NewReader(body2))
	req2.Header.Set("Content-Type", "application/json")
	req2.Header.Set("X-Device-Id", "device-2")
	w2 := httptest.NewRecorder()
	h2.AppleSignIn(w2, req2)
	if w2.Code != http.StatusOK {
		t.Fatalf("fresh post-cutoff token must 200, got %d: %s", w2.Code, w2.Body.String())
	}
	var resp authResponse
	if err := json.NewDecoder(w2.Body).Decode(&resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if resp.User.ID != sess.User.ID {
		t.Fatalf("reconnect must return the existing UUID, got %s want %s", resp.User.ID, sess.User.ID)
	}
}

func TestNotifications_OwnRevocationCallbackHarmlessToReplacement(t *testing.T) {
	store := newTestStore(t)
	client := &fakeAppleClient{
		exchange: func(_ string) (apple.TokenResponse, error) {
			return apple.TokenResponse{RefreshToken: "vault-refresh-r", IDToken: "exchanged-id"}, nil
		},
		revoke: func(_ string) error { return errors.New("apple down") },
	}
	verifier := fakeAppleVerifier{claims: apple.Claims{Sub: "apple-sub-rep", Email: "r@privaterelay.appleid.com"}}
	h := newTestDeletionHandler(t, store, verifier, client, fakeAppleNotifs{})

	// Old account: signup with credential, then explicit deletion (202 —
	// the revoke acknowledgment is lost, the job stays pending).
	oldSess, _ := appleUserWithSession(t, h, store, "apple-sub-rep", "r@privaterelay.appleid.com", "code-r")
	oldID := oldSess.User.ID
	beforePurge := time.Now().UTC()
	if w := doDeleteAccount(t, h, oldSess.AccessToken, testDevice); w.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d: %s", w.Code, w.Body.String())
	}

	// The worker completes the revocation out-of-band; the fence reopens.
	ctx := context.Background()
	jobs := pendingJobIDs(t, store)
	if len(jobs) != 1 {
		t.Fatalf("expected one pending job, got %v", jobs)
	}
	if err := store.CompleteRevocationJob(ctx, jobs[0]); err != nil {
		t.Fatalf("complete: %v", err)
	}

	// Fresh registration with the same Apple identity: new UUID, working
	// session.
	newSess, _ := appleUserWithSession(t, h, store, "apple-sub-rep", "r@privaterelay.appleid.com", "")
	if newSess.User.ID == oldID {
		t.Fatal("re-registration must mint a fresh UUID")
	}

	// Our own purge-triggered revocation callback arrives late (event time
	// from before the re-registration): the cutoff advances to the event,
	// but the replacement — authorized after it — is preserved, not signed
	// out, and nothing is deleted.
	h.appleNotifs = fakeAppleNotifs{event: apple.NotificationEvent{
		Type: "consent-revoked", Sub: "apple-sub-rep", JTI: "jti-own-revoke",
		EventTime: beforePurge.Add(-time.Minute), HasEventTime: true,
	}}
	if w := doNotifications(t, h, "signed-jws"); w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	stored, err := store.GetUserByID(ctx, newSess.User.ID)
	if err != nil {
		t.Fatalf("replacement account must survive: %v", err)
	}
	if stored.AppleConsentCutoff == nil || !stored.AppleConsentCutoff.Equal(beforePurge.Add(-time.Minute).Truncate(time.Millisecond)) {
		t.Fatalf("cutoff must advance to the delayed event, got %+v", stored.AppleConsentCutoff)
	}
	if stored.AppleAuthLineage == nil {
		t.Fatalf("newer lineage metadata must be preserved: %+v", stored)
	}
	body, _ := json.Marshal(map[string]string{"refresh_token": newSess.RefreshToken})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/refresh", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Device-Id", testDevice)
	w := httptest.NewRecorder()
	h.RefreshToken(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("replacement session must keep working, got %d: %s", w.Code, w.Body.String())
	}
}

func pendingJobIDs(t *testing.T, store db.Store) []string {
	t.Helper()
	// Claim far in the future to list due jobs without disturbing them is
	// impossible; instead complete-list via repeated claims is destructive.
	// SQLite test stores expose jobs through a claim with a far-future
	// clock, then fail them back to their grace window.
	ctx := context.Background()
	var ids []string
	for {
		job, err := store.ClaimRevocationJob(ctx, time.Now().Add(365*24*time.Hour))
		if err != nil {
			break
		}
		ids = append(ids, job.ID)
	}
	// Restore: fail each back to due-immediately (test-only clock games;
	// production uses real backoff).
	for _, id := range ids {
		if err := store.FailRevocationJob(ctx, id, "", time.Now()); err != nil {
			t.Fatalf("restore job %s: %v", id, err)
		}
	}
	return ids
}

// failApplyOnceStore injects one transient ApplyAppleConsentCutoff failure,
// then delegates. It proves a failed apply never poisons the delivery id.
type failApplyOnceStore struct {
	db.Store
	failNext bool
}

func (s *failApplyOnceStore) ApplyAppleConsentCutoff(ctx context.Context, sub string, t time.Time) (string, bool, error) {
	if s.failNext {
		s.failNext = false
		return "", false, errors.New("transient storage outage")
	}
	return s.Store.ApplyAppleConsentCutoff(ctx, sub, t)
}

func TestNotifications_TransientApplyFailureRetryStillApplies(t *testing.T) {
	realStore := newTestStore(t)
	verifier := fakeAppleVerifier{claims: apple.Claims{Sub: "apple-sub-flaky", Email: "r@privaterelay.appleid.com"}}
	h := newTestDeletionHandler(t, realStore, verifier, &fakeAppleClient{}, fakeAppleNotifs{})
	sess, _ := appleUserWithSession(t, h, realStore, "apple-sub-flaky", "r@privaterelay.appleid.com", "")

	// Swap in the flaky store AFTER signup: the first delivery's apply fails.
	store := &failApplyOnceStore{Store: realStore, failNext: true}
	h.store = store
	h.appleNotifs = fakeAppleNotifs{event: apple.NotificationEvent{
		Type: "consent-revoked", Sub: "apple-sub-flaky", JTI: "jti-flaky",
		EventTime: time.Now().Add(time.Minute), HasEventTime: true,
	}}

	// The failed apply is a 500 — and crucially NOT an acknowledgment: the
	// delivery id must not be recorded, so the retry still applies.
	if w := doNotifications(t, h, "signed-jws"); w.Code != http.StatusInternalServerError {
		t.Fatalf("failed apply must 500, got %d", w.Code)
	}
	if _, err := realStore.GetUserByID(context.Background(), sess.User.ID); err != nil {
		t.Fatalf("user must survive: %v", err)
	}
	stored, _ := realStore.GetUserByID(context.Background(), sess.User.ID)
	if stored.AppleConsentCutoff != nil {
		t.Fatal("failed apply must not move the cutoff")
	}

	// Same-JTI retry: applies the cutoff this time (no poisoned replay).
	if w := doNotifications(t, h, "signed-jws"); w.Code != http.StatusOK {
		t.Fatalf("retry must 200, got %d: %s", w.Code, w.Body.String())
	}
	stored, _ = realStore.GetUserByID(context.Background(), sess.User.ID)
	if stored.AppleConsentCutoff == nil || stored.AppleAuthLineage != nil {
		t.Fatalf("retry must apply the cutoff: %+v", stored)
	}
	body, _ := json.Marshal(map[string]string{"refresh_token": sess.RefreshToken})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/refresh", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Device-Id", testDevice)
	w := httptest.NewRecorder()
	h.RefreshToken(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("post-retry session must be cut, got %d", w.Code)
	}
}

func TestNotifications_UndatedConsentRevokedRejected(t *testing.T) {
	store := newTestStore(t)
	verifier := fakeAppleVerifier{claims: apple.Claims{Sub: "apple-sub-und", Email: "r@privaterelay.appleid.com"}}
	h := newTestDeletionHandler(t, store, verifier, &fakeAppleClient{}, fakeAppleNotifs{})
	sess, _ := appleUserWithSession(t, h, store, "apple-sub-und", "r@privaterelay.appleid.com", "")

	h.appleNotifs = fakeAppleNotifs{event: apple.NotificationEvent{
		Type: "consent-revoked", Sub: "apple-sub-und", JTI: "jti-undated",
		// No EventTime/HasEventTime: arrival time must never substitute.
	}}

	// Rejected with no state change and no receipt: not 200, not recorded.
	if w := doNotifications(t, h, "signed-jws"); w.Code != http.StatusBadRequest {
		t.Fatalf("undated revocation must 400, got %d", w.Code)
	}
	stored, err := store.GetUserByID(context.Background(), sess.User.ID)
	if err != nil {
		t.Fatalf("user must survive: %v", err)
	}
	if stored.AppleConsentCutoff != nil || stored.AppleAuthLineage == nil {
		t.Fatalf("rejected event must change nothing: %+v", stored)
	}
	// Still rejected on redelivery (no receipt was recorded for it).
	if w := doNotifications(t, h, "signed-jws"); w.Code != http.StatusBadRequest {
		t.Fatalf("redelivered undated event must still 400, got %d", w.Code)
	}

	// The session keeps working: nothing was cut.
	body, _ := json.Marshal(map[string]string{"refresh_token": sess.RefreshToken})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/auth/refresh", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Device-Id", testDevice)
	w := httptest.NewRecorder()
	h.RefreshToken(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("session must survive an undated event, got %d: %s", w.Code, w.Body.String())
	}
}
