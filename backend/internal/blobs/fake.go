// Package blobs fake backend: in-memory Store for tests. Deterministic
// fake URLs, no globals, no network.
package blobs

import (
	"context"
	"fmt"
	"sync"
	"time"
)

var _ Store = (*FakeStore)(nil)

// FakeStore is a map-backed in-memory Store for unit and handler tests. It
// performs no I/O, holds no globals, and has no time bombs: presigned URLs
// are deterministic ("fake://<key>?op=put|get") and expiries are accepted
// but ignored.
type FakeStore struct {
	mu      sync.Mutex
	objects map[string][]byte
}

// NewFakeStore returns an empty FakeStore.
func NewFakeStore() *FakeStore {
	return &FakeStore{objects: make(map[string][]byte)}
}

// Put seeds key with data, as if a client had completed an upload to a
// presigned PUT URL. Tests use it to set up Exists/Delete preconditions; it
// is not part of the Store interface.
func (f *FakeStore) Put(_ context.Context, key string, data []byte) {
	f.mu.Lock()
	defer f.mu.Unlock()
	cp := make([]byte, len(data))
	copy(cp, data)
	f.objects[key] = cp
}

// PresignPut returns the deterministic fake upload URL for key.
func (f *FakeStore) PresignPut(_ context.Context, key, _ string, _ int64, _ time.Duration) (string, error) {
	if key == "" {
		return "", fmt.Errorf("blobs: presign put requires a non-empty key")
	}
	return "fake://" + key + "?op=put", nil
}

// PresignGet returns the deterministic fake download URL for key.
func (f *FakeStore) PresignGet(_ context.Context, key string, _ time.Duration) (string, error) {
	if key == "" {
		return "", fmt.Errorf("blobs: presign get requires a non-empty key")
	}
	return "fake://" + key + "?op=get", nil
}

// Exists reports whether key was seeded via Put.
func (f *FakeStore) Exists(_ context.Context, key string) (bool, error) {
	if key == "" {
		return false, fmt.Errorf("blobs: exists requires a non-empty key")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	_, ok := f.objects[key]
	return ok, nil
}

// Delete removes key; a missing key is success.
func (f *FakeStore) Delete(_ context.Context, key string) error {
	if key == "" {
		return fmt.Errorf("blobs: delete requires a non-empty key")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.objects, key)
	return nil
}
