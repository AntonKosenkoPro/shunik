package db

import (
	"context"
	"crypto/rand"
	"errors"
	"sync"
	"testing"
	"time"
)

// attachAppleSubject binds an Apple subject to an existing user (test-only
// stand-in for the fenced signup path covered in handler tests).
func attachAppleSubject(t *testing.T, store *SQLiteStore, userID, subject string) {
	t.Helper()
	if _, err := store.DB().ExecContext(context.Background(),
		`UPDATE users SET apple_subject = ? WHERE id = ?`, subject, userID); err != nil {
		t.Fatalf("attach apple subject: %v", err)
	}
}

// seedAccount builds a user with one of every associated operational row:
// OTP, refresh token + recovery receipt, category + entry + join, tombstone,
// and an Apple vault credential.
func seedAccount(t *testing.T, store *SQLiteStore, email, subject string) (userID string) {
	t.Helper()
	ctx := context.Background()

	user, err := store.UpsertUser(ctx, email)
	if err != nil {
		t.Fatalf("UpsertUser: %v", err)
	}
	if err := store.SaveOTP(ctx, user.ID, "hash", time.Now().Add(time.Hour), 5); err != nil {
		t.Fatalf("SaveOTP: %v", err)
	}
	if err := store.SaveRefreshToken(ctx, user.ID, "tokhash-"+email, "device-1"); err != nil {
		t.Fatalf("SaveRefreshToken: %v", err)
	}
	if _, err := store.RotateRefreshToken(ctx, RotateArgs{
		UserID: user.ID, DeviceID: "device-1", PredecessorID: mustTokenID(t, store, "tokhash-"+email),
		PredecessorHash: "tokhash-" + email, SuccessorHash: "successor-" + email,
		AttemptHash: "attempt-" + email, SealedSuccessor: []byte("sealed"), ExpiresAt: time.Now().Add(time.Hour),
	}); err != nil {
		t.Fatalf("RotateRefreshToken: %v", err)
	}

	cat, _, err := store.CreateCategory(ctx, Category{ID: uuidV7(), UserID: user.ID, Name: "Work-" + email, Icon: "tag"})
	if err != nil {
		t.Fatalf("CreateCategory: %v", err)
	}
	entry, _, err := store.CreateEntry(ctx, Entry{
		ID: uuidV7(), UserID: user.ID, ActivityText: "Focus",
		Categories: []CategoryTag{{ID: cat.ID}}, StartedAt: time.Now(),
	})
	if err != nil {
		t.Fatalf("CreateEntry: %v", err)
	}
	if err := store.DeleteEntry(ctx, user.ID, entry.ID); err != nil {
		t.Fatalf("DeleteEntry: %v", err)
	}

	var sealed [32]byte
	if _, err := rand.Read(sealed[:]); err != nil {
		t.Fatalf("rand: %v", err)
	}
	if subject != "" {
		attachAppleSubject(t, store, user.ID, subject)
		if err := store.SaveAppleCredential(ctx, AppleCredential{
			UserID: user.ID, SealedRefresh: sealed[:], AuthTime: time.Now(), LineageID: "lin-1",
		}); err != nil {
			t.Fatalf("SaveAppleCredential: %v", err)
		}
		if err := store.SetAppleSession(ctx, user.ID, time.Now(), "lin-1"); err != nil {
			t.Fatalf("SetAppleSession: %v", err)
		}
	}
	return user.ID
}

// countRows counts rows in a user-scoped table for assertions.
func countRows(t *testing.T, store *SQLiteStore, table, userID string) int {
	t.Helper()
	var n int
	if err := store.DB().QueryRow(`SELECT COUNT(*) FROM `+table+` WHERE user_id = ?`, userID).Scan(&n); err != nil {
		t.Fatalf("count %s: %v", table, err)
	}
	return n
}

func mustTokenID(t *testing.T, store *SQLiteStore, hash string) string {
	t.Helper()
	tok, err := store.GetRefreshToken(context.Background(), hash)
	if err != nil {
		t.Fatalf("GetRefreshToken: %v", err)
	}
	return tok.ID
}

// TestPurge_RemovesEveryOperationalRow verifies the atomic purge moves the
// vault credential into a job and deletes every other operational row while
// preserving a second account.
func TestPurge_RemovesEveryOperationalRow(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()

	keep := seedAccount(t, store, "keep@example.com", "")
	gone := seedAccount(t, store, "gone@example.com", "apple-sub-gone")

	// One surviving entry for the kept account (seed deletes its own entry
	// to leave a tombstone behind).
	if _, _, err := store.CreateEntry(ctx, Entry{
		ID: uuidV7(), UserID: keep, ActivityText: "Kept",
		StartedAt: time.Now(),
	}); err != nil {
		t.Fatalf("CreateEntry: %v", err)
	}

	// A live entry + join on the purged account proves join cleanup. The
	// seed's own entry was deleted before purge (leaving only its
	// tombstone), and an entry-side subquery cannot observe an orphaned
	// join (it only counts joins whose entry still exists) — so the join
	// count below runs from the category side, where a leaked join stays
	// visible. Categories stay FK-bound on both engines, which is the
	// schema-enforced backstop this count double-checks.
	liveCat, _, err := store.CreateCategory(ctx, Category{ID: uuidV7(), UserID: gone, Name: "Live", Icon: "tag"})
	if err != nil {
		t.Fatalf("CreateCategory: %v", err)
	}
	if _, _, err := store.CreateEntry(ctx, Entry{
		ID: uuidV7(), UserID: gone, ActivityText: "Live",
		Categories: []CategoryTag{{ID: liveCat.ID}}, StartedAt: time.Now(),
	}); err != nil {
		t.Fatalf("CreateEntry: %v", err)
	}

	res, err := store.PurgeUser(ctx, gone, "com.test.app", func(_ string) string { return "digest-apple-sub-gone" })
	if err != nil {
		t.Fatalf("PurgeUser: %v", err)
	}
	if !res.HadAppleIdentity || res.AppleSubject != "apple-sub-gone" {
		t.Fatalf("expected apple purge result, got %+v", res)
	}
	if res.RevocationJobID == "" || len(res.SealedAppleRefresh) == 0 || res.SubjectDigest != "digest-apple-sub-gone" {
		t.Fatalf("expected a populated revocation job, got %+v", res)
	}
	if res.AuthLineage != "lin-1" {
		t.Fatalf("expected job to carry the vault lineage, got %+v", res)
	}

	for _, table := range []string{"otp_codes", "refresh_tokens", "refresh_recovery_receipts", "entries", "categories", "tombstones"} {
		if n := countRows(t, store, table, gone); n != 0 {
			t.Errorf("expected zero %s rows for purged account, got %d", table, n)
		}
	}
	var joins int
	if err := store.DB().QueryRow(`SELECT COUNT(*) FROM entry_categories WHERE category_id IN (SELECT id FROM categories WHERE user_id = ?)`, gone).Scan(&joins); err != nil {
		t.Fatalf("count joins: %v", err)
	}
	if joins != 0 {
		t.Errorf("expected zero join rows, got %d", joins)
	}
	if _, err := store.GetUserByID(ctx, gone); !errors.Is(err, ErrNotFound) {
		t.Errorf("expected user gone, got %v", err)
	}
	if _, err := store.GetAppleCredential(ctx, gone); !errors.Is(err, ErrNotFound) {
		t.Errorf("expected vault gone, got %v", err)
	}
	// The other account is fully intact.
	if _, err := store.GetUserByID(ctx, keep); err != nil {
		t.Errorf("second account must survive: %v", err)
	}
	for _, table := range []string{"otp_codes", "refresh_tokens", "entries", "categories", "tombstones"} {
		if n := countRows(t, store, table, keep); n == 0 {
			t.Errorf("expected %s rows preserved for the surviving account", table)
		}
	}

	// Second purge is a clean NotFound (idempotent, no partial state).
	if _, err := store.PurgeUser(ctx, gone, "com.test.app", func(_ string) string { return "x" }); !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound on re-purge, got %v", err)
	}
}

// TestPurge_EmailAccountSkipsAppleWork verifies email-only purges complete
// without jobs.
func TestPurge_EmailAccountSkipsAppleWork(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	gone := seedAccount(t, store, "mail@example.com", "")

	res, err := store.PurgeUser(ctx, gone, "", func(_ string) string { return "x" })
	if err != nil {
		t.Fatalf("PurgeUser: %v", err)
	}
	if res.HadAppleIdentity || res.RevocationJobID != "" {
		t.Fatalf("email purge must not create apple work: %+v", res)
	}
}

// TestPurge_RaceWithWriteLeavesNoOrphans runs purge against concurrent
// catalog writes: the single-writer store serializes them, and the final
// state holds rows for exactly one outcome (written-then-purged, or
// rejected/never-written). Committed orphans are impossible here by schema:
// categories.user_id REFERENCES users(id) is FK-enforced (PRAGMA
// foreign_keys = ON in SQLite, native enforcement in Postgres), so this
// count is a documented schema-enforced tripwire, not a purge-correctness
// proof — it stays green regardless. The test's real value is the race
// itself: purge and writes serialize with no deadlock, panic, or partial
// transaction left behind.
func TestPurge_RaceWithWriteLeavesNoOrphans(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	user, err := store.UpsertUser(ctx, "race@example.com")
	if err != nil {
		t.Fatalf("UpsertUser: %v", err)
	}

	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _, _ = store.CreateCategory(ctx, Category{ID: uuidV7(), UserID: user.ID, Name: "R" + uuidV7(), Icon: "tag"})
		}()
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		_, _ = store.PurgeUser(ctx, user.ID, "", func(_ string) string { return "x" })
	}()
	wg.Wait()

	var orphans int
	if err := store.DB().QueryRow(`SELECT COUNT(*) FROM categories WHERE user_id NOT IN (SELECT id FROM users)`).Scan(&orphans); err != nil {
		t.Fatalf("orphan check: %v", err)
	}
	if orphans != 0 {
		t.Errorf("expected no orphan categories, got %d", orphans)
	}
}

// TestFencedUpsert_RejectsEmailOfAnotherAccount verifies identities are
// never merged: an Apple subject signing in with an email that already
// belongs to a different account (OTP or another Apple subject) fails with
// ErrAppleEmailInUse — never a silent no-op, never the race-path ErrNotFound.
func TestFencedUpsert_RejectsEmailOfAnotherAccount(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()

	if _, err := store.UpsertUser(ctx, "taken@example.com"); err != nil {
		t.Fatalf("UpsertUser: %v", err)
	}
	if _, err := store.UpsertAppleUser(ctx, "apple-sub-new", "taken@example.com", "digest-new", time.Now()); !errors.Is(err, ErrAppleEmailInUse) {
		t.Fatalf("expected ErrAppleEmailInUse, got %v", err)
	}

	// Same-subject re-signin with its own email still works.
	u1, err := store.UpsertAppleUser(ctx, "apple-sub-same", "same@example.com", "digest-same", time.Now())
	if err != nil {
		t.Fatalf("UpsertAppleUser: %v", err)
	}
	u2, err := store.UpsertAppleUser(ctx, "apple-sub-same", "same@example.com", "digest-same", time.Now())
	if err != nil {
		t.Fatalf("re-signin: %v", err)
	}
	if u1.ID != u2.ID {
		t.Errorf("re-signin must return the same user, got %v vs %v", u1.ID, u2.ID)
	}
}

// TestFence_BlocksSignupWhileJobPending verifies the same-subject signup
// fence end to end: purge with a stored credential, failed revoke path
// implied, then UpsertAppleUser refuses until the job completes.
func TestFence_BlocksSignupWhileJobPending(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	gone := seedAccount(t, store, "fenced@example.com", "apple-sub-fence")
	digest := "digest-fence"

	res, err := store.PurgeUser(ctx, gone, "com.test.app", func(_ string) string { return digest })
	if err != nil {
		t.Fatalf("PurgeUser: %v", err)
	}
	if res.RevocationJobID == "" {
		t.Fatal("expected a pending job")
	}
	pending, err := store.HasPendingAppleRevocation(ctx, digest)
	if err != nil || !pending {
		t.Fatalf("expected pending job, got %v, %v", pending, err)
	}

	if _, err := store.UpsertAppleUser(ctx, "apple-sub-fence", "new@example.com", digest, time.Now()); !errors.Is(err, ErrAppleRevocationPending) {
		t.Fatalf("expected ErrAppleRevocationPending, got %v", err)
	}

	// A different subject is unaffected.
	u, err := store.UpsertAppleUser(ctx, "apple-sub-other", "other@example.com", "digest-other", time.Now())
	if err != nil {
		t.Fatalf("unrelated subject must pass the fence: %v", err)
	}
	if u.AppleSubject == nil || u.AppleAuthLineage == nil {
		t.Fatalf("fenced upsert must return lineage, got %+v", u)
	}

	// Completing the job reopens the subject.
	if err := store.CompleteRevocationJob(ctx, res.RevocationJobID); err != nil {
		t.Fatalf("Complete: %v", err)
	}
	u2, err := store.UpsertAppleUser(ctx, "apple-sub-fence", "new@example.com", digest, time.Now())
	if err != nil {
		t.Fatalf("subject must pass after completion: %v", err)
	}
	if u2.ID == gone {
		t.Error("re-signup must mint a fresh UUID, never restore the purged one")
	}
}

// TestCutoff_InvalidatesLineagesIdempotently covers ApplyAppleConsentCutoff:
// cutoff advances, lineage nulls, vault of the revoked lineage is erased,
// stale events are ignored, missing users are no-ops.
func TestCutoff_InvalidatesLineagesIdempotently(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	userID := seedAccount(t, store, "cut@example.com", "apple-sub-cut")

	// The revocation genuinely postdates the recorded authorization.
	t1 := time.Now().Add(time.Minute).UTC()
	t2 := t1.Add(time.Minute)
	gotID, applied, err := store.ApplyAppleConsentCutoff(ctx, "apple-sub-cut", t1)
	if err != nil || !applied || gotID != userID {
		t.Fatalf("cutoff: %v %v %v", gotID, applied, err)
	}
	u, err := store.GetUserByID(ctx, userID)
	if err != nil {
		t.Fatalf("GetUserByID: %v", err)
	}
	if u.AppleConsentCutoff == nil || u.AppleAuthLineage != nil {
		t.Fatalf("expected cutoff set + lineage nulled, got %+v", u)
	}
	if _, err := store.GetAppleCredential(ctx, userID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("revoked-lineage vault must be erased: %v", err)
	}

	// Stale event: ignored, returns the user without applying.
	if _, applied, err := store.ApplyAppleConsentCutoff(ctx, "apple-sub-cut", t1.Add(-time.Minute)); err != nil || applied {
		t.Fatalf("stale event must be ignored: %v %v", err, applied)
	}
	// A delayed first event — older than the latest recorded authorization
	// but newer than the cutoff — still advances the cutoff (so pre-event
	// sessions die by per-session comparison) while preserving the newer
	// lineage and vault (so a fresh grant authorized after the event but
	// before the delayed callback survives). This replaces the old
	// full-no-op causality guard: the replacement account it meant to
	// protect stays signed in through preservation, not through ignoring
	// the event.
	freshUser, err := store.UpsertAppleUser(ctx, "apple-sub-fresh2", "fresh2@example.com", "digest-fresh2", time.Now())
	if err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if freshUser.AppleAuthTime == nil {
		t.Fatal("expected auth time stamped")
	}
	delayed := freshUser.AppleAuthTime.Add(-time.Minute)
	if _, applied, err := store.ApplyAppleConsentCutoff(ctx, "apple-sub-fresh2", delayed); err != nil || !applied {
		t.Fatalf("delayed first event must advance the cutoff: %v %v", err, applied)
	}
	after, err := store.GetUserByID(ctx, freshUser.ID)
	if err != nil {
		t.Fatalf("GetUserByID: %v", err)
	}
	if after.AppleConsentCutoff == nil {
		t.Fatalf("cutoff must advance to the delayed event: %+v", after)
	}
	if after.AppleAuthLineage == nil {
		t.Fatalf("newer lineage must be preserved: %+v", after)
	}
	// Newer event advances.
	if _, applied, err := store.ApplyAppleConsentCutoff(ctx, "apple-sub-cut", t2); err != nil || !applied {
		t.Fatalf("newer event must apply: %v %v", err, applied)
	}
	// Missing user: no-op.
	if id, applied, err := store.ApplyAppleConsentCutoff(ctx, "ghost-sub", t2); err != nil || applied || id != "" {
		t.Fatalf("missing user must be a no-op: %v %v %v", id, applied, err)
	}
}

// TestJobs_ClaimCompleteFailCycle covers the worker-facing job lifecycle.
func TestJobs_ClaimCompleteFailCycle(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	gone := seedAccount(t, store, "job@example.com", "apple-sub-job")

	res, err := store.PurgeUser(ctx, gone, "com.test.app", func(_ string) string { return "digest-job" })
	if err != nil {
		t.Fatalf("PurgeUser: %v", err)
	}

	// The purge grace period keeps the job undue for the worker's first pass.
	if _, err := store.ClaimRevocationJob(ctx, time.Now()); !errors.Is(err, ErrNotFound) {
		t.Fatalf("job must not be due inside the grace period: %v", err)
	}
	job, err := store.ClaimRevocationJob(ctx, time.Now().Add(3*time.Minute))
	if err != nil {
		t.Fatalf("Claim: %v", err)
	}
	if job.ID != res.RevocationJobID || len(job.SealedRefresh) == 0 || job.ClientID != "com.test.app" {
		t.Fatalf("unexpected claim: %+v", job)
	}
	if job.AuthLineage != "lin-1" {
		t.Fatalf("job must carry the vault lineage, got %+v", job)
	}
	// Second claim finds nothing (lease held).
	if _, err := store.ClaimRevocationJob(ctx, time.Now().Add(3*time.Minute)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("claimed job must not double-deliver: %v", err)
	}
	// Fail reschedules with backoff; complete removes.
	next := time.Now().Add(time.Hour)
	if err := store.FailRevocationJob(ctx, job.ID, "apple down", next); err != nil {
		t.Fatalf("Fail: %v", err)
	}
	if _, err := store.ClaimRevocationJob(ctx, time.Now().Add(3*time.Minute)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("failed job must wait for backoff: %v", err)
	}
	job2, err := store.ClaimRevocationJob(ctx, next.Add(time.Minute))
	if err != nil {
		t.Fatalf("re-claim after backoff: %v", err)
	}
	if job2.Attempts != job.Attempts+1 {
		t.Fatalf("attempts must increment, got %+v after %+v", job2, job)
	}
	// Crashed-worker recovery: a claim that is neither failed nor completed
	// must redeliver once its lease expires, never wedging the outbox (a
	// wedged outbox would also keep the same-subject signup fence closed
	// indefinitely). No wall-clock tuning: the expiry is the claim-time
	// lease constant plus one minute.
	orphaned, err := store.ClaimRevocationJob(ctx, next.Add(time.Minute).Add(claimLease))
	if err != nil {
		t.Fatalf("redelivery after expired lease: %v", err)
	}
	if orphaned.ID != job2.ID || orphaned.Attempts != job2.Attempts+1 {
		t.Fatalf("expired lease must redeliver the abandoned job, got %+v after %+v", orphaned, job2)
	}
	if err := store.CompleteRevocationJob(ctx, job.ID); err != nil {
		t.Fatalf("Complete: %v", err)
	}
	if _, err := store.ClaimRevocationJob(ctx, next.Add(48*time.Hour)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("completed job must be gone: %v", err)
	}
	// Completing again is idempotent.
	if err := store.CompleteRevocationJob(ctx, job.ID); err != nil {
		t.Fatalf("double complete must succeed: %v", err)
	}
}

// TestNotifications_ReplayGuard verifies the jti log: first record ok,
// duplicate → ErrNotificationReplay, unrelated jtis unaffected.
func TestNotifications_ReplayGuard(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	if err := store.RecordAppleNotification(ctx, "jti-a"); err != nil {
		t.Fatalf("record: %v", err)
	}
	if err := store.RecordAppleNotification(ctx, "jti-a"); !errors.Is(err, ErrNotificationReplay) {
		t.Fatalf("expected replay error, got %v", err)
	}
	if err := store.RecordAppleNotification(ctx, "jti-b"); err != nil {
		t.Fatalf("distinct jti must record: %v", err)
	}
}

// TestRotate_InheritsLineageAndFencesMissingUser pins the rotation contract:
// the successor copies the predecessor lineage in-transaction, and rotation
// for a purged account fails with ErrUserMissing (no orphan successor).
func TestRotate_InheritsLineageAndFencesMissingUser(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	user, err := store.UpsertUser(ctx, "rot@example.com")
	if err != nil {
		t.Fatalf("UpsertUser: %v", err)
	}
	now := time.Now()
	lineage := "lin-rot"
	if err := store.SaveRefreshTokenWithAuth(ctx, user.ID, "pred", "d1", &now, lineage); err != nil {
		t.Fatalf("Save: %v", err)
	}
	pred, err := store.GetRefreshToken(ctx, "pred")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if pred.AuthLineage == nil || *pred.AuthLineage != lineage {
		t.Fatalf("expected lineage round-trip, got %+v", pred)
	}
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
	if succ.AuthLineage == nil || *succ.AuthLineage != lineage {
		t.Fatalf("successor must inherit lineage, got %+v", succ)
	}

	if _, err := store.PurgeUser(ctx, user.ID, "", func(_ string) string { return "x" }); err != nil {
		t.Fatalf("Purge: %v", err)
	}
	if _, err := store.RotateRefreshToken(ctx, RotateArgs{
		UserID: user.ID, DeviceID: "d1", PredecessorID: pred.ID, PredecessorHash: "pred",
		SuccessorHash: "succ2", AttemptHash: "att2", SealedSuccessor: []byte("s"),
		ExpiresAt: now.Add(time.Hour),
	}); !errors.Is(err, ErrUserMissing) {
		t.Fatalf("expected ErrUserMissing after purge, got %v", err)
	}
	var orphans int
	if err := store.DB().QueryRow(`SELECT COUNT(*) FROM refresh_tokens WHERE user_id NOT IN (SELECT id FROM users)`).Scan(&orphans); err != nil {
		t.Fatalf("orphan check: %v", err)
	}
	if orphans != 0 {
		t.Errorf("no orphan refresh rows allowed, got %d", orphans)
	}
}

// TestVault_UpsertAndSession covers the vault/session primitives.
func TestVault_UpsertAndSession(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	user, err := store.UpsertUser(ctx, "vault@example.com")
	if err != nil {
		t.Fatalf("UpsertUser: %v", err)
	}
	if _, err := store.GetAppleCredential(ctx, user.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("empty vault must 404, got %v", err)
	}
	now := time.Now()
	if err := store.SaveAppleCredential(ctx, AppleCredential{UserID: user.ID, SealedRefresh: []byte("s1"), AuthTime: now, LineageID: "l1"}); err != nil {
		t.Fatalf("Save: %v", err)
	}
	if err := store.SaveAppleCredential(ctx, AppleCredential{UserID: user.ID, SealedRefresh: []byte("s2"), AuthTime: now, LineageID: "l2"}); err != nil {
		t.Fatalf("re-save must upsert: %v", err)
	}
	cred, err := store.GetAppleCredential(ctx, user.ID)
	if err != nil || string(cred.SealedRefresh) != "s2" || cred.LineageID != "l2" {
		t.Fatalf("expected upserted credential, got %+v %v", cred, err)
	}
	if err := store.SetAppleSession(ctx, user.ID, now, "l9"); err != nil {
		t.Fatalf("SetAppleSession: %v", err)
	}
	u, err := store.GetUserByID(ctx, user.ID)
	if err != nil || u.AppleAuthLineage == nil || *u.AppleAuthLineage != "l9" {
		t.Fatalf("expected lineage l9, got %+v %v", u, err)
	}
}

// TestFencedUpsert_MintsLineageUnlessCutoff pins the review-driven rule: the
// store mints a lineage only for cutoff-free accounts; a set cutoff leaves
// it NULL for the handler's freshness gate.
func TestFencedUpsert_MintsLineageUnlessCutoff(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	u, err := store.UpsertAppleUser(ctx, "sub-fresh", "f@example.com", "digest-fresh", time.Now())
	if err != nil {
		t.Fatalf("UpsertAppleUser: %v", err)
	}
	if u.AppleAuthLineage == nil || *u.AppleAuthLineage == "" {
		t.Fatalf("fresh apple user must carry a lineage: %+v", u)
	}
	// Second sign-in preserves the lineage (multi-device safety).
	u2, err := store.UpsertAppleUser(ctx, "sub-fresh", "changed@example.com", "digest-fresh", time.Now())
	if err != nil {
		t.Fatalf("re-upsert: %v", err)
	}
	if u2.ID != u.ID || *u2.AppleAuthLineage != *u.AppleAuthLineage {
		t.Fatalf("re-upsert must preserve UUID and lineage: %+v vs %+v", u2, u)
	}
	if u2.Email != "f@example.com" {
		t.Fatalf("first-seen email must win, got %q", u2.Email)
	}

	// With a cutoff set, no lineage is minted: the handler's freshness gate
	// owns minting past revocation (a pre-revocation token must not mint).
	if _, _, err := store.ApplyAppleConsentCutoff(ctx, "sub-fresh", time.Now()); err != nil {
		t.Fatalf("cutoff: %v", err)
	}
	u3, err := store.UpsertAppleUser(ctx, "sub-fresh", "f@example.com", "digest-fresh", time.Now())
	if err != nil {
		t.Fatalf("upsert under cutoff: %v", err)
	}
	if u3.AppleAuthLineage != nil {
		t.Fatalf("upsert under cutoff must not mint lineage: %+v", u3)
	}
}
