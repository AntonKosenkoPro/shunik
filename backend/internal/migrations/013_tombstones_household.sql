-- 013: household-scoped tombstones. Deletion propagation is per
-- household (both owners must converge), so every tombstone carries its
-- household. Pre-household rows (user-scoped entry/category era, tables
-- since dropped) stay NULL and are invisible to household queries.
ALTER TABLE tombstones ADD COLUMN household_id UUID REFERENCES households(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_tombstones_household_deleted
    ON tombstones(household_id, deleted_at);
