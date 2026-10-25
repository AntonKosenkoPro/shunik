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

// Household is one shared home for pets, events, and documents. Day-1:
// one household per user, every member an equal owner.
type Household struct {
	ID        string    `json:"id"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
	UpdatedBy string    `json:"updated_by"`
}

// HouseholdMember binds a user to a household as an equal owner.
// AddedBy names the actor who added the row (the user themselves on
// auto-create and invite accept, the inviter never writes it directly).
type HouseholdMember struct {
	HouseholdID string    `json:"household_id"`
	UserID      string    `json:"user_id"`
	Email       string    `json:"email"`
	AddedBy     string    `json:"added_by"`
	JoinedAt    time.Time `json:"joined_at"`
}

// HouseholdInvite is an outstanding email invitation to a household.
// The raw token is returned once at creation and emailed to the invitee;
// only its SHA-256 hash persists (R1: no plaintext secrets).
type HouseholdInvite struct {
	ID          string     `json:"id"`
	HouseholdID string     `json:"household_id"`
	Email       string     `json:"email"`
	TokenHash   string     `json:"-"`
	InvitedBy   string     `json:"invited_by"`
	ExpiresAt   time.Time  `json:"expires_at"`
	AcceptedAt  *time.Time `json:"accepted_at,omitempty"`
	CreatedAt   time.Time  `json:"created_at"`
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
	// tokens, OTPs, tombstones, the Apple vault row, and finally the user. Commit-all or commit-nothing:
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

	// EnsureHousehold returns the user's household, creating one with the
	// user as owner when the user has none. Called on every successful
	// sign-in so a household always exists before any pet-scoped write.
	EnsureHousehold(ctx context.Context, userID string) (Household, error)

	// GetHouseholdForUser returns the user's household or ErrNotFound.
	GetHouseholdForUser(ctx context.Context, userID string) (Household, error)

	// ListHouseholdMembers returns the household's owners with emails.
	ListHouseholdMembers(ctx context.Context, householdID string) ([]HouseholdMember, error)

	// CreateInvite records an email invitation; only the SHA-256 token hash
	// persists. Re-inviting the same email replaces the pending invite.
	CreateInvite(ctx context.Context, householdID, email, tokenHash, invitedBy string, expiresAt time.Time) (HouseholdInvite, error)

	// GetInviteByTokenHash returns the invite for a token hash or
	// ErrNotFound. Expiry and acceptance are the caller's check.
	GetInviteByTokenHash(ctx context.Context, tokenHash string) (HouseholdInvite, error)

	// AcceptInvite joins the user to the invite's household: consumed or
	// expired invites behave as missing (ErrNotFound — indistinguishable),
	// and users already in a household are rejected (ErrAlreadyMember).
	// The invite is marked accepted in the same transaction.
	AcceptInvite(ctx context.Context, inviteID, userID string) (Household, error)

	// RemoveMember deletes one membership. Token revocation for the removed
	// user is the caller's job, revoked BEFORE removing: a failed removal
	// leaves a locked-but-member user who re-authenticates cleanly, while a
	// failed revocation after removal would leave valid tokens outside.
	RemoveMember(ctx context.Context, householdID, userID string) error

	// Close closes the database connection.
	Close() error
}
