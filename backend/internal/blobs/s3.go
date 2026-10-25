// Package blobs S3 backend: Store implementation over AWS SDK v2 with a
// custom endpoint resolver, so S3-compatible storage (AWS, R2, MinIO,
// Supabase) works through one code path. Construction performs no network
// calls; all URLs are presigned.
package blobs

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/smithy-go"
)

// defaultPresignTTL applies when neither the call-site expiry nor the
// configured presign TTL is positive. It mirrors the S3_PRESIGN_TTL default.
const defaultPresignTTL = 15 * time.Minute

// defaultRegion applies when no region is configured.
const defaultRegion = "us-east-1"

var _ Store = (*s3Store)(nil)

// s3Store is the S3-compatible production Store. The database never sees
// bytes — only keys; clients move bytes directly via presigned URLs.
type s3Store struct {
	client  *s3.Client
	presign *s3.PresignClient
	bucket  string
	// defaultExpiry backs per-call expiries that arrive non-positive.
	defaultExpiry time.Duration
}

// NewBlobStoreFromConfig builds an S3-backed Store from explicit settings
// (normally sourced from S3_* config fields).
//
//   - endpoint: custom base URL for S3-compatible stores (MinIO, R2,
//     Supabase Storage). Empty selects real AWS S3.
//   - bucket: empty means blob storage is disabled — returns (nil, nil) and
//     callers (handlers) must answer 503. Disabled is a valid state and must
//     never fail startup.
//   - region: empty defaults to us-east-1.
//   - accessKey/secretKey: static credentials.
//   - presignTTL: default presign lifetime used when a call-site expiry is
//     non-positive; non-positive here falls back to 15m.
//
// Construction never touches the network: credentials are provided
// explicitly, the region is set locally, and the SDK client only signs
// requests made later by method calls.
func NewBlobStoreFromConfig(endpoint, bucket, region, accessKey, secretKey string, presignTTL time.Duration) (Store, error) {
	if bucket == "" {
		return nil, nil
	}
	if region == "" {
		region = defaultRegion
	}
	if presignTTL <= 0 {
		presignTTL = defaultPresignTTL
	}
	client := s3.New(s3.Options{
		Region:      region,
		Credentials: credentials.NewStaticCredentialsProvider(accessKey, secretKey, ""),
	}, func(o *s3.Options) {
		if endpoint != "" {
			o.BaseEndpoint = aws.String(endpoint)
			// S3-compatibles (MinIO-likes) require path-style addressing
			// (<endpoint>/<bucket>/<key>); virtual-hosted style does not
			// resolve against a custom host.
			o.UsePathStyle = true
		}
	})
	return &s3Store{
		client:        client,
		presign:       s3.NewPresignClient(client),
		bucket:        bucket,
		defaultExpiry: presignTTL,
	}, nil
}

// expiry resolves the effective presign lifetime for one call.
func (s *s3Store) expiry(expiry time.Duration) time.Duration {
	if expiry > 0 {
		return expiry
	}
	return s.defaultExpiry
}

// PresignPut returns a URL the client PUTs exactly sizeBytes of contentType
// to. The signed ContentType binds the upload: the client must send a
// matching Content-Type or S3 rejects the request. sizeBytes is advisory —
// a presigned PUT cannot strictly enforce object length without a POST
// policy, so handlers must still validate size server-side (e.g. via
// HeadObject ContentLength before linking the blob).
func (s *s3Store) PresignPut(ctx context.Context, key, contentType string, sizeBytes int64, expiry time.Duration) (string, error) {
	if key == "" {
		return "", fmt.Errorf("blobs: presign put requires a non-empty key")
	}
	req, err := s.presign.PresignPutObject(ctx, &s3.PutObjectInput{
		Bucket:        aws.String(s.bucket),
		Key:           aws.String(key),
		ContentType:   aws.String(contentType),
		ContentLength: aws.Int64(sizeBytes),
	}, s3.WithPresignExpires(s.expiry(expiry)))
	if err != nil {
		return "", fmt.Errorf("blobs: presign put %q: %w", key, err)
	}
	return req.URL, nil
}

// PresignGet returns a URL the client GETs the key's bytes from.
func (s *s3Store) PresignGet(ctx context.Context, key string, expiry time.Duration) (string, error) {
	if key == "" {
		return "", fmt.Errorf("blobs: presign get requires a non-empty key")
	}
	req, err := s.presign.PresignGetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(key),
	}, s3.WithPresignExpires(s.expiry(expiry)))
	if err != nil {
		return "", fmt.Errorf("blobs: presign get %q: %w", key, err)
	}
	return req.URL, nil
}

// Exists reports whether the key holds bytes. A missing key (S3 NotFound)
// is (false, nil); any other failure is an error.
func (s *s3Store) Exists(ctx context.Context, key string) (bool, error) {
	if key == "" {
		return false, fmt.Errorf("blobs: exists requires a non-empty key")
	}
	_, err := s.client.HeadObject(ctx, &s3.HeadObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		var apiErr smithy.APIError
		if errors.As(err, &apiErr) && (apiErr.ErrorCode() == "NotFound" || apiErr.ErrorCode() == "NoSuchKey") {
			return false, nil
		}
		return false, fmt.Errorf("blobs: head %q: %w", key, err)
	}
	return true, nil
}

// Delete removes the key. S3 DeleteObject is idempotent, so a missing key
// is success.
func (s *s3Store) Delete(ctx context.Context, key string) error {
	if key == "" {
		return fmt.Errorf("blobs: delete requires a non-empty key")
	}
	_, err := s.client.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		return fmt.Errorf("blobs: delete %q: %w", key, err)
	}
	return nil
}
