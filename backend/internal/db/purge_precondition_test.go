package db

// Purge precondition regression: an Apple-identity account without a stored
// revocable credential (e.g. vault erased by a consent callback racing the
// handler's pre-check) must abort the purge — typed error, full rollback,
// account and operational rows intact — never a 204 with nothing to revoke.

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestPurge_MissingVaultAbortsApplePurge(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()

	now := time.Now()
	user, err := store.UpsertAppleUser(ctx, "apple-sub-nocred", "nocred@example.com", "digest-nocred", now)
	if err != nil {
		t.Fatalf("UpsertAppleUser: %v", err)
	}
	// Operational rows that a partial purge would destroy.
	if err := store.SaveOTP(ctx, user.ID, "h", now.Add(time.Hour), 5); err != nil {
		t.Fatalf("SaveOTP: %v", err)
	}
	if err := store.SaveRefreshTokenWithAuth(ctx, user.ID, "pred", "d1", &now, "lin"); err != nil {
		t.Fatalf("SaveRefreshToken: %v", err)
	}
	cat, _, err := store.CreateCategory(ctx, Category{ID: uuidV7(), UserID: user.ID, Name: "W", Icon: "tag"})
	if err != nil {
		t.Fatalf("CreateCategory: %v", err)
	}
	if _, _, err := store.CreateEntry(ctx, Entry{
		ID: uuidV7(), UserID: user.ID, ActivityText: "F",
		Categories: []CategoryTag{{ID: cat.ID}}, StartedAt: now,
	}); err != nil {
		t.Fatalf("CreateEntry: %v", err)
	}

	// Sanity: no vault row (identity-token-only history).
	if _, err := store.GetAppleCredential(ctx, user.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected empty vault, got %v", err)
	}

	if _, err := store.PurgeUser(ctx, user.ID, "com.test.app", func(_ string) string { return "digest-nocred" }); !errors.Is(err, ErrAppleCredentialMissing) {
		t.Fatalf("expected ErrAppleCredentialMissing, got %v", err)
	}

	// Rollback: the account and every operational row survive.
	if _, err := store.GetUserByID(ctx, user.ID); err != nil {
		t.Fatalf("account must survive the aborted purge: %v", err)
	}
	for table, want := range map[string]int{
		"otp_codes": 1, "refresh_tokens": 1, "entries": 1, "categories": 1,
	} {
		if n := countRows(t, store, table, user.ID); n != want {
			t.Errorf("expected %d %s rows preserved, got %d", want, table, n)
		}
	}
	if pending, err := store.HasPendingAppleRevocation(ctx, "digest-nocred"); err != nil || pending {
		t.Errorf("aborted purge must create no job, got %v %v", pending, err)
	}
}

// TestRotation_BlindsPendingJobFence pins the drain-first rotation rule at
// the store level: a revocation job recorded under one digest key is
// invisible to fence lookups under the rotated key, so the same subject
// could re-sign while its old revoke is still pending. Rotation while jobs
// are pending is therefore an operator error, not a supported rollover.
func TestRotation_BlindsPendingJobFence(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()

	now := time.Now()
	user, err := store.UpsertAppleUser(ctx, "apple-sub-rot", "rot@example.com", "digest-rot-v1", now)
	if err != nil {
		t.Fatalf("UpsertAppleUser: %v", err)
	}
	if err := store.SaveAppleCredential(ctx, AppleCredential{
		UserID: user.ID, SealedRefresh: []byte("s"), AuthTime: now, LineageID: "lin",
	}); err != nil {
		t.Fatalf("SaveAppleCredential: %v", err)
	}
	res, err := store.PurgeUser(ctx, user.ID, "com.test.app", func(_ string) string { return "digest-rot-v1" })
	if err != nil {
		t.Fatalf("PurgeUser: %v", err)
	}
	if res.RevocationJobID == "" {
		t.Fatal("expected a pending job")
	}

	// Under the rotated key the job is invisible: no pending revocation,
	// and the same subject re-signs instead of fencing.
	if pending, err := store.HasPendingAppleRevocation(ctx, "digest-rot-v2"); err != nil || pending {
		t.Fatalf("rotated digest must miss the v1 job, got %v %v", pending, err)
	}
	if _, err := store.UpsertAppleUser(ctx, "apple-sub-rot", "rot@example.com", "digest-rot-v2", now); err != nil {
		t.Fatalf("rotated digest bypasses the fence (drain-first required): %v", err)
	}

	// Sanity: the original digest still fences.
	if _, err := store.UpsertAppleUser(ctx, "apple-sub-rot", "rot@example.com", "digest-rot-v1", now); !errors.Is(err, ErrAppleRevocationPending) {
		t.Fatalf("original digest must still fence, got %v", err)
	}
}
