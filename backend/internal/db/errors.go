// Package db provides the Store interface and Postgres/SQLite implementations.
package db

import "errors"

var (
	// ErrNotFound is returned when a requested resource is not found.
	ErrNotFound = errors.New("not found")

	// ErrConflict is returned on a last-write-wins stale write: the client's
	// updated_at is older than the stored updated_at.
	ErrConflict = errors.New("conflict")

	// ErrCategoryExists is returned when creating a category whose name
	// (case-insensitive) already exists for the user.
	ErrCategoryExists = errors.New("category exists")

	// ErrInvalidCategoryID is returned when an entry create references a
	// category_id that does not exist or belong to the user — creates fail
	// loudly (422), unlike merges, which prune unknown ids. It is a
	// validation error (422), not a missing-resource error (404).
	ErrInvalidCategoryID = errors.New("invalid category id")

	// ErrInvalidEntryText is returned when an entry's activity_text is empty
	// (or blank after trimming). The handler surfaces it as a 422 validation
	// error; the store guards direct calls.
	ErrInvalidEntryText = errors.New("invalid entry text")

	// ErrEndBeforeStart is returned when an entry's ended_at is not after its
	// started_at. Because a partial PATCH can move only one side, the check is
	// performed in the store against the merged value; it is a validation error
	// (422), not a persistence error.
	ErrEndBeforeStart = errors.New("ended_at must be after started_at")

	// ErrDuplicateImport is returned when creating an entry whose
	// (user_id, source, source_ref) already exists (the partial unique index
	// on provenance). A source re-sending the same record (e.g. Screen Time
	// firing twice for the same interval) is rejected rather than duplicated.
	ErrDuplicateImport = errors.New("duplicate import")

	// ErrAttemptExists is returned by RotateRefreshToken when the refresh
	// attempt was already accepted by a concurrent duplicate delivery: the
	// winner's successor stands and the loser must recover it instead of
	// rotating forward.
	ErrAttemptExists = errors.New("refresh attempt already accepted")

	// ErrPredecessorRevoked is returned by RotateRefreshToken when the
	// predecessor was already revoked by a concurrent rotation: the
	// single-use guard (`AND revoked = false`) matched zero rows, so this
	// rotation committed nothing. The handler routes the loser to the
	// winner's receipt (same attempt) or to reuse handling (other attempt).
	ErrPredecessorRevoked = errors.New("refresh predecessor already revoked")
)
