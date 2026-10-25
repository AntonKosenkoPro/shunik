-- 010: household sharing (day-1: one household per user, two equal
-- owners). Households scope every future pet resource; members and
-- outstanding invites are account-bound rows, not synced resources.
CREATE TABLE IF NOT EXISTS households (
    id UUID PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS household_members (
    household_id UUID NOT NULL REFERENCES households(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    added_by TEXT NOT NULL,
    joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (household_id, user_id)
);

-- Day-1 rule: one household per user. Relaxing this later means replacing
-- the plain unique index with a partial one over active memberships.
CREATE UNIQUE INDEX IF NOT EXISTS idx_household_members_user_unique
    ON household_members(user_id);

CREATE TABLE IF NOT EXISTS household_invites (
    id UUID PRIMARY KEY,
    household_id UUID NOT NULL REFERENCES households(id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    invited_by TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    accepted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_household_invites_household
    ON household_invites(household_id);
