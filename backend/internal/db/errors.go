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

	// ErrUserMissing is returned when an account-scoped write finds its
	// account already purged. Handlers map it to an ordinary authentication
	// failure — never to deletion proof, recovery, or a partial write.
	ErrUserMissing = errors.New("user account no longer exists")

	// ErrAppleRevocationPending is returned by the fenced Apple upsert when
	// a durable revocation job is still pending for the same Apple subject:
	// accepting a new grant now could be invalidated by the outstanding
	// revoke. The caller surfaces a retryable 503 without consuming the
	// authorization code or creating a session.
	ErrAppleRevocationPending = errors.New("apple revocation pending for subject")

	// ErrAppleEmailInUse is returned by the fenced Apple upsert when the
	// presented Apple identity's email already belongs to a different
	// account (email-OTP or another Apple subject). Identities are never
	// merged: the handler maps it to 409 apple_email_in_use and the client
	// signs in with email instead.
	ErrAppleEmailInUse = errors.New("apple email already registered")

	// ErrAppleCredentialMissing is returned by PurgeUser when an
	// Apple-identity account reaches the purge transaction without a stored
	// revocable credential (e.g. a consent-revocation callback erased the
	// vault between the handler's pre-check and the purge). The transaction
	// rolls back — nothing is deleted — and the handler maps it to 409
	// apple_credential_required: required revocation material must exist
	// under the same lock that deletes the account, never merely observed
	// before it.
	ErrAppleCredentialMissing = errors.New("apple credential missing for purge")

	// ErrNotificationReplay is returned when an Apple server-to-server
	// notification id was already processed. The caller treats it as an
	// idempotent no-op (HTTP 200, no state change).
	ErrNotificationReplay = errors.New("apple notification already processed")

	// ErrAlreadyMember is returned when a household join is attempted by a
	// user who already belongs to a household (day-1: one household per
	// user). The handler maps it to 409 already_member.
	ErrAlreadyMember = errors.New("user already belongs to a household")

	// ErrInvalidPetID is returned when a write references a pet id that
	// does not exist in the household — unknown pet, or another
	// household's pet (never distinguished, no cross-household leak). The
	// same sentinel covers unknown courses/documents' pets ("unknown
	// reference" shape). The handler maps it to 422 invalid_pet_id.
	ErrInvalidPetID = errors.New("invalid pet id")
)
