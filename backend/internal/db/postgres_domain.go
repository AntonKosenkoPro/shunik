package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// pgTxQuerier abstracts *pgxpool.Pool and pgx.Tx so domain helpers run
// unchanged on the pool (single-statement reads) and inside a transaction.
type pgTxQuerier interface {
	Exec(ctx context.Context, sql string, arguments ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, arguments ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, arguments ...any) pgx.Row
}

// pgNormSince normalizes a changed-since cursor: nil/zero means "all", which
// the ($n::timestamptz IS NULL OR ...) filter pattern turns into no bound.
func pgNormSince(since *time.Time) *time.Time {
	if since != nil && since.IsZero() {
		return nil
	}
	return since
}

// ---------------------------------------------------------------------------
// Pets
// ---------------------------------------------------------------------------

// pgPetColumns is the full pet projection in scan order.
const pgPetColumns = `id, household_id, name, species, birthdate, notes, created_at, updated_at, updated_by`

func pgScanPet(sc pgx.Row, p *Pet) error {
	return sc.Scan(&p.ID, &p.HouseholdID, &p.Name, &p.Species, &p.Birthdate,
		&p.Notes, &p.CreatedAt, &p.UpdatedAt, &p.UpdatedBy)
}

// CreatePet inserts a pet (idempotent on ID: replays return the stored row
// with created=false). The pet's household must exist.
func (s *PostgresStore) CreatePet(ctx context.Context, householdID string, in PetInput, updatedBy string) (Pet, bool, error) {
	id := in.ID
	if id == "" {
		id = uuidV7()
	}
	var p Pet
	err := pgScanPet(s.pool.QueryRow(ctx, `
		INSERT INTO pets (id, household_id, name, species, birthdate, notes, created_at, updated_at, updated_by)
		VALUES ($1, $2, $3, $4, $5, $6, NOW(), NOW(), $7)
		ON CONFLICT (id) DO NOTHING
		RETURNING `+pgPetColumns+`
	`, id, householdID, in.Name, in.Species, in.Birthdate, in.Notes, updatedBy), &p)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			// Lost the insert race (or a replay): return the stored row.
			stored, gerr := s.GetPet(ctx, householdID, id)
			if gerr != nil {
				return Pet{}, false, gerr
			}
			return stored, false, nil
		}
		return Pet{}, false, fmt.Errorf("create pet: %w", err)
	}
	return p, true, nil
}

// GetPet returns a pet or ErrNotFound (other households' pets are invisible).
func (s *PostgresStore) GetPet(ctx context.Context, householdID, petID string) (Pet, error) {
	var p Pet
	err := pgScanPet(s.pool.QueryRow(ctx, `
		SELECT `+pgPetColumns+`
		FROM pets
		WHERE id = $1 AND household_id = $2
	`, petID, householdID), &p)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Pet{}, ErrNotFound
		}
		return Pet{}, fmt.Errorf("get pet: %w", err)
	}
	return p, nil
}

// ListPetsChangedSince returns pets with updated_at after since (nil/zero =
// all), ordered by updated_at ASC, for delta pulls.
func (s *PostgresStore) ListPetsChangedSince(ctx context.Context, householdID string, since *time.Time) ([]Pet, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT `+pgPetColumns+`
		FROM pets
		WHERE household_id = $1 AND ($2::timestamptz IS NULL OR updated_at >= $2)
		ORDER BY updated_at ASC, id ASC
	`, householdID, pgNormSince(since))
	if err != nil {
		return nil, fmt.Errorf("list pets: %w", err)
	}
	defer rows.Close()
	var out []Pet
	for rows.Next() {
		var p Pet
		if err := pgScanPet(rows, &p); err != nil {
			return nil, fmt.Errorf("list pets scan: %w", err)
		}
		out = append(out, p)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list pets rows: %w", err)
	}
	return out, nil
}

// UpdatePet full-replaces a pet when baseUpdatedAt matches the stored
// updated_at; otherwise ErrConflict with the row untouched.
func (s *PostgresStore) UpdatePet(ctx context.Context, householdID, petID string, in PetInput, baseUpdatedAt time.Time, updatedBy string) (Pet, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Pet{}, fmt.Errorf("update pet begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var stored time.Time
	err = tx.QueryRow(ctx, `
		SELECT updated_at FROM pets WHERE id = $1 AND household_id = $2 FOR UPDATE
	`, petID, householdID).Scan(&stored)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Pet{}, ErrNotFound
		}
		return Pet{}, fmt.Errorf("update pet lock: %w", err)
	}
	if !stored.Equal(baseUpdatedAt) {
		return Pet{}, ErrConflict
	}
	if _, err := tx.Exec(ctx, `
		UPDATE pets SET name = $3, species = $4, birthdate = $5, notes = $6,
			updated_at = NOW(), updated_by = $7
		WHERE id = $1 AND household_id = $2
	`, petID, householdID, in.Name, in.Species, in.Birthdate, in.Notes, updatedBy); err != nil {
		return Pet{}, fmt.Errorf("update pet: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return Pet{}, fmt.Errorf("update pet commit: %w", err)
	}
	return s.GetPet(ctx, householdID, petID)
}

// DeletePet removes the pet with cascade: every event (details, intakes) is
// tombstoned per resource, documents drop the pet from their link sets via
// document updates, then the pet is tombstoned.
func (s *PostgresStore) DeletePet(ctx context.Context, householdID, petID, deletedBy string) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("delete pet begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var one int
	if err := tx.QueryRow(ctx, `
		SELECT 1 FROM pets WHERE id = $1 AND household_id = $2 FOR UPDATE
	`, petID, householdID).Scan(&one); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return fmt.Errorf("delete pet lock: %w", err)
	}

	eventRows, err := tx.Query(ctx, `
		SELECT id FROM event_base WHERE household_id = $1 AND pet_id = $2
	`, householdID, petID)
	if err != nil {
		return fmt.Errorf("delete pet enumerate events: %w", err)
	}
	var eventIDs []string
	for eventRows.Next() {
		var eid string
		if err := eventRows.Scan(&eid); err != nil {
			eventRows.Close()
			return fmt.Errorf("delete pet scan event: %w", err)
		}
		eventIDs = append(eventIDs, eid)
	}
	eventRows.Close()
	if err := eventRows.Err(); err != nil {
		return fmt.Errorf("delete pet events rows: %w", err)
	}

	now := time.Now().UTC()
	for _, eid := range eventIDs {
		if err := pgDeleteEventTx(ctx, tx, householdID, eid, deletedBy, now); err != nil {
			return err
		}
	}

	// Prune the pet from documents' link sets. Parent documents are bumped
	// (updated_at/updated_by) so pulls converge; link removal itself carries
	// no tombstone.
	linkRows, err := tx.Query(ctx, `
		SELECT DISTINCT document_id FROM document_pets WHERE pet_id = $1
	`, petID)
	if err != nil {
		return fmt.Errorf("delete pet enumerate links: %w", err)
	}
	var docIDs []string
	for linkRows.Next() {
		var did string
		if err := linkRows.Scan(&did); err != nil {
			linkRows.Close()
			return fmt.Errorf("delete pet scan link: %w", err)
		}
		docIDs = append(docIDs, did)
	}
	linkRows.Close()
	if err := linkRows.Err(); err != nil {
		return fmt.Errorf("delete pet links rows: %w", err)
	}
	if len(docIDs) > 0 {
		if _, err := tx.Exec(ctx, `
			UPDATE documents SET updated_at = NOW(), updated_by = $2
			WHERE id = ANY($1)
		`, docIDs, deletedBy); err != nil {
			return fmt.Errorf("delete pet bump documents: %w", err)
		}
	}
	if _, err := tx.Exec(ctx, `DELETE FROM document_pets WHERE pet_id = $1`, petID); err != nil {
		return fmt.Errorf("delete pet prune links: %w", err)
	}

	if _, err := tx.Exec(ctx, `DELETE FROM pets WHERE id = $1 AND household_id = $2`, petID, householdID); err != nil {
		return fmt.Errorf("delete pet: %w", err)
	}
	if err := pgRecordTombstoneTx(ctx, tx, householdID, deletedBy, "pet", petID, now); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("delete pet commit: %w", err)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

// pgEventSelect is the base-plus-details projection in pgScanEvent order.
const pgEventSelect = `
	SELECT b.id, b.household_id, b.pet_id, b.kind, b.occurred_at, b.next_due_at, b.title,
		b.created_at, b.updated_at, b.updated_by,
		v.event_id, v.vaccine, v.batch, v.vet, v.notes,
		g.event_id, g.service, g.place, g.notes,
		w.event_id, w.grams,
		c.event_id, c.drug_name, c.dose_amount, c.dose_unit, c.route, c.schedule_kind,
		c.schedule_times, c.schedule_weekdays, c.duration_days, c.ends_on, c.status,
		c.instructions, c.info_ref
	FROM event_base b
	LEFT JOIN vacc_details v ON v.event_id = b.id
	LEFT JOIN grooming_details g ON g.event_id = b.id
	LEFT JOIN weight_details w ON w.event_id = b.id
	LEFT JOIN med_courses c ON c.event_id = b.id
`

func pgScanEvent(sc pgx.Row) (Event, error) {
	var e Event
	var vID, gID, wID, cID sql.NullString
	var vVaccine, vBatch, vVet, vNotes sql.NullString
	var gService, gPlace, gNotes sql.NullString
	var grams sql.NullInt64
	var drugName, doseAmount, doseUnit, route, schedKind, schedTimes, schedWeekdays sql.NullString
	var durationDays sql.NullInt64
	var endsOn *time.Time
	var status, instructions, infoRef sql.NullString
	err := sc.Scan(
		&e.ID, &e.HouseholdID, &e.PetID, &e.Kind, &e.OccurredAt, &e.NextDueAt, &e.Title,
		&e.CreatedAt, &e.UpdatedAt, &e.UpdatedBy,
		&vID, &vVaccine, &vBatch, &vVet, &vNotes,
		&gID, &gService, &gPlace, &gNotes,
		&wID, &grams,
		&cID, &drugName, &doseAmount, &doseUnit, &route, &schedKind,
		&schedTimes, &schedWeekdays, &durationDays, &endsOn, &status,
		&instructions, &infoRef,
	)
	if err != nil {
		return Event{}, err
	}
	if vID.Valid {
		e.Vaccination = &VaccDetail{Vaccine: vVaccine.String, Batch: vBatch.String, Vet: vVet.String, Notes: vNotes.String}
	}
	if gID.Valid {
		e.Grooming = &GroomDetail{Service: gService.String, Place: gPlace.String, Notes: gNotes.String}
	}
	if wID.Valid {
		e.Weight = &WeightDetail{Grams: grams.Int64}
	}
	if cID.Valid {
		e.Course = &MedCourse{
			DrugName: drugName.String, DoseAmount: doseAmount.String, DoseUnit: doseUnit.String,
			Route: route.String, ScheduleKind: schedKind.String, ScheduleTimes: schedTimes.String,
			ScheduleWeekdays: schedWeekdays.String, DurationDays: int(durationDays.Int64),
			EndsOn: endsOn, Status: status.String, Instructions: instructions.String, InfoRef: infoRef.String,
		}
	}
	return e, nil
}

// pgCheckPetInHousehold fails loudly (ErrInvalidPetID) when the pet is
// unknown or belongs to another household — never distinguished.
func pgCheckPetInHousehold(ctx context.Context, q pgTxQuerier, householdID, petID, op string) error {
	var one int
	err := q.QueryRow(ctx, `SELECT 1 FROM pets WHERE id = $1 AND household_id = $2`, petID, householdID).Scan(&one)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("%s: %w", op, ErrInvalidPetID)
		}
		return fmt.Errorf("%s pet check: %w", op, err)
	}
	return nil
}

// pgDeleteEventDetails removes every kind-detail row for an event (the kind
// may have changed across updates, so all four are pruned unconditionally).
func pgDeleteEventDetails(ctx context.Context, q pgTxQuerier, eventID string) error {
	for _, table := range []string{"vacc_details", "grooming_details", "weight_details", "med_courses"} {
		if _, err := q.Exec(ctx, `DELETE FROM `+table+` WHERE event_id = $1`, eventID); err != nil {
			return fmt.Errorf("delete event details %s: %w", table, err)
		}
	}
	return nil
}

// pgInsertEventDetail inserts the kind detail matching in.Kind.
// pgValidateEventInput enforces kind + exactly-one-detail-present, mirroring
// the sqlite twin (same messages): field-level schedule validation lives in
// the handler layer; the store enforces kind, detail shape minimums, and DB
// CHECK constraints.
func pgValidateEventInput(in EventInput) error {
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

func pgInsertEventDetail(ctx context.Context, q pgTxQuerier, eventID string, in EventInput) error {
	switch in.Kind {
	case "vaccination":
		d := in.Vaccination
		_, err := q.Exec(ctx, `
			INSERT INTO vacc_details (event_id, vaccine, batch, vet, notes)
			VALUES ($1, $2, $3, $4, $5)
		`, eventID, d.Vaccine, d.Batch, d.Vet, d.Notes)
		if err != nil {
			return fmt.Errorf("insert vacc detail: %w", err)
		}
	case "grooming":
		d := in.Grooming
		_, err := q.Exec(ctx, `
			INSERT INTO grooming_details (event_id, service, place, notes)
			VALUES ($1, $2, $3, $4)
		`, eventID, d.Service, d.Place, d.Notes)
		if err != nil {
			return fmt.Errorf("insert grooming detail: %w", err)
		}
	case "weight":
		_, err := q.Exec(ctx, `
			INSERT INTO weight_details (event_id, grams) VALUES ($1, $2)
		`, eventID, in.Weight.Grams)
		if err != nil {
			return fmt.Errorf("insert weight detail: %w", err)
		}
	case "med_course":
		d := in.Course
		_, err := q.Exec(ctx, `
			INSERT INTO med_courses (event_id, drug_name, dose_amount, dose_unit, route,
				schedule_kind, schedule_times, schedule_weekdays, duration_days, ends_on,
				status, instructions, info_ref)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
		`, eventID, d.DrugName, d.DoseAmount, d.DoseUnit, d.Route, d.ScheduleKind,
			d.ScheduleTimes, d.ScheduleWeekdays, d.DurationDays, d.EndsOn,
			d.Status, d.Instructions, d.InfoRef)
		if err != nil {
			return fmt.Errorf("insert med course: %w", err)
		}
	default:
		return fmt.Errorf("unknown event kind %q", in.Kind)
	}
	return nil
}

// pgDeleteEventTx deletes one event's intakes (tombstoned each), details,
// and base row, then tombstones the event — the shared core of DeleteEvent
// and the per-event step of DeletePet.
func pgDeleteEventTx(ctx context.Context, tx pgx.Tx, householdID, eventID, actor string, now time.Time) error {
	intakeRows, err := tx.Query(ctx, `SELECT id FROM med_intakes WHERE course_id = $1`, eventID)
	if err != nil {
		return fmt.Errorf("delete event enumerate intakes: %w", err)
	}
	var intakeIDs []string
	for intakeRows.Next() {
		var iid string
		if err := intakeRows.Scan(&iid); err != nil {
			intakeRows.Close()
			return fmt.Errorf("delete event scan intake: %w", err)
		}
		intakeIDs = append(intakeIDs, iid)
	}
	intakeRows.Close()
	if err := intakeRows.Err(); err != nil {
		return fmt.Errorf("delete event intakes rows: %w", err)
	}
	if len(intakeIDs) > 0 {
		if _, err := tx.Exec(ctx, `DELETE FROM med_intakes WHERE course_id = $1`, eventID); err != nil {
			return fmt.Errorf("delete event intakes: %w", err)
		}
		for _, iid := range intakeIDs {
			if err := pgRecordTombstoneTx(ctx, tx, householdID, actor, "intake", iid, now); err != nil {
				return err
			}
		}
	}
	if err := pgDeleteEventDetails(ctx, tx, eventID); err != nil {
		return err
	}
	tag, err := tx.Exec(ctx, `DELETE FROM event_base WHERE id = $1 AND household_id = $2`, eventID, householdID)
	if err != nil {
		return fmt.Errorf("delete event base: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	if err := pgRecordTombstoneTx(ctx, tx, householdID, actor, "event", eventID, now); err != nil {
		return err
	}
	return nil
}

// CreateEvent inserts an event with its kind detail in one transaction
// (idempotent on ID). The pet must belong to the household.
func (s *PostgresStore) CreateEvent(ctx context.Context, householdID string, in EventInput, updatedBy string) (Event, bool, error) {
	if err := pgValidateEventInput(in); err != nil {
		return Event{}, false, err
	}
	id := in.ID
	if id == "" {
		id = uuidV7()
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Event{}, false, fmt.Errorf("create event begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if err := pgCheckPetInHousehold(ctx, tx, householdID, in.PetID, "create event"); err != nil {
		return Event{}, false, err
	}
	var inserted string
	err = tx.QueryRow(ctx, `
		INSERT INTO event_base (id, household_id, pet_id, kind, occurred_at, next_due_at, title, created_at, updated_at, updated_by)
		VALUES ($1, $2, $3, $4, $5, $6, $7, NOW(), NOW(), $8)
		ON CONFLICT (id) DO NOTHING
		RETURNING id
	`, id, householdID, in.PetID, in.Kind, in.OccurredAt.UTC(), in.NextDueAt, in.Title, updatedBy).Scan(&inserted)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			stored, gerr := s.GetEvent(ctx, householdID, id)
			if gerr != nil {
				return Event{}, false, gerr
			}
			return stored, false, nil
		}
		return Event{}, false, fmt.Errorf("create event base: %w", err)
	}
	if err := pgInsertEventDetail(ctx, tx, id, in); err != nil {
		return Event{}, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Event{}, false, fmt.Errorf("create event commit: %w", err)
	}
	ev, err := s.GetEvent(ctx, householdID, id)
	if err != nil {
		return Event{}, false, err
	}
	return ev, true, nil
}

// GetEvent returns the event with its detail joined, or ErrNotFound.
func (s *PostgresStore) GetEvent(ctx context.Context, householdID, eventID string) (Event, error) {
	ev, err := pgScanEvent(s.pool.QueryRow(ctx, pgEventSelect+`
		WHERE b.id = $1 AND b.household_id = $2
	`, eventID, householdID))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Event{}, ErrNotFound
		}
		return Event{}, fmt.Errorf("get event: %w", err)
	}
	return ev, nil
}

// ListEventsChangedSince returns events (details joined) with base
// updated_at after since, ordered ASC. Empty petID = all pets.
func (s *PostgresStore) ListEventsChangedSince(ctx context.Context, householdID string, since *time.Time, petID string) ([]Event, error) {
	var petArg any = petID
	if petID == "" {
		petArg = nil
	}
	rows, err := s.pool.Query(ctx, pgEventSelect+`
		WHERE b.household_id = $1
		  AND ($2::timestamptz IS NULL OR b.updated_at >= $2)
		  AND ($3::uuid IS NULL OR b.pet_id = $3::uuid)
		ORDER BY b.updated_at ASC, b.id ASC
	`, householdID, pgNormSince(since), petArg)
	if err != nil {
		return nil, fmt.Errorf("list events: %w", err)
	}
	defer rows.Close()
	var out []Event
	for rows.Next() {
		ev, err := pgScanEvent(rows)
		if err != nil {
			return nil, fmt.Errorf("list events scan: %w", err)
		}
		out = append(out, ev)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list events rows: %w", err)
	}
	return out, nil
}

// UpdateEvent full-replaces base + detail when baseUpdatedAt matches the
// stored base updated_at; otherwise ErrConflict.
func (s *PostgresStore) UpdateEvent(ctx context.Context, householdID, eventID string, in EventInput, baseUpdatedAt time.Time, updatedBy string) (Event, error) {
	if err := pgValidateEventInput(in); err != nil {
		return Event{}, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Event{}, fmt.Errorf("update event begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var stored time.Time
	err = tx.QueryRow(ctx, `
		SELECT updated_at FROM event_base WHERE id = $1 AND household_id = $2 FOR UPDATE
	`, eventID, householdID).Scan(&stored)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Event{}, ErrNotFound
		}
		return Event{}, fmt.Errorf("update event lock: %w", err)
	}
	if !stored.Equal(baseUpdatedAt) {
		return Event{}, ErrConflict
	}
	if err := pgCheckPetInHousehold(ctx, tx, householdID, in.PetID, "update event"); err != nil {
		return Event{}, err
	}
	if _, err := tx.Exec(ctx, `
		UPDATE event_base SET pet_id = $3, kind = $4, occurred_at = $5, next_due_at = $6,
			title = $7, updated_at = NOW(), updated_by = $8
		WHERE id = $1 AND household_id = $2
	`, eventID, householdID, in.PetID, in.Kind, in.OccurredAt.UTC(), in.NextDueAt, in.Title, updatedBy); err != nil {
		return Event{}, fmt.Errorf("update event base: %w", err)
	}
	if err := pgDeleteEventDetails(ctx, tx, eventID); err != nil {
		return Event{}, err
	}
	if err := pgInsertEventDetail(ctx, tx, eventID, in); err != nil {
		return Event{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Event{}, fmt.Errorf("update event commit: %w", err)
	}
	return s.GetEvent(ctx, householdID, eventID)
}

// DeleteEvent removes details + base and tombstones resource 'event'.
func (s *PostgresStore) DeleteEvent(ctx context.Context, householdID, eventID string) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("delete event begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var one int
	if err := tx.QueryRow(ctx, `
		SELECT 1 FROM event_base WHERE id = $1 AND household_id = $2 FOR UPDATE
	`, eventID, householdID).Scan(&one); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return fmt.Errorf("delete event lock: %w", err)
	}
	if err := pgDeleteEventTx(ctx, tx, householdID, eventID, "", time.Now().UTC()); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("delete event commit: %w", err)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Intakes
// ---------------------------------------------------------------------------

// pgIntakeColumns is the full intake projection in scan order.
const pgIntakeColumns = `id, household_id, course_id, due_at, status, taken_at, dose_snapshot, note, marked_by, created_at, updated_at`

func pgScanIntake(sc pgx.Row, m *MedIntake) error {
	return sc.Scan(&m.ID, &m.HouseholdID, &m.CourseID, &m.DueAt, &m.Status,
		&m.TakenAt, &m.DoseSnapshot, &m.Note, &m.MarkedBy, &m.CreatedAt, &m.UpdatedAt)
}

// pgCheckCourseInHousehold fails loudly (ErrInvalidPetID covers the
// missing-course case: same "unknown reference" shape).
func pgCheckCourseInHousehold(ctx context.Context, q pgTxQuerier, householdID, courseID, op string) error {
	var one int
	err := q.QueryRow(ctx, `
		SELECT 1 FROM med_courses c
		JOIN event_base b ON b.id = c.event_id
		WHERE c.event_id = $1 AND b.household_id = $2
	`, courseID, householdID).Scan(&one)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("%s: %w", op, ErrInvalidPetID)
		}
		return fmt.Errorf("%s course check: %w", op, err)
	}
	return nil
}

// CreateIntake inserts an intake under a household course (idempotent on ID).
func (s *PostgresStore) CreateIntake(ctx context.Context, householdID string, in IntakeInput, createdBy string) (MedIntake, bool, error) {
	_ = createdBy
	id := in.ID
	if id == "" {
		id = uuidV7()
	}
	if err := pgCheckCourseInHousehold(ctx, s.pool, householdID, in.CourseID, "create intake"); err != nil {
		return MedIntake{}, false, err
	}
	var m MedIntake
	err := pgScanIntake(s.pool.QueryRow(ctx, `
		INSERT INTO med_intakes (id, household_id, course_id, due_at, status, taken_at, dose_snapshot, note, marked_by, created_at, updated_at)
		VALUES ($1, $2, $3, $4, 'pending', NULL, $5, $6, '', NOW(), NOW())
		ON CONFLICT (id) DO NOTHING
		RETURNING `+pgIntakeColumns+`
	`, id, householdID, in.CourseID, in.DueAt, in.DoseSnapshot, in.Note), &m)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			stored, gerr := s.GetIntake(ctx, householdID, id)
			if gerr != nil {
				return MedIntake{}, false, gerr
			}
			return stored, false, nil
		}
		return MedIntake{}, false, fmt.Errorf("create intake: %w", err)
	}
	return m, true, nil
}

// GetIntake returns an intake or ErrNotFound.
func (s *PostgresStore) GetIntake(ctx context.Context, householdID, intakeID string) (MedIntake, error) {
	var m MedIntake
	err := pgScanIntake(s.pool.QueryRow(ctx, `
		SELECT `+pgIntakeColumns+`
		FROM med_intakes
		WHERE id = $1 AND household_id = $2
	`, intakeID, householdID), &m)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return MedIntake{}, ErrNotFound
		}
		return MedIntake{}, fmt.Errorf("get intake: %w", err)
	}
	return m, nil
}

// ListIntakesChangedSince returns intakes with updated_at after since,
// ordered ASC. Empty courseID = all courses.
func (s *PostgresStore) ListIntakesChangedSince(ctx context.Context, householdID, courseID string, since *time.Time) ([]MedIntake, error) {
	var courseArg any = courseID
	if courseID == "" {
		courseArg = nil
	}
	rows, err := s.pool.Query(ctx, `
		SELECT `+pgIntakeColumns+`
		FROM med_intakes
		WHERE household_id = $1
		  AND ($2::uuid IS NULL OR course_id = $2::uuid)
		  AND ($3::timestamptz IS NULL OR updated_at >= $3)
		ORDER BY updated_at ASC, id ASC
	`, householdID, courseArg, pgNormSince(since))
	if err != nil {
		return nil, fmt.Errorf("list intakes: %w", err)
	}
	defer rows.Close()
	var out []MedIntake
	for rows.Next() {
		var m MedIntake
		if err := pgScanIntake(rows, &m); err != nil {
			return nil, fmt.Errorf("list intakes scan: %w", err)
		}
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list intakes rows: %w", err)
	}
	return out, nil
}

// UpdateIntake replaces mutable fields when baseUpdatedAt matches; otherwise
// ErrConflict. Status transitions stamp MarkedBy from the caller; a taken
// mark without TakenAt stamps now.
func (s *PostgresStore) UpdateIntake(ctx context.Context, householdID, intakeID string, in IntakeUpdate, baseUpdatedAt time.Time, markedBy string) (MedIntake, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return MedIntake{}, fmt.Errorf("update intake begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var stored MedIntake
	err = pgScanIntake(tx.QueryRow(ctx, `
		SELECT `+pgIntakeColumns+`
		FROM med_intakes WHERE id = $1 AND household_id = $2 FOR UPDATE
	`, intakeID, householdID), &stored)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return MedIntake{}, ErrNotFound
		}
		return MedIntake{}, fmt.Errorf("update intake lock: %w", err)
	}
	if !stored.UpdatedAt.Equal(baseUpdatedAt) {
		return MedIntake{}, ErrConflict
	}
	nextMarkedBy := stored.MarkedBy
	if in.Status != stored.Status {
		nextMarkedBy = markedBy
	}
	takenAt := in.TakenAt
	if in.Status == "taken" && takenAt == nil {
		now := time.Now().UTC()
		takenAt = &now
	}
	if _, err := tx.Exec(ctx, `
		UPDATE med_intakes SET status = $3, taken_at = $4, dose_snapshot = $5,
			note = $6, marked_by = $7, updated_at = NOW()
		WHERE id = $1 AND household_id = $2
	`, intakeID, householdID, in.Status, takenAt, in.DoseSnapshot, in.Note, nextMarkedBy); err != nil {
		return MedIntake{}, fmt.Errorf("update intake: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return MedIntake{}, fmt.Errorf("update intake commit: %w", err)
	}
	return s.GetIntake(ctx, householdID, intakeID)
}

// DeleteIntake removes the intake and tombstones resource 'intake'.
func (s *PostgresStore) DeleteIntake(ctx context.Context, householdID, intakeID string) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("delete intake begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	tag, err := tx.Exec(ctx, `DELETE FROM med_intakes WHERE id = $1 AND household_id = $2`, intakeID, householdID)
	if err != nil {
		return fmt.Errorf("delete intake: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	if err := pgRecordTombstoneTx(ctx, tx, householdID, "", "intake", intakeID, time.Now().UTC()); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("delete intake commit: %w", err)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Documents
// ---------------------------------------------------------------------------

// pgDocColumns is the document metadata projection in scan order (never
// bytes — there are none in the row).
const pgDocColumns = `id, household_id, title, mime, size_bytes, filename, blob_key, ready, extracted_text, created_at, updated_at, updated_by`

func pgScanDoc(sc pgx.Row, d *Document) error {
	return sc.Scan(&d.ID, &d.HouseholdID, &d.Title, &d.Mime, &d.SizeBytes,
		&d.Filename, &d.BlobKey, &d.Ready, &d.ExtractedText,
		&d.CreatedAt, &d.UpdatedAt, &d.UpdatedBy)
}

// pgDocPetIDs returns a document's linked pet IDs in link-insertion order.
func pgDocPetIDs(ctx context.Context, q pgTxQuerier, docID string) ([]string, error) {
	rows, err := q.Query(ctx, `SELECT pet_id FROM document_pets WHERE document_id = $1 ORDER BY pet_id ASC`, docID)
	if err != nil {
		return nil, fmt.Errorf("document links: %w", err)
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var pid string
		if err := rows.Scan(&pid); err != nil {
			return nil, fmt.Errorf("document links scan: %w", err)
		}
		ids = append(ids, pid)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("document links rows: %w", err)
	}
	return ids, nil
}

// pgGetDocQ assembles document metadata with its pet link set.
func pgGetDocQ(ctx context.Context, q pgTxQuerier, householdID, docID string) (Document, error) {
	var d Document
	err := pgScanDoc(q.QueryRow(ctx, `
		SELECT `+pgDocColumns+`
		FROM documents WHERE id = $1 AND household_id = $2
	`, docID, householdID), &d)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Document{}, ErrNotFound
		}
		return Document{}, fmt.Errorf("get document: %w", err)
	}
	petIDs, err := pgDocPetIDs(ctx, q, docID)
	if err != nil {
		return Document{}, err
	}
	d.PetIDs = petIDs
	return d, nil
}

// pgCheckDocPets validates every linked pet belongs to the household.
func pgCheckDocPets(ctx context.Context, q pgTxQuerier, householdID string, petIDs []string, op string) error {
	for _, pid := range petIDs {
		if err := pgCheckPetInHousehold(ctx, q, householdID, pid, op); err != nil {
			return err
		}
	}
	return nil
}

// CreateDocument inserts document metadata with its pet link set in one
// transaction (idempotent on ID) and assigns the blob key. Bytes upload
// separately; ready stays false until ConfirmDocument.
func (s *PostgresStore) CreateDocument(ctx context.Context, householdID string, in DocumentInput, updatedBy string) (Document, bool, error) {
	id := in.ID
	if id == "" {
		id = uuidV7()
	}
	blobKey := blobKeyFor(householdID, id, in.Filename)
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Document{}, false, fmt.Errorf("create document begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if err := pgCheckDocPets(ctx, tx, householdID, in.PetIDs, "create document"); err != nil {
		return Document{}, false, err
	}
	var inserted string
	err = tx.QueryRow(ctx, `
		INSERT INTO documents (id, household_id, title, mime, size_bytes, filename, blob_key, ready, extracted_text, created_at, updated_at, updated_by)
		VALUES ($1, $2, $3, $4, $5, $6, $7, false, '', NOW(), NOW(), $8)
		ON CONFLICT (id) DO NOTHING
		RETURNING id
	`, id, householdID, in.Title, in.Mime, in.SizeBytes, in.Filename, blobKey, updatedBy).Scan(&inserted)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			stored, gerr := s.GetDocument(ctx, householdID, id)
			if gerr != nil {
				return Document{}, false, gerr
			}
			return stored, false, nil
		}
		return Document{}, false, fmt.Errorf("create document: %w", err)
	}
	for _, pid := range in.PetIDs {
		if _, err := tx.Exec(ctx, `
			INSERT INTO document_pets (document_id, pet_id) VALUES ($1, $2)
			ON CONFLICT DO NOTHING
		`, id, pid); err != nil {
			return Document{}, false, fmt.Errorf("create document links: %w", err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Document{}, false, fmt.Errorf("create document commit: %w", err)
	}
	doc, err := s.GetDocument(ctx, householdID, id)
	if err != nil {
		return Document{}, false, err
	}
	return doc, true, nil
}

// GetDocument returns document metadata with pet IDs, or ErrNotFound.
func (s *PostgresStore) GetDocument(ctx context.Context, householdID, docID string) (Document, error) {
	return pgGetDocQ(ctx, s.pool, householdID, docID)
}

// ListDocumentsChangedSince returns ready document metadata with updated_at
// after since, ordered ASC. Never bytes. Unready rows stay invisible until
// ConfirmDocument (GC-deleted unready rows never need tombstones).
func (s *PostgresStore) ListDocumentsChangedSince(ctx context.Context, householdID string, since *time.Time) ([]Document, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT `+pgDocColumns+`
		FROM documents
		WHERE household_id = $1 AND ready = true
		  AND ($2::timestamptz IS NULL OR updated_at >= $2)
		ORDER BY updated_at ASC, id ASC
	`, householdID, pgNormSince(since))
	if err != nil {
		return nil, fmt.Errorf("list documents: %w", err)
	}
	defer rows.Close()
	var out []Document
	for rows.Next() {
		var d Document
		if err := pgScanDoc(rows, &d); err != nil {
			return nil, fmt.Errorf("list documents scan: %w", err)
		}
		petIDs, err := pgDocPetIDs(ctx, s.pool, d.ID)
		if err != nil {
			return nil, err
		}
		d.PetIDs = petIDs
		out = append(out, d)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list documents rows: %w", err)
	}
	return out, nil
}

// UpdateDocument replaces title + link set when baseUpdatedAt matches;
// otherwise ErrConflict.
func (s *PostgresStore) UpdateDocument(ctx context.Context, householdID, docID, title string, petIDs []string, baseUpdatedAt time.Time, updatedBy string) (Document, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Document{}, fmt.Errorf("update document begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var stored time.Time
	err = tx.QueryRow(ctx, `
		SELECT updated_at FROM documents WHERE id = $1 AND household_id = $2 FOR UPDATE
	`, docID, householdID).Scan(&stored)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Document{}, ErrNotFound
		}
		return Document{}, fmt.Errorf("update document lock: %w", err)
	}
	if !stored.Equal(baseUpdatedAt) {
		return Document{}, ErrConflict
	}
	if err := pgCheckDocPets(ctx, tx, householdID, petIDs, "update document"); err != nil {
		return Document{}, err
	}
	if _, err := tx.Exec(ctx, `
		UPDATE documents SET title = $3, updated_at = NOW(), updated_by = $4
		WHERE id = $1 AND household_id = $2
	`, docID, householdID, title, updatedBy); err != nil {
		return Document{}, fmt.Errorf("update document: %w", err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM document_pets WHERE document_id = $1`, docID); err != nil {
		return Document{}, fmt.Errorf("update document clear links: %w", err)
	}
	for _, pid := range petIDs {
		if _, err := tx.Exec(ctx, `
			INSERT INTO document_pets (document_id, pet_id) VALUES ($1, $2)
			ON CONFLICT DO NOTHING
		`, docID, pid); err != nil {
			return Document{}, fmt.Errorf("update document links: %w", err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Document{}, fmt.Errorf("update document commit: %w", err)
	}
	return s.GetDocument(ctx, householdID, docID)
}

// DeleteDocument removes links + row and tombstones resource 'document'.
// The returned Document carries the blob key for caller-side byte delete.
func (s *PostgresStore) DeleteDocument(ctx context.Context, householdID, docID string) (Document, error) {
	doc, err := s.GetDocument(ctx, householdID, docID)
	if err != nil {
		return Document{}, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return Document{}, fmt.Errorf("delete document begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, `DELETE FROM document_pets WHERE document_id = $1`, docID); err != nil {
		return Document{}, fmt.Errorf("delete document links: %w", err)
	}
	tag, err := tx.Exec(ctx, `DELETE FROM documents WHERE id = $1 AND household_id = $2`, docID, householdID)
	if err != nil {
		return Document{}, fmt.Errorf("delete document: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return Document{}, ErrNotFound
	}
	if err := pgRecordTombstoneTx(ctx, tx, householdID, "", "document", docID, time.Now().UTC()); err != nil {
		return Document{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Document{}, fmt.Errorf("delete document commit: %w", err)
	}
	return doc, nil
}

// ConfirmDocument marks a document ready (bytes verified by the caller),
// bumping updated_at so the newly visible row converges on pulls.
func (s *PostgresStore) ConfirmDocument(ctx context.Context, householdID, docID string) (Document, error) {
	tag, err := s.pool.Exec(ctx, `
		UPDATE documents SET ready = true, updated_at = NOW()
		WHERE id = $1 AND household_id = $2
	`, docID, householdID)
	if err != nil {
		return Document{}, fmt.Errorf("confirm document: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return Document{}, ErrNotFound
	}
	return s.GetDocument(ctx, householdID, docID)
}

// ListUnconfirmedDocuments returns up to limit documents that are still
// unready and were created before olderThan, oldest first — the GC sweep
// input. Only ID and BlobKey are populated (the sweeper needs no metadata).
func (s *PostgresStore) ListUnconfirmedDocuments(ctx context.Context, olderThan time.Time, limit int) ([]Document, error) {
	if limit <= 0 {
		return nil, nil
	}
	rows, err := s.pool.Query(ctx, `
		SELECT id, blob_key FROM documents
		WHERE ready = false AND created_at < $1
		ORDER BY created_at ASC, id ASC
		LIMIT $2
	`, olderThan, limit)
	if err != nil {
		return nil, fmt.Errorf("list unconfirmed documents: %w", err)
	}
	defer rows.Close()
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

// DeleteDocumentsByIDs removes unconfirmed uploads (links + rows) WITHOUT
// tombstones — they were never visible to pulls, so no device can miss them.
func (s *PostgresStore) DeleteDocumentsByIDs(ctx context.Context, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("gc delete documents begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, `DELETE FROM document_pets WHERE document_id = ANY($1)`, ids); err != nil {
		return fmt.Errorf("gc delete document links: %w", err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM documents WHERE id = ANY($1)`, ids); err != nil {
		return fmt.Errorf("gc delete documents: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("gc delete documents commit: %w", err)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Household tombstones
// ---------------------------------------------------------------------------

// pgRecordTombstoneTx writes one household tombstone inside the caller's
// transaction (plain insert: a duplicate (user, resource, record) surfaces
// as a constraint error, never a silent merge). tombstones.user_id stays NOT
// NULL per migration 005, so the row is attributed to the acting user when
// the signature carries one (actor), else to the household's
// earliest-joined member; it is never read back through the Store
// interface — ListHouseholdDeletions filters on household_id only.
func pgRecordTombstoneTx(ctx context.Context, q pgTxQuerier, householdID, actor, resource, recordID string, at time.Time) error {
	userID := actor
	if userID == "" {
		err := q.QueryRow(ctx, `
			SELECT user_id FROM household_members
			WHERE household_id = $1
			ORDER BY joined_at ASC, user_id ASC
			LIMIT 1
		`, householdID).Scan(&userID)
		if err != nil {
			return fmt.Errorf("record tombstone actor: %w", err)
		}
	}
	_, err := q.Exec(ctx, `
		INSERT INTO tombstones (user_id, resource, record_id, deleted_at, household_id)
		VALUES ($1, $2, $3, $4, $5)
	`, userID, resource, recordID, at, householdID)
	if err != nil {
		return fmt.Errorf("record tombstone: %w", err)
	}
	return nil
}

// ListHouseholdDeletions returns the household's tombstones with deleted_at
// after since (nil/zero = all), ordered ASC.
func (s *PostgresStore) ListHouseholdDeletions(ctx context.Context, householdID string, since *time.Time) ([]Tombstone, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT resource, record_id, deleted_at
		FROM tombstones
		WHERE household_id = $1 AND ($2::timestamptz IS NULL OR deleted_at >= $2)
		ORDER BY deleted_at ASC, record_id ASC
	`, householdID, pgNormSince(since))
	if err != nil {
		return nil, fmt.Errorf("list household deletions: %w", err)
	}
	defer rows.Close()
	var out []Tombstone
	for rows.Next() {
		var t Tombstone
		if err := rows.Scan(&t.Resource, &t.ID, &t.DeletedAt); err != nil {
			return nil, fmt.Errorf("list household deletions scan: %w", err)
		}
		out = append(out, t)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list household deletions rows: %w", err)
	}
	return out, nil
}

// RecordTombstone writes one tombstone row.
func (s *PostgresStore) RecordTombstone(ctx context.Context, householdID, resource, recordID string, at time.Time) error {
	return pgRecordTombstoneTx(ctx, s.pool, householdID, "", resource, recordID, at)
}
