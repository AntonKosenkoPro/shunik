package db

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// EnsureHousehold returns the user's household, creating one with the user
// as owner when the user has none.
func (s *PostgresStore) EnsureHousehold(ctx context.Context, userID string) (Household, error) {
	h, err := s.GetHouseholdForUser(ctx, userID)
	if err == nil {
		return h, nil
	}
	if !errors.Is(err, ErrNotFound) {
		return Household{}, err
	}

	hid := uuidV7()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Household{}, fmt.Errorf("ensure household begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `
		INSERT INTO households (id, created_at, updated_at, updated_by)
		VALUES ($1, NOW(), NOW(), $2)
	`, hid, userID); err != nil {
		return Household{}, fmt.Errorf("ensure household insert: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO household_members (household_id, user_id, added_by, joined_at)
		VALUES ($1, $2, $2, NOW())
		ON CONFLICT DO NOTHING
	`, hid, userID); err != nil {
		return Household{}, fmt.Errorf("ensure household member insert: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return Household{}, fmt.Errorf("ensure household commit: %w", err)
	}
	return s.GetHouseholdForUser(ctx, userID)
}

// GetHouseholdForUser returns the user's household or ErrNotFound.
func (s *PostgresStore) GetHouseholdForUser(ctx context.Context, userID string) (Household, error) {
	var h Household
	err := s.pool.QueryRow(ctx, `
		SELECT h.id, h.created_at, h.updated_at, h.updated_by
		FROM households h
		JOIN household_members m ON m.household_id = h.id
		WHERE m.user_id = $1
	`, userID).Scan(&h.ID, &h.CreatedAt, &h.UpdatedAt, &h.UpdatedBy)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Household{}, ErrNotFound
		}
		return Household{}, fmt.Errorf("get household for user: %w", err)
	}
	return h, nil
}

// ListHouseholdMembers returns the household's owners with emails.
func (s *PostgresStore) ListHouseholdMembers(ctx context.Context, householdID string) ([]HouseholdMember, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT m.household_id, m.user_id, u.email, m.added_by, m.joined_at
		FROM household_members m
		JOIN users u ON u.id = m.user_id
		WHERE m.household_id = $1
		ORDER BY m.joined_at ASC
	`, householdID)
	if err != nil {
		return nil, fmt.Errorf("list household members: %w", err)
	}
	defer rows.Close()
	var out []HouseholdMember
	for rows.Next() {
		var m HouseholdMember
		if err := rows.Scan(&m.HouseholdID, &m.UserID, &m.Email, &m.AddedBy, &m.JoinedAt); err != nil {
			return nil, fmt.Errorf("list household members scan: %w", err)
		}
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list household members rows: %w", err)
	}
	return out, nil
}

// CreateInvite records an email invitation; re-inviting the same email
// replaces the pending invite.
func (s *PostgresStore) CreateInvite(ctx context.Context, householdID, email, tokenHash, invitedBy string, expiresAt time.Time) (HouseholdInvite, error) {
	id := uuidV7()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return HouseholdInvite{}, fmt.Errorf("create invite begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `
		DELETE FROM household_invites
		WHERE household_id = $1 AND email = $2 AND accepted_at IS NULL
	`, householdID, email); err != nil {
		return HouseholdInvite{}, fmt.Errorf("create invite replace: %w", err)
	}
	var in HouseholdInvite
	err = tx.QueryRow(ctx, `
		INSERT INTO household_invites (id, household_id, email, token_hash, invited_by, expires_at, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, NOW())
		RETURNING id, household_id, email, invited_by, expires_at, created_at
	`, id, householdID, email, tokenHash, invitedBy, expiresAt.UTC()).Scan(
		&in.ID, &in.HouseholdID, &in.Email, &in.InvitedBy, &in.ExpiresAt, &in.CreatedAt)
	if err != nil {
		return HouseholdInvite{}, fmt.Errorf("create invite insert: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return HouseholdInvite{}, fmt.Errorf("create invite commit: %w", err)
	}
	return in, nil
}

// GetInviteByTokenHash returns the invite for a token hash or ErrNotFound.
func (s *PostgresStore) GetInviteByTokenHash(ctx context.Context, tokenHash string) (HouseholdInvite, error) {
	var in HouseholdInvite
	err := s.pool.QueryRow(ctx, `
		SELECT id, household_id, email, invited_by, expires_at, accepted_at, created_at
		FROM household_invites
		WHERE token_hash = $1
	`, tokenHash).Scan(&in.ID, &in.HouseholdID, &in.Email, &in.InvitedBy,
		&in.ExpiresAt, &in.AcceptedAt, &in.CreatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return HouseholdInvite{}, ErrNotFound
		}
		return HouseholdInvite{}, fmt.Errorf("get invite by token: %w", err)
	}
	return in, nil
}

// AcceptInvite joins the user to the invite's household, marking the invite
// accepted in the same transaction. Consumed or expired invites behave as
// missing; users already in a household are rejected.
func (s *PostgresStore) AcceptInvite(ctx context.Context, inviteID, userID string) (Household, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Household{}, fmt.Errorf("accept invite begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var householdID string
	var expiresAt time.Time
	var acceptedAt *time.Time
	err = tx.QueryRow(ctx, `
		SELECT household_id, expires_at, accepted_at
		FROM household_invites
		WHERE id = $1
		FOR UPDATE
	`, inviteID).Scan(&householdID, &expiresAt, &acceptedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Household{}, ErrNotFound
		}
		return Household{}, fmt.Errorf("accept invite select: %w", err)
	}
	if acceptedAt != nil || time.Now().UTC().After(expiresAt) {
		return Household{}, ErrNotFound
	}
	var existing int
	if err := tx.QueryRow(ctx, `
		SELECT COUNT(*) FROM household_members WHERE user_id = $1
	`, userID).Scan(&existing); err != nil {
		return Household{}, fmt.Errorf("accept invite membership check: %w", err)
	}
	if existing > 0 {
		return Household{}, ErrAlreadyMember
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO household_members (household_id, user_id, added_by, joined_at)
		VALUES ($1, $2, $2, NOW())
	`, householdID, userID); err != nil {
		return Household{}, fmt.Errorf("accept invite member insert: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE household_invites SET accepted_at = NOW() WHERE id = $1
	`, inviteID); err != nil {
		return Household{}, fmt.Errorf("accept invite mark: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE households SET updated_at = NOW(), updated_by = $2 WHERE id = $1
	`, householdID, userID); err != nil {
		return Household{}, fmt.Errorf("accept invite touch: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return Household{}, fmt.Errorf("accept invite commit: %w", err)
	}
	return s.GetHouseholdForUser(ctx, userID)
}

// RemoveMember deletes one membership.
func (s *PostgresStore) RemoveMember(ctx context.Context, householdID, userID string) error {
	tag, err := s.pool.Exec(ctx, `
		DELETE FROM household_members
		WHERE household_id = $1 AND user_id = $2
	`, householdID, userID)
	if err != nil {
		return fmt.Errorf("remove member: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}
