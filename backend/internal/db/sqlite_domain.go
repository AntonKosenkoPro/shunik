package db

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"
)

// SQLite domain methods for the Shunik v1 household data model (pets,
// events + kind details, medication intakes, documents, household
// tombstones). Conventions shared with the other SQLite files:
//
//   - Placeholders are `?`; times are TEXT via fmtTime / parseTime.
//   - Server stamps updated_at with datetime('now'); client timestamps are
//     never trusted for updated_at.
//   - changed-since lists use WHERE updated_at > ? ORDER BY updated_at ASC
//     (nil/zero since = all), with id as a deterministic tiebreak.
//   - Optimistic writes compare baseUpdatedAt with the stored updated_at via
//     .Equal(); mismatch returns bare ErrConflict with the row untouched.
//   - Cross-household rows are invisible: every read scopes by household_id
//     and returns bare ErrNotFound (never wrapped, so == works).
//   - Tombstones are household-scoped (tombstones.household_id). The legacy
//     user_id column is NOT NULL with a FK to users, so each household
//     tombstone is attributed to the acting user when the signature carries
//     one, else to the household's earliest-joined member.

// sqliteRowQuerier abstracts *sql.DB and *sql.Tx for single-row reads.
type sqliteRowQuerier interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// sqliteRowsQuerier abstracts *sql.DB and *sql.Tx for multi-row reads.
type sqliteRowsQuerier interface {
	sqliteRowQuerier
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
}

// sqliteExecer abstracts *sql.DB and *sql.Tx for writes.
type sqliteExecer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

// sqliteSinceArg normalizes a changed-since cursor: nil/zero means "all".
func sqliteSinceArg(since *time.Time) any {
	if since != nil && since.IsZero() {
		since = nil
	}
	if since == nil {
		return nil
	}
	return fmtTime(*since)
}

// sqliteNewID returns in.ID when the client supplied one, else mints a v7.
func sqliteNewID(inID string) string {
	if inID != "" {
		return inID
	}
	return uuidV7()
}

// sqliteNullTimeArg maps a *time.Time param to a NULL-able driver value.
func sqliteNullTimeArg(t *time.Time) any {
	if t == nil {
		return nil
	}
	return fmtTime(*t)
}

// sqliteBumpAfter returns a stamp strictly after base (now, nudged forward
// if the clock hasn't advanced past it). It keeps LWW conflict checks
// deterministic when two writes land in the same millisecond: every
// successful update observably advances updated_at. Comparison happens at
// the storage precision (fmtTime truncates to milliseconds), so a bump can
// never format back to the base value.
func sqliteBumpAfter(base time.Time) time.Time {
	now := time.Now().UTC().Truncate(time.Millisecond)
	if !now.After(base) {
		return base.Add(time.Millisecond)
	}
	return now
}

// ---------------------------------------------------------------------------
// Pets.
// ---------------------------------------------------------------------------

const sqlitePetColumns = `id, household_id, name, species, birthdate, notes, created_at, updated_at, updated_by`

func sqliteScanPet(p *Pet, birthdate sql.NullString, createdAt, updatedAt string) {
	p.Birthdate = nullTimePtr(birthdate)
	p.CreatedAt = parseTime(createdAt)
	p.UpdatedAt = parseTime(updatedAt)
}

func sqliteGetPet(ctx context.Context, q sqliteRowQuerier, where string, args ...any) (Pet, error) {
	var p Pet
	var birthdate sql.NullString
	var createdAt, updatedAt string
	err := q.QueryRowContext(ctx, `SELECT `+sqlitePetColumns+` FROM pets `+where,
		args...).Scan(&p.ID, &p.HouseholdID, &p.Name, &p.Species, &birthdate,
		&p.Notes, &createdAt, &updatedAt, &p.UpdatedBy)
	if err != nil {
		if err == sql.ErrNoRows {
			return Pet{}, ErrNotFound
		}
		return Pet{}, fmt.Errorf("get pet: %w", err)
	}
	sqliteScanPet(&p, birthdate, createdAt, updatedAt)
	return p, nil
}

// CreatePet inserts a pet (idempotent on ID: replays return the stored row
// with created=false). The pet's household must exist (FK-enforced).
func (s *SQLiteStore) CreatePet(ctx context.Context, householdID string, in PetInput, updatedBy string) (Pet, bool, error) {
	id := sqliteNewID(in.ID)
	res, err := s.db.ExecContext(ctx, `
		INSERT INTO pets (id, household_id, name, species, birthdate, notes, created_at, updated_at, updated_by)
		VALUES (?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'), ?)
		ON CONFLICT (id) DO NOTHING
	`, id, householdID, in.Name, in.Species, sqliteNullTimeArg(in.Birthdate), in.Notes, updatedBy)
	if err != nil {
		return Pet{}, false, fmt.Errorf("create pet: %w", err)
	}
	affected, err := res.RowsAffected()
	if err != nil {
		return Pet{}, false, fmt.Errorf("create pet: %w", err)
	}
	p, err := sqliteGetPet(ctx, s.db, `WHERE id = ?`, id)
	if err != nil {
		return Pet{}, false, err
	}
	return p, affected == 1, nil
}

// GetPet returns a pet or ErrNotFound (other households' pets are invisible).
func (s *SQLiteStore) GetPet(ctx context.Context, householdID, petID string) (Pet, error) {
	return sqliteGetPet(ctx, s.db, `WHERE id = ? AND household_id = ?`, petID, householdID)
}

// ListPetsChangedSince returns pets with updated_at after since (nil/zero =
// all), ordered by updated_at ASC, for delta pulls.
func (s *SQLiteStore) ListPetsChangedSince(ctx context.Context, householdID string, since *time.Time) ([]Pet, error) {
	sinceArg := sqliteSinceArg(since)
	rows, err := s.db.QueryContext(ctx, `
		SELECT `+sqlitePetColumns+`
		FROM pets
		WHERE household_id = ? AND (? IS NULL OR updated_at > ?)
		ORDER BY updated_at ASC, id ASC
	`, householdID, sinceArg, sinceArg)
	if err != nil {
		return nil, fmt.Errorf("list pets: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var out []Pet
	for rows.Next() {
		var p Pet
		var birthdate sql.NullString
		var createdAt, updatedAt string
		if err := rows.Scan(&p.ID, &p.HouseholdID, &p.Name, &p.Species, &birthdate,
			&p.Notes, &createdAt, &updatedAt, &p.UpdatedBy); err != nil {
			return nil, fmt.Errorf("list pets scan: %w", err)
		}
		sqliteScanPet(&p, birthdate, createdAt, updatedAt)
		out = append(out, p)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list pets rows: %w", err)
	}
	return out, nil
}

// UpdatePet full-replaces a pet when baseUpdatedAt matches the stored
// updated_at; otherwise ErrConflict with the row untouched.
func (s *SQLiteStore) UpdatePet(ctx context.Context, householdID, petID string, in PetInput, baseUpdatedAt time.Time, updatedBy string) (Pet, error) {
	stored, err := s.GetPet(ctx, householdID, petID)
	if err != nil {
		return Pet{}, err
	}
	if !stored.UpdatedAt.Equal(baseUpdatedAt) {
		return Pet{}, ErrConflict
	}
	if _, err := s.db.ExecContext(ctx, `
		UPDATE pets
		SET name = ?, species = ?, birthdate = ?, notes = ?,
		    updated_at = ?, updated_by = ?
		WHERE id = ? AND household_id = ?
	`, in.Name, in.Species, sqliteNullTimeArg(in.Birthdate), in.Notes,
		fmtTime(sqliteBumpAfter(stored.UpdatedAt)), updatedBy, petID, householdID); err != nil {
		return Pet{}, fmt.Errorf("update pet: %w", err)
	}
	return s.GetPet(ctx, householdID, petID)
}

// DeletePet removes the pet with cascade: every event (details, intakes) is
// tombstoned per resource, documents drop the pet from their link sets via
// document updates (updated_at bumped, no link tombstones), then the pet is
// tombstoned.
func (s *SQLiteStore) DeletePet(ctx context.Context, householdID, petID, deletedBy string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("delete pet: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var one int
	if err := tx.QueryRowContext(ctx, `
		SELECT 1 FROM pets WHERE id = ? AND household_id = ?
	`, petID, householdID).Scan(&one); err != nil {
		if err == sql.ErrNoRows {
			return ErrNotFound
		}
		return fmt.Errorf("delete pet: %w", err)
	}

	eventRows, err := tx.QueryContext(ctx, `
		SELECT id FROM event_base WHERE pet_id = ? AND household_id = ?
	`, petID, householdID)
	if err != nil {
		return fmt.Errorf("delete pet events: %w", err)
	}
	var eventIDs []string
	for eventRows.Next() {
		var eid string
		if err := eventRows.Scan(&eid); err != nil {
			_ = eventRows.Close()
			return fmt.Errorf("delete pet events scan: %w", err)
		}
		eventIDs = append(eventIDs, eid)
	}
	if err := eventRows.Err(); err != nil {
		_ = eventRows.Close()
		return fmt.Errorf("delete pet events rows: %w", err)
	}
	_ = eventRows.Close()

	now := time.Now().UTC()
	for _, eid := range eventIDs {
		if err := sqliteDeleteEventTx(ctx, tx, householdID, eid, "", now); err != nil {
			return err
		}
	}

	// Prune the pet from documents' link sets: bump the parents so other
	// devices pull the change, then drop the links. No link tombstones.
	// Each parent is stamped strictly after its own updated_at so the bump
	// is observable even when the delete lands in the same millisecond.
	touchRows, err := tx.QueryContext(ctx, `
		SELECT d.id, d.updated_at FROM documents d
		WHERE d.id IN (SELECT document_id FROM document_pets WHERE pet_id = ?)
		  AND d.household_id = ?
	`, petID, householdID)
	if err != nil {
		return fmt.Errorf("delete pet document touch: %w", err)
	}
	type docTouch struct {
		id      string
		updated time.Time
	}
	var touches []docTouch
	for touchRows.Next() {
		var dt docTouch
		var updatedAt string
		if err := touchRows.Scan(&dt.id, &updatedAt); err != nil {
			_ = touchRows.Close()
			return fmt.Errorf("delete pet document touch scan: %w", err)
		}
		dt.updated = parseTime(updatedAt)
		touches = append(touches, dt)
	}
	if err := touchRows.Err(); err != nil {
		_ = touchRows.Close()
		return fmt.Errorf("delete pet document touch rows: %w", err)
	}
	_ = touchRows.Close()
	for _, dt := range touches {
		if _, err := tx.ExecContext(ctx, `
			UPDATE documents
			SET updated_at = ?, updated_by = ?
			WHERE id = ?
		`, fmtTime(sqliteBumpAfter(dt.updated)), deletedBy, dt.id); err != nil {
			return fmt.Errorf("delete pet document touch: %w", err)
		}
	}
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM document_pets WHERE pet_id = ?
	`, petID); err != nil {
		return fmt.Errorf("delete pet document links: %w", err)
	}

	if _, err := tx.ExecContext(ctx, `
		DELETE FROM pets WHERE id = ? AND household_id = ?
	`, petID, householdID); err != nil {
		return fmt.Errorf("delete pet row: %w", err)
	}
	if err := sqliteInsertHouseholdTombstoneTx(ctx, tx, householdID, "", "pet", petID, now); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("delete pet: %w", err)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Events.
// ---------------------------------------------------------------------------

const sqliteEventBaseColumns = `id, household_id, pet_id, kind, occurred_at, next_due_at, title, created_at, updated_at, updated_by`

func sqliteScanEventBase(e *Event, occurredAt string, nextDueAt sql.NullString, createdAt, updatedAt string) {
	e.OccurredAt = parseTime(occurredAt)
	e.NextDueAt = nullTimePtr(nextDueAt)
	e.CreatedAt = parseTime(createdAt)
	e.UpdatedAt = parseTime(updatedAt)
}

// sqliteValidateEventInput enforces kind + exactly-one-detail-present.
// Field-level schedule validation lives in the handler layer; the store
// enforces kind, detail presence/shape minimums, and DB CHECK constraints.
func sqliteValidateEventInput(in EventInput) error {
	switch in.Kind {
	case "vaccination":
		if in.Vaccination == nil || in.Grooming != nil || in.Weight != nil || in.Course != nil {
			return fmt.Errorf("invalid event: kind vaccination needs exactly one vaccination detail")
		}
		if in.Vaccination.Vaccine == "" {
			return fmt.Errorf("invalid event: vaccine required")
		}
	case "grooming":
		if in.Grooming == nil || in.Vaccination != nil || in.Weight != nil || in.Course != nil {
			return fmt.Errorf("invalid event: kind grooming needs exactly one grooming detail")
		}
		if in.Grooming.Service == "" {
			return fmt.Errorf("invalid event: service required")
		}
	case "weight":
		if in.Weight == nil || in.Vaccination != nil || in.Grooming != nil || in.Course != nil {
			return fmt.Errorf("invalid event: kind weight needs exactly one weight detail")
		}
		if in.Weight.Grams <= 0 {
			return fmt.Errorf("invalid event: grams must be positive")
		}
	case "med_course":
		if in.Course == nil || in.Vaccination != nil || in.Grooming != nil || in.Weight != nil {
			return fmt.Errorf("invalid event: kind med_course needs exactly one course detail")
		}
		if in.Course.DrugName == "" || in.Course.DoseAmount == "" || in.Course.DoseUnit == "" {
			return fmt.Errorf("invalid event: drug_name and dose required")
		}
	default:
		return fmt.Errorf("invalid event kind %q", in.Kind)
	}
	return nil
}

func sqliteInsertEventDetail(ctx context.Context, ex sqliteExecer, eventID string, in EventInput) error {
	switch in.Kind {
	case "vaccination":
		d := in.Vaccination
		_, err := ex.ExecContext(ctx, `
			INSERT INTO vacc_details (event_id, vaccine, batch, vet, notes)
			VALUES (?, ?, ?, ?, ?)
		`, eventID, d.Vaccine, d.Batch, d.Vet, d.Notes)
		if err != nil {
			return fmt.Errorf("insert vacc detail: %w", err)
		}
	case "grooming":
		d := in.Grooming
		_, err := ex.ExecContext(ctx, `
			INSERT INTO grooming_details (event_id, service, place, notes)
			VALUES (?, ?, ?, ?)
		`, eventID, d.Service, d.Place, d.Notes)
		if err != nil {
			return fmt.Errorf("insert grooming detail: %w", err)
		}
	case "weight":
		_, err := ex.ExecContext(ctx, `
			INSERT INTO weight_details (event_id, grams)
			VALUES (?, ?)
		`, eventID, in.Weight.Grams)
		if err != nil {
			return fmt.Errorf("insert weight detail: %w", err)
		}
	case "med_course":
		c := in.Course
		_, err := ex.ExecContext(ctx, `
			INSERT INTO med_courses (event_id, drug_name, dose_amount, dose_unit, route,
				schedule_kind, schedule_times, schedule_weekdays, duration_days,
				ends_on, status, instructions, info_ref)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		`, eventID, c.DrugName, c.DoseAmount, c.DoseUnit, c.Route,
			c.ScheduleKind, c.ScheduleTimes, c.ScheduleWeekdays, c.DurationDays,
			sqliteNullTimeArg(c.EndsOn), c.Status, c.Instructions, c.InfoRef)
		if err != nil {
			return fmt.Errorf("insert med course: %w", err)
		}
	default:
		return fmt.Errorf("invalid event kind %q", in.Kind)
	}
	return nil
}

func sqliteDeleteEventDetails(ctx context.Context, ex sqliteExecer, eventID string) error {
	for _, stmt := range []string{
		`DELETE FROM vacc_details WHERE event_id = ?`,
		`DELETE FROM grooming_details WHERE event_id = ?`,
		`DELETE FROM weight_details WHERE event_id = ?`,
		`DELETE FROM med_courses WHERE event_id = ?`,
	} {
		if _, err := ex.ExecContext(ctx, stmt, eventID); err != nil {
			return fmt.Errorf("delete event detail: %w", err)
		}
	}
	return nil
}

// sqliteLoadEventDetail joins the kind detail onto a base-scanned event.
func sqliteLoadEventDetail(ctx context.Context, q sqliteRowQuerier, e *Event) error {
	switch e.Kind {
	case "vaccination":
		var d VaccDetail
		if err := q.QueryRowContext(ctx, `
			SELECT vaccine, batch, vet, notes FROM vacc_details WHERE event_id = ?
		`, e.ID).Scan(&d.Vaccine, &d.Batch, &d.Vet, &d.Notes); err != nil {
			return fmt.Errorf("load vacc detail: %w", err)
		}
		e.Vaccination = &d
	case "grooming":
		var d GroomDetail
		if err := q.QueryRowContext(ctx, `
			SELECT service, place, notes FROM grooming_details WHERE event_id = ?
		`, e.ID).Scan(&d.Service, &d.Place, &d.Notes); err != nil {
			return fmt.Errorf("load grooming detail: %w", err)
		}
		e.Grooming = &d
	case "weight":
		var d WeightDetail
		if err := q.QueryRowContext(ctx, `
			SELECT grams FROM weight_details WHERE event_id = ?
		`, e.ID).Scan(&d.Grams); err != nil {
			return fmt.Errorf("load weight detail: %w", err)
		}
		e.Weight = &d
	case "med_course":
		var c MedCourse
		var endsOn sql.NullString
		if err := q.QueryRowContext(ctx, `
			SELECT drug_name, dose_amount, dose_unit, route, schedule_kind,
			       schedule_times, schedule_weekdays, duration_days, ends_on,
			       status, instructions, info_ref
			FROM med_courses WHERE event_id = ?
		`, e.ID).Scan(&c.DrugName, &c.DoseAmount, &c.DoseUnit, &c.Route,
			&c.ScheduleKind, &c.ScheduleTimes, &c.ScheduleWeekdays, &c.DurationDays,
			&endsOn, &c.Status, &c.Instructions, &c.InfoRef); err != nil {
			return fmt.Errorf("load med course: %w", err)
		}
		c.EndsOn = nullTimePtr(endsOn)
		e.Course = &c
	default:
		return fmt.Errorf("load event detail: unknown kind %q", e.Kind)
	}
	return nil
}

func sqliteScanEventRow(ctx context.Context, q sqliteRowQuerier, e *Event, occurredAt string, nextDueAt sql.NullString, createdAt, updatedAt string) error {
	sqliteScanEventBase(e, occurredAt, nextDueAt, createdAt, updatedAt)
	return sqliteLoadEventDetail(ctx, q, e)
}

func sqliteGetEvent(ctx context.Context, q sqliteRowsQuerier, where string, args ...any) (Event, error) {
	var e Event
	var occurredAt, createdAt, updatedAt string
	var nextDueAt sql.NullString
	err := q.QueryRowContext(ctx, `SELECT `+sqliteEventBaseColumns+` FROM event_base `+where,
		args...).Scan(&e.ID, &e.HouseholdID, &e.PetID, &e.Kind, &occurredAt,
		&nextDueAt, &e.Title, &createdAt, &updatedAt, &e.UpdatedBy)
	if err != nil {
		if err == sql.ErrNoRows {
			return Event{}, ErrNotFound
		}
		return Event{}, fmt.Errorf("get event: %w", err)
	}
	if err := sqliteScanEventRow(ctx, q, &e, occurredAt, nextDueAt, createdAt, updatedAt); err != nil {
		return Event{}, err
	}
	return e, nil
}

// sqlitePetInHousehold reports whether a pet belongs to a household.
func sqlitePetInHousehold(ctx context.Context, q sqliteRowQuerier, householdID, petID string) (bool, error) {
	var one int
	err := q.QueryRowContext(ctx, `
		SELECT 1 FROM pets WHERE id = ? AND household_id = ?
	`, petID, householdID).Scan(&one)
	if err != nil {
		if err == sql.ErrNoRows {
			return false, nil
		}
		return false, fmt.Errorf("pet lookup: %w", err)
	}
	return true, nil
}

// CreateEvent inserts an event with its kind detail in one transaction
// (idempotent on ID). The pet must belong to the household or the write
// fails loudly (ErrInvalidPetID).
func (s *SQLiteStore) CreateEvent(ctx context.Context, householdID string, in EventInput, updatedBy string) (Event, bool, error) {
	if err := sqliteValidateEventInput(in); err != nil {
		return Event{}, false, err
	}
	id := sqliteNewID(in.ID)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Event{}, false, fmt.Errorf("create event: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	ok, err := sqlitePetInHousehold(ctx, tx, householdID, in.PetID)
	if err != nil {
		return Event{}, false, err
	}
	if !ok {
		return Event{}, false, ErrInvalidPetID
	}

	res, err := tx.ExecContext(ctx, `
		INSERT INTO event_base (id, household_id, pet_id, kind, occurred_at, next_due_at, title,
			created_at, updated_at, updated_by)
		VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'), ?)
		ON CONFLICT (id) DO NOTHING
	`, id, householdID, in.PetID, in.Kind, fmtTime(in.OccurredAt),
		sqliteNullTimeArg(in.NextDueAt), in.Title, updatedBy)
	if err != nil {
		return Event{}, false, fmt.Errorf("create event: %w", err)
	}
	affected, err := res.RowsAffected()
	if err != nil {
		return Event{}, false, fmt.Errorf("create event: %w", err)
	}
	if affected == 0 {
		existing, err := sqliteGetEvent(ctx, tx, `WHERE id = ?`, id)
		if err != nil {
			return Event{}, false, err
		}
		if err := tx.Commit(); err != nil {
			return Event{}, false, fmt.Errorf("create event: %w", err)
		}
		return existing, false, nil
	}
	if err := sqliteInsertEventDetail(ctx, tx, id, in); err != nil {
		return Event{}, false, err
	}
	if err := tx.Commit(); err != nil {
		return Event{}, false, fmt.Errorf("create event: %w", err)
	}
	created, err := sqliteGetEvent(ctx, s.db, `WHERE id = ?`, id)
	if err != nil {
		return Event{}, false, err
	}
	return created, true, nil
}

// GetEvent returns the event with its detail joined, or ErrNotFound.
func (s *SQLiteStore) GetEvent(ctx context.Context, householdID, eventID string) (Event, error) {
	return sqliteGetEvent(ctx, s.db, `WHERE id = ? AND household_id = ?`, eventID, householdID)
}

// ListEventsChangedSince returns events (details joined) with base
// updated_at after since, ordered ASC. Empty petID = all pets.
func (s *SQLiteStore) ListEventsChangedSince(ctx context.Context, householdID string, since *time.Time, petID string) ([]Event, error) {
	sinceArg := sqliteSinceArg(since)
	query := `
		SELECT ` + sqliteEventBaseColumns + `
		FROM event_base
		WHERE household_id = ? AND (? IS NULL OR updated_at > ?)
	`
	args := []any{householdID, sinceArg, sinceArg}
	if petID != "" {
		query += ` AND pet_id = ?`
		args = append(args, petID)
	}
	query += ` ORDER BY updated_at ASC, id ASC`
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("list events: %w", err)
	}
	type eventRow struct {
		e          Event
		occurredAt string
		nextDueAt  sql.NullString
		createdAt  string
		updatedAt  string
	}
	var base []eventRow
	for rows.Next() {
		var r eventRow
		if err := rows.Scan(&r.e.ID, &r.e.HouseholdID, &r.e.PetID, &r.e.Kind,
			&r.occurredAt, &r.nextDueAt, &r.e.Title,
			&r.createdAt, &r.updatedAt, &r.e.UpdatedBy); err != nil {
			_ = rows.Close()
			return nil, fmt.Errorf("list events scan: %w", err)
		}
		base = append(base, r)
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return nil, fmt.Errorf("list events rows: %w", err)
	}
	_ = rows.Close()
	out := make([]Event, 0, len(base))
	for i := range base {
		r := &base[i]
		if err := sqliteScanEventRow(ctx, s.db, &r.e, r.occurredAt, r.nextDueAt, r.createdAt, r.updatedAt); err != nil {
			return nil, err
		}
		out = append(out, r.e)
	}
	return out, nil
}

// UpdateEvent full-replaces base + detail when baseUpdatedAt matches the
// stored base updated_at; otherwise ErrConflict.
func (s *SQLiteStore) UpdateEvent(ctx context.Context, householdID, eventID string, in EventInput, baseUpdatedAt time.Time, updatedBy string) (Event, error) {
	if err := sqliteValidateEventInput(in); err != nil {
		return Event{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Event{}, fmt.Errorf("update event: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var storedUpdated string
	if err := tx.QueryRowContext(ctx, `
		SELECT updated_at FROM event_base WHERE id = ? AND household_id = ?
	`, eventID, householdID).Scan(&storedUpdated); err != nil {
		if err == sql.ErrNoRows {
			return Event{}, ErrNotFound
		}
		return Event{}, fmt.Errorf("update event: %w", err)
	}
	storedTime := parseTime(storedUpdated)
	if !storedTime.Equal(baseUpdatedAt) {
		return Event{}, ErrConflict
	}
	ok, err := sqlitePetInHousehold(ctx, tx, householdID, in.PetID)
	if err != nil {
		return Event{}, err
	}
	if !ok {
		return Event{}, ErrInvalidPetID
	}
	if _, err := tx.ExecContext(ctx, `
		UPDATE event_base
		SET pet_id = ?, kind = ?, occurred_at = ?, next_due_at = ?, title = ?,
		    updated_at = ?, updated_by = ?
		WHERE id = ? AND household_id = ?
	`, in.PetID, in.Kind, fmtTime(in.OccurredAt), sqliteNullTimeArg(in.NextDueAt),
		in.Title, fmtTime(sqliteBumpAfter(storedTime)), updatedBy, eventID, householdID); err != nil {
		return Event{}, fmt.Errorf("update event: %w", err)
	}
	// Details are immutable snapshots keyed by event_id: delete + re-insert.
	if err := sqliteDeleteEventDetails(ctx, tx, eventID); err != nil {
		return Event{}, err
	}
	if err := sqliteInsertEventDetail(ctx, tx, eventID, in); err != nil {
		return Event{}, err
	}
	if err := tx.Commit(); err != nil {
		return Event{}, fmt.Errorf("update event: %w", err)
	}
	return s.GetEvent(ctx, householdID, eventID)
}

// sqliteDeleteEventTx deletes one event's intakes (tombstoning each),
// details, and base row, then tombstones the event. Caller owns the tx.
func sqliteDeleteEventTx(ctx context.Context, tx *sql.Tx, householdID, eventID, actor string, at time.Time) error {
	intakeRows, err := tx.QueryContext(ctx, `
		SELECT id FROM med_intakes WHERE course_id = ?
	`, eventID)
	if err != nil {
		return fmt.Errorf("delete event intakes: %w", err)
	}
	var intakeIDs []string
	for intakeRows.Next() {
		var iid string
		if err := intakeRows.Scan(&iid); err != nil {
			_ = intakeRows.Close()
			return fmt.Errorf("delete event intakes scan: %w", err)
		}
		intakeIDs = append(intakeIDs, iid)
	}
	if err := intakeRows.Err(); err != nil {
		_ = intakeRows.Close()
		return fmt.Errorf("delete event intakes rows: %w", err)
	}
	_ = intakeRows.Close()
	for _, iid := range intakeIDs {
		if _, err := tx.ExecContext(ctx, `DELETE FROM med_intakes WHERE id = ?`, iid); err != nil {
			return fmt.Errorf("delete event intake: %w", err)
		}
		if err := sqliteInsertHouseholdTombstoneTx(ctx, tx, householdID, actor, "intake", iid, at); err != nil {
			return err
		}
	}
	if err := sqliteDeleteEventDetails(ctx, tx, eventID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM event_base WHERE id = ?`, eventID); err != nil {
		return fmt.Errorf("delete event base: %w", err)
	}
	return sqliteInsertHouseholdTombstoneTx(ctx, tx, householdID, actor, "event", eventID, at)
}

// DeleteEvent removes details + base and tombstones resource 'event'.
func (s *SQLiteStore) DeleteEvent(ctx context.Context, householdID, eventID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("delete event: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var one int
	if err := tx.QueryRowContext(ctx, `
		SELECT 1 FROM event_base WHERE id = ? AND household_id = ?
	`, eventID, householdID).Scan(&one); err != nil {
		if err == sql.ErrNoRows {
			return ErrNotFound
		}
		return fmt.Errorf("delete event: %w", err)
	}
	if err := sqliteDeleteEventTx(ctx, tx, householdID, eventID, "", time.Now().UTC()); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("delete event: %w", err)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Medication intakes.
// ---------------------------------------------------------------------------

const sqliteIntakeColumns = `id, household_id, course_id, due_at, status, taken_at, dose_snapshot, note, marked_by, created_at, updated_at`

func sqliteScanIntake(m *MedIntake, dueAt, takenAt sql.NullString, createdAt, updatedAt string) {
	m.DueAt = nullTimePtr(dueAt)
	m.TakenAt = nullTimePtr(takenAt)
	m.CreatedAt = parseTime(createdAt)
	m.UpdatedAt = parseTime(updatedAt)
}

func sqliteGetIntake(ctx context.Context, q sqliteRowQuerier, where string, args ...any) (MedIntake, error) {
	var m MedIntake
	var dueAt, takenAt sql.NullString
	var createdAt, updatedAt string
	err := q.QueryRowContext(ctx, `SELECT `+sqliteIntakeColumns+` FROM med_intakes `+where,
		args...).Scan(&m.ID, &m.HouseholdID, &m.CourseID, &dueAt, &m.Status,
		&takenAt, &m.DoseSnapshot, &m.Note, &m.MarkedBy, &createdAt, &updatedAt)
	if err != nil {
		if err == sql.ErrNoRows {
			return MedIntake{}, ErrNotFound
		}
		return MedIntake{}, fmt.Errorf("get intake: %w", err)
	}
	sqliteScanIntake(&m, dueAt, takenAt, createdAt, updatedAt)
	return m, nil
}

// sqliteCourseInHousehold reports whether a med course belongs to a household.
func sqliteCourseInHousehold(ctx context.Context, q sqliteRowQuerier, householdID, courseID string) (bool, error) {
	var one int
	err := q.QueryRowContext(ctx, `
		SELECT 1 FROM med_courses c
		JOIN event_base b ON b.id = c.event_id
		WHERE c.event_id = ? AND b.household_id = ?
	`, courseID, householdID).Scan(&one)
	if err != nil {
		if err == sql.ErrNoRows {
			return false, nil
		}
		return false, fmt.Errorf("course lookup: %w", err)
	}
	return true, nil
}

// CreateIntake inserts an intake under a household course (idempotent on
// ID). The course must belong to the household (ErrInvalidPetID covers the
// missing-course case: same "unknown reference" shape). Creates always start
// pending with empty marked_by (see MedIntake docs), so createdBy is
// accepted for handler symmetry but not persisted.
func (s *SQLiteStore) CreateIntake(ctx context.Context, householdID string, in IntakeInput, _ string) (MedIntake, bool, error) {
	id := sqliteNewID(in.ID)
	ok, err := sqliteCourseInHousehold(ctx, s.db, householdID, in.CourseID)
	if err != nil {
		return MedIntake{}, false, err
	}
	if !ok {
		return MedIntake{}, false, ErrInvalidPetID
	}
	res, err := s.db.ExecContext(ctx, `
		INSERT INTO med_intakes (id, household_id, course_id, due_at, status, taken_at,
			dose_snapshot, note, marked_by, created_at, updated_at)
		VALUES (?, ?, ?, ?, 'pending', NULL, ?, ?, '', datetime('now'), datetime('now'))
		ON CONFLICT (id) DO NOTHING
	`, id, householdID, in.CourseID, sqliteNullTimeArg(in.DueAt), in.DoseSnapshot, in.Note)
	if err != nil {
		return MedIntake{}, false, fmt.Errorf("create intake: %w", err)
	}
	affected, err := res.RowsAffected()
	if err != nil {
		return MedIntake{}, false, fmt.Errorf("create intake: %w", err)
	}
	m, err := sqliteGetIntake(ctx, s.db, `WHERE id = ?`, id)
	if err != nil {
		return MedIntake{}, false, err
	}
	return m, affected == 1, nil
}

// GetIntake returns an intake or ErrNotFound.
func (s *SQLiteStore) GetIntake(ctx context.Context, householdID, intakeID string) (MedIntake, error) {
	return sqliteGetIntake(ctx, s.db, `WHERE id = ? AND household_id = ?`, intakeID, householdID)
}

// ListIntakesChangedSince returns intakes with updated_at after since,
// ordered ASC. Empty courseID = all courses.
func (s *SQLiteStore) ListIntakesChangedSince(ctx context.Context, householdID, courseID string, since *time.Time) ([]MedIntake, error) {
	sinceArg := sqliteSinceArg(since)
	query := `
		SELECT ` + sqliteIntakeColumns + `
		FROM med_intakes
		WHERE household_id = ? AND (? IS NULL OR updated_at > ?)
	`
	args := []any{householdID, sinceArg, sinceArg}
	if courseID != "" {
		query += ` AND course_id = ?`
		args = append(args, courseID)
	}
	query += ` ORDER BY updated_at ASC, id ASC`
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("list intakes: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var out []MedIntake
	for rows.Next() {
		var m MedIntake
		var dueAt, takenAt sql.NullString
		var createdAt, updatedAt string
		if err := rows.Scan(&m.ID, &m.HouseholdID, &m.CourseID, &dueAt, &m.Status,
			&takenAt, &m.DoseSnapshot, &m.Note, &m.MarkedBy, &createdAt, &updatedAt); err != nil {
			return nil, fmt.Errorf("list intakes scan: %w", err)
		}
		sqliteScanIntake(&m, dueAt, takenAt, createdAt, updatedAt)
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list intakes rows: %w", err)
	}
	return out, nil
}

// UpdateIntake replaces mutable fields when baseUpdatedAt matches;
// otherwise ErrConflict. Status transitions stamp MarkedBy from the caller;
// a taken mark without TakenAt stamps now.
func (s *SQLiteStore) UpdateIntake(ctx context.Context, householdID, intakeID string, in IntakeUpdate, baseUpdatedAt time.Time, markedBy string) (MedIntake, error) {
	stored, err := s.GetIntake(ctx, householdID, intakeID)
	if err != nil {
		return MedIntake{}, err
	}
	if !stored.UpdatedAt.Equal(baseUpdatedAt) {
		return MedIntake{}, ErrConflict
	}
	newMarkedBy := stored.MarkedBy
	if in.Status != stored.Status {
		newMarkedBy = markedBy
	}
	takenAt := in.TakenAt
	if in.Status == "taken" && takenAt == nil {
		now := time.Now().UTC()
		takenAt = &now
	}
	if _, err := s.db.ExecContext(ctx, `
		UPDATE med_intakes
		SET status = ?, taken_at = ?, dose_snapshot = ?, note = ?, marked_by = ?,
		    updated_at = ?
		WHERE id = ? AND household_id = ?
	`, in.Status, sqliteNullTimeArg(takenAt), in.DoseSnapshot, in.Note,
		newMarkedBy, fmtTime(sqliteBumpAfter(stored.UpdatedAt)), intakeID, householdID); err != nil {
		return MedIntake{}, fmt.Errorf("update intake: %w", err)
	}
	return s.GetIntake(ctx, householdID, intakeID)
}

// DeleteIntake removes the intake and tombstones resource 'intake'.
func (s *SQLiteStore) DeleteIntake(ctx context.Context, householdID, intakeID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("delete intake: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var one int
	if err := tx.QueryRowContext(ctx, `
		SELECT 1 FROM med_intakes WHERE id = ? AND household_id = ?
	`, intakeID, householdID).Scan(&one); err != nil {
		if err == sql.ErrNoRows {
			return ErrNotFound
		}
		return fmt.Errorf("delete intake: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM med_intakes WHERE id = ?`, intakeID); err != nil {
		return fmt.Errorf("delete intake row: %w", err)
	}
	if err := sqliteInsertHouseholdTombstoneTx(ctx, tx, householdID, "", "intake", intakeID, time.Now().UTC()); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("delete intake: %w", err)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Documents.
// ---------------------------------------------------------------------------

const sqliteDocumentColumns = `id, household_id, title, mime, size_bytes, filename, blob_key, ready, extracted_text, created_at, updated_at, updated_by`

func sqliteScanDocument(d *Document, createdAt, updatedAt string) {
	d.CreatedAt = parseTime(createdAt)
	d.UpdatedAt = parseTime(updatedAt)
}

// sqliteDocumentPetIDs returns a document's linked pet IDs in stable order.
func sqliteDocumentPetIDs(ctx context.Context, q sqliteRowsQuerier, docID string) ([]string, error) {
	rows, err := q.QueryContext(ctx, `
		SELECT pet_id FROM document_pets WHERE document_id = ? ORDER BY pet_id ASC
	`, docID)
	if err != nil {
		return nil, fmt.Errorf("document pets: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var out []string
	for rows.Next() {
		var pid string
		if err := rows.Scan(&pid); err != nil {
			return nil, fmt.Errorf("document pets scan: %w", err)
		}
		out = append(out, pid)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("document pets rows: %w", err)
	}
	return out, nil
}

func sqliteGetDocument(ctx context.Context, q sqliteRowsQuerier, where string, args ...any) (Document, error) {
	var d Document
	var createdAt, updatedAt string
	err := q.QueryRowContext(ctx, `SELECT `+sqliteDocumentColumns+` FROM documents `+where,
		args...).Scan(&d.ID, &d.HouseholdID, &d.Title, &d.Mime, &d.SizeBytes,
		&d.Filename, &d.BlobKey, &d.Ready, &d.ExtractedText,
		&createdAt, &updatedAt, &d.UpdatedBy)
	if err != nil {
		if err == sql.ErrNoRows {
			return Document{}, ErrNotFound
		}
		return Document{}, fmt.Errorf("get document: %w", err)
	}
	sqliteScanDocument(&d, createdAt, updatedAt)
	petIDs, err := sqliteDocumentPetIDs(ctx, q, d.ID)
	if err != nil {
		return Document{}, err
	}
	d.PetIDs = petIDs
	return d, nil
}

// sqliteValidateDocumentPets rejects pet IDs outside the household with
// ErrInvalidPetID (same "unknown reference" shape as events/intakes).
func sqliteValidateDocumentPets(ctx context.Context, q sqliteRowQuerier, householdID string, petIDs []string) error {
	for _, pid := range petIDs {
		ok, err := sqlitePetInHousehold(ctx, q, householdID, pid)
		if err != nil {
			return err
		}
		if !ok {
			return ErrInvalidPetID
		}
	}
	return nil
}

// CreateDocument inserts document metadata with its pet link set in one
// transaction (idempotent on ID) and assigns the blob key. Bytes upload
// separately; ready stays false until ConfirmDocument.
func (s *SQLiteStore) CreateDocument(ctx context.Context, householdID string, in DocumentInput, updatedBy string) (Document, bool, error) {
	if err := sqliteValidateDocumentPets(ctx, s.db, householdID, in.PetIDs); err != nil {
		return Document{}, false, err
	}
	id := sqliteNewID(in.ID)
	blobKey := blobKeyFor(householdID, id, in.Filename)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Document{}, false, fmt.Errorf("create document: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.ExecContext(ctx, `
		INSERT INTO documents (id, household_id, title, mime, size_bytes, filename, blob_key,
			ready, extracted_text, created_at, updated_at, updated_by)
		VALUES (?, ?, ?, ?, ?, ?, ?, false, '', datetime('now'), datetime('now'), ?)
		ON CONFLICT (id) DO NOTHING
	`, id, householdID, in.Title, in.Mime, in.SizeBytes, in.Filename, blobKey, updatedBy)
	if err != nil {
		return Document{}, false, fmt.Errorf("create document: %w", err)
	}
	affected, err := res.RowsAffected()
	if err != nil {
		return Document{}, false, fmt.Errorf("create document: %w", err)
	}
	if affected == 1 {
		for _, pid := range in.PetIDs {
			if _, err := tx.ExecContext(ctx, `
				INSERT INTO document_pets (document_id, pet_id) VALUES (?, ?)
			`, id, pid); err != nil {
				return Document{}, false, fmt.Errorf("create document links: %w", err)
			}
		}
	}
	if err := tx.Commit(); err != nil {
		return Document{}, false, fmt.Errorf("create document: %w", err)
	}
	d, err := sqliteGetDocument(ctx, s.db, `WHERE id = ?`, id)
	if err != nil {
		return Document{}, false, err
	}
	return d, affected == 1, nil
}

// GetDocument returns document metadata with pet IDs, or ErrNotFound.
func (s *SQLiteStore) GetDocument(ctx context.Context, householdID, docID string) (Document, error) {
	return sqliteGetDocument(ctx, s.db, `WHERE id = ? AND household_id = ?`, docID, householdID)
}

// ListDocumentsChangedSince returns ready document metadata with updated_at
// after since, ordered ASC. Never bytes. Unready rows are invisible: clients
// never saw them, so the GC path deletes them without tombstones.
func (s *SQLiteStore) ListDocumentsChangedSince(ctx context.Context, householdID string, since *time.Time) ([]Document, error) {
	sinceArg := sqliteSinceArg(since)
	rows, err := s.db.QueryContext(ctx, `
		SELECT `+sqliteDocumentColumns+`
		FROM documents
		WHERE household_id = ? AND ready = true AND (? IS NULL OR updated_at > ?)
		ORDER BY updated_at ASC, id ASC
	`, householdID, sinceArg, sinceArg)
	if err != nil {
		return nil, fmt.Errorf("list documents: %w", err)
	}
	type docRow struct {
		d         Document
		createdAt string
		updatedAt string
	}
	var base []docRow
	for rows.Next() {
		var r docRow
		if err := rows.Scan(&r.d.ID, &r.d.HouseholdID, &r.d.Title, &r.d.Mime,
			&r.d.SizeBytes, &r.d.Filename, &r.d.BlobKey, &r.d.Ready,
			&r.d.ExtractedText, &r.createdAt, &r.updatedAt, &r.d.UpdatedBy); err != nil {
			_ = rows.Close()
			return nil, fmt.Errorf("list documents scan: %w", err)
		}
		base = append(base, r)
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return nil, fmt.Errorf("list documents rows: %w", err)
	}
	_ = rows.Close()
	out := make([]Document, 0, len(base))
	for i := range base {
		r := &base[i]
		sqliteScanDocument(&r.d, r.createdAt, r.updatedAt)
		petIDs, err := sqliteDocumentPetIDs(ctx, s.db, r.d.ID)
		if err != nil {
			return nil, err
		}
		r.d.PetIDs = petIDs
		out = append(out, r.d)
	}
	return out, nil
}

// UpdateDocument replaces title + link set when baseUpdatedAt matches;
// otherwise ErrConflict.
func (s *SQLiteStore) UpdateDocument(ctx context.Context, householdID, docID, title string, petIDs []string, baseUpdatedAt time.Time, updatedBy string) (Document, error) {
	stored, err := s.GetDocument(ctx, householdID, docID)
	if err != nil {
		return Document{}, err
	}
	if !stored.UpdatedAt.Equal(baseUpdatedAt) {
		return Document{}, ErrConflict
	}
	if err := sqliteValidateDocumentPets(ctx, s.db, householdID, petIDs); err != nil {
		return Document{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Document{}, fmt.Errorf("update document: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, `
		UPDATE documents
		SET title = ?, updated_at = ?, updated_by = ?
		WHERE id = ? AND household_id = ?
	`, title, fmtTime(sqliteBumpAfter(stored.UpdatedAt)), updatedBy, docID, householdID); err != nil {
		return Document{}, fmt.Errorf("update document: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM document_pets WHERE document_id = ?
	`, docID); err != nil {
		return Document{}, fmt.Errorf("update document links: %w", err)
	}
	for _, pid := range petIDs {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO document_pets (document_id, pet_id) VALUES (?, ?)
		`, docID, pid); err != nil {
			return Document{}, fmt.Errorf("update document links: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return Document{}, fmt.Errorf("update document: %w", err)
	}
	return s.GetDocument(ctx, householdID, docID)
}

// DeleteDocument removes links + row and tombstones resource 'document'.
// The blob bytes are the caller's job (delete after commit; failures leave
// orphans for the GC sweep).
func (s *SQLiteStore) DeleteDocument(ctx context.Context, householdID, docID string) (Document, error) {
	stored, err := s.GetDocument(ctx, householdID, docID)
	if err != nil {
		return Document{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Document{}, fmt.Errorf("delete document: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM document_pets WHERE document_id = ?
	`, docID); err != nil {
		return Document{}, fmt.Errorf("delete document links: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM documents WHERE id = ? AND household_id = ?
	`, docID, householdID); err != nil {
		return Document{}, fmt.Errorf("delete document row: %w", err)
	}
	if err := sqliteInsertHouseholdTombstoneTx(ctx, tx, householdID, "", "document", docID, time.Now().UTC()); err != nil {
		return Document{}, err
	}
	if err := tx.Commit(); err != nil {
		return Document{}, fmt.Errorf("delete document: %w", err)
	}
	return stored, nil
}

// ConfirmDocument marks a document ready (bytes verified by the caller).
// updated_at is bumped so other devices pull the newly-visible row.
func (s *SQLiteStore) ConfirmDocument(ctx context.Context, householdID, docID string) (Document, error) {
	stored, err := s.GetDocument(ctx, householdID, docID)
	if err != nil {
		return Document{}, err
	}
	if _, err := s.db.ExecContext(ctx, `
		UPDATE documents
		SET ready = true, updated_at = ?
		WHERE id = ? AND household_id = ?
	`, fmtTime(sqliteBumpAfter(stored.UpdatedAt)), docID, householdID); err != nil {
		return Document{}, fmt.Errorf("confirm document: %w", err)
	}
	return s.GetDocument(ctx, householdID, docID)
}

// DeleteDocumentsByIDs deletes the listed documents + their links WITHOUT
// tombstones. GC path for unconfirmed uploads: clients never saw unready
// rows (ListDocumentsChangedSince filters ready=true), so there is nothing
// to propagate.
func (s *SQLiteStore) DeleteDocumentsByIDs(ctx context.Context, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	placeholders := strings.Repeat("?,", len(ids))
	placeholders = placeholders[:len(placeholders)-1]
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("gc documents: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM document_pets WHERE document_id IN (`+placeholders+`)
	`, args...); err != nil {
		return fmt.Errorf("gc document links: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM documents WHERE id IN (`+placeholders+`)
	`, args...); err != nil {
		return fmt.Errorf("gc documents: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("gc documents: %w", err)
	}
	return nil
}

// ListUnconfirmedDocuments returns up to limit documents that are still
// unready and were created before olderThan, oldest first — the GC sweep
// input. Only ID and BlobKey are populated (the sweeper needs no metadata).
func (s *SQLiteStore) ListUnconfirmedDocuments(ctx context.Context, olderThan time.Time, limit int) ([]Document, error) {
	if limit <= 0 {
		return nil, nil
	}
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, blob_key FROM documents
		WHERE ready = 0 AND created_at < ?
		ORDER BY created_at ASC, id ASC
		LIMIT ?
	`, fmtTime(olderThan), limit)
	if err != nil {
		return nil, fmt.Errorf("list unconfirmed documents: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var out []Document
	for rows.Next() {
		var d Document
		if err := rows.Scan(&d.ID, &d.BlobKey); err != nil {
			return nil, fmt.Errorf("list unconfirmed documents scan: %w", err)
		}
		out = append(out, d)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list unconfirmed documents rows: %w", err)
	}
	return out, nil
}

// ---------------------------------------------------------------------------
// Household tombstones.
// ---------------------------------------------------------------------------

// sqliteTombstoneActorTx resolves the user_id for a household tombstone:
// the household's earliest-joined member (the same convention as the
// Postgres twin). The legacy user_id column is NOT NULL with a FK to
// users, so it must name a real user; earliest-member keeps both backends
// byte-identical. The preferred override exists for callers that already
// resolved an actor.
func sqliteTombstoneActorTx(ctx context.Context, tx *sql.Tx, householdID, preferred string) (string, error) {
	if preferred != "" {
		return preferred, nil
	}
	var uid string
	if err := tx.QueryRowContext(ctx, `
		SELECT user_id FROM household_members
		WHERE household_id = ?
		ORDER BY joined_at ASC, user_id ASC
		LIMIT 1
	`, householdID).Scan(&uid); err != nil {
		return "", fmt.Errorf("tombstone actor: %w", err)
	}
	return uid, nil
}

// sqliteInsertHouseholdTombstoneTx writes one household tombstone row (plain
// insert: a duplicate (user, resource, record) surfaces as a constraint
// error, never a silent merge).
func sqliteInsertHouseholdTombstoneTx(ctx context.Context, tx *sql.Tx, householdID, actor, resource, recordID string, at time.Time) error {
	resolved, err := sqliteTombstoneActorTx(ctx, tx, householdID, actor)
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO tombstones (user_id, resource, record_id, deleted_at, household_id)
		VALUES (?, ?, ?, ?, ?)
	`, resolved, resource, recordID, fmtTime(at), householdID); err != nil {
		return fmt.Errorf("insert tombstone: %w", err)
	}
	return nil
}

// ListHouseholdDeletions returns the household's tombstones with deleted_at
// after since (nil/zero = all), ordered ASC.
func (s *SQLiteStore) ListHouseholdDeletions(ctx context.Context, householdID string, since *time.Time) ([]Tombstone, error) {
	sinceArg := sqliteSinceArg(since)
	rows, err := s.db.QueryContext(ctx, `
		SELECT resource, record_id, deleted_at
		FROM tombstones
		WHERE household_id = ? AND (? IS NULL OR deleted_at > ?)
		ORDER BY deleted_at ASC, record_id ASC
	`, householdID, sinceArg, sinceArg)
	if err != nil {
		return nil, fmt.Errorf("list household deletions: %w", err)
	}
	defer func() { _ = rows.Close() }()
	var out []Tombstone
	for rows.Next() {
		var t Tombstone
		var deletedAt string
		if err := rows.Scan(&t.Resource, &t.ID, &deletedAt); err != nil {
			return nil, fmt.Errorf("list household deletions scan: %w", err)
		}
		t.DeletedAt = parseTime(deletedAt)
		out = append(out, t)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list household deletions rows: %w", err)
	}
	return out, nil
}

// RecordTombstone writes one tombstone row.
func (s *SQLiteStore) RecordTombstone(ctx context.Context, householdID, resource, recordID string, at time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("record tombstone: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if err := sqliteInsertHouseholdTombstoneTx(ctx, tx, householdID, "", resource, recordID, at); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("record tombstone: %w", err)
	}
	return nil
}
