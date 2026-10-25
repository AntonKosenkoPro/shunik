package db

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/antonkosenko/shunik/backend/internal/migrations"
)

// PostgreSQL parity suite (R-007 / 1.1-API-007): the same critical auth
// semantics the SQLite store is tested against (refresh rotation, revocation
// receipts, Apple fencing), executed against real PostgreSQL so SQLite-only
// CI cannot mask production behavior drift.
//
// Gated on TEST_PG_DSN — `make test:pg` sets it against docker-compose.
// When unset, every test here skips and `go test ./...` stays green offline.

func newParityStore(t *testing.T) *PostgresStore {
	t.Helper()
	dsn := os.Getenv("TEST_PG_DSN")
	if dsn == "" {
		t.Skip("TEST_PG_DSN not set — skipping PostgreSQL parity tests (make test:pg)")
	}

	ctx := context.Background()
	store, err := NewPostgresStore(ctx, dsn)
	if err != nil {
		t.Fatalf("NewPostgresStore: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })

	if err := migrations.RunPostgres(ctx, store.DB()); err != nil {
		t.Fatalf("RunPostgres: %v", err)
	}

	// Truncate for isolation (migrations run once per DB via schema_migrations).
	// The account-deletion tables carry cross-test state (the revocation
	// outbox has no FK to users, so users CASCADE never clears it; a
	// leftover job digest would fence the next test's signup), so they are
	// truncated explicitly.
	if _, err := store.DB().Exec(ctx, `
		TRUNCATE refresh_recovery_receipts, refresh_tokens, otp_codes, users,
		         apple_vault, apple_revocation_jobs, apple_notifications_seen RESTART IDENTITY CASCADE
	`); err != nil {
		t.Fatalf("truncate: %v", err)
	}
	return store
}

// TestPostgres_RotateRefreshToken_Atomic exercises the transactional
// rotation against real PostgreSQL: revoke + successor + receipt commit
// together, a duplicate attempt loses without touching the family, and
// device revocation closes the receipt.
func TestPostgres_RotateRefreshToken_Atomic(t *testing.T) {
	store := newParityStore(t)
	ctx := context.Background()

	u, err := store.UpsertUser(ctx, "pg-rotate@example.com")
	if err != nil {
		t.Fatalf("UpsertUser: %v", err)
	}
	if err := store.SaveRefreshToken(ctx, u.ID, "pred-hash", "device-A"); err != nil {
		t.Fatalf("SaveRefreshToken: %v", err)
	}
	pred, err := store.GetRefreshToken(ctx, "pred-hash")
	if err != nil {
		t.Fatalf("GetRefreshToken: %v", err)
	}

	res, err := store.RotateRefreshToken(ctx, RotateArgs{
		UserID:          u.ID,
		DeviceID:        "device-A",
		PredecessorID:   pred.ID,
		PredecessorHash: "pred-hash",
		SuccessorHash:   "succ-hash",
		AttemptHash:     "attempt-hash",
		SealedSuccessor: []byte("sealed"),
		ExpiresAt:       time.Now().Add(time.Hour),
	})
	if err != nil {
		t.Fatalf("RotateRefreshToken: %v", err)
	}
	if res.SuccessorID == "" || res.SuccessorCreatedAt.IsZero() {
		t.Errorf("expected a committed successor, got %+v", res)
	}

	receipt, err := store.FindRecoveryReceipt(ctx, "attempt-hash")
	if err != nil {
		t.Fatalf("FindRecoveryReceipt: %v", err)
	}
	if receipt.SuccessorHash != "succ-hash" || receipt.Consumed {
		t.Errorf("unexpected receipt: %+v", receipt)
	}

	// Duplicate attempt with another predecessor loses the race.
	if err := store.SaveRefreshToken(ctx, u.ID, "pred-2-hash", "device-A"); err != nil {
		t.Fatalf("SaveRefreshToken: %v", err)
	}
	pred2, err := store.GetRefreshToken(ctx, "pred-2-hash")
	if err != nil {
		t.Fatalf("GetRefreshToken: %v", err)
	}
	_, err = store.RotateRefreshToken(ctx, RotateArgs{
		UserID:          u.ID,
		DeviceID:        "device-A",
		PredecessorID:   pred2.ID,
		PredecessorHash: "pred-2-hash",
		SuccessorHash:   "succ-2-hash",
		AttemptHash:     "attempt-hash",
		SealedSuccessor: []byte("sealed-2"),
		ExpiresAt:       time.Now().Add(time.Hour),
	})
	if !errors.Is(err, ErrAttemptExists) {
		t.Fatalf("expected ErrAttemptExists, got %v", err)
	}
	if live, err := store.GetRefreshToken(ctx, "pred-2-hash"); err != nil || live.Revoked {
		t.Errorf("loser predecessor must stay usable, err=%v live=%+v", err, live)
	}

	// Device revocation closes the receipt.
	if err := store.RevokeUserDeviceSessions(ctx, u.ID, "device-A"); err != nil {
		t.Fatalf("RevokeUserDeviceSessions: %v", err)
	}
	receipt, err = store.FindRecoveryReceipt(ctx, "attempt-hash")
	if err != nil {
		t.Fatalf("FindRecoveryReceipt: %v", err)
	}
	if !receipt.Consumed {
		t.Error("device revocation must close the receipt")
	}
}

// TestPostgres_RotateRefreshToken_GuardAndPrune pins the round-1 review
// fixes against real PostgreSQL: the single-use predecessor guard rejects a
// rotation of an already-consumed predecessor (no fork), and the
// opportunistic sweep prunes consumed long-expired receipts only.
func TestPostgres_RotateRefreshToken_GuardAndPrune(t *testing.T) {
	store := newParityStore(t)
	ctx := context.Background()

	u, err := store.UpsertUser(ctx, "pg-guard-prune@example.com")
	if err != nil {
		t.Fatalf("UpsertUser: %v", err)
	}
	if err := store.SaveRefreshToken(ctx, u.ID, "pred-hash", "device-A"); err != nil {
		t.Fatalf("SaveRefreshToken: %v", err)
	}
	pred, err := store.GetRefreshToken(ctx, "pred-hash")
	if err != nil {
		t.Fatalf("GetRefreshToken: %v", err)
	}
	if _, err := store.RotateRefreshToken(ctx, RotateArgs{
		UserID:          u.ID,
		DeviceID:        "device-A",
		PredecessorID:   pred.ID,
		PredecessorHash: "pred-hash",
		SuccessorHash:   "succ-hash",
		AttemptHash:     "attempt-hash",
		SealedSuccessor: []byte("sealed"),
		ExpiresAt:       time.Now().Add(time.Hour),
	}); err != nil {
		t.Fatalf("RotateRefreshToken: %v", err)
	}

	// A second rotation citing the consumed predecessor with another
	// attempt must fail closed with ErrPredecessorRevoked: no fork.
	_, err = store.RotateRefreshToken(ctx, RotateArgs{
		UserID:          u.ID,
		DeviceID:        "device-A",
		PredecessorID:   pred.ID,
		PredecessorHash: "pred-hash",
		SuccessorHash:   "forked-hash",
		AttemptHash:     "attempt-other",
		SealedSuccessor: []byte("sealed-other"),
		ExpiresAt:       time.Now().Add(time.Hour),
	})
	if !errors.Is(err, ErrPredecessorRevoked) {
		t.Fatalf("expected ErrPredecessorRevoked, got %v", err)
	}
	if _, err := store.GetRefreshToken(ctx, "forked-hash"); !errors.Is(err, ErrNotFound) {
		t.Errorf("no forked successor may persist, got %v", err)
	}

	// Consume the first receipt, age it, and verify the next rotation
	// sweeps it while keeping the live receipt.
	succ, err := store.GetRefreshToken(ctx, "succ-hash")
	if err != nil {
		t.Fatalf("GetRefreshToken: %v", err)
	}
	if _, err := store.RotateRefreshToken(ctx, RotateArgs{
		UserID:          u.ID,
		DeviceID:        "device-A",
		PredecessorID:   succ.ID,
		PredecessorHash: "succ-hash",
		SuccessorHash:   "succ-2-hash",
		AttemptHash:     "attempt-2-hash",
		SealedSuccessor: []byte("sealed-2"),
		ExpiresAt:       time.Now().Add(time.Hour),
	}); err != nil {
		t.Fatalf("second RotateRefreshToken: %v", err)
	}
	if _, err := store.DB().Exec(ctx, `
		UPDATE refresh_recovery_receipts SET expires_at = $1
		WHERE attempt_hash = $2
	`, time.Now().Add(-30*24*time.Hour), "attempt-hash"); err != nil {
		t.Fatalf("age receipt: %v", err)
	}
	third, err := store.GetRefreshToken(ctx, "succ-2-hash")
	if err != nil {
		t.Fatalf("GetRefreshToken: %v", err)
	}
	if _, err := store.RotateRefreshToken(ctx, RotateArgs{
		UserID:              u.ID,
		DeviceID:            "device-A",
		PredecessorID:       third.ID,
		PredecessorHash:     "succ-2-hash",
		SuccessorHash:       "succ-3-hash",
		AttemptHash:         "attempt-3-hash",
		SealedSuccessor:     []byte("sealed-3"),
		ExpiresAt:           time.Now().Add(time.Hour),
		PruneConsumedBefore: time.Now(),
	}); err != nil {
		t.Fatalf("third RotateRefreshToken: %v", err)
	}
	if _, err := store.FindRecoveryReceipt(ctx, "attempt-hash"); !errors.Is(err, ErrNotFound) {
		t.Errorf("ancient consumed receipt must be pruned, got %v", err)
	}
	if _, err := store.FindRecoveryReceipt(ctx, "attempt-2-hash"); err != nil {
		t.Errorf("live receipt must survive pruning: %v", err)
	}

	// All-user revocation closes every pending receipt of the user.
	// ("attempt-hash" was already pruned above as consumed + long expired.)
	if err := store.RevokeAllUserSessions(ctx, u.ID); err != nil {
		t.Fatalf("RevokeAllUserSessions: %v", err)
	}
	for _, attempt := range []string{"attempt-2-hash", "attempt-3-hash"} {
		receipt, err := store.FindRecoveryReceipt(ctx, attempt)
		if err != nil {
			t.Fatalf("FindRecoveryReceipt %s: %v", attempt, err)
		}
		if !receipt.Consumed {
			t.Errorf("all-user revocation must close receipt %s", attempt)
		}
	}
}

// TestPostgres_RevokeSuccessor_ClosesPendingReceipt pins that revoking the
// successor by id closes its receipt, so a replayed attempt cannot
// recreate the session.
func TestPostgres_RevokeSuccessor_ClosesPendingReceipt(t *testing.T) {
	store := newParityStore(t)
	ctx := context.Background()

	u, err := store.UpsertUser(ctx, "pg-revoke-succ@example.com")
	if err != nil {
		t.Fatalf("UpsertUser: %v", err)
	}
	if err := store.SaveRefreshToken(ctx, u.ID, "pred-hash", "device-A"); err != nil {
		t.Fatalf("SaveRefreshToken: %v", err)
	}
	pred, err := store.GetRefreshToken(ctx, "pred-hash")
	if err != nil {
		t.Fatalf("GetRefreshToken: %v", err)
	}
	res, err := store.RotateRefreshToken(ctx, RotateArgs{
		UserID:          u.ID,
		DeviceID:        "device-A",
		PredecessorID:   pred.ID,
		PredecessorHash: "pred-hash",
		SuccessorHash:   "succ-hash",
		AttemptHash:     "attempt-hash",
		SealedSuccessor: []byte("sealed"),
		ExpiresAt:       time.Now().Add(time.Hour),
	})
	if err != nil {
		t.Fatalf("RotateRefreshToken: %v", err)
	}
	if err := store.RevokeRefreshToken(ctx, res.SuccessorID); err != nil {
		t.Fatalf("RevokeRefreshToken: %v", err)
	}
	receipt, err := store.FindRecoveryReceipt(ctx, "attempt-hash")
	if err != nil {
		t.Fatalf("FindRecoveryReceipt: %v", err)
	}
	if !receipt.Consumed {
		t.Error("single-token revocation of the successor must close its receipt")
	}
}

// TestPostgres_UpsertUserByAppleSubject exercises the SIWA upsert against real
// PostgreSQL: the conflict target must match the partial unique index
// (idx_users_apple_subject … WHERE apple_subject IS NOT NULL). Omitting the
// predicate fails with SQLSTATE 42P10 at runtime — a bug SQLite's
// INSERT OR IGNORE cannot reproduce.
func TestPostgres_UpsertUserByAppleSubject(t *testing.T) {
	store := newParityStore(t)
	ctx := context.Background()

	first, err := store.UpsertUserByAppleSubject(ctx, "apple-sub-parity", "relay@privaterelay.appleid.com")
	if err != nil {
		t.Fatalf("first upsert: %v", err)
	}
	if !first.EmailVerified {
		t.Error("expected email_verified=true on create")
	}

	// Same subject, email withheld (Apple's behavior on re-auth): same user,
	// original email retained, still verified.
	second, err := store.UpsertUserByAppleSubject(ctx, "apple-sub-parity", "")
	if err != nil {
		t.Fatalf("second upsert (conflict path): %v", err)
	}
	if second.ID != first.ID {
		t.Errorf("expected same user ID across sign-ins: %q vs %q", first.ID, second.ID)
	}
	if second.Email != first.Email {
		t.Errorf("expected retained email %q, got %q", first.Email, second.Email)
	}
	if !second.EmailVerified {
		t.Error("expected email_verified=true after conflict update")
	}
}
