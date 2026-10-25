package apple

import (
	"bytes"
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/antonkosenko/shunik/backend/internal/db"
	"github.com/antonkosenko/shunik/backend/internal/recovery"
)

// stubDeletionStore is a minimal in-memory Store for worker tests: only the
// job lifecycle is implemented; everything else panics via the nil embedded
// interface (the worker never touches it).
type stubDeletionStore struct {
	db.Store
	mu        sync.Mutex
	jobs      map[string]db.RevocationJob
	completed []string
	failed    map[string]time.Time
}

func (s *stubDeletionStore) ClaimRevocationJob(_ context.Context, now time.Time) (db.RevocationJob, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var best *db.RevocationJob
	for id, j := range s.jobs {
		if j.NextAttemptAt.After(now) {
			continue
		}
		if best == nil || j.NextAttemptAt.Before(best.NextAttemptAt) {
			cp := j
			cp.ID = id
			best = &cp
		}
	}
	if best == nil {
		return db.RevocationJob{}, db.ErrNotFound
	}
	j := *best
	j.Attempts++
	j.LastAttemptAt = &now
	// Mirror the store's claim lease (db.claimLease): a crashed claimant
	// redelivers after the lease instead of wedging the job.
	j.NextAttemptAt = now.Add(5 * time.Minute)
	s.jobs[j.ID] = j
	return j, nil
}

func (s *stubDeletionStore) CompleteRevocationJob(_ context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.jobs, id)
	s.completed = append(s.completed, id)
	return nil
}

func (s *stubDeletionStore) FailRevocationJob(_ context.Context, id, _ string, next time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	j := s.jobs[id]
	j.NextAttemptAt = next
	s.jobs[id] = j
	s.failed[id] = next
	return nil
}

type stubAppleClient struct {
	mu      sync.Mutex
	revoked []string
	err     error
}

func (f *stubAppleClient) ExchangeCode(_ context.Context, _ string) (TokenResponse, error) {
	return TokenResponse{}, errors.New("unused")
}

func (f *stubAppleClient) RevokeToken(_ context.Context, token string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.revoked = append(f.revoked, token)
	return f.err
}

func testKeyring() *recovery.Keyring {
	return recovery.NewKeyring([][]byte{bytes.Repeat([]byte{0x0b}, recovery.KeySize)})
}

func sealForJob(t *testing.T, keys *recovery.Keyring, secret, lineage string, authTime time.Time) []byte {
	t.Helper()
	sealed, err := keys.Seal([]byte(secret), VaultAAD(lineage, authTime))
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	return sealed
}

func TestWorker_RunOnceCompletes(t *testing.T) {
	keys := testKeyring()
	authTime := time.Now().Add(-time.Minute).UTC().Truncate(time.Second)
	sealed := sealForJob(t, keys, "apple-refresh-1", "lin-1", authTime)
	store := &stubDeletionStore{jobs: map[string]db.RevocationJob{
		"job-1": {ID: "job-1", SubjectDigest: "d1", SealedRefresh: sealed, ClientID: "com.test.app",
			AuthLineage: "lin-1", AuthTime: authTime, NextAttemptAt: time.Now().Add(-time.Minute)},
	}, failed: map[string]time.Time{}}
	client := &stubAppleClient{}
	w := NewWorker(store, client, keys, nil, time.Minute)

	claimed, err := w.RunOnce(context.Background())
	if err != nil || !claimed {
		t.Fatalf("RunOnce: %v %v", claimed, err)
	}
	if len(store.completed) != 1 || store.completed[0] != "job-1" {
		t.Fatalf("expected job-1 completed, got %v", store.completed)
	}
	if len(client.revoked) != 1 || client.revoked[0] != "apple-refresh-1" {
		t.Fatalf("expected revoke of the sealed credential, got %v", client.revoked)
	}
	// Drained: nothing more due.
	if claimed, err := w.RunOnce(context.Background()); err != nil || claimed {
		t.Fatalf("expected idle, got %v %v", claimed, err)
	}
}

func TestWorker_FailureReschedules(t *testing.T) {
	keys := testKeyring()
	authTime := time.Now().Add(-time.Minute).UTC().Truncate(time.Second)
	sealed := sealForJob(t, keys, "apple-refresh-2", "lin-2", authTime)
	store := &stubDeletionStore{jobs: map[string]db.RevocationJob{
		"job-2": {SubjectDigest: "d2", SealedRefresh: sealed, ClientID: "com.test.app",
			AuthLineage: "lin-2", AuthTime: authTime, NextAttemptAt: time.Now().Add(-time.Minute)},
	}, failed: map[string]time.Time{}}
	client := &stubAppleClient{err: errors.New("apple down")}
	w := NewWorker(store, client, keys, nil, time.Minute)

	if _, err := w.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	if len(store.completed) != 0 {
		t.Fatalf("failed job must not complete: %v", store.completed)
	}
	next, ok := store.failed["job-2"]
	if !ok {
		t.Fatal("failed job must be rescheduled, not dropped")
	}
	if next.Before(time.Now()) {
		t.Fatalf("reschedule must carry bounded backoff, got %v", next)
	}
}

func TestWorker_DecryptFailureKeepsJob(t *testing.T) {
	// Sealed under a different keyring: Open fails, the job is rescheduled
	// (never completed, never dropped).
	other := recovery.NewKeyring([][]byte{bytes.Repeat([]byte{0x0c}, recovery.KeySize)})
	authTime := time.Now().UTC().Truncate(time.Second)
	sealed := sealForJob(t, other, "secret", "lin-9", authTime)
	store := &stubDeletionStore{jobs: map[string]db.RevocationJob{
		"job-9": {SubjectDigest: "d9", SealedRefresh: sealed, ClientID: "com.test.app",
			AuthLineage: "lin-9", AuthTime: authTime, NextAttemptAt: time.Now().Add(-time.Minute)},
	}, failed: map[string]time.Time{}}
	w := NewWorker(store, &stubAppleClient{}, testKeyring(), nil, time.Minute)

	if _, err := w.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	if len(store.completed) != 0 {
		t.Fatal("undecryptable job must not complete")
	}
	if _, ok := store.failed["job-9"]; !ok {
		t.Fatal("undecryptable job must be rescheduled")
	}
}

func TestWorker_UnconfiguredIsInert(t *testing.T) {
	store := &stubDeletionStore{jobs: map[string]db.RevocationJob{
		"job-x": {NextAttemptAt: time.Now().Add(-time.Hour)},
	}, failed: map[string]time.Time{}}
	w := NewWorker(store, nil, nil, nil, time.Minute)
	if claimed, err := w.RunOnce(context.Background()); err != nil || claimed {
		t.Fatalf("unconfigured worker must claim nothing, got %v %v", claimed, err)
	}
	if len(store.jobs) != 1 {
		t.Fatal("unconfigured worker must not touch jobs")
	}
}
