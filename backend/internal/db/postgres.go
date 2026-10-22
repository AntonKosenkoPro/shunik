package db

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// PostgresStore implements Store using PostgreSQL via pgx.
type PostgresStore struct {
	pool *pgxpool.Pool
}

// hostedMaxConns bounds the pgx pool for hosted Postgres (Supabase Free,
// migrate-db-to-supabase-free). pgx defaults are CPU-scaled and assume a
// local database; against a hosted micro a burst turns into connection
// churn and risks plan limits. Tuned to 4–8 by the k6 probe (task 4.2).
const hostedMaxConns = 5

// NewPostgresStore creates a new PostgresStore and connects to the database.
func NewPostgresStore(ctx context.Context, databaseURL string) (*PostgresStore, error) {
	config, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse database config: %w", err)
	}
	config.MaxConns = hostedMaxConns

	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		return nil, fmt.Errorf("create connection pool: %w", err)
	}

	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping database: %w", err)
	}

	return &PostgresStore{pool: pool}, nil
}

// Close closes the database connection pool.
func (s *PostgresStore) Close() error {
	s.pool.Close()
	return nil
}

// pgUserColumns is the full user projection, including the Apple
// session-lineage and consent-cutoff columns added by 009.
const pgUserColumns = `id, email, email_verified, created_at,
	apple_subject, apple_auth_time, apple_auth_lineage, apple_consent_cutoff`

// pgScanUser scans a user row in pgUserColumns order. Nullable Apple columns
// decode into pointer fields (NULL → nil); a revoked-but-live account keeps
// its identity columns while its lineage is nulled.
func pgScanUser(sc pgxScanner, u *User) error {
	return sc.Scan(&u.ID, &u.Email, &u.EmailVerified, &u.CreatedAt,
		&u.AppleSubject, &u.AppleAuthTime, &u.AppleAuthLineage, &u.AppleConsentCutoff)
}

// GetUserByEmail returns a user by their email.
func (s *PostgresStore) GetUserByEmail(ctx context.Context, email string) (User, error) {
	var u User
	err := pgScanUser(s.pool.QueryRow(ctx, `
		SELECT `+pgUserColumns+`
		FROM users
		WHERE email = $1
	`, email), &u)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return User{}, fmt.Errorf("get user by email: %w", ErrNotFound)
		}
		return User{}, fmt.Errorf("get user by email: %w", err)
	}
	return u, nil
}

// UpsertUser creates a user if not exists, returns the user.
func (s *PostgresStore) UpsertUser(ctx context.Context, email string) (User, error) {
	var u User
	err := pgScanUser(s.pool.QueryRow(ctx, `
		INSERT INTO users (id, email, email_verified, created_at)
		VALUES (gen_random_uuid(), $1, false, NOW())
		ON CONFLICT (email) DO NOTHING
		RETURNING `+pgUserColumns+`
	`, email), &u)
	if err != nil {
		// If the conflict prevented returning, fetch the existing user
		if errors.Is(err, pgx.ErrNoRows) {
			err = pgScanUser(s.pool.QueryRow(ctx, `
				SELECT `+pgUserColumns+`
				FROM users
				WHERE email = $1
			`, email), &u)
		}
		if err != nil {
			return User{}, fmt.Errorf("upsert user: %w", err)
		}
	}
	return u, nil
}

// SetUserVerified marks a user's email as verified.
func (s *PostgresStore) SetUserVerified(ctx context.Context, userID string) error {
	_, err := s.pool.Exec(ctx, `
		UPDATE users SET email_verified = true WHERE id = $1
	`, userID)
	if err != nil {
		return fmt.Errorf("set user verified: %w", err)
	}
	return nil
}

// SaveOTP stores a new OTP code for a user with the given attempt budget.
func (s *PostgresStore) SaveOTP(ctx context.Context, userID string, codeHash string, expiresAt time.Time, maxAttempts int) error {
	_, err := s.pool.Exec(ctx, `
		INSERT INTO otp_codes (id, user_id, code_hash, expires_at, attempts, max_attempts, created_at)
		VALUES (gen_random_uuid(), $1, $2, $3, 0, $4, NOW())
	`, userID, codeHash, expiresAt, maxAttempts)
	if err != nil {
		return fmt.Errorf("save otp: %w", err)
	}
	return nil
}

// GetValidOTP returns the latest non-expired, non-exhausted OTP for a user.
func (s *PostgresStore) GetValidOTP(ctx context.Context, userID string) (OTP, error) {
	var o OTP
	err := s.pool.QueryRow(ctx, `
		SELECT id, user_id, code_hash, expires_at, attempts, max_attempts
		FROM otp_codes
		WHERE user_id = $1
		  AND expires_at > NOW()
		  AND attempts < max_attempts
		ORDER BY created_at DESC
		LIMIT 1
	`, userID).Scan(&o.ID, &o.UserID, &o.CodeHash, &o.ExpiresAt, &o.Attempts, &o.MaxAttempts)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return OTP{}, fmt.Errorf("get valid otp: %w", ErrNotFound)
		}
		return OTP{}, fmt.Errorf("get valid otp: %w", err)
	}
	return o, nil
}

// IncrementOTPAttempts increments the attempt counter for an OTP.
func (s *PostgresStore) IncrementOTPAttempts(ctx context.Context, otpID string) error {
	_, err := s.pool.Exec(ctx, `
		UPDATE otp_codes SET attempts = attempts + 1 WHERE id = $1
	`, otpID)
	if err != nil {
		return fmt.Errorf("increment otp attempts: %w", err)
	}
	return nil
}

// MarkOTPExhausted marks an OTP as exhausted (max attempts reached).
func (s *PostgresStore) MarkOTPExhausted(ctx context.Context, otpID string) error {
	_, err := s.pool.Exec(ctx, `
		UPDATE otp_codes SET attempts = max_attempts WHERE id = $1
	`, otpID)
	if err != nil {
		return fmt.Errorf("mark otp exhausted: %w", err)
	}
	return nil
}

// SaveRefreshToken stores a new refresh token.
func (s *PostgresStore) SaveRefreshToken(ctx context.Context, userID string, tokenHash string, deviceID string) error {
	return s.SaveRefreshTokenWithAuth(ctx, userID, tokenHash, deviceID, nil, "")
}

// SaveRefreshTokenWithAuth stores a refresh token with its session's Apple
// auth pair (nil/empty = email-OTP session, unaffected by Apple cutoffs).
func (s *PostgresStore) SaveRefreshTokenWithAuth(ctx context.Context, userID string, tokenHash string, deviceID string, authTime *time.Time, authLineage string) error {
	var lineage any
	if authLineage != "" {
		lineage = authLineage
	}
	_, err := s.pool.Exec(ctx, `
		INSERT INTO refresh_tokens (id, user_id, token_hash, device_id, revoked, created_at, auth_time, auth_lineage)
		VALUES (gen_random_uuid(), $1, $2, $3, false, NOW(), $4, $5)
	`, userID, tokenHash, deviceID, authTime, lineage)
	if err != nil {
		return fmt.Errorf("save refresh token: %w", err)
	}
	return nil
}

// GetRefreshToken returns a refresh token by its hash, including user info.
func (s *PostgresStore) GetRefreshToken(ctx context.Context, tokenHash string) (RefreshToken, error) {
	var t RefreshToken
	err := s.pool.QueryRow(ctx, `
		SELECT id, user_id, token_hash, device_id, revoked, created_at, auth_time, auth_lineage
		FROM refresh_tokens
		WHERE token_hash = $1
	`, tokenHash).Scan(&t.ID, &t.UserID, &t.TokenHash, &t.DeviceID, &t.Revoked, &t.CreatedAt, &t.AuthTime, &t.AuthLineage)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return RefreshToken{}, fmt.Errorf("get refresh token: %w", ErrNotFound)
		}
		return RefreshToken{}, fmt.Errorf("get refresh token: %w", err)
	}
	return t, nil
}

// RevokeRefreshToken marks a refresh token as revoked.
func (s *PostgresStore) RevokeRefreshToken(ctx context.Context, tokenID string) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("revoke refresh token: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `
		UPDATE refresh_tokens SET revoked = true WHERE id = $1
	`, tokenID); err != nil {
		return fmt.Errorf("revoke refresh token: %w", err)
	}
	if err := closeSuccessorReceiptsPG(ctx, tx, tokenID); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("revoke refresh token: %w", err)
	}
	return nil
}

// RevokeAllUserSessions revokes all refresh tokens for a user.
func (s *PostgresStore) RevokeAllUserSessions(ctx context.Context, userID string) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("revoke all user sessions: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `
		UPDATE refresh_tokens SET revoked = true WHERE user_id = $1 AND revoked = false
	`, userID); err != nil {
		return fmt.Errorf("revoke all user sessions: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE refresh_recovery_receipts SET consumed = true
		WHERE user_id = $1 AND consumed = false
	`, userID); err != nil {
		return fmt.Errorf("revoke all user sessions: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("revoke all user sessions: %w", err)
	}
	return nil
}

// RevokeUserDeviceSessions revokes the refresh family of one device.
func (s *PostgresStore) RevokeUserDeviceSessions(ctx context.Context, userID, deviceID string) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("revoke user device sessions: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `
		UPDATE refresh_tokens SET revoked = true
		WHERE user_id = $1 AND device_id = $2 AND revoked = false
	`, userID, deviceID); err != nil {
		return fmt.Errorf("revoke user device sessions: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE refresh_recovery_receipts SET consumed = true
		WHERE user_id = $1 AND device_id = $2 AND consumed = false
	`, userID, deviceID); err != nil {
		return fmt.Errorf("revoke user device sessions: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("revoke user device sessions: %w", err)
	}
	return nil
}

// closeSuccessorReceiptsPG closes the pending receipts whose successor is
// the revoked token, so a replayed attempt cannot recreate the session.
func closeSuccessorReceiptsPG(ctx context.Context, tx pgx.Tx, tokenID string) error {
	if _, err := tx.Exec(ctx, `
		UPDATE refresh_recovery_receipts SET consumed = true
		WHERE successor_hash = (SELECT token_hash FROM refresh_tokens WHERE id = $1)
		  AND consumed = false
	`, tokenID); err != nil {
		return fmt.Errorf("revoke refresh token: %w", err)
	}
	return nil
}

// RotateRefreshToken atomically revokes the predecessor, inserts the
// successor, records the pending recovery receipt, and closes the receipt
// the predecessor itself recovered. Statements touch refresh_tokens before
// refresh_recovery_receipts — the same lock order as the revocation paths —
// so a concurrent logout/device revocation cannot deadlock against rotation.
// The predecessor revocation is single-use guarded (`AND revoked = false`):
// a concurrent rotation that already consumed it gets ErrPredecessorRevoked
// and commits nothing, so cross-attempt races cannot fork the device family.
// The receipt insert arbitrates same-attempt duplicates (ErrAttemptExists).
func (s *PostgresStore) RotateRefreshToken(ctx context.Context, args RotateArgs) (RotateResult, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// Account lifecycle fence first (consistent lock order: the account row
	// before the family rows, matching purge). A purge that removed the
	// account races here as ErrUserMissing — never a partial successor and
	// never a reuse burn: the handler maps it to an ordinary authentication
	// failure without recovery or revocation.
	var one int
	if err := tx.QueryRow(ctx, `
		SELECT 1 FROM users WHERE id = $1 FOR UPDATE
	`, args.UserID).Scan(&one); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return RotateResult{}, fmt.Errorf("rotate refresh token: %w", ErrUserMissing)
		}
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", err)
	}

	// Single-use guard: only a live predecessor rotates. A concurrent
	// rotation that already revoked it matches zero rows and loses here,
	// before any successor or receipt is written.
	updateres, err := tx.Exec(ctx, `
		UPDATE refresh_tokens SET revoked = true
		WHERE id = $1 AND revoked = false
	`, args.PredecessorID)
	if err != nil {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", err)
	}
	if updateres.RowsAffected() == 0 {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", ErrPredecessorRevoked)
	}

	var out RotateResult
	// The successor inherits the predecessor's auth lineage in the same
	// statement, so a rotation can never mint a lineage-clean token from a
	// cutoff session — rotation cannot evade the cutoff. A purge that
	// removed the account races here as a zero-row copy.
	if err := tx.QueryRow(ctx, `
		INSERT INTO refresh_tokens (id, user_id, token_hash, device_id, revoked, created_at, auth_time, auth_lineage)
		SELECT gen_random_uuid(), $1, $2, $3, false, NOW(), auth_time, auth_lineage
		FROM refresh_tokens WHERE id = $4
		RETURNING id, created_at
	`, args.UserID, args.SuccessorHash, args.DeviceID, args.PredecessorID).Scan(&out.SuccessorID, &out.SuccessorCreatedAt); err != nil {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", err)
	}

	if _, err := tx.Exec(ctx, `
		UPDATE refresh_recovery_receipts SET consumed = true
		WHERE successor_hash = $1 AND consumed = false
	`, args.PredecessorHash); err != nil {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", err)
	}

	res, err := tx.Exec(ctx, `
		INSERT INTO refresh_recovery_receipts
			(attempt_hash, user_id, device_id, predecessor_hash, successor_hash,
			 sealed_successor, expires_at, consumed, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, false, NOW())
		ON CONFLICT (attempt_hash) DO NOTHING
	`, args.AttemptHash, args.UserID, args.DeviceID, args.PredecessorHash,
		args.SuccessorHash, args.SealedSuccessor, args.ExpiresAt)
	if err != nil {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", err)
	}
	if res.RowsAffected() == 0 {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", ErrAttemptExists)
	}

	if err := pruneRecoveryReceiptsPG(ctx, tx, args.PruneConsumedBefore); err != nil {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return RotateResult{}, fmt.Errorf("rotate refresh token: %w", err)
	}
	return out, nil
}

// pruneRecoveryReceiptsPG deletes consumed receipts long past their expiry.
// Consumed rows are kept while a very late duplicate replay could still
// arrive (it turns into a harmless 409 instead of a family-burning reuse);
// only rows expired well before the cutoff are swept, so retention stays
// bounded without a background job. Capped per rotation so a backlog drains
// incrementally instead of lengthening one transaction's critical section.
func pruneRecoveryReceiptsPG(ctx context.Context, tx pgx.Tx, before time.Time) error {
	if before.IsZero() {
		return nil
	}
	if _, err := tx.Exec(ctx, `
		DELETE FROM refresh_recovery_receipts
		WHERE ctid IN (
			SELECT ctid FROM refresh_recovery_receipts
			WHERE consumed = true AND expires_at < $1
			LIMIT 100
		)
	`, before); err != nil {
		return fmt.Errorf("prune recovery receipts: %w", err)
	}
	return nil
}

// FindRecoveryReceipt returns the pending receipt for an attempt hash.
func (s *PostgresStore) FindRecoveryReceipt(ctx context.Context, attemptHash string) (RecoveryReceipt, error) {
	var rc RecoveryReceipt
	err := s.pool.QueryRow(ctx, `
		SELECT attempt_hash, user_id, device_id, predecessor_hash, successor_hash,
		       sealed_successor, expires_at, consumed, created_at
		FROM refresh_recovery_receipts
		WHERE attempt_hash = $1
	`, attemptHash).Scan(
		&rc.AttemptHash, &rc.UserID, &rc.DeviceID, &rc.PredecessorHash,
		&rc.SuccessorHash, &rc.SealedSuccessor, &rc.ExpiresAt, &rc.Consumed, &rc.CreatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return RecoveryReceipt{}, fmt.Errorf("find recovery receipt: %w", ErrNotFound)
		}
		return RecoveryReceipt{}, fmt.Errorf("find recovery receipt: %w", err)
	}
	return rc, nil
}

// ConsumeRecoveryReceipt closes a pending receipt without revoking anything.
func (s *PostgresStore) ConsumeRecoveryReceipt(ctx context.Context, attemptHash string) error {
	if _, err := s.pool.Exec(ctx, `
		UPDATE refresh_recovery_receipts SET consumed = true
		WHERE attempt_hash = $1 AND consumed = false
	`, attemptHash); err != nil {
		return fmt.Errorf("consume recovery receipt: %w", err)
	}
	return nil
}

// GetUserByID returns a user by their ID.
func (s *PostgresStore) GetUserByID(ctx context.Context, userID string) (User, error) {
	var u User
	err := pgScanUser(s.pool.QueryRow(ctx, `
		SELECT `+pgUserColumns+`
		FROM users
		WHERE id = $1
	`, userID), &u)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return User{}, fmt.Errorf("get user by id: %w", ErrNotFound)
		}
		return User{}, fmt.Errorf("get user by id: %w", err)
	}
	return u, nil
}

// UpsertUserByAppleSubject upserts a user keyed by Apple's stable `sub`.
// The email is stored on first sign-in; on later sign-ins (ON CONFLICT) the
// existing email is kept and the user is marked verified. The conflict target
// must repeat the partial index predicate (idx_users_apple_subject is
// `WHERE apple_subject IS NOT NULL`); omitting it fails with SQLSTATE 42P10.
func (s *PostgresStore) UpsertUserByAppleSubject(ctx context.Context, appleSubject, email string) (User, error) {
	var u User
	err := pgScanUser(s.pool.QueryRow(ctx, `
		INSERT INTO users (id, email, email_verified, created_at, apple_subject)
		VALUES (gen_random_uuid(), $1, true, NOW(), $2)
		ON CONFLICT (apple_subject) WHERE apple_subject IS NOT NULL DO UPDATE
			SET email_verified = true
		RETURNING `+pgUserColumns+`
	`, email, appleSubject), &u)
	if err != nil {
		return User{}, fmt.Errorf("upsert apple user: %w", err)
	}
	return u, nil
}

// DB returns the underlying pool for use by migrations.
func (s *PostgresStore) DB() *pgxpool.Pool {
	return s.pool
}
