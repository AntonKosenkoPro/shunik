package db

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/antonkosenko/shunik/backend/internal/migrations"
)

// newDomainStore opens a live Postgres store for the §4 domain tests,
// gated on TEST_PG_DSN like the parity suite (skips offline; CI covers pg).
func newDomainStore(t *testing.T) *PostgresStore {
	t.Helper()
	dsn := os.Getenv("TEST_PG_DSN")
	if dsn == "" {
		t.Skip("TEST_PG_DSN not set — skipping PostgreSQL domain tests (make test:pg)")
	}

	ctx := context.Background()
	store, err := NewPostgresStore(ctx, dsn)
	if err != nil {
		t.Fatalf("NewPostgresStore: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })

	if err := migrations.RunPostgres(ctx, store.DB()); err != nil {
		t.Fatalf("RunPostgres: %v", err)
	}

	if _, err := store.DB().Exec(ctx, `
		TRUNCATE refresh_recovery_receipts, refresh_tokens, otp_codes, users,
		         households, tombstones, apple_vault, apple_revocation_jobs,
		         apple_notifications_seen RESTART IDENTITY CASCADE
	`); err != nil {
		t.Fatalf("truncate: %v", err)
	}
	return store
}

// TestPgDomain_HouseholdPetEventIntake exercises the §4 round trip against
// live Postgres: household → pet → med_course event → intake, with an
// idempotent replay and one LWW conflict.
func TestPgDomain_HouseholdPetEventIntake(t *testing.T) {
	store := newDomainStore(t)
	ctx := context.Background()

	u, err := store.UpsertUser(ctx, "pg-domain@example.com")
	if err != nil {
		t.Fatalf("UpsertUser: %v", err)
	}
	// NOTE: EnsureHousehold's member INSERT reuses one $n for a UUID and a
	// TEXT column, which Postgres rejects (42P08) on every version —
	// latent bug in postgres_households.go (not this change's file), left
	// for its owner. Seed the household directly with casted params.
	hhID := uuidV7()
	if _, err := store.DB().Exec(ctx, `
		INSERT INTO households (id, created_at, updated_at, updated_by)
		VALUES ($1::uuid, NOW(), NOW(), $2)
	`, hhID, u.ID); err != nil {
		t.Fatalf("seed household: %v", err)
	}
	if _, err := store.DB().Exec(ctx, `
		INSERT INTO household_members (household_id, user_id, added_by, joined_at)
		VALUES ($1::uuid, $2::uuid, $2, NOW())
	`, hhID, u.ID); err != nil {
		t.Fatalf("seed membership: %v", err)
	}
	hh, err := store.GetHouseholdForUser(ctx, u.ID)
	if err != nil {
		t.Fatalf("GetHouseholdForUser: %v", err)
	}

	pet, created, err := store.CreatePet(ctx, hh.ID, PetInput{
		ID: "11111111-1111-7111-8111-111111111111", Name: "Barsik", Species: "cat",
	}, u.ID)
	if err != nil || !created {
		t.Fatalf("CreatePet: pet=%+v created=%v err=%v", pet, created, err)
	}
	replay, created, err := store.CreatePet(ctx, hh.ID, PetInput{
		ID: pet.ID, Name: "Other", Species: "dog",
	}, u.ID)
	if err != nil || created {
		t.Fatalf("CreatePet replay: created=%v err=%v", created, err)
	}
	if replay.Name != "Barsik" {
		t.Errorf("replay must return the stored row, got %+v", replay)
	}

	in := EventInput{
		ID: "22222222-2222-7222-8222-222222222222", PetID: pet.ID, Kind: "med_course",
		OccurredAt: time.Now().UTC().Truncate(time.Microsecond), Title: "Antibiotics",
		Course: &MedCourse{
			DrugName: "Amoxicillin", DoseAmount: "0.5", DoseUnit: "ml", Route: "oral",
			ScheduleKind: "daily", ScheduleTimes: "08:00,20:00", Status: "active",
		},
	}
	ev, created, err := store.CreateEvent(ctx, hh.ID, in, u.ID)
	if err != nil || !created {
		t.Fatalf("CreateEvent: created=%v err=%v", created, err)
	}
	if ev.Course == nil || ev.Course.DrugName != "Amoxicillin" {
		t.Fatalf("event detail not joined: %+v", ev)
	}
	got, err := store.GetEvent(ctx, hh.ID, ev.ID)
	if err != nil || got.Course == nil || got.Course.DoseAmount != "0.5" {
		t.Fatalf("GetEvent: %+v err=%v", got, err)
	}

	listed, err := store.ListEventsChangedSince(ctx, hh.ID, nil, pet.ID)
	if err != nil || len(listed) != 1 {
		t.Fatalf("ListEventsChangedSince: n=%d err=%v", len(listed), err)
	}

	intake, created, err := store.CreateIntake(ctx, hh.ID, IntakeInput{
		ID: "33333333-3333-7333-8333-333333333333", CourseID: ev.ID, DoseSnapshot: "0.5 ml",
	}, u.ID)
	if err != nil || !created {
		t.Fatalf("CreateIntake: created=%v err=%v", created, err)
	}
	marked, err := store.UpdateIntake(ctx, hh.ID, intake.ID, IntakeUpdate{
		Status: "taken", Note: "ate well", DoseSnapshot: "0.5 ml",
	}, intake.UpdatedAt, u.ID)
	if err != nil {
		t.Fatalf("UpdateIntake taken: %v", err)
	}
	if marked.TakenAt == nil {
		t.Error("taken mark without TakenAt must stamp now")
	}
	if marked.MarkedBy != u.ID {
		t.Errorf("status transition must stamp MarkedBy, got %q", marked.MarkedBy)
	}

	// One conflict case: a stale baseUpdatedAt leaves the row untouched.
	stale := intake.UpdatedAt
	if _, err := store.UpdatePet(ctx, hh.ID, pet.ID, PetInput{
		ID: pet.ID, Name: "Stale", Species: "cat",
	}, stale.Add(-time.Hour), u.ID); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale UpdatePet: expected ErrConflict, got %v", err)
	}
	unchanged, err := store.GetPet(ctx, hh.ID, pet.ID)
	if err != nil || unchanged.Name != "Barsik" {
		t.Fatalf("conflict loser must leave the row untouched: %+v err=%v", unchanged, err)
	}

	// Delete the intake: tombstone visible on the household deletions feed.
	if err := store.DeleteIntake(ctx, hh.ID, intake.ID); err != nil {
		t.Fatalf("DeleteIntake: %v", err)
	}
	if _, err := store.GetIntake(ctx, hh.ID, intake.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("GetIntake after delete: expected ErrNotFound, got %v", err)
	}
	dels, err := store.ListHouseholdDeletions(ctx, hh.ID, nil)
	if err != nil {
		t.Fatalf("ListHouseholdDeletions: %v", err)
	}
	found := false
	for _, d := range dels {
		if d.Resource == "intake" && d.ID == intake.ID {
			found = true
		}
	}
	if !found {
		t.Errorf("intake tombstone missing from deletions feed: %+v", dels)
	}
}
