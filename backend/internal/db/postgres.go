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

// GetUserByEmail returns a user by their email.
func (s *PostgresStore) GetUserByEmail(ctx context.Context, email string) (User, error) {
	var u User
	err := s.pool.QueryRow(ctx, `
		SELECT id, email, email_verified, created_at
		FROM users
		WHERE email = $1
	`, email).Scan(&u.ID, &u.Email, &u.EmailVerified, &u.CreatedAt)
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
	err := s.pool.QueryRow(ctx, `
		INSERT INTO users (id, email, email_verified, created_at)
		VALUES (gen_random_uuid(), $1, false, NOW())
		ON CONFLICT (email) DO NOTHING
		RETURNING id, email, email_verified, created_at
	`, email).Scan(&u.ID, &u.Email, &u.EmailVerified, &u.CreatedAt)
	if err != nil {
		// If the conflict prevented returning, fetch the existing user
		if errors.Is(err, pgx.ErrNoRows) {
			err = s.pool.QueryRow(ctx, `
				SELECT id, email, email_verified, created_at
				FROM users
				WHERE email = $1
			`, email).Scan(&u.ID, &u.Email, &u.EmailVerified, &u.CreatedAt)
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
	_, err := s.pool.Exec(ctx, `
		INSERT INTO refresh_tokens (id, user_id, token_hash, device_id, revoked, created_at)
		VALUES (gen_random_uuid(), $1, $2, $3, false, NOW())
	`, userID, tokenHash, deviceID)
	if err != nil {
		return fmt.Errorf("save refresh token: %w", err)
	}
	return nil
}

// GetRefreshToken returns a refresh token by its hash, including user info.
func (s *PostgresStore) GetRefreshToken(ctx context.Context, tokenHash string) (RefreshToken, error) {
	var t RefreshToken
	err := s.pool.QueryRow(ctx, `
		SELECT id, user_id, token_hash, device_id, revoked, created_at
		FROM refresh_tokens
		WHERE token_hash = $1
	`, tokenHash).Scan(&t.ID, &t.UserID, &t.TokenHash, &t.DeviceID, &t.Revoked, &t.CreatedAt)
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
	_, err := s.pool.Exec(ctx, `
		UPDATE refresh_tokens SET revoked = true WHERE id = $1
	`, tokenID)
	if err != nil {
		return fmt.Errorf("revoke refresh token: %w", err)
	}
	return nil
}

// RevokeAllUserSessions revokes all refresh tokens for a user.
func (s *PostgresStore) RevokeAllUserSessions(ctx context.Context, userID string) error {
	_, err := s.pool.Exec(ctx, `
		UPDATE refresh_tokens SET revoked = true WHERE user_id = $1 AND revoked = false
	`, userID)
	if err != nil {
		return fmt.Errorf("revoke all user sessions: %w", err)
	}
	return nil
}

// RevokeUserDeviceSessions revokes the refresh family of one device.
func (s *PostgresStore) RevokeUserDeviceSessions(ctx context.Context, userID, deviceID string) error {
	_, err := s.pool.Exec(ctx, `
		UPDATE refresh_tokens SET revoked = true
		WHERE user_id = $1 AND device_id = $2 AND revoked = false
	`, userID, deviceID)
	if err != nil {
		return fmt.Errorf("revoke user device sessions: %w", err)
	}
	return nil
}

// GetUserByID returns a user by their ID.
func (s *PostgresStore) GetUserByID(ctx context.Context, userID string) (User, error) {
	var u User
	err := s.pool.QueryRow(ctx, `
		SELECT id, email, email_verified, created_at
		FROM users
		WHERE id = $1
	`, userID).Scan(&u.ID, &u.Email, &u.EmailVerified, &u.CreatedAt)
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
	err := s.pool.QueryRow(ctx, `
		INSERT INTO users (id, email, email_verified, created_at, apple_subject)
		VALUES (gen_random_uuid(), $1, true, NOW(), $2)
		ON CONFLICT (apple_subject) WHERE apple_subject IS NOT NULL DO UPDATE
			SET email_verified = true
		RETURNING id, email, email_verified, created_at
	`, email, appleSubject).Scan(&u.ID, &u.Email, &u.EmailVerified, &u.CreatedAt)
	if err != nil {
		return User{}, fmt.Errorf("upsert apple user: %w", err)
	}
	return u, nil
}

// DB returns the underlying pool for use by migrations.
func (s *PostgresStore) DB() *pgxpool.Pool {
	return s.pool
}
