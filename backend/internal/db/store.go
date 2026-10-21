package db

import (
	"context"
	"time"
)

// User represents a registered user.
type User struct {
	ID            string    `json:"id"`
	Email         string    `json:"email"`
	EmailVerified bool      `json:"email_verified"`
	CreatedAt     time.Time `json:"created_at"`
}

// OTP represents a one-time password code.
type OTP struct {
	ID          string    `json:"id"`
	UserID      string    `json:"user_id"`
	CodeHash    string    `json:"-"`
	ExpiresAt   time.Time `json:"expires_at"`
	Attempts    int       `json:"attempts"`
	MaxAttempts int       `json:"max_attempts"`
}

// RefreshToken represents a stored refresh token.
type RefreshToken struct {
	ID        string    `json:"id"`
	UserID    string    `json:"user_id"`
	TokenHash string    `json:"-"`
	DeviceID  string    `json:"device_id,omitempty"`
	Revoked   bool      `json:"revoked"`
	CreatedAt time.Time `json:"created_at"`
}

// RecoveryReceipt is the pending record of one accepted refresh rotation
// (fix-refresh-response-loss). It binds an attempt to one predecessor,
// account, and device and carries the successor refresh credential in
// authenticated-encrypted form plus the successor's fixed expiry. Only
// hashes and the sealed blob are persisted — never plaintext tokens or raw
// attempt identifiers. A receipt closes (Consumed) when its successor is
// consumed by the next rotation, or on logout/revocation; expiry is checked
// lazily on access, so no background sweeper is needed.
type RecoveryReceipt struct {
	AttemptHash     string
	UserID          string
	DeviceID        string
	PredecessorHash string
	SuccessorHash   string
	SealedSuccessor []byte
	ExpiresAt       time.Time
	Consumed        bool
	CreatedAt       time.Time
}

// RotateArgs carries one transactional refresh rotation: revoke the
// predecessor, insert the successor, and record the pending recovery
// receipt. SuccessorHash and AttemptHash are SHA-256 hex digests;
// SealedSuccessor is the AES-256-GCM sealed successor; ExpiresAt is the
// successor's fixed refresh expiry (retries never extend it).
// PruneConsumedBefore bounds retention: receipts that are consumed and
// expired before it are deleted opportunistically; zero disables pruning.
type RotateArgs struct {
	UserID              string
	DeviceID            string
	PredecessorID       string
	PredecessorHash     string
	SuccessorHash       string
	AttemptHash         string
	SealedSuccessor     []byte
	ExpiresAt           time.Time
	PruneConsumedBefore time.Time
}

// RotateResult reports the committed successor row.
type RotateResult struct {
	SuccessorID        string
	SuccessorCreatedAt time.Time
}

// CategoryTag is a denormalized category (id + name + icon) attached to an
// entry in API responses. It is never written on its own.
type CategoryTag struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Icon string `json:"icon"`
}

// Category is a many-to-many tag an entry may carry.
type Category struct {
	ID        string    `json:"id"`
	UserID    string    `json:"-"`
	Name      string    `json:"name"`
	Icon      string    `json:"icon"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

// Entry is one timed interval. Entries are self-contained: ActivityText is
// the entry's own display text (trimmed, case-sensitive identity — `Gym` ≠
// `GYM`), Categories are the entry's own ordered tags (stored via
// entry_categories), and Notes belong to the entry. Nothing is resolved from
// another record at read time, so history never mutates retroactively.
// Source/SourceRef record entry provenance (where the entry came from:
// manual, widget, siri, control, screentime, garmin, ...); Source defaults
// to "manual" and SourceRef is null for entries created without them.
type Entry struct {
	ID              string        `json:"id"`
	UserID          string        `json:"-"`
	ActivityText    string        `json:"activity_text"`
	Notes           string        `json:"notes"`
	StartedAt       time.Time     `json:"started_at"`
	EndedAt         *time.Time    `json:"ended_at"`
	DurationSeconds *int          `json:"duration_seconds"`
	Source          string        `json:"source"`
	SourceRef       *string       `json:"source_ref"`
	Categories      []CategoryTag `json:"categories"`
	CreatedAt       time.Time     `json:"created_at"`
	UpdatedAt       time.Time     `json:"updated_at"`
}

// Tombstone records a hard delete that other devices must apply.
type Tombstone struct {
	Resource  string    `json:"resource"`
	ID        string    `json:"id"`
	DeletedAt time.Time `json:"deleted_at"`
}

// EntryFilter carries the optional GET /entries query parameters.
type EntryFilter struct {
	From          *time.Time // include entries with started_at >= From
	To            *time.Time // include entries with started_at <= To (inclusive upper bound)
	CategoryID    string     // restrict to entries carrying this category tag
	Limit         int        // page size; 0 → default
	Cursor        string     // opaque pagination cursor from a previous response
	ModifiedSince *time.Time // include entries with updated_at > ModifiedSince (delta pull-sync; nil = full)
}

// NullableTime represents an optional timestamp on a partial update: Set=false
// leaves the column unchanged; Set=true with Valid=false sets it to NULL;
// Set=true with Valid=true sets it to Value.
type NullableTime struct {
	Set   bool
	Valid bool
	Value time.Time
}

// EntryPatch is a partial update for an entry (PATCH /entries/{id}). Nil/zero
// fields are left unchanged. CategoryIDs nil leaves the entry's tags; a
// non-nil slice replaces them in order (unknown or non-owned ids are pruned,
// the remainder kept — a merge never fails the sync cycle). UpdatedAt is the
// LWW version (required).
type EntryPatch struct {
	ActivityText *string
	Notes        *string
	CategoryIDs  *[]CategoryTag
	StartedAt    *time.Time
	EndedAt      NullableTime // Set=false leaves ended_at unchanged
	UpdatedAt    time.Time
}

// CategoryPatch is a partial update for a category (PATCH /categories/{id}).
// Nil pointer fields are left unchanged. UpdatedAt is the LWW version (required).
type CategoryPatch struct {
	Name      *string
	Icon      *string
	UpdatedAt time.Time
}

// Store defines the interface for all database operations.
type Store interface {
	// GetUserByEmail returns a user by their email.
	GetUserByEmail(ctx context.Context, email string) (User, error)

	// UpsertUser creates a user if not exists, returns the user.
	UpsertUser(ctx context.Context, email string) (User, error)

	// SetUserVerified marks a user's email as verified.
	SetUserVerified(ctx context.Context, userID string) error

	// SaveOTP stores a new OTP code for a user with the given attempt budget.
	SaveOTP(ctx context.Context, userID string, codeHash string, expiresAt time.Time, maxAttempts int) error

	// GetValidOTP returns the latest non-expired, non-exhausted OTP for a user.
	GetValidOTP(ctx context.Context, userID string) (OTP, error)

	// IncrementOTPAttempts increments the attempt counter for an OTP.
	IncrementOTPAttempts(ctx context.Context, otpID string) error

	// MarkOTPExhausted marks an OTP as exhausted (max attempts reached).
	MarkOTPExhausted(ctx context.Context, otpID string) error

	// SaveRefreshToken stores a new refresh token.
	SaveRefreshToken(ctx context.Context, userID string, tokenHash string, deviceID string) error

	// GetRefreshToken returns a refresh token by its hash, including user info.
	GetRefreshToken(ctx context.Context, tokenHash string) (RefreshToken, error)

	// RevokeRefreshToken marks a refresh token as revoked. Pending
	// recovery receipts naming it as successor close with it.
	RevokeRefreshToken(ctx context.Context, tokenID string) error

	// RevokeAllUserSessions revokes all refresh tokens for a user. Pending
	// recovery receipts of the user close with them.
	RevokeAllUserSessions(ctx context.Context, userID string) error

	// RevokeUserDeviceSessions revokes the refresh family of one device:
	// all non-revoked refresh tokens for user with the given device_id.
	// Pending recovery receipts of that device close with it, so a replayed
	// attempt can no longer recreate the revoked session.
	RevokeUserDeviceSessions(ctx context.Context, userID, deviceID string) error

	// RotateRefreshToken atomically revokes the predecessor, inserts the
	// successor, records the pending recovery receipt, and closes the
	// receipt the predecessor itself recovered (successor consumption).
	// Commit-all or commit-nothing: failures before commit leave the
	// predecessor usable and persist no partial successor or receipt. The
	// predecessor revocation is single-use guarded: a concurrent rotation
	// that already consumed it returns ErrPredecessorRevoked without
	// touching the family. A concurrent duplicate delivery that already
	// accepted the attempt returns ErrAttemptExists without touching it.
	RotateRefreshToken(ctx context.Context, args RotateArgs) (RotateResult, error)

	// FindRecoveryReceipt returns the pending receipt for an attempt hash,
	// or ErrNotFound when the attempt was never accepted.
	FindRecoveryReceipt(ctx context.Context, attemptHash string) (RecoveryReceipt, error)

	// ConsumeRecoveryReceipt closes a pending receipt without revoking
	// anything. Used when an expiry check rejects recovery: the receipt is
	// dead from that moment, and closing it lets the opportunistic sweep
	// reclaim the row once it is long past expiry.
	ConsumeRecoveryReceipt(ctx context.Context, attemptHash string) error
	// GetUserByID returns a user by their ID.
	GetUserByID(ctx context.Context, userID string) (User, error)

	// UpsertUserByAppleSubject upserts a user keyed by Apple's stable `sub`
	// identifier. Apple users are considered email-verified. The email is
	// persisted on first sign-in and left untouched on later sign-ins (Apple
	// may omit it after the first authorization). May return an error if the
	// email collides with an existing email-only account (account linking is a
	// follow-up).
	UpsertUserByAppleSubject(ctx context.Context, appleSubject, email string) (User, error)

	// ListCategories returns the user's categories ordered by name.
	ListCategories(ctx context.Context, userID string) ([]Category, error)

	// GetCategory returns one category by id, scoped to the user. Returns
	// ErrNotFound if missing or owned by another user.
	GetCategory(ctx context.Context, userID, id string) (Category, error)

	// CreateCategory inserts a new category using its client-generated id,
	// idempotent on id (replay → created=false). A case-insensitive name
	// collision returns ErrCategoryExists.
	CreateCategory(ctx context.Context, c Category) (Category, bool, error)

	// UpdateCategory applies a partial LWW update on name/icon. Returns
	// ErrNotFound, ErrConflict, or ErrCategoryExists.
	UpdateCategory(ctx context.Context, userID, id string, p CategoryPatch) (Category, error)

	// DeleteCategory hard-deletes a category and its join rows (entries are
	// unaffected). Returns ErrNotFound if missing.
	DeleteCategory(ctx context.Context, userID, id string) error

	// ListEntries returns one page of the user's entries ordered by started_at
	// DESC, filtered by EntryFilter, each with its own ordered category tags.
	// nextCursor is the opaque cursor for the next page, or empty when the
	// page is the last.
	ListEntries(ctx context.Context, userID string, f EntryFilter) (items []Entry, nextCursor string, err error)

	// GetEntry returns one entry by id with its own ordered categories.
	// Returns ErrNotFound if missing/foreign.
	GetEntry(ctx context.Context, userID, id string) (Entry, error)

	// CreateEntry inserts a new entry using its client-generated id, idempotent
	// on id (replay → created=false). ActivityText is the entry's own trimmed
	// display text; CategoryIDs (nil/empty = untagged) are stored via the
	// entry_categories join with order preserved — unknown or non-owned ids
	// are strictly rejected (ErrInvalidCategoryID → 422 validation_error with
	// details.category_ids; atomic, nothing persisted). duration_seconds is
	// computed from ended_at - started_at when ended_at is present.
	CreateEntry(ctx context.Context, e Entry) (Entry, bool, error)

	// UpdateEntry applies a partial LWW update on activity_text/notes/
	// category_ids/started_at/ended_at and recomputes duration_seconds.
	// Returns ErrNotFound or ErrConflict.
	UpdateEntry(ctx context.Context, userID, id string, p EntryPatch) (Entry, error)

	// ListRecents returns up to limit representative entries for the
	// recents experience (design D5): entries grouped by exact activity_text,
	// where per group the newest started_at wins (id DESC tiebreak), ordered
	// by that newest started_at DESC, each with its own ordered categories.
	ListRecents(ctx context.Context, userID string, limit int) ([]Entry, error)

	// DeleteEntry hard-deletes an entry. Returns ErrNotFound if missing.
	DeleteEntry(ctx context.Context, userID, id string) error

	// ListDeletions returns the user's tombstones with deleted_at > since
	// (nil/zero = all), ordered by deleted_at ASC.
	ListDeletions(ctx context.Context, userID string, since *time.Time) ([]Tombstone, error)

	// Close closes the database connection.
	Close() error
}
