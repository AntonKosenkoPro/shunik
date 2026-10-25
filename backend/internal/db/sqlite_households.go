package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// EnsureHousehold returns the user's household, creating one with the user
// as owner when the user has none.
func (s *SQLiteStore) EnsureHousehold(ctx context.Context, userID string) (Household, error) {
	h, err := s.GetHouseholdForUser(ctx, userID)
	if err == nil {
		return h, nil
	}
	if !isNotFound(err) {
		return Household{}, err
	}

	hid := uuidV7()
	now := fmtTime(time.Now().UTC())
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO households (id, created_at, updated_at, updated_by)
		VALUES (?, ?, ?, ?)
	`, hid, now, now, userID); err != nil {
		return Household{}, fmt.Errorf("ensure household insert: %w", err)
	}
	if _, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO household_members (household_id, user_id, added_by, joined_at)
		VALUES (?, ?, ?, ?)
	`, hid, userID, userID, now); err != nil {
		return Household{}, fmt.Errorf("ensure household member insert: %w", err)
	}
	return s.GetHouseholdForUser(ctx, userID)
}

// GetHouseholdForUser returns the user's household or ErrNotFound.
func (s *SQLiteStore) GetHouseholdForUser(ctx context.Context, userID string) (Household, error) {
	var h Household
	var createdAt, updatedAt string
	err := s.db.QueryRowContext(ctx, `
		SELECT h.id, h.created_at, h.updated_at, h.updated_by
		FROM households h
		JOIN household_members m ON m.household_id = h.id
		WHERE m.user_id = ?
	`, userID).Scan(&h.ID, &createdAt, &updatedAt, &h.UpdatedBy)
	if err != nil {
		if err == sql.ErrNoRows {
			return Household{}, ErrNotFound
		}
		return Household{}, fmt.Errorf("get household for user: %w", err)
	}
	h.CreatedAt, h.UpdatedAt = parseTime(createdAt), parseTime(updatedAt)
	return h, nil
}

// ListHouseholdMembers returns the household's owners with emails.
func (s *SQLiteStore) ListHouseholdMembers(ctx context.Context, householdID string) ([]HouseholdMember, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT m.household_id, m.user_id, u.email, m.added_by, m.joined_at
		FROM household_members m
		JOIN users u ON u.id = m.user_id
		WHERE m.household_id = ?
		ORDER BY m.joined_at ASC
	`, householdID)
	if err != nil {
		return nil, fmt.Errorf("list household members: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var out []HouseholdMember
	for rows.Next() {
		var m HouseholdMember
		var joinedAt string
		if err := rows.Scan(&m.HouseholdID, &m.UserID, &m.Email, &m.AddedBy, &joinedAt); err != nil {
			return nil, fmt.Errorf("list household members scan: %w", err)
		}
		m.JoinedAt = parseTime(joinedAt)
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list household members rows: %w", err)
	}
	return out, nil
}

// CreateInvite records an email invitation; re-inviting the same email
// replaces the pending invite.
func (s *SQLiteStore) CreateInvite(ctx context.Context, householdID, email, tokenHash, invitedBy string, expiresAt time.Time) (HouseholdInvite, error) {
	id := uuidV7()
	now := fmtTime(time.Now().UTC())
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return HouseholdInvite{}, fmt.Errorf("create invite begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM household_invites
		WHERE household_id = ? AND email = ? AND accepted_at IS NULL
	`, householdID, email); err != nil {
		return HouseholdInvite{}, fmt.Errorf("create invite replace: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO household_invites (id, household_id, email, token_hash, invited_by, expires_at, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
	`, id, householdID, email, tokenHash, invitedBy, fmtTime(expiresAt.UTC()), now); err != nil {
		return HouseholdInvite{}, fmt.Errorf("create invite insert: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return HouseholdInvite{}, fmt.Errorf("create invite commit: %w", err)
	}
	return HouseholdInvite{
		ID: id, HouseholdID: householdID, Email: email,
		InvitedBy: invitedBy, ExpiresAt: expiresAt.UTC(), CreatedAt: parseTime(now),
	}, nil
}

// GetInviteByTokenHash returns the invite for a token hash or ErrNotFound.
func (s *SQLiteStore) GetInviteByTokenHash(ctx context.Context, tokenHash string) (HouseholdInvite, error) {
	var in HouseholdInvite
	var expiresAt, createdAt string
	var acceptedAt sql.NullString
	err := s.db.QueryRowContext(ctx, `
		SELECT id, household_id, email, invited_by, expires_at, accepted_at, created_at
		FROM household_invites
		WHERE token_hash = ?
	`, tokenHash).Scan(&in.ID, &in.HouseholdID, &in.Email, &in.InvitedBy, &expiresAt, &acceptedAt, &createdAt)
	if err != nil {
		if err == sql.ErrNoRows {
			return HouseholdInvite{}, ErrNotFound
		}
		return HouseholdInvite{}, fmt.Errorf("get invite by token: %w", err)
	}
	in.ExpiresAt, in.CreatedAt = parseTime(expiresAt), parseTime(createdAt)
	if acceptedAt.Valid {
		t := parseTime(acceptedAt.String)
		in.AcceptedAt = &t
	}
	return in, nil
}

// AcceptInvite joins the user to the invite's household, marking the invite
// accepted in the same transaction. Consumed or expired invites behave as
// missing; users already in a household are rejected.
func (s *SQLiteStore) AcceptInvite(ctx context.Context, inviteID, userID string) (Household, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Household{}, fmt.Errorf("accept invite begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var householdID string
	var expiresAt string
	var acceptedAt sql.NullString
	err = tx.QueryRowContext(ctx, `
		SELECT household_id, expires_at, accepted_at
		FROM household_invites
		WHERE id = ?
	`, inviteID).Scan(&householdID, &expiresAt, &acceptedAt)
	if err != nil {
		if err == sql.ErrNoRows {
			return Household{}, ErrNotFound
		}
		return Household{}, fmt.Errorf("accept invite select: %w", err)
	}
	if !acceptedAt.Valid && time.Now().UTC().After(parseTime(expiresAt)) {
		return Household{}, ErrNotFound
	}
	if acceptedAt.Valid {
		return Household{}, ErrNotFound
	}
	var existing int
	if err := tx.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM household_members WHERE user_id = ?
	`, userID).Scan(&existing); err != nil {
		return Household{}, fmt.Errorf("accept invite membership check: %w", err)
	}
	if existing > 0 {
		return Household{}, ErrAlreadyMember
	}
	now := fmtTime(time.Now().UTC())
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO household_members (household_id, user_id, added_by, joined_at)
		VALUES (?, ?, ?, ?)
	`, householdID, userID, userID, now); err != nil {
		return Household{}, fmt.Errorf("accept invite member insert: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE household_invites SET accepted_at = ? WHERE id = ?
	`, now, inviteID); err != nil {
		return Household{}, fmt.Errorf("accept invite mark: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE households SET updated_at = ?, updated_by = ? WHERE id = ?
	`, now, userID, householdID); err != nil {
		return Household{}, fmt.Errorf("accept invite touch: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return Household{}, fmt.Errorf("accept invite commit: %w", err)
	}
	return s.GetHouseholdForUser(ctx, userID)
}

// RemoveMember deletes one membership.
func (s *SQLiteStore) RemoveMember(ctx context.Context, householdID, userID string) error {
	res, err := s.db.ExecContext(ctx, `
		DELETE FROM household_members
		WHERE household_id = ? AND user_id = ?
	`, householdID, userID)
	if err != nil {
		return fmt.Errorf("remove member: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("remove member count: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// isNotFound reports whether err wraps ErrNotFound.
func isNotFound(err error) bool {
	return errors.Is(err, ErrNotFound)
}
