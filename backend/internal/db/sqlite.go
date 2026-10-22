package db

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	_ "modernc.org/sqlite" // pure-Go SQLite driver for testing
)

// SQLiteStore implements Store using SQLite (for testing only).
type SQLiteStore struct {
	db *sql.DB
}

// NewSQLiteStore creates a new SQLiteStore.
func NewSQLiteStore(dsn string) (*SQLiteStore, error) {
	// Enforce foreign keys like production Postgres. The pragma is a
	// per-connection setting, so it rides the DSN (executed on every
	// (re)opened pooled connection) instead of a one-shot Exec that a
	// replacement connection after a driver reset would silently drop.
	// Account-scoped writes after a purge then fail loudly instead of
	// orphaning rows, and the purge's explicit ordered deletes stay valid
	// under the same constraints.
	sep := "?"
	if strings.Contains(dsn, "?") {
		sep = "&"
	}
	db, err := sql.Open("sqlite", dsn+sep+"_pragma=foreign_keys(1)")
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}

	// Configure connection pool for SQLite
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)

	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("ping sqlite: %w", err)
	}

	return &SQLiteStore{db: db}, nil
}

// Close closes the database connection.
func (s *SQLiteStore) Close() error {
	return s.db.Close()
}

// DB returns the underlying *sql.DB for use by migrations.
func (s *SQLiteStore) DB() *sql.DB {
	return s.db
}

// sqliteUserColumns is the full user projection, including the Apple
// session-lineage and consent-cutoff columns added by 009.
const sqliteUserColumns = `id, email, email_verified, created_at,
	apple_subject, apple_auth_time, apple_auth_lineage, apple_consent_cutoff`

// sqliteScanUser scans a user row in sqliteUserColumns order. Nullable
// columns land in pointer fields (NULL → nil); timestamps parse through the
// shared nullTimePtr helper.
func sqliteScanUser(u *User, createdAt string, appleSubject, appleAuthTime, appleAuthLineage, appleConsentCutoff sql.NullString) {
	u.CreatedAt = parseTime(createdAt)
	if appleSubject.Valid {
		v := appleSubject.String
		u.AppleSubject = &v
	}
	u.AppleAuthTime = nullTimePtr(appleAuthTime)
	if appleAuthLineage.Valid {
		v := appleAuthLineage.String
		u.AppleAuthLineage = &v
	}
	u.AppleConsentCutoff = nullTimePtr(appleConsentCutoff)
}

// GetUserByEmail returns a user by their email.
func (s *SQLiteStore) GetUserByEmail(ctx context.Context, email string) (User, error) {
	var u User
	var createdAt string
	var appleSubject, appleAuthTime, appleAuthLineage, appleConsentCutoff sql.NullString
	err := s.db.QueryRowContext(ctx, `
		SELECT `+sqliteUserColumns+`
		FROM users
		WHERE email = ?
	`, email).Scan(&u.ID, &u.Email, &u.EmailVerified, &createdAt,
		&appleSubject, &appleAuthTime, &appleAuthLineage, &appleConsentCutoff)
	if err != nil {
		if err == sql.ErrNoRows {
			return User{}, fmt.Errorf("get user by email: %w", ErrNotFound)
		}
		return User{}, fmt.Errorf("get user by email: %w", err)
	}
	sqliteScanUser(&u, createdAt, appleSubject, appleAuthTime, appleAuthLineage, appleConsentCutoff)
	return u, nil
}

// UpsertUser creates a user if not exists, returns the user.
func (s *SQLiteStore) UpsertUser(ctx context.Context, email string) (User, error) {
	// Try insert first
	_, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO users (id, email, email_verified, created_at)
		VALUES (?, ?, false, datetime('now'))
	`, uuidV7(), email)
	if err != nil {
		return User{}, fmt.Errorf("upsert user insert: %w", err)
	}

	var u User
	var createdAt string
	var appleSubject, appleAuthTime, appleAuthLineage, appleConsentCutoff sql.NullString
	err = s.db.QueryRowContext(ctx, `
		SELECT `+sqliteUserColumns+`
		FROM users
		WHERE email = ?
	`, email).Scan(&u.ID, &u.Email, &u.EmailVerified, &createdAt,
		&appleSubject, &appleAuthTime, &appleAuthLineage, &appleConsentCutoff)
	if err != nil {
		return User{}, fmt.Errorf("upsert user select: %w", err)
	}
	sqliteScanUser(&u, createdAt, appleSubject, appleAuthTime, appleAuthLineage, appleConsentCutoff)
	return u, nil
}

// SetUserVerified marks a user's email as verified.
func (s *SQLiteStore) SetUserVerified(ctx context.Context, userID string) error {
	_, err := s.db.ExecContext(ctx, `
		UPDATE users SET email_verified = true WHERE id = ?
	`, userID)
	if err != nil {
		return fmt.Errorf("set user verified: %w", err)
	}
	return nil
}

// SaveOTP stores a new OTP code for a user with the given attempt budget.
func (s *SQLiteStore) SaveOTP(ctx context.Context, userID string, codeHash string, expiresAt time.Time, maxAttempts int) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO otp_codes (id, user_id, code_hash, expires_at, attempts, max_attempts, created_at)
		VALUES (?, ?, ?, ?, 0, ?, datetime('now'))
	`, uuidV7(), userID, codeHash, expiresAt.UTC().Format("2006-01-02 15:04:05"), maxAttempts)
	if err != nil {
		return fmt.Errorf("save otp: %w", err)
	}
	return nil
}

// GetValidOTP returns the latest non-expired, non-exhausted OTP for a user.
func (s *SQLiteStore) GetValidOTP(ctx context.Context, userID string) (OTP, error) {
	var o OTP
	var expiresAt string
	err := s.db.QueryRowContext(ctx, `
		SELECT id, user_id, code_hash, expires_at, attempts, max_attempts
		FROM otp_codes
		WHERE user_id = ?
		  AND expires_at > datetime('now')
		  AND attempts < max_attempts
		ORDER BY rowid DESC
		LIMIT 1
	`, userID).Scan(&o.ID, &o.UserID, &o.CodeHash, &expiresAt, &o.Attempts, &o.MaxAttempts)
	if err != nil {
		if err == sql.ErrNoRows {
			return OTP{}, fmt.Errorf("get valid otp: %w", ErrNotFound)
		}
		return OTP{}, fmt.Errorf("get valid otp: %w", err)
	}
	o.ExpiresAt = parseTime(expiresAt)
	return o, nil
}

// IncrementOTPAttempts increments the attempt counter for an OTP.
func (s *SQLiteStore) IncrementOTPAttempts(ctx context.Context, otpID string) error {
	_, err := s.db.ExecContext(ctx, `
		UPDATE otp_codes SET attempts = attempts + 1 WHERE id = ?
	`, otpID)
	if err != nil {
		return fmt.Errorf("increment otp attempts: %w", err)
	}
	return nil
}

// MarkOTPExhausted marks an OTP as exhausted (max attempts reached).
func (s *SQLiteStore) MarkOTPExhausted(ctx context.Context, otpID string) error {
	_, err := s.db.ExecContext(ctx, `
		UPDATE otp_codes SET attempts = max_attempts WHERE id = ?
	`, otpID)
	if err != nil {
		return fmt.Errorf("mark otp exhausted: %w", err)
	}
	return nil
}

// SaveRefreshToken stores a new refresh token.
func (s *SQLiteStore) SaveRefreshToken(ctx context.Context, userID string, tokenHash string, deviceID string) error {
	return s.SaveRefreshTokenWithAuth(ctx, userID, tokenHash, deviceID, nil, "")
}

// SaveRefreshTokenWithAuth stores a refresh token with its session's Apple
// auth pair (nil/empty = email-OTP session, unaffected by Apple cutoffs).
func (s *SQLiteStore) SaveRefreshTokenWithAuth(ctx context.Context, userID string, tokenHash string, deviceID string, authTime *time.Time, authLineage string) error {
	var at any
	if authTime != nil {
		at = fmtTime(*authTime)
	}
	var lineage any
	if authLineage != "" {
		lineage = authLineage
	}
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO refresh_tokens (id, user_id, token_hash, device_id, revoked, created_at, auth_time, auth_lineage)
		VALUES (?, ?, ?, ?, false, datetime('now'), ?, ?)
	`, uuidV7(), userID, tokenHash, deviceID, at, lineage)
	if err != nil {
		return fmt.Errorf("save refresh token: %w", err)
	}
	return nil
}

// GetRefreshToken returns a refresh token by its hash, including user info.
func (s *SQLiteStore) GetRefreshToken(ctx context.Context, tokenHash string) (RefreshToken, error) {
	var t RefreshToken
	var createdAt string
	var authTime sql.NullString
	var authLineage sql.NullString
	err := s.db.QueryRowContext(ctx, `
		SELECT id, user_id, token_hash, device_id, revoked, created_at, auth_time, auth_lineage
		FROM refresh_tokens
		WHERE token_hash = ?
	`, tokenHash).Scan(&t.ID, &t.UserID, &t.TokenHash, &t.DeviceID, &t.Revoked, &createdAt, &authTime, &authLineage)
	if err != nil {
		if err == sql.ErrNoRows {
			return RefreshToken{}, fmt.Errorf("get refresh token: %w", ErrNotFound)
		}
		return RefreshToken{}, fmt.Errorf("get refresh token: %w", err)
	}
	t.CreatedAt = parseTime(createdAt)
	t.AuthTime = nullTimePtr(authTime)
	if authLineage.Valid {
		v := authLineage.String
		t.AuthLineage = &v
	}
	return t, nil
}

// RevokeRefreshToken marks a refresh token as revoked.
func (s *SQLiteStore) RevokeRefreshToken(ctx context.Context, tokenID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("revoke refresh token: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, `
		UPDATE refresh_tokens SET revoked = true WHERE id = ?
	`, tokenID); err != nil {
		return fmt.Errorf("revoke refresh token: %w", err)
	}
	if err := closeSuccessorReceiptsSQLite(ctx, tx, tokenID); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("revoke refresh token: %w", err)
	}
	return nil
}

// RevokeAllUserSessions revokes all refresh tokens for a user.
func (s *SQLiteStore) RevokeAllUserSessions(ctx context.Context, userID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("revoke all user sessions: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, `
		UPDATE refresh_tokens SET revoked = true WHERE user_id = ? AND revoked = false
	`, userID); err != nil {
		return fmt.Errorf("revoke all user sessions: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE refresh_recovery_receipts SET consumed = true
		WHERE user_id = ? AND consumed = false
	`, userID); err != nil {
		return fmt.Errorf("revoke all user sessions: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("revoke all user sessions: %w", err)
	}
	return nil
}

// RevokeUserDeviceSessions revokes the refresh family of one device.
func (s *SQLiteStore) RevokeUserDeviceSessions(ctx context.Context, userID, deviceID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("revoke user device sessions: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, `
		UPDATE refresh_tokens SET revoked = true
		WHERE user_id = ? AND device_id = ? AND revoked = false
	`, userID, deviceID); err != nil {
		return fmt.Errorf("revoke user device sessions: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE refresh_recovery_receipts SET consumed = true
		WHERE user_id = ? AND device_id = ? AND consumed = false
	`, userID, deviceID); err != nil {
		return fmt.Errorf("revoke user device sessions: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("revoke user device sessions: %w", err)
	}
	return nil
}

// closeSuccessorReceiptsSQLite closes the pending receipts whose successor
// is the revoked token, so a replayed attempt cannot recreate the session.
func closeSuccessorReceiptsSQLite(ctx context.Context, tx *sql.Tx, tokenID string) error {
	if _, err := tx.ExecContext(ctx, `
		UPDATE refresh_recovery_receipts SET consumed = true
		WHERE successor_hash = (SELECT token_hash FROM refresh_tokens WHERE id = ?)
		  AND consumed = false
	`, tokenID); err != nil {
		return fmt.Errorf("revoke refresh token: %w", err)
	}
	return nil
}

// RotateRefreshToken atomically revokes the predecessor, inserts the
// successor, records the pending recovery receipt, and closes the receipt
// the predecessor itself recovered. Statements touch refresh_tokens before
// refresh_recovery_receipts — the same lock order as the revocation paths.
// The predecessor revocation is single-use guarded (`AND revoked = false`):
// a concurrent rotation that already consumed it gets ErrPredecessorRevoked
// and commits nothing, so cross-attempt races cannot fork the device family.
func (s *SQLiteStore) RotateRefreshToken(ctx context.Context, args RotateArgs) (RotateResult, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	// Account lifecycle fence first: a purge that removed the account races
	// here as ErrUserMissing — never a partial successor. (Single-writer
	// SQLite serializes writers, so no explicit row lock is needed.)
	var one int
	if err := tx.QueryRowContext(ctx, `
		SELECT 1 FROM users WHERE id = ?
	`, args.UserID).Scan(&one); err != nil {
		if err == sql.ErrNoRows {
			return RotateResult{}, fmt.Errorf("rotate refresh token: %w", ErrUserMissing)
		}
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", err)
	}

	// Single-use guard: only a live predecessor rotates.
	updateres, err := tx.ExecContext(ctx, `
		UPDATE refresh_tokens SET revoked = true
		WHERE id = ? AND revoked = false
	`, args.PredecessorID)
	if err != nil {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", err)
	}
	affected, err := updateres.RowsAffected()
	if err != nil {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", err)
	}
	if affected == 0 {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", ErrPredecessorRevoked)
	}

	// Bind the successor timestamp in Go so the committed row's created_at
	// is known without a post-commit read (which could fail after commit
	// and misreport a successful rotation as failed).
	now := time.Now().UTC()
	successorID := uuidV7()
	// The successor inherits the predecessor's auth lineage in the same
	// statement, so a rotation can never mint a lineage-clean token from a
	// cutoff session — rotation cannot evade the cutoff.
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO refresh_tokens (id, user_id, token_hash, device_id, revoked, created_at, auth_time, auth_lineage)
		SELECT ?, ?, ?, ?, false, ?, auth_time, auth_lineage
		FROM refresh_tokens WHERE id = ?
	`, successorID, args.UserID, args.SuccessorHash, args.DeviceID, fmtTime(now), args.PredecessorID); err != nil {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", err)
	}

	if _, err := tx.ExecContext(ctx, `
		UPDATE refresh_recovery_receipts SET consumed = true
		WHERE successor_hash = ? AND consumed = false
	`, args.PredecessorHash); err != nil {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", err)
	}

	// Scoped conflict target: only a duplicate attempt_hash folds into
	// ErrAttemptExists. Any other constraint failure surfaces as a real
	// storage error instead of misrouting into the recovery path.
	res, err := tx.ExecContext(ctx, `
		INSERT INTO refresh_recovery_receipts
			(attempt_hash, user_id, device_id, predecessor_hash, successor_hash,
			 sealed_successor, expires_at, consumed, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, false, ?)
		ON CONFLICT (attempt_hash) DO NOTHING
	`, args.AttemptHash, args.UserID, args.DeviceID, args.PredecessorHash,
		args.SuccessorHash, args.SealedSuccessor, fmtTime(args.ExpiresAt), fmtTime(now))
	if err != nil {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", err)
	}
	affected, err = res.RowsAffected()
	if err != nil {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", err)
	}
	if affected == 0 {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", ErrAttemptExists)
	}

	if err := pruneRecoveryReceiptsSQLite(ctx, tx, args.PruneConsumedBefore); err != nil {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", err)
	}

	return RotateResult{SuccessorID: successorID, SuccessorCreatedAt: now}, nil
}

// pruneRecoveryReceiptsSQLite deletes consumed receipts long past their
// expiry (see pruneRecoveryReceiptsPG): bounded retention, no sweeper.
// Capped per rotation like the Postgres twin.
func pruneRecoveryReceiptsSQLite(ctx context.Context, tx *sql.Tx, before time.Time) error {
	if before.IsZero() {
		return nil
	}
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM refresh_recovery_receipts
		WHERE rowid IN (
			SELECT rowid FROM refresh_recovery_receipts
			WHERE consumed = true AND expires_at < ?
			LIMIT 100
		)
	`, fmtTime(before)); err != nil {
		return fmt.Errorf("prune recovery receipts: %w", err)
	}
	return nil
}

// FindRecoveryReceipt returns the pending receipt for an attempt hash.
func (s *SQLiteStore) FindRecoveryReceipt(ctx context.Context, attemptHash string) (RecoveryReceipt, error) {
	var rc RecoveryReceipt
	var expiresAt, createdAt string
	err := s.db.QueryRowContext(ctx, `
		SELECT attempt_hash, user_id, device_id, predecessor_hash, successor_hash,
		       sealed_successor, expires_at, consumed, created_at
		FROM refresh_recovery_receipts
		WHERE attempt_hash = ?
	`, attemptHash).Scan(
		&rc.AttemptHash, &rc.UserID, &rc.DeviceID, &rc.PredecessorHash,
		&rc.SuccessorHash, &rc.SealedSuccessor, &expiresAt, &rc.Consumed, &createdAt)
	if err != nil {
		if err == sql.ErrNoRows {
			return RecoveryReceipt{}, fmt.Errorf("find recovery receipt: %w", ErrNotFound)
		}
		return RecoveryReceipt{}, fmt.Errorf("find recovery receipt: %w", err)
	}
	rc.ExpiresAt = parseTime(expiresAt)
	rc.CreatedAt = parseTime(createdAt)
	return rc, nil
}

// ConsumeRecoveryReceipt closes a pending receipt without revoking anything.
func (s *SQLiteStore) ConsumeRecoveryReceipt(ctx context.Context, attemptHash string) error {
	if _, err := s.db.ExecContext(ctx, `
		UPDATE refresh_recovery_receipts SET consumed = true
		WHERE attempt_hash = ? AND consumed = false
	`, attemptHash); err != nil {
		return fmt.Errorf("consume recovery receipt: %w", err)
	}
	return nil
}

// GetUserByID returns a user by their ID.
func (s *SQLiteStore) GetUserByID(ctx context.Context, userID string) (User, error) {
	var u User
	var createdAt string
	var appleSubject, appleAuthTime, appleAuthLineage, appleConsentCutoff sql.NullString
	err := s.db.QueryRowContext(ctx, `
		SELECT `+sqliteUserColumns+`
		FROM users
		WHERE id = ?
	`, userID).Scan(&u.ID, &u.Email, &u.EmailVerified, &createdAt,
		&appleSubject, &appleAuthTime, &appleAuthLineage, &appleConsentCutoff)
	if err != nil {
		if err == sql.ErrNoRows {
			return User{}, fmt.Errorf("get user by id: %w", ErrNotFound)
		}
		return User{}, fmt.Errorf("get user by id: %w", err)
	}
	sqliteScanUser(&u, createdAt, appleSubject, appleAuthTime, appleAuthLineage, appleConsentCutoff)
	return u, nil
}

// UpsertUserByAppleSubject upserts a user keyed by Apple's stable `sub`.
// INSERT OR IGNORE handles the "already exists" case; the user is then marked
// verified and re-fetched. A pre-existing email-only account with the same
// email causes the insert to be ignored without a matching apple_subject, and
// the subsequent select returns no row (account linking is a follow-up).
func (s *SQLiteStore) UpsertUserByAppleSubject(ctx context.Context, appleSubject, email string) (User, error) {
	_, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO users (id, email, email_verified, created_at, apple_subject)
		VALUES (?, ?, true, datetime('now'), ?)
	`, uuidV7(), email, appleSubject)
	if err != nil {
		return User{}, fmt.Errorf("upsert apple user insert: %w", err)
	}

	if _, err := s.db.ExecContext(ctx, `
		UPDATE users SET email_verified = true WHERE apple_subject = ?
	`, appleSubject); err != nil {
		return User{}, fmt.Errorf("upsert apple user verify: %w", err)
	}

	var u User
	var createdAt string
	var colSub, colAuthTime, colLineage, colCutoff sql.NullString
	err = s.db.QueryRowContext(ctx, `
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
	return u, nil
}
