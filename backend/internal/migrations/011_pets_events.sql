-- 011: pets + events (base + kind details) + medication courses + intakes.
-- Base updated_at is the LWW clock for the whole event: every detail
-- mutation touches the base row in the same transaction.
CREATE TABLE IF NOT EXISTS pets (
    id UUID PRIMARY KEY,
    household_id UUID NOT NULL REFERENCES households(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    species TEXT NOT NULL,
    birthdate TIMESTAMPTZ,
    notes TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_pets_household ON pets(household_id);

-- kinds: vaccination | grooming | weight | med_course
CREATE TABLE IF NOT EXISTS event_base (
    id UUID PRIMARY KEY,
    household_id UUID NOT NULL REFERENCES households(id) ON DELETE CASCADE,
    pet_id UUID NOT NULL REFERENCES pets(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('vaccination', 'grooming', 'weight', 'med_course')),
    occurred_at TIMESTAMPTZ NOT NULL,
    next_due_at TIMESTAMPTZ,
    title TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_events_household ON event_base(household_id);
CREATE INDEX IF NOT EXISTS idx_events_pet ON event_base(pet_id);
CREATE INDEX IF NOT EXISTS idx_events_household_due ON event_base(household_id, next_due_at);

CREATE TABLE IF NOT EXISTS vacc_details (
    event_id UUID PRIMARY KEY REFERENCES event_base(id) ON DELETE CASCADE,
    vaccine TEXT NOT NULL,
    batch TEXT NOT NULL DEFAULT '',
    vet TEXT NOT NULL DEFAULT '',
    notes TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS grooming_details (
    event_id UUID PRIMARY KEY REFERENCES event_base(id) ON DELETE CASCADE,
    service TEXT NOT NULL,
    place TEXT NOT NULL DEFAULT '',
    notes TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS weight_details (
    event_id UUID PRIMARY KEY REFERENCES event_base(id) ON DELETE CASCADE,
    grams INTEGER NOT NULL CHECK (grams > 0)
);

CREATE TABLE IF NOT EXISTS med_courses (
    event_id UUID PRIMARY KEY REFERENCES event_base(id) ON DELETE CASCADE,
    drug_name TEXT NOT NULL,
    dose_amount TEXT NOT NULL,
    dose_unit TEXT NOT NULL,
    route TEXT NOT NULL DEFAULT 'oral',
    schedule_kind TEXT NOT NULL CHECK (schedule_kind IN ('daily', 'weekdays', 'prn')),
    schedule_times TEXT NOT NULL DEFAULT '',
    schedule_weekdays TEXT NOT NULL DEFAULT '',
    duration_days INTEGER NOT NULL DEFAULT 0,
    ends_on TIMESTAMPTZ,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'done', 'stopped')),
    instructions TEXT NOT NULL DEFAULT '',
    info_ref TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS med_intakes (
    id UUID PRIMARY KEY,
    household_id UUID NOT NULL REFERENCES households(id) ON DELETE CASCADE,
    course_id UUID NOT NULL REFERENCES med_courses(event_id) ON DELETE CASCADE,
    due_at TIMESTAMPTZ,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'taken', 'missed', 'skipped')),
    taken_at TIMESTAMPTZ,
    dose_snapshot TEXT NOT NULL,
    note TEXT NOT NULL DEFAULT '',
    marked_by TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_intakes_course ON med_intakes(course_id);
CREATE INDEX IF NOT EXISTS idx_intakes_household_due ON med_intakes(household_id, due_at);
