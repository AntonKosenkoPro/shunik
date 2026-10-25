package db

import (
	"context"
	"testing"
	"time"
)

func mustUser(t *testing.T, store *SQLiteStore, email string) string {
	t.Helper()
	user, err := store.UpsertUser(context.Background(), email)
	if err != nil {
		t.Fatalf("UpsertUser: %v", err)
	}
	return user.ID
}

func TestEnsureHousehold_CreatesAndIsIdempotent(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	uid := mustUser(t, store, "owner@example.com")

	first, err := store.EnsureHousehold(ctx, uid)
	if err != nil {
		t.Fatalf("EnsureHousehold: %v", err)
	}
	if first.ID == "" || first.UpdatedBy != uid {
		t.Fatalf("unexpected household: %+v", first)
	}

	second, err := store.EnsureHousehold(ctx, uid)
	if err != nil {
		t.Fatalf("EnsureHousehold again: %v", err)
	}
	if second.ID != first.ID {
		t.Fatalf("expected same household %s, got %s", first.ID, second.ID)
	}

	members, err := store.ListHouseholdMembers(ctx, first.ID)
	if err != nil {
		t.Fatalf("ListHouseholdMembers: %v", err)
	}
	if len(members) != 1 || members[0].UserID != uid || members[0].Email != "owner@example.com" {
		t.Fatalf("expected one owner member, got %+v", members)
	}
}

func TestGetHouseholdForUser_MissingIsNotFound(t *testing.T) {
	store := setupTestStore(t)
	uid := mustUser(t, store, "lonely@example.com")
	if _, err := store.GetHouseholdForUser(context.Background(), uid); err != ErrNotFound {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
}

func TestInviteFlow_AcceptJoinsHousehold(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	owner := mustUser(t, store, "owner@example.com")
	guest := mustUser(t, store, "guest@example.com")

	house, err := store.EnsureHousehold(ctx, owner)
	if err != nil {
		t.Fatalf("EnsureHousehold: %v", err)
	}

	inv, err := store.CreateInvite(ctx, house.ID, "guest@example.com", "hash-1", owner, time.Now().Add(time.Hour))
	if err != nil {
		t.Fatalf("CreateInvite: %v", err)
	}

	got, err := store.GetInviteByTokenHash(ctx, "hash-1")
	if err != nil {
		t.Fatalf("GetInviteByTokenHash: %v", err)
	}
	if got.ID != inv.ID {
		t.Fatalf("expected invite %s, got %s", inv.ID, got.ID)
	}

	joined, err := store.AcceptInvite(ctx, inv.ID, guest)
	if err != nil {
		t.Fatalf("AcceptInvite: %v", err)
	}
	if joined.ID != house.ID {
		t.Fatalf("expected household %s, got %s", house.ID, joined.ID)
	}

	members, err := store.ListHouseholdMembers(ctx, house.ID)
	if err != nil {
		t.Fatalf("ListHouseholdMembers: %v", err)
	}
	if len(members) != 2 {
		t.Fatalf("expected 2 members, got %+v", members)
	}
}

func TestAcceptInvite_RejectsConsumedExpiredAndDoubleJoin(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	owner := mustUser(t, store, "owner@example.com")
	guest := mustUser(t, store, "guest@example.com")
	other := mustUser(t, store, "other@example.com")

	house, err := store.EnsureHousehold(ctx, owner)
	if err != nil {
		t.Fatalf("EnsureHousehold: %v", err)
	}
	if _, err := store.EnsureHousehold(ctx, other); err != nil {
		t.Fatalf("EnsureHousehold other: %v", err)
	}

	// Consumed invite behaves as missing.
	inv, err := store.CreateInvite(ctx, house.ID, "guest@example.com", "hash-used", owner, time.Now().Add(time.Hour))
	if err != nil {
		t.Fatalf("CreateInvite: %v", err)
	}
	if _, err := store.AcceptInvite(ctx, inv.ID, guest); err != nil {
		t.Fatalf("AcceptInvite: %v", err)
	}
	if _, err := store.AcceptInvite(ctx, inv.ID, guest); err != ErrNotFound {
		t.Fatalf("expected ErrNotFound for consumed invite, got %v", err)
	}

	// Expired invite behaves as missing.
	expired, err := store.CreateInvite(ctx, house.ID, "other@example.com", "hash-old", owner, time.Now().Add(-time.Hour))
	if err != nil {
		t.Fatalf("CreateInvite expired: %v", err)
	}
	if _, err := store.AcceptInvite(ctx, expired.ID, guest); err != ErrNotFound {
		t.Fatalf("expected ErrNotFound for expired invite, got %v", err)
	}

	// A user already in a household is rejected, not moved.
	fresh, err := store.CreateInvite(ctx, house.ID, "other@example.com", "hash-fresh", owner, time.Now().Add(time.Hour))
	if err != nil {
		t.Fatalf("CreateInvite fresh: %v", err)
	}
	if _, err := store.AcceptInvite(ctx, fresh.ID, other); err != ErrAlreadyMember {
		t.Fatalf("expected ErrAlreadyMember, got %v", err)
	}
}

func TestCreateInvite_ReplacesPendingForSameEmail(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	owner := mustUser(t, store, "owner@example.com")
	house, err := store.EnsureHousehold(ctx, owner)
	if err != nil {
		t.Fatalf("EnsureHousehold: %v", err)
	}

	if _, err := store.CreateInvite(ctx, house.ID, "guest@example.com", "hash-old", owner, time.Now().Add(time.Hour)); err != nil {
		t.Fatalf("CreateInvite: %v", err)
	}
	if _, err := store.CreateInvite(ctx, house.ID, "guest@example.com", "hash-new", owner, time.Now().Add(time.Hour)); err != nil {
		t.Fatalf("CreateInvite again: %v", err)
	}
	if _, err := store.GetInviteByTokenHash(ctx, "hash-old"); err != ErrNotFound {
		t.Fatalf("expected replaced invite to be gone, got %v", err)
	}
	if _, err := store.GetInviteByTokenHash(ctx, "hash-new"); err != nil {
		t.Fatalf("expected new invite present: %v", err)
	}
	if _, err := store.GetInviteByTokenHash(ctx, "hash-missing"); err != ErrNotFound {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
}

func TestRemoveMember_RemovesAndReportsMissing(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	owner := mustUser(t, store, "owner@example.com")
	guest := mustUser(t, store, "guest@example.com")

	house, err := store.EnsureHousehold(ctx, owner)
	if err != nil {
		t.Fatalf("EnsureHousehold: %v", err)
	}
	inv, err := store.CreateInvite(ctx, house.ID, "guest@example.com", "hash-1", owner, time.Now().Add(time.Hour))
	if err != nil {
		t.Fatalf("CreateInvite: %v", err)
	}
	if _, err := store.AcceptInvite(ctx, inv.ID, guest); err != nil {
		t.Fatalf("AcceptInvite: %v", err)
	}

	if err := store.RemoveMember(ctx, house.ID, guest); err != nil {
		t.Fatalf("RemoveMember: %v", err)
	}
	if _, err := store.GetHouseholdForUser(ctx, guest); err != ErrNotFound {
		t.Fatalf("expected removed member to be household-less, got %v", err)
	}
	if err := store.RemoveMember(ctx, house.ID, guest); err != ErrNotFound {
		t.Fatalf("expected ErrNotFound for repeat removal, got %v", err)
	}
}

func TestPurgeUser_RemovesHouseholdRows(t *testing.T) {
	store := setupTestStore(t)
	ctx := context.Background()
	owner := mustUser(t, store, "owner@example.com")
	guest := mustUser(t, store, "guest@example.com")

	house, err := store.EnsureHousehold(ctx, owner)
	if err != nil {
		t.Fatalf("EnsureHousehold: %v", err)
	}
	if _, err := store.CreateInvite(ctx, house.ID, "guest@example.com", "hash-1", owner, time.Now().Add(time.Hour)); err != nil {
		t.Fatalf("CreateInvite: %v", err)
	}

	if _, err := store.PurgeUser(ctx, owner, "com.test.app", func(_ string) string { return "digest" }); err != nil {
		t.Fatalf("PurgeUser: %v", err)
	}
	var n int
	if err := store.DB().QueryRowContext(ctx, `SELECT COUNT(*) FROM household_members WHERE user_id = ?`, owner).Scan(&n); err != nil {
		t.Fatalf("count memberships: %v", err)
	}
	if n != 0 {
		t.Fatalf("expected purged memberships gone, found %d", n)
	}
	if err := store.DB().QueryRowContext(ctx, `SELECT COUNT(*) FROM household_invites WHERE invited_by = ?`, owner).Scan(&n); err != nil {
		t.Fatalf("count invites: %v", err)
	}
	if n != 0 {
		t.Fatalf("expected purged invites gone, found %d", n)
	}
	// The guest (never a member) and the household row survive the purge.
	if _, err := store.GetHouseholdForUser(ctx, guest); err != ErrNotFound {
		t.Fatalf("expected guest still household-less, got %v", err)
	}
}
