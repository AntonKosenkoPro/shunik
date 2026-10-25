package db

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// purgeJobGracePeriod is the initial next_attempt_at for a revocation job
// created by PurgeUser. The DELETE handler attempts the revoke inline first;
// the worker picks the job up after this grace unless the handler already
// completed or rescheduled it. Immediate due would race a concurrent worker
// claim against the handler's inline attempt (harmless but noisy); the grace
// gives the inline path first shot while surviving a handler crash.
const purgeJobGracePeriod = 2 * time.Minute

// claimLease is how far ClaimRevocationJob pushes next_attempt_at into the
// future when handing a job out. A crashed claimant therefore redelivers the
// job after the lease instead of wedging it, and two workers cannot act on
// the same job concurrently.
const claimLease = 5 * time.Minute

// isRetryableTxnError reports Postgres serialization/deadlock failures worth
// one retry cycle (purge races a concurrent write on the same account row).
func isRetryableTxnError(err error) bool {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return false
	}
	return pgErr.Code == "40001" || pgErr.Code == "40P01"
}

// lockAppleSubject serializes purge/job-creation against fenced Apple
// signup for the same Apple subject. Advisory locks are session-scoped, so
// the xact variant releases automatically at commit/rollback.
func lockAppleSubject(ctx context.Context, tx pgx.Tx, subject string) error {
	_, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, subject)
	return err
}

// SaveAppleCredential upserts the encrypted Apple revocable credential for
// an Apple user. Only the sealed blob plus routing metadata persist.
func (s *PostgresStore) SaveAppleCredential(ctx context.Context, cred AppleCredential) error {
	_, err := s.pool.Exec(ctx, `
		INSERT INTO apple_vault (user_id, sealed_refresh, auth_time, lineage_id, created_at, updated_at)
		VALUES ($1, $2, $3, $4, NOW(), NOW())
		ON CONFLICT (user_id) DO UPDATE
			SET sealed_refresh = EXCLUDED.sealed_refresh,
			    auth_time = EXCLUDED.auth_time,
			    lineage_id = EXCLUDED.lineage_id,
			    updated_at = NOW()
	`, cred.UserID, cred.SealedRefresh, cred.AuthTime, cred.LineageID)
	if err != nil {
		return fmt.Errorf("save apple credential: %w", err)
	}
	return nil
}

// GetAppleCredential returns the stored Apple credential for a user.
func (s *PostgresStore) GetAppleCredential(ctx context.Context, userID string) (AppleCredential, error) {
	var c AppleCredential
	err := s.pool.QueryRow(ctx, `
		SELECT user_id, sealed_refresh, auth_time, lineage_id, created_at, updated_at
		FROM apple_vault
		WHERE user_id = $1
	`, userID).Scan(&c.UserID, &c.SealedRefresh, &c.AuthTime, &c.LineageID, &c.CreatedAt, &c.UpdatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return AppleCredential{}, fmt.Errorf("get apple credential: %w", ErrNotFound)
		}
		return AppleCredential{}, fmt.Errorf("get apple credential: %w", err)
	}
	return c, nil
}

// SetAppleSession stamps the account's latest completed Apple authorization.
func (s *PostgresStore) SetAppleSession(ctx context.Context, userID string, authTime time.Time, lineageID string) error {
	_, err := s.pool.Exec(ctx, `
		UPDATE users SET apple_auth_time = $2, apple_auth_lineage = $3 WHERE id = $1
	`, userID, authTime, lineageID)
	if err != nil {
		return fmt.Errorf("set apple session: %w", err)
	}
	return nil
}

// UpsertAppleUser fences and upserts an Apple identity in one transaction.
// subjectDigest is the HMAC-SHA256 digest of appleSubject under the
// purpose-separated digest key (computed by the handler layer — the store
// never sees the derivation secret, only the digest domain). A pending
// revocation job for the same digest refuses the signup with
// ErrAppleRevocationPending before any user row is touched; otherwise the
// user is upserted and guaranteed a non-empty auth lineage (minted when
// absent, preserved across devices when present so one device's sign-in
// never kills another's sessions).
func (s *PostgresStore) UpsertAppleUser(ctx context.Context, appleSubject, email, subjectDigest string, authTime time.Time) (User, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return User{}, fmt.Errorf("upsert apple user: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if err := lockAppleSubject(ctx, tx, appleSubject); err != nil {
		return User{}, fmt.Errorf("upsert apple user: %w", err)
	}

	if fenced, err := txHasPendingRevocation(ctx, tx, subjectDigest); err != nil {
		return User{}, err
	} else if fenced {
		return User{}, fmt.Errorf("upsert apple user: %w", ErrAppleRevocationPending)
	}

	var u User
	err = tx.QueryRow(ctx, `
		INSERT INTO users (id, email, email_verified, created_at, apple_subject)
		VALUES (gen_random_uuid(), $1, true, NOW(), $2)
		ON CONFLICT (apple_subject) WHERE apple_subject IS NOT NULL DO UPDATE
			SET email_verified = true
		RETURNING `+pgUserColumns+`
	`, email, appleSubject).Scan(&u.ID, &u.Email, &u.EmailVerified, &u.CreatedAt,
		&u.AppleSubject, &u.AppleAuthTime, &u.AppleAuthLineage, &u.AppleConsentCutoff)
	if err != nil {
		// An email UNIQUE violation here means the presented Apple email
		// belongs to a different account: identities are never merged.
		// Surface it as its own sentinel (never the race-path ErrNotFound)
		// so the handler can map a defined client error.
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" &&
			pgErr.ConstraintName == "users_email_key" {
			return User{}, fmt.Errorf("upsert apple user: %w", ErrAppleEmailInUse)
		}
		if errors.Is(err, pgx.ErrNoRows) {
			return User{}, fmt.Errorf("upsert apple user: %w", ErrNotFound)
		}
		return User{}, fmt.Errorf("upsert apple user: %w", err)
	}

	if u.AppleAuthLineage == nil || *u.AppleAuthLineage == "" {
		// Mint a lineage only for cutoff-free accounts. When a consent
		// cutoff is set, the lineage stays NULL here: the handler must
		// prove a fresh Apple authorization (identity-token iat or a live
		// code exchange past the cutoff) before minting, otherwise a
		// pre-revocation token could mint its way around the cutoff.
		if u.AppleConsentCutoff == nil {
			lineage := uuidV7()
			if _, err := tx.Exec(ctx, `
				UPDATE users SET apple_auth_time = $2, apple_auth_lineage = $3 WHERE id = $1
			`, u.ID, authTime, lineage); err != nil {
				return User{}, fmt.Errorf("upsert apple user lineage: %w", err)
			}
			at := authTime
			u.AppleAuthTime = &at
			u.AppleAuthLineage = &lineage
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return User{}, fmt.Errorf("upsert apple user: %w", err)
	}
	return u, nil
}

// txHasPendingRevocation reports a pending revocation job for a digest in-txn.
func txHasPendingRevocation(ctx context.Context, tx pgx.Tx, digest string) (bool, error) {
	var one int
	err := tx.QueryRow(ctx, `
		SELECT 1 FROM apple_revocation_jobs WHERE subject_digest = $1 LIMIT 1
	`, digest).Scan(&one)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil
		}
		return false, fmt.Errorf("fence check: %w", err)
	}
	return true, nil
}

// ApplyAppleConsentCutoff records a verified Apple consent-revoked event:
// the cutoff advances to eventTime (stale/duplicate/out-of-order events are
// ignored), the current auth lineage is nulled so pre-cutoff sessions die,
// and vault secrets of the revoked lineage are erased (never a newer
// reauthorization's). Missing users are idempotent no-ops (never an upsert).
// Returns the affected user ID and whether the cutoff advanced.
func (s *PostgresStore) ApplyAppleConsentCutoff(ctx context.Context, appleSubject string, eventTime time.Time) (string, bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return "", false, fmt.Errorf("apply consent cutoff: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if err := lockAppleSubject(ctx, tx, appleSubject); err != nil {
		return "", false, fmt.Errorf("apply consent cutoff: %w", err)
	}

	var userID string
	var cutoff *time.Time
	var lineage *string
	var authTime *time.Time
	err = tx.QueryRow(ctx, `
		SELECT id, apple_consent_cutoff, apple_auth_lineage, apple_auth_time
		FROM users WHERE apple_subject = $1 FOR UPDATE
	`, appleSubject).Scan(&userID, &cutoff, &lineage, &authTime)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			if err := tx.Commit(ctx); err != nil {
				return "", false, fmt.Errorf("apply consent cutoff: %w", err)
			}
			return "", false, nil
		}
		return "", false, fmt.Errorf("apply consent cutoff: %w", err)
	}

	// Monotonic cutoff: stale/duplicate/out-of-order events never move the
	// cutoff backwards. A delayed FIRST event (older than the latest
	// recorded authorization but newer than the cutoff) still advances it:
	// sessions authorized before the event die by per-session auth-time
	// comparison, while newer vault/current metadata is preserved below.
	// (There is no full no-op for "event older than latest auth": that
	// guard would leave pre-event sessions alive forever after a delayed
	// callback, and the replacement account it meant to protect is safe
	// anyway — its re-authorization postdates the event, so its sessions
	// survive the per-session check and its newer metadata is preserved.)
	if cutoff != nil && !eventTime.After(*cutoff) {
		if err := tx.Commit(ctx); err != nil {
			return "", false, fmt.Errorf("apply consent cutoff: %w", err)
		}
		return userID, false, nil
	}

	if authTime == nil || eventTime.After(*authTime) {
		if _, err := tx.Exec(ctx, `
			UPDATE users SET apple_consent_cutoff = $2, apple_auth_lineage = NULL WHERE id = $1
		`, userID, eventTime); err != nil {
			return "", false, fmt.Errorf("apply consent cutoff: %w", err)
		}
	} else {
		// The latest completed authorization postdates the event (a fresh
		// grant before the delayed callback): preserve its lineage while
		// the cutoff still advances to end genuinely older sessions.
		if _, err := tx.Exec(ctx, `
			UPDATE users SET apple_consent_cutoff = $2 WHERE id = $1
		`, userID, eventTime); err != nil {
			return "", false, fmt.Errorf("apply consent cutoff: %w", err)
		}
	}

	// Erase only stale Apple secrets: a vault credential authorized before
	// the event belongs to a grant Apple already revoked (unusable — and a
	// later purge correctly reports missing credential instead of minting a
	// job for a dead grant). A credential authorized at/after the event is
	// a fresh re-authorization and stays for the purge path.
	if _, err := tx.Exec(ctx, `
		DELETE FROM apple_vault WHERE user_id = $1 AND auth_time < $2
	`, userID, eventTime); err != nil {
		return "", false, fmt.Errorf("apply consent cutoff: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return "", false, fmt.Errorf("apply consent cutoff: %w", err)
	}
	return userID, true, nil
}

// pgxScanner abstracts *pgxpool.Pool and pgx.Row for single-row scans.
type pgxScanner interface {
	Scan(dest ...any) error
}

// pgUpsertTombstone records (or refreshes) a deletion tombstone for one hard
// delete, inside the caller's transaction. Tombstones are generic
// cross-device delete propagation — future resources reuse them.
//
//nolint:unused // kept for future resources; no callers until the next resource lands.
func pgUpsertTombstone(ctx context.Context, tx pgx.Tx, userID, resource, recordID string) error {
	_, err := tx.Exec(ctx, `
		INSERT INTO tombstones (user_id, resource, record_id, deleted_at)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (user_id, resource, record_id)
		DO UPDATE SET deleted_at = excluded.deleted_at
	`, userID, resource, recordID, time.Now().UTC())
	if err != nil {
		return fmt.Errorf("upsert tombstone: %w", err)
	}
	return nil
}

// pgClearTombstone removes a record's tombstone so a recreation never meets
// its own stale tombstone. Harmless when no tombstone exists.
//
//nolint:unused // kept for future resources; no callers until the next resource lands.
func pgClearTombstone(ctx context.Context, pool *pgxpool.Pool, userID, resource, recordID string) error {
	if _, err := pool.Exec(ctx, `
		DELETE FROM tombstones WHERE user_id = $1 AND resource = $2 AND record_id = $3
	`, userID, resource, recordID); err != nil {
		return fmt.Errorf("clear tombstone: %w", err)
	}
	return nil
}

// ListDeletions returns the user's tombstones with deleted_at > since
// (nil/zero = all), ordered by deleted_at ASC. Kept without a Store
// interface slot (no deletion-list route): future resources reuse it.
func (s *PostgresStore) ListDeletions(ctx context.Context, userID string, since *time.Time) ([]Tombstone, error) {
	if since != nil && since.IsZero() {
		since = nil
	}
	rows, err := s.pool.Query(ctx, `
		SELECT resource, record_id, deleted_at
		FROM tombstones
		WHERE user_id = $1 AND ($2::timestamptz IS NULL OR deleted_at > $2)
		ORDER BY deleted_at ASC
	`, userID, since)
	if err != nil {
		return nil, fmt.Errorf("list deletions: %w", err)
	}
	defer rows.Close()
	var out []Tombstone
	for rows.Next() {
		var t Tombstone
		if err := rows.Scan(&t.Resource, &t.ID, &t.DeletedAt); err != nil {
			return nil, fmt.Errorf("list deletions scan: %w", err)
		}
		out = append(out, t)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list deletions rows: %w", err)
	}
	return out, nil
}

// scanRevocationJob scans a revocation job row in jobColumns order.
const pgJobColumns = `id, subject_digest, sealed_refresh, client_id,
	auth_lineage, auth_time, attempts, next_attempt_at, last_attempt_at, last_error, created_at`

func pgScanJob(sc pgxScanner, j *RevocationJob) error {
	return sc.Scan(&j.ID, &j.SubjectDigest, &j.SealedRefresh, &j.ClientID,
		&j.AuthLineage, &j.AuthTime, &j.Attempts, &j.NextAttemptAt, &j.LastAttemptAt, &j.LastError, &j.CreatedAt)
}

// PurgeUser atomically deletes the account and every associated operational
// row. The account row is locked first (consistent lock order with the
// rotation path); a stored Apple credential is moved into a
// durable revocation job before operational rows disappear; then receipts,
// refresh tokens, OTPs, tombstones, the vault row, and finally the user are
// deleted explicitly in dependency order. Commit-all or commit-nothing: any failure rolls the purge back.
// Serialization/deadlock races against concurrent writes retry boundedly.
func (s *PostgresStore) PurgeUser(ctx context.Context, userID, clientID string, digestFn func(string) string) (PurgeResult, error) {
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		res, err := s.purgeUserOnce(ctx, userID, clientID, digestFn)
		if err == nil {
			return res, nil
		}
		if !isRetryableTxnError(err) {
			return PurgeResult{}, err
		}
		lastErr = err
	}
	return PurgeResult{}, fmt.Errorf("purge user retries exhausted: %w", lastErr)
}

func (s *PostgresStore) purgeUserOnce(ctx context.Context, userID, clientID string, digestFn func(string) string) (PurgeResult, error) {
	var res PurgeResult
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return res, fmt.Errorf("purge user: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// Consistent lock order (subject advisory lock BEFORE the account row
	// lock, matching UpsertAppleUser and ApplyAppleConsentCutoff): the
	// subject is read without locking first (apple_subject is immutable —
	// set once at creation, never updated — so the re-read under the row
	// lock below cannot observe a different value, only a concurrent
	// purge's delete, which correctly reports NotFound). Taking the row
	// lock first and the advisory lock second would deadlock against a
	// concurrent fenced signup holding them in the opposite order.
	var appleSubject *string
	if err := tx.QueryRow(ctx, `
		SELECT apple_subject FROM users WHERE id = $1
	`, userID).Scan(&appleSubject); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return res, fmt.Errorf("purge user: %w", ErrNotFound)
		}
		return res, fmt.Errorf("purge user lock: %w", err)
	}
	if appleSubject != nil {
		if err := lockAppleSubject(ctx, tx, *appleSubject); err != nil {
			return res, fmt.Errorf("purge user: %w", err)
		}
	}
	if err := tx.QueryRow(ctx, `
		SELECT apple_subject FROM users WHERE id = $1 FOR UPDATE
	`, userID).Scan(&appleSubject); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return res, fmt.Errorf("purge user: %w", ErrNotFound)
		}
		return res, fmt.Errorf("purge user lock: %w", err)
	}
	res.UserID = userID

	// Move a stored Apple credential into the durable revocation outbox
	// before operational rows disappear. No FK constrains the job table, so
	// the job survives the account it was born from. The sealed blob keeps
	// its vault AAD; the job copies the lineage + auth time so the worker
	// can rebuild that AAD without any account identifier. Email-only
	// accounts (no vault row) skip Apple work entirely. For Apple accounts
	// the vault row is REQUIRED under this lock: a missing credential aborts
	// the whole purge (ErrAppleCredentialMissing, rolled back, mapped to
	// 409) instead of deleting the account with nothing to revoke — the
	// handler's pre-check cannot close the race with a consent callback
	// erasing the vault between the check and this transaction.
	if appleSubject != nil {
		res.HadAppleIdentity = true
		res.AppleSubject = *appleSubject
		var sealed []byte
		var lineage string
		var authTime time.Time
		err := tx.QueryRow(ctx, `
			DELETE FROM apple_vault WHERE user_id = $1
			RETURNING sealed_refresh, lineage_id, auth_time
		`, userID).Scan(&sealed, &lineage, &authTime)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return res, fmt.Errorf("purge user: %w", ErrAppleCredentialMissing)
			}
			return res, fmt.Errorf("purge user vault: %w", err)
		}
		if len(sealed) > 0 {
			// The subject advisory lock is already held (taken above in
			// subject→row order); job creation serializes against fenced
			// signups on the same subject here.
			digest := digestFn(*appleSubject)
			var jobID string
			if err := tx.QueryRow(ctx, `
				INSERT INTO apple_revocation_jobs
					(id, subject_digest, sealed_refresh, client_id, auth_lineage, auth_time, attempts, next_attempt_at)
				VALUES (gen_random_uuid(), $1, $2, $3, $4, $5, 0, $6)
				RETURNING id
			`, digest, sealed, clientID, lineage, authTime, time.Now().Add(purgeJobGracePeriod)).Scan(&jobID); err != nil {
				return res, fmt.Errorf("purge user revocation job: %w", err)
			}
			res.SealedAppleRefresh = sealed
			res.AuthLineage = lineage
			res.AuthTime = authTime
			res.RevocationJobID = jobID
			res.SubjectDigest = digest
		}
	}

	// Explicit ordered child deletes (auditable against the schema; no
	// reliance on FK cascades or the SQLite pragma).
	for _, stmt := range []struct {
		name string
		sql  string
	}{
		{"recovery receipts", `DELETE FROM refresh_recovery_receipts WHERE user_id = $1`},
		{"refresh tokens", `DELETE FROM refresh_tokens WHERE user_id = $1`},
		{"otp codes", `DELETE FROM otp_codes WHERE user_id = $1`},
		{"tombstones", `DELETE FROM tombstones WHERE user_id = $1`},
		{"household memberships", `DELETE FROM household_members WHERE user_id = $1`},
		{"household invites sent", `DELETE FROM household_invites WHERE invited_by = $1`},
	} {
		if _, err := tx.Exec(ctx, stmt.sql, userID); err != nil {
			return res, fmt.Errorf("purge user %s: %w", stmt.name, err)
		}
	}

	if _, err := tx.Exec(ctx, `DELETE FROM users WHERE id = $1`, userID); err != nil {
		return res, fmt.Errorf("purge user account: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return res, fmt.Errorf("purge user: %w", err)
	}
	return res, nil
}

// HasPendingAppleRevocation reports whether a durable revocation job is
// pending for the given HMAC subject digest.
func (s *PostgresStore) HasPendingAppleRevocation(ctx context.Context, subjectDigest string) (bool, error) {
	var one int
	err := s.pool.QueryRow(ctx, `
		SELECT 1 FROM apple_revocation_jobs WHERE subject_digest = $1 LIMIT 1
	`, subjectDigest).Scan(&one)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil
		}
		return false, fmt.Errorf("pending revocation check: %w", err)
	}
	return true, nil
}

// ClaimRevocationJob exclusively claims one due job, bumping its attempt
// counters and pushing its due time out by the claim lease. Returns
// ErrNotFound when nothing is due.
func (s *PostgresStore) ClaimRevocationJob(ctx context.Context, now time.Time) (RevocationJob, error) {
	var j RevocationJob
	err := pgScanJob(s.pool.QueryRow(ctx, `
		UPDATE apple_revocation_jobs SET
			attempts = attempts + 1,
			last_attempt_at = $1,
			next_attempt_at = $2
		WHERE id = (
			SELECT id FROM apple_revocation_jobs
			WHERE next_attempt_at <= $1
			ORDER BY next_attempt_at, created_at
			LIMIT 1
			FOR UPDATE SKIP LOCKED
		)
		RETURNING `+pgJobColumns+`
	`, now, now.Add(claimLease)), &j)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return RevocationJob{}, fmt.Errorf("claim revocation job: %w", ErrNotFound)
		}
		return RevocationJob{}, fmt.Errorf("claim revocation job: %w", err)
	}
	return j, nil
}

// CompleteRevocationJob removes a job after acknowledged Apple revocation.
// Idempotent: completing an already-removed job succeeds.
func (s *PostgresStore) CompleteRevocationJob(ctx context.Context, id string) error {
	if _, err := s.pool.Exec(ctx, `DELETE FROM apple_revocation_jobs WHERE id = $1`, id); err != nil {
		return fmt.Errorf("complete revocation job: %w", err)
	}
	return nil
}

// FailRevocationJob records a failed attempt and reschedules the job. Never
// drops unresolved work.
func (s *PostgresStore) FailRevocationJob(ctx context.Context, id, errMsg string, nextAttempt time.Time) error {
	if _, err := s.pool.Exec(ctx, `
		UPDATE apple_revocation_jobs
		SET last_error = $2, next_attempt_at = $3, last_attempt_at = NOW()
		WHERE id = $1
	`, id, errMsg, nextAttempt); err != nil {
		return fmt.Errorf("fail revocation job: %w", err)
	}
	return nil
}

// RecordAppleNotification logs a processed Apple notification id. A
// duplicate id returns ErrNotificationReplay (idempotent no-op).
func (s *PostgresStore) RecordAppleNotification(ctx context.Context, jti string) error {
	ct, err := s.pool.Exec(ctx, `
		INSERT INTO apple_notifications_seen (jti, received_at)
		VALUES ($1, NOW())
		ON CONFLICT (jti) DO NOTHING
	`, jti)
	if err != nil {
		return fmt.Errorf("record apple notification: %w", err)
	}
	if ct.RowsAffected() == 0 {
		return fmt.Errorf("record apple notification: %w", ErrNotificationReplay)
	}
	// Opportunistic retention bound: drop ids older than 30 days so the log
	// cannot grow without bound. Best-effort; a failure here never fails
	// the notification itself.
	_, _ = s.pool.Exec(ctx, `DELETE FROM apple_notifications_seen WHERE received_at < NOW() - make_interval(days => 30)`)
	return nil
}
