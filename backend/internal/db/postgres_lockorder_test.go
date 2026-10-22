package db

// Purge-vs-signup lock-ordering hammer: purge, fenced signup, and consent
// cutoff contend on the same Apple subject. All three take the subject
// advisory lock before the account row lock; any order inversion deadlocks
// (SQLSTATE 40P01) under contention. Fails loudly on deadlock signatures.

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

func TestPostgres_PurgeVsSignupLockOrder(t *testing.T) {
	store := newParityStore(t)
	ctx := context.Background()

	var uid atomic.Value
	now := time.Now()
	u, err := store.UpsertAppleUser(ctx, "hammer-sub", "hammer@example.com", "digest-hammer", now)
	if err != nil {
		t.Fatalf("setup upsert: %v", err)
	}
	uid.Store(u.ID)
	if err := store.SaveAppleCredential(ctx, AppleCredential{
		UserID: u.ID, SealedRefresh: []byte("sealed-hammer"), AuthTime: now, LineageID: "lin-h",
	}); err != nil {
		t.Fatalf("setup vault: %v", err)
	}

	var mu sync.Mutex
	var deadlockHits, unexpectedHits []string
	// Detect deadlocks the way production does (typed SQLSTATE via
	// errors.As on *pgconn.PgError, not substring matching), and record
	// anything else instead of swallowing it: call sites already filter
	// the tolerated sentinels (purge filters ErrNotFound and
	// ErrAppleCredentialMissing, upsert filters ErrAppleRevocationPending),
	// so whatever reaches note() is unexpected by construction.
	note := func(op string, err error) {
		if err == nil {
			return
		}
		var pgErr *pgconn.PgError
		mu.Lock()
		defer mu.Unlock()
		if errors.As(err, &pgErr) && (pgErr.Code == "40P01" || pgErr.Code == "40001") {
			deadlockHits = append(deadlockHits, op+": "+err.Error())
			return
		}
		unexpectedHits = append(unexpectedHits, op+": "+err.Error())
	}

	const rounds = 25
	for i := 0; i < rounds; i++ {
		id, _ := uid.Load().(string)
		var wg sync.WaitGroup
		wg.Add(3)
		go func() {
			defer wg.Done()
			_, err := store.PurgeUser(ctx, id, "com.test.app", func(_ string) string { return "digest-hammer" })
			if err != nil && !errors.Is(err, ErrNotFound) && !errors.Is(err, ErrAppleCredentialMissing) {
				note("purge", err)
			}
		}()
		go func() {
			defer wg.Done()
			nu, err := store.UpsertAppleUser(ctx, "hammer-sub", "hammer@example.com", "digest-hammer", time.Now())
			if err != nil {
				if !errors.Is(err, ErrAppleRevocationPending) {
					note("upsert", err)
				}
				return
			}
			uid.Store(nu.ID)
		}()
		go func() {
			defer wg.Done()
			_, _, err := store.ApplyAppleConsentCutoff(ctx, "hammer-sub", time.Now())
			note("cutoff", err)
		}()
		wg.Wait()

		// Reopen the fence + restore the vault so every round contends.
		// Only ErrNotFound ends the drain: a real claim error fails the
		// round instead of silently leaving a pending job behind.
		for {
			job, err := store.ClaimRevocationJob(ctx, time.Now().Add(time.Hour))
			if err != nil {
				if !errors.Is(err, ErrNotFound) {
					t.Errorf("claim during job reopen: %v", err)
				}
				break
			}
			if err := store.CompleteRevocationJob(ctx, job.ID); err != nil {
				t.Fatalf("complete: %v", err)
			}
		}
		if id2, ok := uid.Load().(string); ok {
			if _, err := store.GetUserByID(ctx, id2); errors.Is(err, ErrNotFound) {
				nu, err := store.UpsertAppleUser(ctx, "hammer-sub", "hammer@example.com", "digest-hammer", time.Now())
				if err != nil {
					if !errors.Is(err, ErrAppleRevocationPending) {
						t.Fatalf("recreate: %v", err)
					}
				} else {
					uid.Store(nu.ID)
				}
			}
		}
		// Re-seal a vault row for the surviving account (purge-needs-job path).
		if id3, ok := uid.Load().(string); ok {
			_ = store.SaveAppleCredential(ctx, AppleCredential{
				UserID: id3, SealedRefresh: []byte("sealed-hammer"), AuthTime: time.Now(), LineageID: "lin-h",
			})
		}
	}

	if len(deadlockHits) > 0 {
		t.Fatalf("deadlock detected (%d): %v", len(deadlockHits), deadlockHits[:min(3, len(deadlockHits))])
	}
	if len(unexpectedHits) > 0 {
		t.Fatalf("unexpected contention errors (%d): %v", len(unexpectedHits), unexpectedHits[:min(3, len(unexpectedHits))])
	}

	// No job leak. (A refresh_tokens orphan check would be vacuous here:
	// user_id is FK-bound to users in Postgres, so committed orphans are
	// impossible regardless of purge correctness — the only place state
	// can genuinely leak is the FK-free revocation outbox, asserted below.)
	var jobs int
	if err := store.DB().QueryRow(ctx, `SELECT COUNT(*) FROM apple_revocation_jobs WHERE subject_digest = 'digest-hammer'`).Scan(&jobs); err != nil {
		t.Fatalf("job leak check: %v", err)
	}
	if jobs != 0 {
		t.Errorf("job leak: %d", jobs)
	}
}
