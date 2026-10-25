package db

import (
	"context"
	"errors"
	"testing"
	"time"
)

// SQLite domain tests (Shunik v1 household model). Helpers are
// sqliteDomain-prefixed so a future postgres twin can add its own without
// colliding; test names carry the SQLiteDomain infix for the same reason.

func sqliteDomainHousehold(ctx context.Context, t *testing.T, store *SQLiteStore, email string) (string, string) {
	t.Helper()
	uid := mustUser(t, store, email)
	house, err := store.EnsureHousehold(ctx, uid)
	if err != nil {
		t.Fatalf("EnsureHousehold: %v", err)
	}
	return uid, house.ID
}

func sqliteDomainMustPet(ctx context.Context, t *testing.T, store *SQLiteStore, householdID, name, updatedBy string) Pet {
	t.Helper()
	p, created, err := store.CreatePet(ctx, householdID, PetInput{
		ID: uuidV7(), Name: name, Species: "cat", Notes: "",
	}, updatedBy)
	if err != nil {
		t.Fatalf("CreatePet: %v", err)
	}
	if !created {
		t.Fatalf("expected created=true for fresh pet")
	}
	return p
}

func sqliteDomainVaccInput(petID string) EventInput {
	return EventInput{
		ID: uuidV7(), PetID: petID, Kind: "vaccination",
		OccurredAt:  time.Now().UTC().Truncate(time.Second),
		Title:       "rabies",
		Vaccination: &VaccDetail{Vaccine: "rabies", Batch: "b1", Vet: "vet", Notes: ""},
	}
}

func sqliteDomainMustVaccEvent(ctx context.Context, t *testing.T, store *SQLiteStore, householdID, petID, updatedBy string) Event {
	t.Helper()
	e, created, err := store.CreateEvent(ctx, householdID, sqliteDomainVaccInput(petID), updatedBy)
	if err != nil {
		t.Fatalf("CreateEvent: %v", err)
	}
	if !created {
		t.Fatalf("expected created=true for fresh event")
	}
	return e
}

func sqliteDomainMustCourse(ctx context.Context, t *testing.T, store *SQLiteStore, householdID, petID, updatedBy string) Event {
	t.Helper()
	e, created, err := store.CreateEvent(ctx, householdID, EventInput{
		ID: uuidV7(), PetID: petID, Kind: "med_course",
		OccurredAt: time.Now().UTC().Truncate(time.Second), Title: "antibiotics",
		Course: &MedCourse{
			DrugName: "amoxicillin", DoseAmount: "0.5", DoseUnit: "ml",
			Route: "oral", ScheduleKind: "daily", ScheduleTimes: "08:00",
			Status: "active",
		},
	}, updatedBy)
	if err != nil {
		t.Fatalf("CreateEvent course: %v", err)
	}
	if !created {
		t.Fatalf("expected created=true for fresh course")
	}
	return e
}

func sqliteDomainMustIntake(ctx context.Context, t *testing.T, store *SQLiteStore, householdID, courseID, createdBy string) MedIntake {
	t.Helper()
	m, created, err := store.CreateIntake(ctx, householdID, IntakeInput{
		ID: uuidV7(), CourseID: courseID, DoseSnapshot: "0.5ml", Note: "",
	}, createdBy)
	if err != nil {
		t.Fatalf("CreateIntake: %v", err)
	}
	if !created {
		t.Fatalf("expected created=true for fresh intake")
	}
	return m
}

func sqliteDomainMustDoc(ctx context.Context, t *testing.T, store *SQLiteStore, householdID string, petIDs []string, updatedBy string) Document {
	t.Helper()
	d, created, err := store.CreateDocument(ctx, householdID, DocumentInput{
		ID: uuidV7(), Title: "lab results", Mime: "application/pdf",
		SizeBytes: 123, Filename: "lab.pdf", PetIDs: petIDs,
	}, updatedBy)
	if err != nil {
		t.Fatalf("CreateDocument: %v", err)
	}
	if !created {
		t.Fatalf("expected created=true for fresh document")
	}
	return d
}

// restampUpdatedAt crafts distinct updated_at values via SQL for ordering
// tests (server stamps are second-precision, so same-second writes tie).
func sqliteDomainRestamp(ctx context.Context, t *testing.T, store *SQLiteStore, table, id string, at time.Time) {
	t.Helper()
	if _, err := store.DB().ExecContext(ctx,
		`UPDATE `+table+` SET updated_at = ? WHERE id = ?`, fmtTimeForTest(at), id); err != nil {
		t.Fatalf("restamp %s %s: %v", table, id, err)
	}
}

func TestSQLiteDomain_PetCRUDAndSince(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	uid, hid := sqliteDomainHousehold(ctx, t, store, "owner@example.com")

	p := sqliteDomainMustPet(ctx, t, store, hid, "Barsik", uid)

	got, err := store.GetPet(ctx, hid, p.ID)
	if err != nil {
		t.Fatalf("GetPet: %v", err)
	}
	if got.Name != "Barsik" || got.Species != "cat" || got.HouseholdID != hid || got.UpdatedBy != uid {
		t.Fatalf("unexpected pet: %+v", got)
	}

	if _, err := store.GetPet(ctx, "other-household", p.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound cross-household, got %v", err)
	}

	all, err := store.ListPetsChangedSince(ctx, hid, nil)
	if err != nil {
		t.Fatalf("ListPetsChangedSince nil: %v", err)
	}
	if len(all) != 1 || all[0].ID != p.ID {
		t.Fatalf("expected one pet, got %+v", all)
	}

	yesterday := time.Now().UTC().Add(-24 * time.Hour)
	if all, err := store.ListPetsChangedSince(ctx, hid, &yesterday); err != nil || len(all) != 1 {
		t.Fatalf("expected all since yesterday, got %+v, %v", all, err)
	}
	tomorrow := time.Now().UTC().Add(24 * time.Hour)
	if all, err := store.ListPetsChangedSince(ctx, hid, &tomorrow); err != nil || len(all) != 0 {
		t.Fatalf("expected none since tomorrow, got %+v, %v", all, err)
	}
	// Nothing is strictly newer than the row's own stamp.
	if all, err := store.ListPetsChangedSince(ctx, hid, &got.UpdatedAt); err != nil || len(all) != 0 {
		t.Fatalf("expected none since own stamp, got %+v, %v", all, err)
	}
	zero := time.Time{}
	if all, err := store.ListPetsChangedSince(ctx, hid, &zero); err != nil || len(all) != 1 {
		t.Fatalf("expected zero time = all, got %+v, %v", all, err)
	}
}

func TestSQLiteDomain_PetListOrdering(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	uid, hid := sqliteDomainHousehold(ctx, t, store, "owner@example.com")

	p1 := sqliteDomainMustPet(ctx, t, store, hid, "one", uid)
	p2 := sqliteDomainMustPet(ctx, t, store, hid, "two", uid)
	base := time.Now().UTC().Truncate(time.Second)
	sqliteDomainRestamp(ctx, t, store, "pets", p1.ID, base.Add(2*time.Second))
	sqliteDomainRestamp(ctx, t, store, "pets", p2.ID, base.Add(time.Second))

	all, err := store.ListPetsChangedSince(ctx, hid, nil)
	if err != nil {
		t.Fatalf("ListPetsChangedSince: %v", err)
	}
	if len(all) != 2 || all[0].ID != p2.ID || all[1].ID != p1.ID {
		t.Fatalf("expected [two one] order, got %+v", all)
	}
	cursor := base.Add(90 * time.Millisecond)
	got, err := store.ListPetsChangedSince(ctx, hid, &cursor)
	if err != nil {
		t.Fatalf("ListPetsChangedSince cursor: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("expected both after early cursor, got %+v", got)
	}
	mid := base.Add(1500 * time.Millisecond)
	got, err = store.ListPetsChangedSince(ctx, hid, &mid)
	if err != nil {
		t.Fatalf("ListPetsChangedSince mid: %v", err)
	}
	if len(got) != 1 || got[0].ID != p1.ID {
		t.Fatalf("expected only newest after mid cursor, got %+v", got)
	}
}

func TestSQLiteDomain_PetIdempotentReplay(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	uid, hid := sqliteDomainHousehold(ctx, t, store, "owner@example.com")

	id := uuidV7()
	first, created, err := store.CreatePet(ctx, hid, PetInput{ID: id, Name: "A", Species: "dog"}, uid)
	if err != nil || !created {
		t.Fatalf("first CreatePet: %+v, %v", first, err)
	}
	second, created, err := store.CreatePet(ctx, hid, PetInput{ID: id, Name: "CHANGED", Species: "bird"}, uid)
	if err != nil {
		t.Fatalf("replay CreatePet: %v", err)
	}
	if created {
		t.Fatalf("expected created=false on replay")
	}
	if second.ID != id || second.Name != "A" || second.Species != "dog" {
		t.Fatalf("replay must return stored row, got %+v", second)
	}
}

func TestSQLiteDomain_PetUpdateAndConflict(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	uid, hid := sqliteDomainHousehold(ctx, t, store, "owner@example.com")
	p := sqliteDomainMustPet(ctx, t, store, hid, "Old", uid)

	updated, err := store.UpdatePet(ctx, hid, p.ID, PetInput{
		ID: p.ID, Name: "New", Species: "cat", Notes: "n",
	}, p.UpdatedAt, uid)
	if err != nil {
		t.Fatalf("UpdatePet: %v", err)
	}
	if updated.Name != "New" || updated.Notes != "n" {
		t.Fatalf("unexpected updated pet: %+v", updated)
	}

	// Stale write with the original stamp conflicts, row untouched.
	if _, err := store.UpdatePet(ctx, hid, p.ID, PetInput{
		ID: p.ID, Name: "Stale", Species: "cat",
	}, p.UpdatedAt, uid); !errors.Is(err, ErrConflict) {
		t.Fatalf("expected ErrConflict, got %v", err)
	}
	got, err := store.GetPet(ctx, hid, p.ID)
	if err != nil {
		t.Fatalf("GetPet: %v", err)
	}
	if got.Name != "New" {
		t.Fatalf("stale write touched the row: %+v", got)
	}

	if _, err := store.UpdatePet(ctx, hid, uuidV7(), PetInput{ID: "x"}, time.Now().UTC(), uid); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound for missing pet, got %v", err)
	}
}

func TestSQLiteDomain_EventKindValidation(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	uid, hid := sqliteDomainHousehold(ctx, t, store, "owner@example.com")
	p := sqliteDomainMustPet(ctx, t, store, hid, "P", uid)

	cases := map[string]EventInput{
		"bad kind":            {ID: uuidV7(), PetID: p.ID, Kind: "nap", Title: "x", Vaccination: &VaccDetail{Vaccine: "v"}},
		"missing detail":      {ID: uuidV7(), PetID: p.ID, Kind: "vaccination", Title: "x"},
		"two details":         {ID: uuidV7(), PetID: p.ID, Kind: "vaccination", Title: "x", Vaccination: &VaccDetail{Vaccine: "v"}, Grooming: &GroomDetail{Service: "s"}},
		"wrong detail":        {ID: uuidV7(), PetID: p.ID, Kind: "grooming", Title: "x", Vaccination: &VaccDetail{Vaccine: "v"}},
		"empty vaccine":       {ID: uuidV7(), PetID: p.ID, Kind: "vaccination", Title: "x", Vaccination: &VaccDetail{}},
		"empty service":       {ID: uuidV7(), PetID: p.ID, Kind: "grooming", Title: "x", Grooming: &GroomDetail{}},
		"zero grams":          {ID: uuidV7(), PetID: p.ID, Kind: "weight", Title: "x", Weight: &WeightDetail{}},
		"course missing":      {ID: uuidV7(), PetID: p.ID, Kind: "med_course", Title: "x"},
		"course missing drug": {ID: uuidV7(), PetID: p.ID, Kind: "med_course", Title: "x", Course: &MedCourse{DoseAmount: "1", DoseUnit: "ml"}},
	}
	for name, in := range cases {
		if _, _, err := store.CreateEvent(ctx, hid, in, uid); err == nil {
			t.Fatalf("%s: expected validation error, got nil", name)
		}
	}
}

func TestSQLiteDomain_EventInvalidPet(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	uid, hid := sqliteDomainHousehold(ctx, t, store, "owner@example.com")
	p := sqliteDomainMustPet(ctx, t, store, hid, "P", uid)

	in := sqliteDomainVaccInput(uuidV7())
	if _, _, err := store.CreateEvent(ctx, hid, in, uid); !errors.Is(err, ErrInvalidPetID) {
		t.Fatalf("expected ErrInvalidPetID for unknown pet, got %v", err)
	}

	_, otherHid := sqliteDomainHousehold(ctx, t, store, "other@example.com")
	in = sqliteDomainVaccInput(p.ID) // p belongs to hid, not otherHid
	if _, _, err := store.CreateEvent(ctx, otherHid, in, uid); !errors.Is(err, ErrInvalidPetID) {
		t.Fatalf("expected ErrInvalidPetID cross-household, got %v", err)
	}
}

func TestSQLiteDomain_EventCRUDListUpdateDelete(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	uid, hid := sqliteDomainHousehold(ctx, t, store, "owner@example.com")
	p := sqliteDomainMustPet(ctx, t, store, hid, "P", uid)
	p2 := sqliteDomainMustPet(ctx, t, store, hid, "Q", uid)

	e := sqliteDomainMustVaccEvent(ctx, t, store, hid, p.ID, uid)

	got, err := store.GetEvent(ctx, hid, e.ID)
	if err != nil {
		t.Fatalf("GetEvent: %v", err)
	}
	if got.Kind != "vaccination" || got.Vaccination == nil || got.Vaccination.Vaccine != "rabies" {
		t.Fatalf("unexpected event detail: %+v", got)
	}

	// Weight + grooming + course round-trips.
	w, _, err := store.CreateEvent(ctx, hid, EventInput{
		ID: uuidV7(), PetID: p.ID, Kind: "weight",
		OccurredAt: time.Now().UTC().Truncate(time.Second), Title: "weigh-in",
		Weight: &WeightDetail{Grams: 4200},
	}, uid)
	if err != nil {
		t.Fatalf("CreateEvent weight: %v", err)
	}
	if w.Weight == nil || w.Weight.Grams != 4200 {
		t.Fatalf("unexpected weight detail: %+v", w)
	}
	course := sqliteDomainMustCourse(ctx, t, store, hid, p.ID, uid)
	if course.Course == nil || course.Course.DrugName != "amoxicillin" {
		t.Fatalf("unexpected course detail: %+v", course)
	}

	// Idempotent replay returns the stored row.
	replay, created, err := store.CreateEvent(ctx, hid, EventInput{
		ID: e.ID, PetID: p.ID, Kind: "grooming",
		OccurredAt: time.Now().UTC(), Title: "CHANGED",
		Grooming: &GroomDetail{Service: "s"},
	}, uid)
	if err != nil || created {
		t.Fatalf("replay: created=%v err=%v", created, err)
	}
	if replay.Kind != "vaccination" || replay.Title != "rabies" {
		t.Fatalf("replay must return stored row, got %+v", replay)
	}

	// List: pet filter + since filter.
	all, err := store.ListEventsChangedSince(ctx, hid, nil, "")
	if err != nil || len(all) != 3 {
		t.Fatalf("expected 3 events, got %+v, %v", all, err)
	}
	for _, ev := range all {
		switch ev.Kind {
		case "vaccination":
			if ev.Vaccination == nil {
				t.Fatalf("missing vacc detail in list: %+v", ev)
			}
		case "med_course":
			if ev.Course == nil {
				t.Fatalf("missing course detail in list: %+v", ev)
			}
		}
	}
	onlyQ, err := store.ListEventsChangedSince(ctx, hid, nil, p2.ID)
	if err != nil || len(onlyQ) != 0 {
		t.Fatalf("expected no events for pet Q, got %+v, %v", onlyQ, err)
	}
	onlyP, err := store.ListEventsChangedSince(ctx, hid, nil, p.ID)
	if err != nil || len(onlyP) != 3 {
		t.Fatalf("expected 3 events for pet P, got %+v, %v", onlyP, err)
	}
	tomorrow := time.Now().UTC().Add(24 * time.Hour)
	if got, err := store.ListEventsChangedSince(ctx, hid, &tomorrow, ""); err != nil || len(got) != 0 {
		t.Fatalf("expected none since tomorrow, got %+v, %v", got, err)
	}

	// Full-replace update swaps base + detail; stale stamp conflicts.
	updated, err := store.UpdateEvent(ctx, hid, e.ID, EventInput{
		ID: e.ID, PetID: p2.ID, Kind: "grooming",
		OccurredAt: e.OccurredAt, Title: "full groom",
		Grooming: &GroomDetail{Service: "bath", Place: "salon"},
	}, e.UpdatedAt, uid)
	if err != nil {
		t.Fatalf("UpdateEvent: %v", err)
	}
	if updated.Kind != "grooming" || updated.Grooming == nil || updated.Grooming.Service != "bath" || updated.PetID != p2.ID {
		t.Fatalf("unexpected updated event: %+v", updated)
	}
	if updated.Vaccination != nil || updated.Weight != nil || updated.Course != nil {
		t.Fatalf("old details must be gone: %+v", updated)
	}
	if _, err := store.UpdateEvent(ctx, hid, e.ID, EventInput{
		ID: e.ID, PetID: p2.ID, Kind: "grooming", OccurredAt: e.OccurredAt, Title: "stale",
		Grooming: &GroomDetail{Service: "x"},
	}, e.UpdatedAt, uid); !errors.Is(err, ErrConflict) {
		t.Fatalf("expected ErrConflict on stale update, got %v", err)
	}
	// Update to an outside-household pet is rejected.
	_, otherHid := sqliteDomainHousehold(ctx, t, store, "stranger@example.com")
	otherPet := sqliteDomainMustPet(ctx, t, store, otherHid, "Z", uid)
	latest, err := store.GetEvent(ctx, hid, e.ID)
	if err != nil {
		t.Fatalf("GetEvent: %v", err)
	}
	if _, err := store.UpdateEvent(ctx, hid, e.ID, EventInput{
		ID: e.ID, PetID: otherPet.ID, Kind: "grooming", OccurredAt: latest.OccurredAt, Title: "x",
		Grooming: &GroomDetail{Service: "x"},
	}, latest.UpdatedAt, uid); !errors.Is(err, ErrInvalidPetID) {
		t.Fatalf("expected ErrInvalidPetID for outside pet, got %v", err)
	}

	// Delete tombstones 'event'.
	if err := store.DeleteEvent(ctx, hid, e.ID); err != nil {
		t.Fatalf("DeleteEvent: %v", err)
	}
	if _, err := store.GetEvent(ctx, hid, e.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound after delete, got %v", err)
	}
	if err := store.DeleteEvent(ctx, hid, e.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound on repeat delete, got %v", err)
	}
	dels, err := store.ListHouseholdDeletions(ctx, hid, nil)
	if err != nil {
		t.Fatalf("ListHouseholdDeletions: %v", err)
	}
	found := false
	for _, d := range dels {
		if d.Resource == "event" && d.ID == e.ID {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected event tombstone, got %+v", dels)
	}
}

func TestSQLiteDomain_EventCrossHouseholdInvisible(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	uid, hid := sqliteDomainHousehold(ctx, t, store, "owner@example.com")
	p := sqliteDomainMustPet(ctx, t, store, hid, "P", uid)
	e := sqliteDomainMustVaccEvent(ctx, t, store, hid, p.ID, uid)

	_, otherHid := sqliteDomainHousehold(ctx, t, store, "other@example.com")
	if _, err := store.GetEvent(ctx, otherHid, e.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound cross-household, got %v", err)
	}
	if all, err := store.ListEventsChangedSince(ctx, otherHid, nil, ""); err != nil || len(all) != 0 {
		t.Fatalf("expected no events in other household, got %+v, %v", all, err)
	}
}

func TestSQLiteDomain_IntakeLifecycle(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	uid, hid := sqliteDomainHousehold(ctx, t, store, "owner@example.com")
	p := sqliteDomainMustPet(ctx, t, store, hid, "P", uid)
	course := sqliteDomainMustCourse(ctx, t, store, hid, p.ID, uid)

	// Unknown course (same "unknown reference" shape as pets).
	if _, _, err := store.CreateIntake(ctx, hid, IntakeInput{ID: uuidV7(), CourseID: uuidV7()}, uid); !errors.Is(err, ErrInvalidPetID) {
		t.Fatalf("expected ErrInvalidPetID for unknown course, got %v", err)
	}
	// Course from another household is invisible.
	_, otherHid := sqliteDomainHousehold(ctx, t, store, "other@example.com")
	if _, _, err := store.CreateIntake(ctx, otherHid, IntakeInput{ID: uuidV7(), CourseID: course.ID}, uid); !errors.Is(err, ErrInvalidPetID) {
		t.Fatalf("expected ErrInvalidPetID cross-household course, got %v", err)
	}

	m := sqliteDomainMustIntake(ctx, t, store, hid, course.ID, uid)
	if m.Status != "pending" || m.MarkedBy != "" || m.TakenAt != nil {
		t.Fatalf("fresh intake must be pending/unmarked, got %+v", m)
	}

	// Idempotent replay.
	replay, created, err := store.CreateIntake(ctx, hid, IntakeInput{ID: m.ID, CourseID: course.ID, Note: "CHANGED"}, uid)
	if err != nil || created {
		t.Fatalf("replay: created=%v err=%v", created, err)
	}
	if replay.ID != m.ID || replay.Note != "" {
		t.Fatalf("replay must return stored row, got %+v", replay)
	}

	got, err := store.GetIntake(ctx, hid, m.ID)
	if err != nil {
		t.Fatalf("GetIntake: %v", err)
	}
	if got.CourseID != course.ID {
		t.Fatalf("unexpected intake: %+v", got)
	}
	if _, err := store.GetIntake(ctx, otherHid, m.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound cross-household, got %v", err)
	}

	// Taken mark without TakenAt stamps now + marks actor.
	taken, err := store.UpdateIntake(ctx, hid, m.ID, IntakeUpdate{Status: "taken", Note: "gave it", DoseSnapshot: "0.5ml"}, m.UpdatedAt, uid)
	if err != nil {
		t.Fatalf("UpdateIntake taken: %v", err)
	}
	if taken.Status != "taken" || taken.TakenAt == nil || taken.MarkedBy != uid {
		t.Fatalf("unexpected taken intake: %+v", taken)
	}
	if time.Since(taken.TakenAt.UTC()) > time.Minute {
		t.Fatalf("taken_at should be ~now, got %v", taken.TakenAt)
	}

	// Note-only edit (same status) preserves marked_by.
	edited, err := store.UpdateIntake(ctx, hid, m.ID, IntakeUpdate{Status: "taken", TakenAt: taken.TakenAt, Note: "late note", DoseSnapshot: "0.5ml"}, taken.UpdatedAt, "someone-else")
	if err != nil {
		t.Fatalf("UpdateIntake note: %v", err)
	}
	if edited.MarkedBy != uid || edited.Note != "late note" {
		t.Fatalf("note-only edit must preserve marked_by, got %+v", edited)
	}

	// Status change re-stamps marked_by.
	skipped, err := store.UpdateIntake(ctx, hid, m.ID, IntakeUpdate{Status: "skipped", TakenAt: taken.TakenAt, DoseSnapshot: "0.5ml"}, edited.UpdatedAt, "other-actor")
	if err != nil {
		t.Fatalf("UpdateIntake skipped: %v", err)
	}
	if skipped.MarkedBy != "other-actor" {
		t.Fatalf("status change must re-stamp marked_by, got %+v", skipped)
	}

	// Stale stamp conflicts.
	if _, err := store.UpdateIntake(ctx, hid, m.ID, IntakeUpdate{Status: "taken"}, m.UpdatedAt, uid); !errors.Is(err, ErrConflict) {
		t.Fatalf("expected ErrConflict, got %v", err)
	}

	// List filters.
	m2 := sqliteDomainMustIntake(ctx, t, store, hid, course.ID, uid)
	byCourse, err := store.ListIntakesChangedSince(ctx, hid, course.ID, nil)
	if err != nil || len(byCourse) != 2 {
		t.Fatalf("expected 2 intakes for course, got %+v, %v", byCourse, err)
	}
	byOther, err := store.ListIntakesChangedSince(ctx, hid, uuidV7(), nil)
	if err != nil || len(byOther) != 0 {
		t.Fatalf("expected none for unknown course filter, got %+v, %v", byOther, err)
	}
	tomorrow := time.Now().UTC().Add(24 * time.Hour)
	if got, err := store.ListIntakesChangedSince(ctx, hid, "", &tomorrow); err != nil || len(got) != 0 {
		t.Fatalf("expected none since tomorrow, got %+v, %v", got, err)
	}

	// Delete tombstones 'intake'.
	if err := store.DeleteIntake(ctx, hid, m2.ID); err != nil {
		t.Fatalf("DeleteIntake: %v", err)
	}
	if _, err := store.GetIntake(ctx, hid, m2.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound after delete, got %v", err)
	}
	dels, err := store.ListHouseholdDeletions(ctx, hid, nil)
	if err != nil {
		t.Fatalf("ListHouseholdDeletions: %v", err)
	}
	found := false
	for _, d := range dels {
		if d.Resource == "intake" && d.ID == m2.ID {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected intake tombstone, got %+v", dels)
	}
}

func TestSQLiteDomain_DocumentLifecycle(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	uid, hid := sqliteDomainHousehold(ctx, t, store, "owner@example.com")
	p := sqliteDomainMustPet(ctx, t, store, hid, "P", uid)
	p2 := sqliteDomainMustPet(ctx, t, store, hid, "Q", uid)

	// Unknown pet link is rejected.
	if _, _, err := store.CreateDocument(ctx, hid, DocumentInput{
		ID: uuidV7(), Title: "x", Mime: "application/pdf", PetIDs: []string{uuidV7()},
	}, uid); !errors.Is(err, ErrInvalidPetID) {
		t.Fatalf("expected ErrInvalidPetID for unknown pet link, got %v", err)
	}

	d := sqliteDomainMustDoc(ctx, t, store, hid, []string{p.ID}, uid)
	if d.BlobKey == "" || d.Ready {
		t.Fatalf("fresh doc must have blob key and ready=false, got %+v", d)
	}

	// Unready rows are invisible to sync pulls.
	if got, err := store.ListDocumentsChangedSince(ctx, hid, nil); err != nil || len(got) != 0 {
		t.Fatalf("expected no docs before confirm, got %+v, %v", got, err)
	}
	// ... but direct Get works.
	got, err := store.GetDocument(ctx, hid, d.ID)
	if err != nil {
		t.Fatalf("GetDocument: %v", err)
	}
	if len(got.PetIDs) != 1 || got.PetIDs[0] != p.ID {
		t.Fatalf("unexpected links: %+v", got)
	}
	_, otherHid := sqliteDomainHousehold(ctx, t, store, "other@example.com")
	if _, err := store.GetDocument(ctx, otherHid, d.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound cross-household, got %v", err)
	}

	// Replay returns stored row.
	replay, created, err := store.CreateDocument(ctx, hid, DocumentInput{
		ID: d.ID, Title: "CHANGED", Mime: "x/y", PetIDs: nil,
	}, uid)
	if err != nil || created {
		t.Fatalf("replay: created=%v err=%v", created, err)
	}
	if replay.Title != "lab results" || len(replay.PetIDs) != 1 {
		t.Fatalf("replay must return stored row, got %+v", replay)
	}

	confirmed, err := store.ConfirmDocument(ctx, hid, d.ID)
	if err != nil {
		t.Fatalf("ConfirmDocument: %v", err)
	}
	if !confirmed.Ready {
		t.Fatalf("expected ready=true, got %+v", confirmed)
	}
	if _, err := store.ConfirmDocument(ctx, hid, uuidV7()); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound confirming missing doc, got %v", err)
	}
	visible, err := store.ListDocumentsChangedSince(ctx, hid, nil)
	if err != nil || len(visible) != 1 || visible[0].ID != d.ID {
		t.Fatalf("expected doc after confirm, got %+v, %v", visible, err)
	}
	if len(visible[0].PetIDs) != 1 || visible[0].PetIDs[0] != p.ID {
		t.Fatalf("unexpected links in list: %+v", visible[0])
	}

	// Title + link-set replace; stale stamp conflicts.
	updated, err := store.UpdateDocument(ctx, hid, d.ID, "renamed", []string{p.ID, p2.ID}, confirmed.UpdatedAt, uid)
	if err != nil {
		t.Fatalf("UpdateDocument: %v", err)
	}
	if updated.Title != "renamed" || len(updated.PetIDs) != 2 {
		t.Fatalf("unexpected updated doc: %+v", updated)
	}
	if _, err := store.UpdateDocument(ctx, hid, d.ID, "stale", nil, confirmed.UpdatedAt, uid); !errors.Is(err, ErrConflict) {
		t.Fatalf("expected ErrConflict, got %v", err)
	}
	if _, err := store.UpdateDocument(ctx, hid, d.ID, "x", []string{uuidV7()}, updated.UpdatedAt, uid); !errors.Is(err, ErrInvalidPetID) {
		t.Fatalf("expected ErrInvalidPetID for bad link, got %v", err)
	}

	tomorrow := time.Now().UTC().Add(24 * time.Hour)
	if got, err := store.ListDocumentsChangedSince(ctx, hid, &tomorrow); err != nil || len(got) != 0 {
		t.Fatalf("expected none since tomorrow, got %+v, %v", got, err)
	}
}

func TestSQLiteDomain_DeleteDocumentReturnsBlobKey(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	uid, hid := sqliteDomainHousehold(ctx, t, store, "owner@example.com")
	p := sqliteDomainMustPet(ctx, t, store, hid, "P", uid)
	d := sqliteDomainMustDoc(ctx, t, store, hid, []string{p.ID}, uid)
	if _, err := store.ConfirmDocument(ctx, hid, d.ID); err != nil {
		t.Fatalf("ConfirmDocument: %v", err)
	}

	deleted, err := store.DeleteDocument(ctx, hid, d.ID)
	if err != nil {
		t.Fatalf("DeleteDocument: %v", err)
	}
	if deleted.BlobKey == "" || deleted.BlobKey != d.BlobKey {
		t.Fatalf("deleted doc must carry blob key %q, got %+v", d.BlobKey, deleted)
	}
	if _, err := store.GetDocument(ctx, hid, d.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound after delete, got %v", err)
	}
	if _, err := store.DeleteDocument(ctx, hid, d.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound on repeat delete, got %v", err)
	}
	dels, err := store.ListHouseholdDeletions(ctx, hid, nil)
	if err != nil {
		t.Fatalf("ListHouseholdDeletions: %v", err)
	}
	found := false
	for _, del := range dels {
		if del.Resource == "document" && del.ID == d.ID {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected document tombstone, got %+v", dels)
	}
}

func TestSQLiteDomain_DeleteDocumentsByIDsSkipsTombstones(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	uid, hid := sqliteDomainHousehold(ctx, t, store, "owner@example.com")
	d1 := sqliteDomainMustDoc(ctx, t, store, hid, nil, uid)
	d2 := sqliteDomainMustDoc(ctx, t, store, hid, nil, uid)

	if err := store.DeleteDocumentsByIDs(ctx, nil); err != nil {
		t.Fatalf("empty GC: %v", err)
	}
	if err := store.DeleteDocumentsByIDs(ctx, []string{d1.ID, d2.ID}); err != nil {
		t.Fatalf("DeleteDocumentsByIDs: %v", err)
	}
	if _, err := store.GetDocument(ctx, hid, d1.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected d1 gone, got %v", err)
	}
	if _, err := store.GetDocument(ctx, hid, d2.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected d2 gone, got %v", err)
	}
	dels, err := store.ListHouseholdDeletions(ctx, hid, nil)
	if err != nil {
		t.Fatalf("ListHouseholdDeletions: %v", err)
	}
	if len(dels) != 0 {
		t.Fatalf("GC path must not tombstone, got %+v", dels)
	}
}

func TestSQLiteDomain_DeletePetCascade(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	uid, hid := sqliteDomainHousehold(ctx, t, store, "owner@example.com")
	p := sqliteDomainMustPet(ctx, t, store, hid, "P", uid)
	other := sqliteDomainMustPet(ctx, t, store, hid, "Other", uid)

	vacc := sqliteDomainMustVaccEvent(ctx, t, store, hid, p.ID, uid)
	course := sqliteDomainMustCourse(ctx, t, store, hid, p.ID, uid)
	i1 := sqliteDomainMustIntake(ctx, t, store, hid, course.ID, uid)
	i2 := sqliteDomainMustIntake(ctx, t, store, hid, course.ID, uid)
	otherEvent := sqliteDomainMustVaccEvent(ctx, t, store, hid, other.ID, uid)

	linked := sqliteDomainMustDoc(ctx, t, store, hid, []string{p.ID, other.ID}, uid)
	unlinked := sqliteDomainMustDoc(ctx, t, store, hid, []string{other.ID}, uid)

	if err := store.DeletePet(ctx, hid, p.ID, uid); err != nil {
		t.Fatalf("DeletePet: %v", err)
	}
	if _, err := store.GetPet(ctx, hid, p.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected pet gone, got %v", err)
	}
	for _, eid := range []string{vacc.ID, course.ID} {
		if _, err := store.GetEvent(ctx, hid, eid); !errors.Is(err, ErrNotFound) {
			t.Fatalf("expected event %s gone, got %v", eid, err)
		}
	}
	for _, iid := range []string{i1.ID, i2.ID} {
		if _, err := store.GetIntake(ctx, hid, iid); !errors.Is(err, ErrNotFound) {
			t.Fatalf("expected intake %s gone, got %v", iid, err)
		}
	}
	// Unrelated pet + event survive.
	if _, err := store.GetPet(ctx, hid, other.ID); err != nil {
		t.Fatalf("other pet must survive: %v", err)
	}
	if _, err := store.GetEvent(ctx, hid, otherEvent.ID); err != nil {
		t.Fatalf("other event must survive: %v", err)
	}

	// Tombstones: pet + both events + both intakes.
	dels, err := store.ListHouseholdDeletions(ctx, hid, nil)
	if err != nil {
		t.Fatalf("ListHouseholdDeletions: %v", err)
	}
	want := map[string]string{
		"pet:" + p.ID:        "pet",
		"event:" + vacc.ID:   "event",
		"event:" + course.ID: "event",
		"intake:" + i1.ID:    "intake",
		"intake:" + i2.ID:    "intake",
	}
	for _, d := range dels {
		delete(want, d.Resource+":"+d.ID)
	}
	if len(want) != 0 {
		t.Fatalf("missing tombstones %v (have %+v)", want, dels)
	}

	// Linked doc survives with the pet pruned; unlinked doc untouched.
	gotLinked, err := store.GetDocument(ctx, hid, linked.ID)
	if err != nil {
		t.Fatalf("linked doc must survive: %v", err)
	}
	if len(gotLinked.PetIDs) != 1 || gotLinked.PetIDs[0] != other.ID {
		t.Fatalf("expected only other pet linked, got %+v", gotLinked)
	}
	gotUnlinked, err := store.GetDocument(ctx, hid, unlinked.ID)
	if err != nil {
		t.Fatalf("unlinked doc must survive: %v", err)
	}
	if len(gotUnlinked.PetIDs) != 1 || gotUnlinked.PetIDs[0] != other.ID {
		t.Fatalf("unlinked doc must be untouched, got %+v", gotUnlinked)
	}
	// Doc tombstones are never written for link pruning.
	for _, d := range dels {
		if d.Resource == "document" {
			t.Fatalf("unexpected document tombstone from link prune: %+v", dels)
		}
	}

	if err := store.DeletePet(ctx, hid, p.ID, uid); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound on repeat delete, got %v", err)
	}
}

func TestSQLiteDomain_HouseholdDeletions(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	_, hid := sqliteDomainHousehold(ctx, t, store, "owner@example.com")
	_, otherHid := sqliteDomainHousehold(ctx, t, store, "other@example.com")

	base := time.Now().UTC().Truncate(time.Second)
	for i, id := range []string{"rec-a", "rec-b", "rec-c"} {
		if err := store.RecordTombstone(ctx, hid, "pet", id, base.Add(time.Duration(i)*time.Second)); err != nil {
			t.Fatalf("RecordTombstone: %v", err)
		}
	}
	if err := store.RecordTombstone(ctx, otherHid, "pet", "rec-x", base); err != nil {
		t.Fatalf("RecordTombstone other: %v", err)
	}

	all, err := store.ListHouseholdDeletions(ctx, hid, nil)
	if err != nil {
		t.Fatalf("ListHouseholdDeletions: %v", err)
	}
	if len(all) != 3 || all[0].ID != "rec-a" || all[1].ID != "rec-b" || all[2].ID != "rec-c" {
		t.Fatalf("expected ordered tombstones, got %+v", all)
	}
	if all[0].Resource != "pet" {
		t.Fatalf("unexpected resource: %+v", all[0])
	}
	cursor := base.Add(time.Second)
	got, err := store.ListHouseholdDeletions(ctx, hid, &cursor)
	if err != nil || len(got) != 1 || got[0].ID != "rec-c" {
		t.Fatalf("expected only rec-c after cursor, got %+v, %v", got, err)
	}
	zero := time.Time{}
	if got, err := store.ListHouseholdDeletions(ctx, hid, &zero); err != nil || len(got) != 3 {
		t.Fatalf("zero time = all, got %+v, %v", got, err)
	}
	other, err := store.ListHouseholdDeletions(ctx, otherHid, nil)
	if err != nil || len(other) != 1 || other[0].ID != "rec-x" {
		t.Fatalf("households must not leak tombstones, got %+v, %v", other, err)
	}
}

func TestSQLiteDomain_PurgeEmptiesHousehold(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	uid, hid := sqliteDomainHousehold(ctx, t, store, "owner@example.com")
	p := sqliteDomainMustPet(ctx, t, store, hid, "P", uid)
	_ = sqliteDomainMustVaccEvent(ctx, t, store, hid, p.ID, uid)
	d := sqliteDomainMustDoc(ctx, t, store, hid, []string{p.ID}, uid)

	res, err := store.PurgeUser(ctx, uid, "com.test.app", func(_ string) string { return "digest" })
	if err != nil {
		t.Fatalf("PurgeUser: %v", err)
	}
	if len(res.OrphanedBlobKeys) != 1 || res.OrphanedBlobKeys[0] != d.BlobKey {
		t.Fatalf("expected orphaned blob key %q, got %+v", d.BlobKey, res)
	}
	var n int
	if err := store.DB().QueryRowContext(ctx, `SELECT COUNT(*) FROM households WHERE id = ?`, hid).Scan(&n); err != nil {
		t.Fatalf("household count: %v", err)
	}
	if n != 0 {
		t.Fatalf("expected emptied household row gone")
	}
	if err := store.DB().QueryRowContext(ctx, `SELECT COUNT(*) FROM pets WHERE household_id = ?`, hid).Scan(&n); err != nil {
		t.Fatalf("pet count: %v", err)
	}
	if n != 0 {
		t.Fatalf("expected pets cascaded away, found %d", n)
	}
	if err := store.DB().QueryRowContext(ctx, `SELECT COUNT(*) FROM tombstones WHERE household_id = ?`, hid).Scan(&n); err != nil {
		t.Fatalf("tombstone count: %v", err)
	}
	if n != 0 {
		t.Fatalf("expected tombstones cascaded away, found %d", n)
	}
}

func TestSQLiteDomain_PurgeKeepsSharedHousehold(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	owner, hid := sqliteDomainHousehold(ctx, t, store, "owner@example.com")
	guest := mustUser(t, store, "guest@example.com")
	inv, err := store.CreateInvite(ctx, hid, "guest@example.com", "hash-1", owner, time.Now().Add(time.Hour))
	if err != nil {
		t.Fatalf("CreateInvite: %v", err)
	}
	if _, err := store.AcceptInvite(ctx, inv.ID, guest); err != nil {
		t.Fatalf("AcceptInvite: %v", err)
	}

	p := sqliteDomainMustPet(ctx, t, store, hid, "P", owner)
	d := sqliteDomainMustDoc(ctx, t, store, hid, []string{p.ID}, owner)

	res, err := store.PurgeUser(ctx, owner, "com.test.app", func(_ string) string { return "digest" })
	if err != nil {
		t.Fatalf("PurgeUser: %v", err)
	}
	if len(res.OrphanedBlobKeys) != 0 {
		t.Fatalf("shared household must not orphan blobs, got %+v", res.OrphanedBlobKeys)
	}
	house, err := store.GetHouseholdForUser(ctx, guest)
	if err != nil || house.ID != hid {
		t.Fatalf("household must survive for remaining member: %+v, %v", house, err)
	}
	if _, err := store.GetPet(ctx, hid, p.ID); err != nil {
		t.Fatalf("pet must survive: %v", err)
	}
	if _, err := store.GetDocument(ctx, hid, d.ID); err != nil {
		t.Fatalf("document must survive: %v", err)
	}
	members, err := store.ListHouseholdMembers(ctx, hid)
	if err != nil || len(members) != 1 || members[0].UserID != guest {
		t.Fatalf("expected only guest member, got %+v, %v", members, err)
	}
}

// fmtTimeForTest formats a cursor time the same way the store does.
func fmtTimeForTest(t time.Time) string { return fmtTime(t) }
