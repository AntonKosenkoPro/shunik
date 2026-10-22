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
	// AppleSubject is Apple's stable `sub` for Apple-created accounts; nil
	// for email-only accounts. It is server truth for provider handling —
	// never inferred from an email suffix.
	AppleSubject *string `json:"-"`
	// AppleAuthTime/AppleAuthLineage name the latest completed Apple
	// authorization. AppleConsentCutoff is the latest verified Apple
	// consent-revoked event time; a set cutoff with a nulled lineage ends
	// every pre-cutoff session until a fresh authorization mints a lineage.
	AppleAuthTime      *time.Time `json:"-"`
	AppleAuthLineage   *string    `json:"-"`
	AppleConsentCutoff *time.Time `json:"-"`
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
	// AuthTime/AuthLineage bind the token to the Apple authorization that
	// issued its session (nil = pre-lineage, issued before this change).
	// Rotation copies the predecessor's pair, so rotation can never evade a
	// consent cutoff. Email-OTP sessions carry nils and are unaffected.
	AuthTime    *time.Time `json:"-"`
	AuthLineage *string    `json:"-"`
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

// AppleCredential is the encrypted Apple revocable credential retained for
// one Apple user (automatic unlinking on explicit deletion). Only the sealed
// blob plus routing metadata persist — never a plaintext token.
type AppleCredential struct {
	UserID        string
	SealedRefresh []byte
	AuthTime      time.Time
	LineageID     string
	CreatedAt     time.Time
	UpdatedAt     time.Time
}

// RevocationJob is one durable Apple-revocation work item. It is created
// inside the account-purge transaction and therefore survives the account it
// was born from (no FK to users). Subjects appear only as HMAC digests; the
// sealed credential's lineage + auth time ride along so the worker can
// rebuild the vault AAD without any account identifier.
type RevocationJob struct {
	ID            string
	SubjectDigest string
	SealedRefresh []byte
	ClientID      string
	AuthLineage   string
	AuthTime      time.Time
	Attempts      int
	NextAttemptAt time.Time
	LastAttemptAt *time.Time
	LastError     string
	CreatedAt     time.Time
}

// PurgeResult reports an atomic account purge.
type PurgeResult struct {
	UserID string
	// HadAppleIdentity reports the purged account was Apple-created.
	HadAppleIdentity bool
	// AppleSubject is the Apple `sub` of the purged account ("" when none).
	AppleSubject string
	// SealedAppleRefresh is the encrypted Apple credential moved into the
	// revocation job (nil when no vault credential was stored), sealed for
	// apple.VaultAAD(AuthLineage, AuthTime).
	SealedAppleRefresh []byte
	// AuthLineage/AuthTime describe the authorization the sealed credential
	// belongs to (copied from the vault row at purge).
	AuthLineage string
	AuthTime    time.Time
	// RevocationJobID is the durable job created for post-purge Apple
	// revocation ("" when no Apple work applies).
	RevocationJobID string
	// SubjectDigest is the job's HMAC subject digest ("" when no job).
	SubjectDigest string
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
	// The successor inherits the predecessor's auth lineage in the same
	// transaction, so rotation can never evade an Apple consent cutoff. A
	// missing account aborts with ErrUserMissing (no orphan successor).
	RotateRefreshToken(ctx context.Context, args RotateArgs) (RotateResult, error)

	// SaveRefreshTokenWithAuth stores a refresh token with its session's
	// Apple auth pair (nil/empty = email-OTP session, unaffected by Apple
	// consent cutoffs).
	SaveRefreshTokenWithAuth(ctx context.Context, userID, tokenHash, deviceID string, authTime *time.Time, authLineage string) error

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

	// SaveAppleCredential upserts the encrypted Apple revocable credential
	// for an Apple user (same-subject deletion authorization). Never
	// persists a plaintext token.
	SaveAppleCredential(ctx context.Context, cred AppleCredential) error

	// GetAppleCredential returns the stored Apple credential for a user, or
	// ErrNotFound when none was retained.
	GetAppleCredential(ctx context.Context, userID string) (AppleCredential, error)

	// SetAppleSession stamps the account's latest completed Apple
	// authorization (auth time + lineage). Mint a fresh lineage after a
	// consent cutoff; otherwise keep the existing one so multi-device
	// sessions stay valid.
	SetAppleSession(ctx context.Context, userID string, authTime time.Time, lineageID string) error

	// UpsertAppleUser atomically fences and upserts an Apple identity: when
	// a durable revocation job is pending for the same subject digest, the
	// signup is refused with ErrAppleRevocationPending (no code consumed, no
	// user created); otherwise the user is upserted keyed by Apple's stable
	// `sub` and returned with a non-empty lineage unless a consent cutoff is
	// set (the handler must then prove a fresh authorization before minting).
	// The fence check and the upsert serialize against purge/job creation on
	// the same subject, so a just-purged grant can never be reaccepted before
	// its revocation. subjectDigest is the HMAC-SHA256 digest of
	// appleSubject under the purpose-separated digest key; the store never
	// sees the derivation secret.
	UpsertAppleUser(ctx context.Context, appleSubject, email, subjectDigest string, authTime time.Time) (User, error)

	// ApplyAppleConsentCutoff records a verified Apple consent-revoked event:
	// the cutoff advances to eventTime (stale/duplicate events are ignored),
	// the current auth lineage is nulled so pre-cutoff sessions die, and
	// vault secrets of the revoked lineage are erased (never a newer
	// reauthorization's). Missing users are idempotent no-ops. Returns the
	// affected user ID and whether the cutoff advanced.
	ApplyAppleConsentCutoff(ctx context.Context, appleSubject string, eventTime time.Time) (userID string, applied bool, err error)

	// PurgeUser atomically deletes the account and every associated
	// operational row: it locks the account row first, moves a stored Apple
	// credential into a durable revocation job (referencing the passed
	// clientID) where one exists, deletes refresh-recovery receipts, refresh
	// tokens, OTPs, entry-category joins, entries, categories, tombstones,
	// the Apple vault row, and finally the user. Commit-all or commit-nothing:
	// any failure rolls the whole purge back. A missing account returns
	// ErrNotFound. digestFn maps the Apple subject to the job's HMAC subject
	// digest (purpose-separated, rotation-stable).
	PurgeUser(ctx context.Context, userID, clientID string, digestFn func(subject string) string) (PurgeResult, error)

	// HasPendingAppleRevocation reports whether a durable revocation job is
	// pending for the given HMAC subject digest.
	HasPendingAppleRevocation(ctx context.Context, subjectDigest string) (bool, error)

	// ClaimRevocationJob exclusively claims one due job (next_attempt_at <=
	// now), bumping its attempt counters for bounded backoff. Returns
	// ErrNotFound when nothing is due.
	ClaimRevocationJob(ctx context.Context, now time.Time) (RevocationJob, error)

	// CompleteRevocationJob removes a job after acknowledged Apple
	// revocation, erasing its sealed material immediately. Idempotent.
	CompleteRevocationJob(ctx context.Context, id string) error

	// FailRevocationJob records a failed attempt (attempt count, error) and
	// reschedules the job at nextAttempt. Never drops unresolved work.
	FailRevocationJob(ctx context.Context, id, errMsg string, nextAttempt time.Time) error

	// RecordAppleNotification logs a processed Apple server-to-server
	// notification id. A duplicate id returns ErrNotificationReplay and must
	// be treated as an idempotent no-op by the caller.
	RecordAppleNotification(ctx context.Context, jti string) error

	// Close closes the database connection.
	Close() error
}
