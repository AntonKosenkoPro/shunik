package db

// PostgreSQL parity for explicit account deletion (add-account-deletion).
// Gated on TEST_PG_DSN like the rest of the parity suite — skips offline.

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestPostgres_PurgeFenceCutoffParity(t *testing.T) {
	store := newParityStore(t)
	ctx := context.Background()

	now := time.Now()
	// The Apple identity owns this account (same pattern as the SQLite
	// seed, which binds the subject to the email row): creating a separate
	// email row first would collide on users_email_key, because neither
	// engine links an Apple subject onto an existing email account.
	user, err := store.UpsertAppleUser(ctx, "pg-sub", "pg-purge@example.com", "digest-pg", now)
	if err != nil {
		t.Fatalf("UpsertAppleUser: %v", err)
	}
	if err := store.SaveOTP(ctx, user.ID, "h", time.Now().Add(time.Hour), 5); err != nil {
		t.Fatalf("SaveOTP: %v", err)
	}
	if err := store.SaveRefreshTokenWithAuth(ctx, user.ID, "pred", "d1", &now, "lin-pg"); err != nil {
		t.Fatalf("Save: %v", err)
	}
	pred, err := store.GetRefreshToken(ctx, "pred")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	cat, _, err := store.CreateCategory(ctx, Category{ID: uuidV7(), UserID: user.ID, Name: "W", Icon: "tag"})
	if err != nil {
		t.Fatalf("CreateCategory: %v", err)
	}
	entry, _, err := store.CreateEntry(ctx, Entry{
		ID: uuidV7(), UserID: user.ID, ActivityText: "F",
		Categories: []CategoryTag{{ID: cat.ID}}, StartedAt: time.Now(),
	})
	if err != nil {
		t.Fatalf("CreateEntry: %v", err)
	}
	if err := store.DeleteEntry(ctx, user.ID, entry.ID); err != nil {
		t.Fatalf("DeleteEntry: %v", err)
	}

	// Apple identity + vault + lineage.
	if _, err := store.UpsertAppleUser(ctx, "pg-sub", "pg-purge@example.com", "digest-pg", now); err != nil {
		t.Fatalf("UpsertAppleUser: %v", err)
	}
	if err := store.SaveAppleCredential(ctx, AppleCredential{
		UserID: user.ID, SealedRefresh: []byte("sealed"), AuthTime: now, LineageID: "lin-pg",
	}); err != nil {
		t.Fatalf("SaveAppleCredential: %v", err)
	}
	if err := store.SetAppleSession(ctx, user.ID, now, "lin-pg"); err != nil {
		t.Fatalf("SetAppleSession: %v", err)
	}

	// Rotation inherits lineage on Postgres too.
	if _, err := store.RotateRefreshToken(ctx, RotateArgs{
		UserID: user.ID, DeviceID: "d1", PredecessorID: pred.ID, PredecessorHash: "pred",
		SuccessorHash: "succ", AttemptHash: "att", SealedSuccessor: []byte("s"),
		ExpiresAt: now.Add(time.Hour),
	}); err != nil {
		t.Fatalf("Rotate: %v", err)
	}
	succ, err := store.GetRefreshToken(ctx, "succ")
	if err != nil {
		t.Fatalf("Get successor: %v", err)
	}
	if succ.AuthLineage == nil || *succ.AuthLineage != "lin-pg" {
		t.Fatalf("successor must inherit lineage: %+v", succ)
	}

	// Cutoff applies; fenced upsert respects the fence only for jobs (no
	// job yet → passes). The cutoff erases the revoked lineage's vault row
	// by design, so a fresh post-cutoff authorization restores a revocable
	// credential under a new lineage (the handler's freshness gate owns
	// this minting in production).
	if _, applied, err := store.ApplyAppleConsentCutoff(ctx, "pg-sub", now.Add(time.Minute)); err != nil || !applied {
		t.Fatalf("cutoff: %v %v", applied, err)
	}
	fresh := now.Add(2 * time.Minute)
	if err := store.SetAppleSession(ctx, user.ID, fresh, "lin-pg-2"); err != nil {
		t.Fatalf("SetAppleSession: %v", err)
	}
	if err := store.SaveAppleCredential(ctx, AppleCredential{
		UserID: user.ID, SealedRefresh: []byte("sealed"), AuthTime: fresh, LineageID: "lin-pg-2",
	}); err != nil {
		t.Fatalf("SaveAppleCredential: %v", err)
	}

	res, err := store.PurgeUser(ctx, user.ID, "com.test.app", func(_ string) string { return "digest-pg" })
	if err != nil {
		t.Fatalf("PurgeUser: %v", err)
	}
	if !res.HadAppleIdentity || res.RevocationJobID == "" || res.AuthLineage != "lin-pg-2" {
		t.Fatalf("unexpected purge result: %+v", res)
	}

	// Every operational table is empty for the account; the user is gone.
	for _, q := range []string{
		`SELECT COUNT(*) FROM otp_codes WHERE user_id = $1`,
		`SELECT COUNT(*) FROM refresh_tokens WHERE user_id = $1`,
		`SELECT COUNT(*) FROM refresh_recovery_receipts WHERE user_id = $1`,
		`SELECT COUNT(*) FROM entries WHERE user_id = $1`,
		`SELECT COUNT(*) FROM categories WHERE user_id = $1`,
		`SELECT COUNT(*) FROM tombstones WHERE user_id = $1`,
		`SELECT COUNT(*) FROM apple_vault WHERE user_id = $1`,
	} {
		var n int
		if err := store.DB().QueryRow(ctx, q, user.ID).Scan(&n); err != nil {
			t.Fatalf("count: %v", err)
		}
		if n != 0 {
			t.Errorf("expected zero rows for %q, got %d", q, n)
		}
	}
	if _, err := store.GetUserByID(ctx, user.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected user gone: %v", err)
	}

	// Fence holds on Postgres; completing reopens.
	if _, err := store.UpsertAppleUser(ctx, "pg-sub", "x@example.com", "digest-pg", now); !errors.Is(err, ErrAppleRevocationPending) {
		t.Fatalf("expected fence, got %v", err)
	}
	job, err := store.ClaimRevocationJob(ctx, time.Now().Add(time.Hour))
	if err != nil || job.ID != res.RevocationJobID {
		t.Fatalf("claim: %+v %v", job, err)
	}
	if err := store.CompleteRevocationJob(ctx, job.ID); err != nil {
		t.Fatalf("complete: %v", err)
	}
	u2, err := store.UpsertAppleUser(ctx, "pg-sub", "x@example.com", "digest-pg", now)
	if err != nil {
		t.Fatalf("post-completion signup: %v", err)
	}
	if u2.ID == user.ID {
		t.Error("re-signup must mint a fresh UUID")
	}
}

// TestPostgres_AppleEmailCollisionIsTyped is the Postgres twin of the
// SQLite collision test: an Apple subject whose email belongs to a
// different account surfaces ErrAppleEmailInUse (never the race-path
// ErrNotFound), proving the users_email_key constraint mapping.
func TestPostgres_AppleEmailCollisionIsTyped(t *testing.T) {
	store := newParityStore(t)
	ctx := context.Background()
	now := time.Now()

	if _, err := store.UpsertUser(ctx, "pg-taken@example.com"); err != nil {
		t.Fatalf("UpsertUser: %v", err)
	}
	if _, err := store.UpsertAppleUser(ctx, "pg-sub-collide", "pg-taken@example.com", "digest-pg-collide", now); !errors.Is(err, ErrAppleEmailInUse) {
		t.Fatalf("expected ErrAppleEmailInUse, got %v", err)
	}
}

// TestPostgres_PurgeMissingVaultAborts is the Postgres twin of the SQLite
// precondition test: an Apple-identity account without a vault row aborts
// the purge with ErrAppleCredentialMissing, rolling everything back.
func TestPostgres_PurgeMissingVaultAborts(t *testing.T) {
	store := newParityStore(t)
	ctx := context.Background()

	now := time.Now()
	user, err := store.UpsertAppleUser(ctx, "pg-nocred", "pg-nocred@example.com", "digest-pg-nocred", now)
	if err != nil {
		t.Fatalf("UpsertAppleUser: %v", err)
	}
	if err := store.SaveOTP(ctx, user.ID, "h", now.Add(time.Hour), 5); err != nil {
		t.Fatalf("SaveOTP: %v", err)
	}

	if _, err := store.PurgeUser(ctx, user.ID, "com.test.app", func(_ string) string { return "digest-pg-nocred" }); !errors.Is(err, ErrAppleCredentialMissing) {
		t.Fatalf("expected ErrAppleCredentialMissing, got %v", err)
	}
	if _, err := store.GetUserByID(ctx, user.ID); err != nil {
		t.Fatalf("account must survive the aborted purge: %v", err)
	}
	var n int
	if err := store.DB().QueryRow(ctx, `SELECT COUNT(*) FROM otp_codes WHERE user_id = $1`, user.ID).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 1 {
		t.Errorf("expected the OTP row preserved, got %d", n)
	}
}
