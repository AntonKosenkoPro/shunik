-- 009: Explicit account deletion (add-account-deletion).
--
-- Extends the users table with Apple session lineage + consent cutoff, adds
-- the encrypted Apple credential vault, the durable Apple-revocation outbox
-- (which survives the account purge by design — no FK to users), per-token
-- auth lineage on refresh tokens, and the notification replay log.
--
-- Postgres dialect; migrations.adaptToSQLite converts this for the SQLite
-- test store (TIMESTAMPTZ->TEXT, UUID->TEXT, NOW()->(datetime('now')),
-- DEFAULT false/true->0/1, IF NOT EXISTS stripped on CREATE/ADD COLUMN).
-- BYTEA relies on SQLite's BLOB type affinity, as in 008.

-- Apple session lineage + external consent cutoff on the account row.
-- apple_auth_time/apple_auth_lineage name the latest completed Apple
-- authorization; apple_consent_cutoff is the latest verified Apple
-- consent-revoked event time. A NULL lineage with a set cutoff means every
-- pre-cutoff Lifio session is dead until a fresh Apple authorization mints a
-- new lineage. Email-only accounts never get a cutoff.
ALTER TABLE users ADD COLUMN IF NOT EXISTS apple_auth_time TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN IF NOT EXISTS apple_auth_lineage TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS apple_consent_cutoff TIMESTAMPTZ;

-- Encrypted Apple revocable-credential vault (one row per Apple user at
-- most). sealed_refresh is AES-256-GCM from the APPLE_TOKEN_KEYS keyring
-- with domain-bound associated data — never a plaintext token. The row is
-- read for the deletion-credential check and moved into a revocation job by
-- the atomic purge; the purge deletes this row with the rest of the account.
CREATE TABLE IF NOT EXISTS apple_vault (
    user_id UUID PRIMARY KEY REFERENCES users(id),
    sealed_refresh BYTEA NOT NULL,
    auth_time TIMESTAMPTZ NOT NULL,
    lineage_id TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Durable Apple-revocation outbox. Created inside the account-purge
-- transaction and completed by the in-process worker (or the immediate
-- post-commit revoke attempt). Deliberately NOT a child of users: it must
-- survive the purge it was born in. subjects are indexed only as
-- HMAC-SHA256 digests (purpose-separated key derived from
-- ACCOUNT_STATUS_SECRET, stable across APPLE_TOKEN_KEYS rotation) so a
-- pending job can fence a new Apple authorization for the same subject
-- without retaining the subject itself.
CREATE TABLE IF NOT EXISTS apple_revocation_jobs (
    id TEXT PRIMARY KEY,
    subject_digest TEXT NOT NULL,
    sealed_refresh BYTEA NOT NULL,
    client_id TEXT NOT NULL,
    auth_lineage TEXT NOT NULL,
    auth_time TIMESTAMPTZ NOT NULL,
    attempts INT NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_attempt_at TIMESTAMPTZ,
    last_error TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_apple_revoke_jobs_subject
    ON apple_revocation_jobs(subject_digest);

CREATE INDEX IF NOT EXISTS idx_apple_revoke_jobs_due
    ON apple_revocation_jobs(next_attempt_at);

-- Auth lineage on refresh tokens. NULL = pre-lineage (issued before this
-- change); such rows can never pass a set consent cutoff. Rotation copies
-- the predecessor's lineage inside the rotation transaction, so rotation can
-- never evade the cutoff.
ALTER TABLE refresh_tokens ADD COLUMN IF NOT EXISTS auth_time TIMESTAMPTZ;
ALTER TABLE refresh_tokens ADD COLUMN IF NOT EXISTS auth_lineage TEXT;

-- Server-to-server Apple notification replay log. jti is Apple's unique
-- notification id; duplicates are idempotent no-ops. Rows older than the
-- retention window are pruned opportunistically on each notification.
CREATE TABLE IF NOT EXISTS apple_notifications_seen (
    jti TEXT PRIMARY KEY,
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
