package handlers

// Apple 400 bodies may echo request material, and DeleteAccount's inline
// revoke failure persists the error into revocation-job last_error (and
// logs it). This pins the end-to-end sink: a 400 echo from Apple must yield
// a 202 with a durable job whose last_error carries only the allowlisted
// code — never raw response bytes.

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/antonkosenko/time-of-life/backend/internal/apple"
)

const deletionEchoCanary = "CANARY-SECRET-handler-789"

// echoAppleServer 400s every Apple call with a body echoing the canary.
func echoAppleServer() *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":"invalid_grant","error_description":"token ` + deletionEchoCanary + ` echoed"}`))
	}))
}

func testRESTClient(t *testing.T, srv *httptest.Server) *apple.RESTClient {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	return apple.NewRESTClient("com.test.app", "TEAMID", "KEYID", key, srv.URL, "", nil)
}

func TestDeleteAccount_InlineRevokeFailureNeverPersistsEcho(t *testing.T) {
	store := newTestStore(t)
	exchanger := &fakeAppleClient{
		exchange: func(code string) (apple.TokenResponse, error) {
			return apple.TokenResponse{RefreshToken: "apple-refresh-" + code, IDToken: "exchanged-id"}, nil
		},
	}
	verifier := fakeAppleVerifier{claims: apple.Claims{Sub: "apple-sub-echo", Email: "r@privaterelay.appleid.com"}}
	h := newTestDeletionHandler(t, store, verifier, exchanger, fakeAppleNotifs{})

	// Vault-backed sign-in via the fake exchanger.
	sess, _ := appleUserWithSession(t, h, store, "apple-sub-echo", "r@privaterelay.appleid.com", "code-echo")

	// Swap the revoker for the echoing Apple server.
	srv := echoAppleServer()
	defer srv.Close()
	h.appleClient = testRESTClient(t, srv)

	w := doDeleteAccount(t, h, sess.AccessToken, testDevice)
	if w.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d: %s", w.Code, w.Body.String())
	}
	if strings.Contains(w.Body.String(), deletionEchoCanary) {
		t.Fatalf("LEAK: canary reached the 202 body: %s", w.Body.String())
	}

	// The durable job's last_error is the persisted sink: claim past the
	// inline grace period and inspect it.
	job, err := store.ClaimRevocationJob(t.Context(), time.Now().Add(3*time.Hour))
	if err != nil {
		t.Fatalf("ClaimRevocationJob: %v", err)
	}
	if strings.Contains(job.LastError, deletionEchoCanary) {
		t.Fatalf("LEAK: canary reached persisted last_error: %q", job.LastError)
	}
	if !strings.Contains(job.LastError, "invalid_grant") {
		t.Fatalf("expected allowlisted code in last_error, got %q", job.LastError)
	}
}
