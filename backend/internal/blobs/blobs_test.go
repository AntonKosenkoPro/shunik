package blobs

import (
	"context"
	"testing"
	"time"
)

func TestFake_PresignURLsDeterministic(t *testing.T) {
	f := NewFakeStore()
	ctx := context.Background()

	put1, err := f.PresignPut(ctx, "docs/a.pdf", "application/pdf", 100, time.Minute)
	if err != nil {
		t.Fatalf("PresignPut: %v", err)
	}
	put2, err := f.PresignPut(ctx, "docs/a.pdf", "application/pdf", 100, time.Minute)
	if err != nil {
		t.Fatalf("PresignPut: %v", err)
	}
	if put1 != put2 {
		t.Errorf("PresignPut URLs not deterministic: %q vs %q", put1, put2)
	}
	if want := "fake://docs/a.pdf?op=put"; put1 != want {
		t.Errorf("PresignPut = %q, want %q", put1, want)
	}

	get, err := f.PresignGet(ctx, "docs/a.pdf", time.Minute)
	if err != nil {
		t.Fatalf("PresignGet: %v", err)
	}
	if want := "fake://docs/a.pdf?op=get"; get != want {
		t.Errorf("PresignGet = %q, want %q", get, want)
	}
	if get == put1 {
		t.Errorf("put and get URLs must differ: %q", get)
	}
}

func TestFake_ExistsDelete(t *testing.T) {
	f := NewFakeStore()
	ctx := context.Background()

	ok, err := f.Exists(ctx, "docs/missing.pdf")
	if err != nil {
		t.Fatalf("Exists: %v", err)
	}
	if ok {
		t.Errorf("Exists(missing) = true, want false")
	}

	f.Put(ctx, "docs/a.pdf", []byte("bytes"))
	ok, err = f.Exists(ctx, "docs/a.pdf")
	if err != nil {
		t.Fatalf("Exists: %v", err)
	}
	if !ok {
		t.Errorf("Exists(seeded) = false, want true")
	}

	if err := f.Delete(ctx, "docs/a.pdf"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	ok, err = f.Exists(ctx, "docs/a.pdf")
	if err != nil {
		t.Fatalf("Exists: %v", err)
	}
	if ok {
		t.Errorf("Exists(deleted) = true, want false")
	}

	// Missing keys are success.
	if err := f.Delete(ctx, "docs/never-there.pdf"); err != nil {
		t.Errorf("Delete(missing) = %v, want nil", err)
	}
}

func TestFake_EmptyKeyErrors(t *testing.T) {
	f := NewFakeStore()
	ctx := context.Background()

	if _, err := f.PresignPut(ctx, "", "application/pdf", 1, time.Minute); err == nil {
		t.Errorf("PresignPut(\"\") = nil error, want error")
	}
	if _, err := f.PresignGet(ctx, "", time.Minute); err == nil {
		t.Errorf("PresignGet(\"\") = nil error, want error")
	}
	if _, err := f.Exists(ctx, ""); err == nil {
		t.Errorf("Exists(\"\") = nil error, want error")
	}
	if err := f.Delete(ctx, ""); err == nil {
		t.Errorf("Delete(\"\") = nil error, want error")
	}
}

// TestNewBlobStoreFromConfig_Disabled pins the disabled state: an empty
// bucket returns (nil, nil) without touching the network, so handlers can
// answer 503 and startup never fails on S3 misconfiguration.
func TestNewBlobStoreFromConfig_Disabled(t *testing.T) {
	store, err := NewBlobStoreFromConfig("", "", "", "", "", 0)
	if err != nil {
		t.Fatalf("NewBlobStoreFromConfig(disabled): %v", err)
	}
	if store != nil {
		t.Errorf("NewBlobStoreFromConfig(disabled) = non-nil store, want nil")
	}
}

// TestNewBlobStoreFromConfig_ConstructsOffline pins that construction with a
// bucket set succeeds without network access (no endpoint reachable here;
// any dial would fail the test with a hang or error).
func TestNewBlobStoreFromConfig_ConstructsOffline(t *testing.T) {
	ctx := context.Background()
	store, err := NewBlobStoreFromConfig(
		"http://127.0.0.1:1", // unroutable: any network use fails
		"test-bucket",
		"",
		"test-access",
		"test-secret",
		0,
	)
	if err != nil {
		t.Fatalf("NewBlobStoreFromConfig: %v", err)
	}
	if store == nil {
		t.Fatalf("NewBlobStoreFromConfig = nil store, want non-nil")
	}

	putURL, err := store.PresignPut(ctx, "docs/a.pdf", "application/pdf", 100, time.Minute)
	if err != nil {
		t.Fatalf("PresignPut: %v", err)
	}
	if putURL == "" {
		t.Errorf("PresignPut = empty URL")
	}

	getURL, err := store.PresignGet(ctx, "docs/a.pdf", 0) // zero expiry → configured default
	if err != nil {
		t.Fatalf("PresignGet: %v", err)
	}
	if getURL == "" {
		t.Errorf("PresignGet = empty URL")
	}
}
