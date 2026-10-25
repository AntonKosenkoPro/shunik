// Package blobs abstracts object storage for document bytes. Production
// uses S3-compatible presigned URLs (AWS SDK v2 with a custom endpoint, so
// AWS, R2, MinIO, and Supabase Storage all fit); tests use the in-memory
// fake. The database never sees bytes — only keys.
package blobs

import (
	"context"
	"time"
)

// Store presigns uploads/downloads and deletes blobs.
type Store interface {
	// PresignPut returns a URL the client PUTs exactly sizeBytes of
	// contentType to. The URL expires after expiry.
	PresignPut(ctx context.Context, key, contentType string, sizeBytes int64, expiry time.Duration) (string, error)

	// PresignGet returns a URL the client GETs the key's bytes from.
	// The URL expires after expiry.
	PresignGet(ctx context.Context, key string, expiry time.Duration) (string, error)

	// Exists reports whether the key holds bytes.
	Exists(ctx context.Context, key string) (bool, error)

	// Delete removes the key; missing keys are success.
	Delete(ctx context.Context, key string) error
}
