package handlers

// Purge-precondition mapping: when the purge transaction aborts with
// ErrAppleCredentialMissing (vault lost between the pre-check and the purge),
// DELETE maps it to the same 409 apple_credential_required verdict as the
// pre-check — with the account intact and no purge committed.

import (
	"context"
	"net/http"
	"testing"

	"github.com/antonkosenko/time-of-life/backend/internal/apple"
	"github.com/antonkosenko/time-of-life/backend/internal/db"
)

// purgeMissingStore behaves like the real store except the purge aborts
// with the typed missing-credential error (the race under test).
type purgeMissingStore struct {
	db.Store
}

func (s purgeMissingStore) PurgeUser(_ context.Context, _, _ string, _ func(string) string) (db.PurgeResult, error) {
	return db.PurgeResult{}, db.ErrAppleCredentialMissing
}

func TestDeleteAccount_PurgeRaceMissingVaultIs409(t *testing.T) {
	store := newTestStore(t)
	client := &fakeAppleClient{
		exchange: func(code string) (apple.TokenResponse, error) {
			return apple.TokenResponse{RefreshToken: "apple-refresh-" + code, IDToken: "exchanged-id"}, nil
		},
	}
	verifier := fakeAppleVerifier{claims: apple.Claims{Sub: "apple-sub-race", Email: "r@privaterelay.appleid.com"}}
	h := newTestDeletionHandler(t, store, verifier, client, fakeAppleNotifs{})

	// Vault-backed session (passes the pre-check); the race then removes
	// the credential before the purge transaction runs.
	sess, _ := appleUserWithSession(t, h, store, "apple-sub-race", "r@privaterelay.appleid.com", "code-race")

	// Swap in the race: the vault the pre-check saw is gone by purge time.
	h.store = purgeMissingStore{Store: store}

	w := doDeleteAccount(t, h, sess.AccessToken, testDevice)
	if w.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d: %s", w.Code, w.Body.String())
	}
	if _, err := store.GetUserByID(context.Background(), sess.User.ID); err != nil {
		t.Fatalf("409 must leave the account intact: %v", err)
	}
}
