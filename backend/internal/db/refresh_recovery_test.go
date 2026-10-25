package db

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/antonkosenko/shunik/backend/internal/migrations"
)

func newRecoveryTestStore(t *testing.T) *SQLiteStore {
	t.Helper()
	store, err := NewSQLiteStore(":memory:")
	if err != nil {
		t.Fatalf("NewSQLiteStore: %v", err)
	}
	if err := migrations.RunSQLite(context.Background(), store.DB()); err != nil {
		t.Fatalf("RunSQLite: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return store
}

func recoveryUser(t *testing.T, store *SQLiteStore, email string) (userID, tokenID string) {
	t.Helper()
	ctx := context.Background()
	u, err := store.UpsertUser(ctx, email)
	if err != nil {
		t.Fatalf("UpsertUser: %v", err)
	}
	if err := store.SaveRefreshToken(ctx, u.ID, "predecessor-hash", "device-A"); err != nil {
		t.Fatalf("SaveRefreshToken: %v", err)
	}
	stored, err := store.GetRefreshToken(ctx, "predecessor-hash")
	if err != nil {
		t.Fatalf("GetRefreshToken: %v", err)
	}
	return u.ID, stored.ID
}

func rotateOnce(t *testing.T, store *SQLiteStore, userID, predecessorID string) RotateResult {
	t.Helper()
	res, err := store.RotateRefreshToken(context.Background(), RotateArgs{
		UserID:          userID,
		DeviceID:        "device-A",
		PredecessorID:   predecessorID,
		PredecessorHash: "predecessor-hash",
		SuccessorHash:   "successor-hash",
		AttemptHash:     "attempt-hash",
		SealedSuccessor: []byte("sealed-successor"),
		ExpiresAt:       time.Now().Add(time.Hour),
	})
	if err != nil {
		t.Fatalf("RotateRefreshToken: %v", err)
	}
	return res
}

func TestRotate_CommitsPredecessorSuccessorAndReceipt(t *testing.T) {
	store := newRecoveryTestStore(t)
	ctx := context.Background()
	userID, predecessorID := recoveryUser(t, store, "rotate@example.com")

	res := rotateOnce(t, store, userID, predecessorID)
	if res.SuccessorID == "" {
		t.Fatal("expected a successor id")
	}
	if res.SuccessorCreatedAt.IsZero() {
		t.Error("expected a successor created_at")
	}

	pred, err := store.GetRefreshToken(ctx, "predecessor-hash")
	if err != nil {
		t.Fatalf("GetRefreshToken predecessor: %v", err)
	}
	if !pred.Revoked {
		t.Error("expected predecessor revoked after commit")
	}

	succ, err := store.GetRefreshToken(ctx, "successor-hash")
	if err != nil {
		t.Fatalf("GetRefreshToken successor: %v", err)
	}
	if succ.Revoked || succ.DeviceID != "device-A" {
		t.Errorf("expected live successor in device-A family, got %+v", succ)
	}

	receipt, err := store.FindRecoveryReceipt(ctx, "attempt-hash")
	if err != nil {
		t.Fatalf("FindRecoveryReceipt: %v", err)
	}
	if receipt.UserID != userID || receipt.DeviceID != "device-A" ||
		receipt.PredecessorHash != "predecessor-hash" || receipt.SuccessorHash != "successor-hash" {
		t.Errorf("receipt routing metadata mismatch: %+v", receipt)
	}
	if string(receipt.SealedSuccessor) != "sealed-successor" {
		t.Error("sealed successor must round-trip opaquely")
	}
	if receipt.Consumed {
		t.Error("fresh receipt must not be consumed")
	}
}

func TestRotate_DuplicateAttemptLosesWithoutTouchingFamily(t *testing.T) {
	store := newRecoveryTestStore(t)
	ctx := context.Background()
	userID, predecessorID := recoveryUser(t, store, "dupe@example.com")
	rotateOnce(t, store, userID, predecessorID)

	// A second predecessor races with the same attempt: the receipt insert
	// arbitrates and the loser gets ErrAttemptExists.
	if err := store.SaveRefreshToken(ctx, userID, "predecessor-2-hash", "device-A"); err != nil {
		t.Fatalf("SaveRefreshToken: %v", err)
	}
	second, err := store.GetRefreshToken(ctx, "predecessor-2-hash")
	if err != nil {
		t.Fatalf("GetRefreshToken: %v", err)
	}
	_, err = store.RotateRefreshToken(ctx, RotateArgs{
		UserID:          userID,
		DeviceID:        "device-A",
		PredecessorID:   second.ID,
		PredecessorHash: "predecessor-2-hash",
		SuccessorHash:   "successor-2-hash",
		AttemptHash:     "attempt-hash",
		SealedSuccessor: []byte("sealed-2"),
		ExpiresAt:       time.Now().Add(time.Hour),
	})
	if !errors.Is(err, ErrAttemptExists) {
		t.Fatalf("expected ErrAttemptExists, got %v", err)
	}

	// The loser's predecessor stays usable and no partial successor exists.
	again, err := store.GetRefreshToken(ctx, "predecessor-2-hash")
	if err != nil {
		t.Fatalf("GetRefreshToken: %v", err)
	}
	if again.Revoked {
		t.Error("loser predecessor must stay usable after ErrAttemptExists")
	}
	if _, err := store.GetRefreshToken(ctx, "successor-2-hash"); !errors.Is(err, ErrNotFound) {
		t.Errorf("no partial successor may persist, got %v", err)
	}
	// The winner's receipt is unchanged.
	receipt, err := store.FindRecoveryReceipt(ctx, "attempt-hash")
	if err != nil {
		t.Fatalf("FindRecoveryReceipt: %v", err)
	}
	if receipt.SuccessorHash != "successor-hash" {
		t.Errorf("winner receipt must stand, got %+v", receipt)
	}
}

func TestRotate_FailureBeforeCommitLeavesPredecessorUsable(t *testing.T) {
	store := newRecoveryTestStore(t)
	userID, predecessorID := recoveryUser(t, store, "crash@example.com")

	// A canceled context stands in for a crash before commit: the
	// transaction rolls back and nothing is persisted.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := store.RotateRefreshToken(ctx, RotateArgs{
		UserID:          userID,
		DeviceID:        "device-A",
		PredecessorID:   predecessorID,
		PredecessorHash: "predecessor-hash",
		SuccessorHash:   "successor-hash",
		AttemptHash:     "attempt-hash",
		SealedSuccessor: []byte("sealed"),
		ExpiresAt:       time.Now().Add(time.Hour),
	})
	if err == nil {
		t.Fatal("expected an error from the canceled context")
	}

	pred, err := store.GetRefreshToken(context.Background(), "predecessor-hash")
	if err != nil {
		t.Fatalf("GetRefreshToken: %v", err)
	}
	if pred.Revoked {
		t.Error("predecessor must stay usable when rotation fails before commit")
	}
	if _, err := store.FindRecoveryReceipt(context.Background(), "attempt-hash"); !errors.Is(err, ErrNotFound) {
		t.Errorf("no partial receipt may persist, got %v", err)
	}
	if _, err := store.GetRefreshToken(context.Background(), "successor-hash"); !errors.Is(err, ErrNotFound) {
		t.Errorf("no partial successor may persist, got %v", err)
	}
}

func TestRotate_ConsumesPredecessorReceipt(t *testing.T) {
	store := newRecoveryTestStore(t)
	ctx := context.Background()
	userID, predecessorID := recoveryUser(t, store, "consume@example.com")
	rotateOnce(t, store, userID, predecessorID)

	successor, err := store.GetRefreshToken(ctx, "successor-hash")
	if err != nil {
		t.Fatalf("GetRefreshToken: %v", err)
	}
	if _, err := store.RotateRefreshToken(ctx, RotateArgs{
		UserID:          userID,
		DeviceID:        "device-A",
		PredecessorID:   successor.ID,
		PredecessorHash: "successor-hash",
		SuccessorHash:   "successor-2-hash",
		AttemptHash:     "attempt-2-hash",
		SealedSuccessor: []byte("sealed-2"),
		ExpiresAt:       time.Now().Add(time.Hour),
	}); err != nil {
		t.Fatalf("second RotateRefreshToken: %v", err)
	}

	receipt, err := store.FindRecoveryReceipt(ctx, "attempt-hash")
	if err != nil {
		t.Fatalf("FindRecoveryReceipt: %v", err)
	}
	if !receipt.Consumed {
		t.Error("consuming the successor must close the predecessor receipt")
	}
}

func TestRevoke_ClosesReceipts(t *testing.T) {
	store := newRecoveryTestStore(t)
	ctx := context.Background()
	userID, predecessorID := recoveryUser(t, store, "revoke@example.com")
	rotateOnce(t, store, userID, predecessorID)

	if err := store.RevokeUserDeviceSessions(ctx, userID, "device-A"); err != nil {
		t.Fatalf("RevokeUserDeviceSessions: %v", err)
	}
	receipt, err := store.FindRecoveryReceipt(ctx, "attempt-hash")
	if err != nil {
		t.Fatalf("FindRecoveryReceipt: %v", err)
	}
	if !receipt.Consumed {
		t.Error("device revocation must close the device receipts")
	}
}

func TestRevokeAll_ClosesReceipts(t *testing.T) {
	store := newRecoveryTestStore(t)
	ctx := context.Background()
	userID, predecessorID := recoveryUser(t, store, "revoke-all@example.com")
	rotateOnce(t, store, userID, predecessorID)

	if err := store.RevokeAllUserSessions(ctx, userID); err != nil {
		t.Fatalf("RevokeAllUserSessions: %v", err)
	}
	receipt, err := store.FindRecoveryReceipt(ctx, "attempt-hash")
	if err != nil {
		t.Fatalf("FindRecoveryReceipt: %v", err)
	}
	if !receipt.Consumed {
		t.Error("all-user revocation must close the pending receipt")
	}
}

func TestRevokeSuccessor_ClosesPendingReceipt(t *testing.T) {
	store := newRecoveryTestStore(t)
	ctx := context.Background()
	userID, predecessorID := recoveryUser(t, store, "revoke-succ@example.com")
	res := rotateOnce(t, store, userID, predecessorID)

	// Revoking the successor by id (single-token revocation) must close
	// the pending receipt, so a replayed attempt cannot recreate it.
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

func TestFindRecoveryReceipt_NotFound(t *testing.T) {
	store := newRecoveryTestStore(t)
	if _, err := store.FindRecoveryReceipt(context.Background(), "no-such-attempt"); !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound, got %v", err)
	}
}

func TestRotate_ConsumedPredecessorFailsSingleUseGuard(t *testing.T) {
	store := newRecoveryTestStore(t)
	ctx := context.Background()
	userID, predecessorID := recoveryUser(t, store, "guard@example.com")
	rotateOnce(t, store, userID, predecessorID)

	// A second rotation citing the already-consumed predecessor with a
	// different attempt must fail closed: no fork, family untouched.
	_, err := store.RotateRefreshToken(ctx, RotateArgs{
		UserID:          userID,
		DeviceID:        "device-A",
		PredecessorID:   predecessorID,
		PredecessorHash: "predecessor-hash",
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
	if _, err := store.FindRecoveryReceipt(ctx, "attempt-other"); !errors.Is(err, ErrNotFound) {
		t.Errorf("no receipt may persist for the failed rotation, got %v", err)
	}
	succ, err := store.GetRefreshToken(ctx, "successor-hash")
	if err != nil {
		t.Fatalf("GetRefreshToken successor: %v", err)
	}
	if succ.Revoked {
		t.Error("the winner's successor must stay live after the guarded loss")
	}
}

func TestRotate_PrunesConsumedLongExpiredReceipts(t *testing.T) {
	store := newRecoveryTestStore(t)
	ctx := context.Background()
	userID, predecessorID := recoveryUser(t, store, "prune@example.com")
	rotateOnce(t, store, userID, predecessorID)

	// Consume the first receipt by rotating its successor forward, then age
	// it well past expiry.
	successor, err := store.GetRefreshToken(ctx, "successor-hash")
	if err != nil {
		t.Fatalf("GetRefreshToken: %v", err)
	}
	if _, err := store.RotateRefreshToken(ctx, RotateArgs{
		UserID:          userID,
		DeviceID:        "device-A",
		PredecessorID:   successor.ID,
		PredecessorHash: "successor-hash",
		SuccessorHash:   "successor-2-hash",
		AttemptHash:     "attempt-2-hash",
		SealedSuccessor: []byte("sealed-2"),
		ExpiresAt:       time.Now().Add(time.Hour),
	}); err != nil {
		t.Fatalf("second RotateRefreshToken: %v", err)
	}
	if _, err := store.DB().ExecContext(ctx, `
		UPDATE refresh_recovery_receipts
		SET expires_at = ?
		WHERE attempt_hash = ?
	`, fmtTime(time.Now().Add(-30*24*time.Hour)), "attempt-hash"); err != nil {
		t.Fatalf("age receipt: %v", err)
	}

	// A further rotation with a prune cutoff sweeps the ancient consumed
	// receipt but keeps the live one.
	third, err := store.GetRefreshToken(ctx, "successor-2-hash")
	if err != nil {
		t.Fatalf("GetRefreshToken: %v", err)
	}
	if _, err := store.RotateRefreshToken(ctx, RotateArgs{
		UserID:              userID,
		DeviceID:            "device-A",
		PredecessorID:       third.ID,
		PredecessorHash:     "successor-2-hash",
		SuccessorHash:       "successor-3-hash",
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
}
