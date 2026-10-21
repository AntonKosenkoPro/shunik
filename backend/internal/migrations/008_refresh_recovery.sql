-- 008: refresh recovery receipts (fix-refresh-response-loss).
--
-- A committed rotation records one pending receipt keyed by the client's
-- refresh attempt (stored only as its SHA-256 hash). The receipt carries the
-- authenticated-encrypted successor refresh credential plus non-secret
-- routing metadata, so the issuing device can recover the same successor
-- after losing the response instead of tripping reuse detection.
--
-- Plaintext tokens are never persisted: only the sealed successor blob
-- (AES-256-GCM, application-side keyring) and SHA-256 hashes.
-- Receipts close on successor consumption, logout/revocation, or expiry;
-- expiry is lazy (checked on access) — no background sweeper.
-- Consumed rows are kept while a very late duplicate replay could still
-- arrive (it answers 409 instead of burning the family); rows that are
-- consumed AND long past expiry are swept opportunistically inside each
-- rotation, so the table stays bounded.
CREATE TABLE IF NOT EXISTS refresh_recovery_receipts (
    attempt_hash TEXT PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id),
    device_id TEXT NOT NULL,
    predecessor_hash TEXT NOT NULL,
    successor_hash TEXT NOT NULL,
    sealed_successor BYTEA NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    consumed BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_recovery_user_device
    ON refresh_recovery_receipts(user_id, device_id);

CREATE INDEX IF NOT EXISTS idx_recovery_successor
    ON refresh_recovery_receipts(successor_hash);

-- Supports the opportunistic retention sweep (consumed rows long past
-- expiry); plain index keeps the Postgres→SQLite migration adapter happy.
CREATE INDEX IF NOT EXISTS idx_recovery_consumed_expires
    ON refresh_recovery_receipts(consumed, expires_at);
