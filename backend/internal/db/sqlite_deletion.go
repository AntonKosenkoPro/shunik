package db

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// SaveAppleCredential upserts the encrypted Apple revocable credential for
// an Apple user. Only the sealed blob plus routing metadata persist.
func (s *SQLiteStore) SaveAppleCredential(ctx context.Context, cred AppleCredential) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO apple_vault (user_id, sealed_refresh, auth_time, lineage_id, created_at, updated_at)
		VALUES (?, ?, ?, ?, datetime('now'), datetime('now'))
		ON CONFLICT (user_id) DO UPDATE
			SET sealed_refresh = excluded.sealed_refresh,
			    auth_time = excluded.auth_time,
			    lineage_id = excluded.lineage_id,
			    updated_at = datetime('now')
	`, cred.UserID, cred.SealedRefresh, fmtTime(cred.AuthTime), cred.LineageID)
	if err != nil {
		return fmt.Errorf("save apple credential: %w", err)
	}
	return nil
}

// GetAppleCredential returns the stored Apple credential for a user.
func (s *SQLiteStore) GetAppleCredential(ctx context.Context, userID string) (AppleCredential, error) {
	var c AppleCredential
	var authTime, createdAt, updatedAt string
	err := s.db.QueryRowContext(ctx, `
		SELECT user_id, sealed_refresh, auth_time, lineage_id, created_at, updated_at
		FROM apple_vault
		WHERE user_id = ?
	`, userID).Scan(&c.UserID, &c.SealedRefresh, &authTime, &c.LineageID, &createdAt, &updatedAt)
	if err != nil {
		if err == sql.ErrNoRows {
			return AppleCredential{}, fmt.Errorf("get apple credential: %w", ErrNotFound)
		}
		return AppleCredential{}, fmt.Errorf("get apple credential: %w", err)
	}
	c.AuthTime = parseTime(authTime)
	c.CreatedAt = parseTime(createdAt)
	c.UpdatedAt = parseTime(updatedAt)
	return c, nil
}

// SetAppleSession stamps the account's latest completed Apple authorization.
func (s *SQLiteStore) SetAppleSession(ctx context.Context, userID string, authTime time.Time, lineageID string) error {
	_, err := s.db.ExecContext(ctx, `
		UPDATE users SET apple_auth_time = ?, apple_auth_lineage = ? WHERE id = ?
	`, fmtTime(authTime), lineageID, userID)
	if err != nil {
		return fmt.Errorf("set apple session: %w", err)
	}
	return nil
}

// UpsertAppleUser fences and upserts an Apple identity in one transaction.
// See the Postgres twin for the contract: the fence digest is HMAC-based and
// supplied by the handler layer. Single-writer SQLite serializes writers,
// which provides the same exclusion the Postgres advisory lock gives.
func (s *SQLiteStore) UpsertAppleUser(ctx context.Context, appleSubject, email, subjectDigest string, authTime time.Time) (User, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return User{}, fmt.Errorf("upsert apple user: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var one int
	if err := tx.QueryRowContext(ctx, `
		SELECT 1 FROM apple_revocation_jobs WHERE subject_digest = ? LIMIT 1
	`, subjectDigest).Scan(&one); err != nil && err != sql.ErrNoRows {
		return User{}, fmt.Errorf("upsert apple user fence check: %w", err)
	} else if err == nil {
		return User{}, fmt.Errorf("upsert apple user: %w", ErrAppleRevocationPending)
	}

	// Email belongs to a different account: identities are never merged.
	// Checked in-transaction (single-writer SQLite serializes signups), so
	// a concurrent OTP registration cannot slip between check and insert.
	// A row carrying this same apple_subject is the re-signin path below,
	// not a collision.
	var holderSubject sql.NullString
	if err := tx.QueryRowContext(ctx, `
		SELECT apple_subject FROM users WHERE email = ?
	`, email).Scan(&holderSubject); err != nil && err != sql.ErrNoRows {
		return User{}, fmt.Errorf("upsert apple user email check: %w", err)
	} else if err == nil && (!holderSubject.Valid || holderSubject.String != appleSubject) {
		return User{}, fmt.Errorf("upsert apple user: %w", ErrAppleEmailInUse)
	}

	if _, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO users (id, email, email_verified, created_at, apple_subject)
		VALUES (?, ?, true, datetime('now'), ?)
	`, uuidV7(), email, appleSubject); err != nil {
		return User{}, fmt.Errorf("upsert apple user insert: %w", err)
	}

	if _, err := tx.ExecContext(ctx, `
		UPDATE users SET email_verified = true WHERE apple_subject = ?
	`, appleSubject); err != nil {
		return User{}, fmt.Errorf("upsert apple user verify: %w", err)
	}

	var u User
	var createdAt string
	var colSub, colAuthTime, colLineage, colCutoff sql.NullString
	err = tx.QueryRowContext(ctx, `
		SELECT `+sqliteUserColumns+`
		FROM users
		WHERE apple_subject = ?
	`, appleSubject).Scan(&u.ID, &u.Email, &u.EmailVerified, &createdAt,
		&colSub, &colAuthTime, &colLineage, &colCutoff)
	if err != nil {
		if err == sql.ErrNoRows {
			return User{}, fmt.Errorf("upsert apple user: %w", ErrNotFound)
		}
		return User{}, fmt.Errorf("upsert apple user select: %w", err)
	}
	sqliteScanUser(&u, createdAt, colSub, colAuthTime, colLineage, colCutoff)

	// Mint a lineage only for cutoff-free accounts; a set cutoff leaves the
	// lineage NULL until the handler proves a fresh Apple authorization
	// (identity-token iat or a live code exchange past the cutoff).
	if (u.AppleAuthLineage == nil || *u.AppleAuthLineage == "") && u.AppleConsentCutoff == nil {
		lineage := uuidV7()
		if _, err := tx.ExecContext(ctx, `
			UPDATE users SET apple_auth_time = ?, apple_auth_lineage = ? WHERE id = ?
		`, fmtTime(authTime), lineage, u.ID); err != nil {
			return User{}, fmt.Errorf("upsert apple user lineage: %w", err)
		}
		at := authTime
		u.AppleAuthTime = &at
		u.AppleAuthLineage = &lineage
	}

	if err := tx.Commit(); err != nil {
		return User{}, fmt.Errorf("upsert apple user: %w", err)
	}
	return u, nil
}

// ApplyAppleConsentCutoff records a verified Apple consent-revoked event.
// See the Postgres twin for the contract.
func (s *SQLiteStore) ApplyAppleConsentCutoff(ctx context.Context, appleSubject string, eventTime time.Time) (string, bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", false, fmt.Errorf("apply consent cutoff: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var userID string
	var cutoff, lineage, authTimeStr sql.NullString
	err = tx.QueryRowContext(ctx, `
		SELECT id, apple_consent_cutoff, apple_auth_lineage, apple_auth_time
		FROM users WHERE apple_subject = ?
	`, appleSubject).Scan(&userID, &cutoff, &lineage, &authTimeStr)
	if err != nil {
		if err == sql.ErrNoRows {
			if err := tx.Commit(); err != nil {
				return "", false, fmt.Errorf("apply consent cutoff: %w", err)
			}
			return "", false, nil
		}
		return "", false, fmt.Errorf("apply consent cutoff: %w", err)
	}

	if cutoff.Valid && !eventTime.After(parseTime(cutoff.String)) {
		if err := tx.Commit(); err != nil {
			return "", false, fmt.Errorf("apply consent cutoff: %w", err)
		}
		return userID, false, nil
	}
	// Monotonic cutoff (see the Postgres twin): a delayed first event
	// still advances the cutoff to end pre-event sessions, while newer
	// current metadata is preserved. No full no-op for events older than
	// the latest authorization — the fresh replacement that guard meant
	// to protect survives via the per-session auth-time check and the
	// preservation below.
	if !authTimeStr.Valid || eventTime.After(parseTime(authTimeStr.String)) {
		if _, err := tx.ExecContext(ctx, `
			UPDATE users SET apple_consent_cutoff = ?, apple_auth_lineage = NULL WHERE id = ?
		`, fmtTime(eventTime), userID); err != nil {
			return "", false, fmt.Errorf("apply consent cutoff: %w", err)
		}
	} else {
		if _, err := tx.ExecContext(ctx, `
			UPDATE users SET apple_consent_cutoff = ? WHERE id = ?
		`, fmtTime(eventTime), userID); err != nil {
			return "", false, fmt.Errorf("apply consent cutoff: %w", err)
		}
	}

	// Erase only vault credentials authorized before the event; a fresh
	// re-authorization at/after the event stays for the purge path.
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM apple_vault WHERE user_id = ? AND auth_time < ?
	`, userID, fmtTime(eventTime)); err != nil {
		return "", false, fmt.Errorf("apply consent cutoff: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return "", false, fmt.Errorf("apply consent cutoff: %w", err)
	}
	return userID, true, nil
}

// HasPendingAppleRevocation reports whether a durable revocation job is
// pending for the given HMAC subject digest.
func (s *SQLiteStore) HasPendingAppleRevocation(ctx context.Context, subjectDigest string) (bool, error) {
	var one int
	err := s.db.QueryRowContext(ctx, `
		SELECT 1 FROM apple_revocation_jobs WHERE subject_digest = ? LIMIT 1
	`, subjectDigest).Scan(&one)
	if err != nil {
		if err == sql.ErrNoRows {
			return false, nil
		}
		return false, fmt.Errorf("pending revocation check: %w", err)
	}
	return true, nil
}

// PurgeUser atomically deletes the account and every associated operational
// row. See the Postgres twin for the contract; single-writer SQLite
// serializes the transaction with all other writers.
func (s *SQLiteStore) PurgeUser(ctx context.Context, userID, clientID string, digestFn func(subject string) string) (PurgeResult, error) {
	var res PurgeResult
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return res, fmt.Errorf("purge user: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var appleSubject sql.NullString
	if err := tx.QueryRowContext(ctx, `
		SELECT apple_subject FROM users WHERE id = ?
	`, userID).Scan(&appleSubject); err != nil {
		if err == sql.ErrNoRows {
			return res, fmt.Errorf("purge user: %w", ErrNotFound)
		}
		return res, fmt.Errorf("purge user lock: %w", err)
	}
	res.UserID = userID

	if appleSubject.Valid {
		res.HadAppleIdentity = true
		res.AppleSubject = appleSubject.String
		var sealed []byte
		var lineage string
		var authTimeStr string
		err := tx.QueryRowContext(ctx, `
			DELETE FROM apple_vault WHERE user_id = ? RETURNING sealed_refresh, lineage_id, auth_time
		`, userID).Scan(&sealed, &lineage, &authTimeStr)
		if err != nil {
			// See the Postgres twin: the vault row is required under this
			// lock for Apple accounts. A consent-callback erase racing the
			// handler's pre-check aborts the whole purge instead of
			// deleting the account with nothing to revoke.
			if err == sql.ErrNoRows {
				return res, fmt.Errorf("purge user: %w", ErrAppleCredentialMissing)
			}
			return res, fmt.Errorf("purge user vault: %w", err)
		}
		if len(sealed) > 0 {
			digest := digestFn(appleSubject.String)
			jobID := uuidV7()
			authTime := parseTime(authTimeStr)
			if _, err := tx.ExecContext(ctx, `
				INSERT INTO apple_revocation_jobs
					(id, subject_digest, sealed_refresh, client_id, auth_lineage, auth_time, attempts, next_attempt_at, created_at)
				VALUES (?, ?, ?, ?, ?, ?, 0, ?, datetime('now'))
			`, jobID, digest, sealed, clientID, lineage, fmtTime(authTime), fmtTime(time.Now().Add(purgeJobGracePeriod))); err != nil {
				return res, fmt.Errorf("purge user revocation job: %w", err)
			}
			res.SealedAppleRefresh = sealed
			res.AuthLineage = lineage
			res.AuthTime = authTime
			res.RevocationJobID = jobID
			res.SubjectDigest = digest
		}
	}

	for _, stmt := range []struct {
		name string
		sql  string
	}{
		{"recovery receipts", `DELETE FROM refresh_recovery_receipts WHERE user_id = ?`},
		{"refresh tokens", `DELETE FROM refresh_tokens WHERE user_id = ?`},
		{"otp codes", `DELETE FROM otp_codes WHERE user_id = ?`},
		{"entry-category joins", `DELETE FROM entry_categories WHERE entry_id IN (SELECT id FROM entries WHERE user_id = ?)`},
		{"entries", `DELETE FROM entries WHERE user_id = ?`},
		{"categories", `DELETE FROM categories WHERE user_id = ?`},
		{"tombstones", `DELETE FROM tombstones WHERE user_id = ?`},
	} {
		if _, err := tx.ExecContext(ctx, stmt.sql, userID); err != nil {
			return res, fmt.Errorf("purge user %s: %w", stmt.name, err)
		}
	}

	if _, err := tx.ExecContext(ctx, `DELETE FROM users WHERE id = ?`, userID); err != nil {
		return res, fmt.Errorf("purge user account: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return res, fmt.Errorf("purge user: %w", err)
	}
	return res, nil
}

// scanSQLiteJob scans a revocation job row.
func scanSQLiteJob(j *RevocationJob, id, digest string, sealed []byte, clientID string,
	lineage, authTimeStr string, attempts int,
	nextAttempt, lastAttempt sql.NullString, lastError string, createdAt string) {
	j.ID = id
	j.SubjectDigest = digest
	j.SealedRefresh = sealed
	j.ClientID = clientID
	j.AuthLineage = lineage
	j.AuthTime = parseTime(authTimeStr)
	j.Attempts = attempts
	j.NextAttemptAt = parseTime(nextAttempt.String)
	if lastAttempt.Valid {
		v := parseTime(lastAttempt.String)
		j.LastAttemptAt = &v
	}
	j.LastError = lastError
	j.CreatedAt = parseTime(createdAt)
}

// ClaimRevocationJob exclusively claims one due job. Returns ErrNotFound when
// nothing is due.
func (s *SQLiteStore) ClaimRevocationJob(ctx context.Context, now time.Time) (RevocationJob, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return RevocationJob{}, fmt.Errorf("claim revocation job: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var j RevocationJob
	var nextAttempt, lastAttempt sql.NullString
	var createdAt, authTimeStr string
	err = tx.QueryRowContext(ctx, `
		SELECT id, subject_digest, sealed_refresh, client_id, auth_lineage, auth_time,
		       attempts, next_attempt_at, last_attempt_at, last_error, created_at
		FROM apple_revocation_jobs
		WHERE next_attempt_at <= ?
		ORDER BY next_attempt_at, created_at
		LIMIT 1
	`, fmtTime(now)).Scan(&j.ID, &j.SubjectDigest, &j.SealedRefresh, &j.ClientID,
		&j.AuthLineage, &authTimeStr, &j.Attempts, &nextAttempt, &lastAttempt, &j.LastError, &createdAt)
	if err != nil {
		if err == sql.ErrNoRows {
			return RevocationJob{}, fmt.Errorf("claim revocation job: %w", ErrNotFound)
		}
		return RevocationJob{}, fmt.Errorf("claim revocation job: %w", err)
	}
	scanSQLiteJob(&j, j.ID, j.SubjectDigest, j.SealedRefresh, j.ClientID, j.AuthLineage,
		authTimeStr, j.Attempts, nextAttempt, lastAttempt, j.LastError, createdAt)

	if _, err := tx.ExecContext(ctx, `
		UPDATE apple_revocation_jobs
		SET attempts = attempts + 1, last_attempt_at = ?, next_attempt_at = ?
		WHERE id = ?
	`, fmtTime(now), fmtTime(now.Add(claimLease)), j.ID); err != nil {
		return RevocationJob{}, fmt.Errorf("claim revocation job: %w", err)
	}
	j.Attempts++

	if err := tx.Commit(); err != nil {
		return RevocationJob{}, fmt.Errorf("claim revocation job: %w", err)
	}
	return j, nil
}

// CompleteRevocationJob removes a job after acknowledged Apple revocation.
// Idempotent: completing an already-removed job succeeds.
func (s *SQLiteStore) CompleteRevocationJob(ctx context.Context, id string) error {
	if _, err := s.db.ExecContext(ctx, `DELETE FROM apple_revocation_jobs WHERE id = ?`, id); err != nil {
		return fmt.Errorf("complete revocation job: %w", err)
	}
	return nil
}

// FailRevocationJob records a failed attempt and reschedules the job. Never
// drops unresolved work.
func (s *SQLiteStore) FailRevocationJob(ctx context.Context, id, errMsg string, nextAttempt time.Time) error {
	if _, err := s.db.ExecContext(ctx, `
		UPDATE apple_revocation_jobs
		SET last_error = ?, next_attempt_at = ?, last_attempt_at = datetime('now')
		WHERE id = ?
	`, errMsg, fmtTime(nextAttempt), id); err != nil {
		return fmt.Errorf("fail revocation job: %w", err)
	}
	return nil
}

// RecordAppleNotification logs a processed Apple notification id. A
// duplicate id returns ErrNotificationReplay (idempotent no-op).
func (s *SQLiteStore) RecordAppleNotification(ctx context.Context, jti string) error {
	res, err := s.db.ExecContext(ctx, `
		INSERT INTO apple_notifications_seen (jti, received_at)
		VALUES (?, datetime('now'))
		ON CONFLICT (jti) DO NOTHING
	`, jti)
	if err != nil {
		return fmt.Errorf("record apple notification: %w", err)
	}
	affected, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("record apple notification: %w", err)
	}
	if affected == 0 {
		return fmt.Errorf("record apple notification: %w", ErrNotificationReplay)
	}
	// Opportunistic retention bound (best-effort).
	_, _ = s.db.ExecContext(ctx, `DELETE FROM apple_notifications_seen WHERE received_at < datetime('now', '-30 days')`)
	return nil
}
