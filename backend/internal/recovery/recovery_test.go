package recovery

import (
	"bytes"
	"testing"
)

func testKeyring(t *testing.T) *Keyring {
	t.Helper()
	primary := bytes.Repeat([]byte{0x01}, KeySize)
	retired := bytes.Repeat([]byte{0x02}, KeySize)
	return NewKeyring([][]byte{primary, retired})
}

func testAAD() []byte {
	return AAD("user-1", "device-A", "pred-hash", "attempt-hash", "2026-10-19T00:00:00Z")
}

func TestSealOpenRoundTrip(t *testing.T) {
	k := testKeyring(t)
	aad := testAAD()

	sealed, err := k.Seal([]byte("successor-refresh-token"), aad)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	if len(sealed) <= NonceSize {
		t.Fatalf("sealed blob must carry nonce plus ciphertext, got %d bytes", len(sealed))
	}

	plain, err := k.Open(sealed, aad)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if string(plain) != "successor-refresh-token" {
		t.Errorf("round trip mismatch, got %q", plain)
	}
}

func TestSealUsesFreshNonce(t *testing.T) {
	k := testKeyring(t)
	aad := testAAD()

	first, err := k.Seal([]byte("same-plaintext"), aad)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	second, err := k.Seal([]byte("same-plaintext"), aad)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	if bytes.Equal(first, second) {
		t.Error("two seals of the same plaintext must differ (fresh nonce)")
	}
}

func TestOpenRejectsWrongAAD(t *testing.T) {
	k := testKeyring(t)

	sealed, err := k.Seal([]byte("successor"), testAAD())
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}

	// Rebinding to another account, device, predecessor, attempt, or expiry
	// must fail authentication.
	for _, aad := range [][]byte{
		AAD("user-2", "device-A", "pred-hash", "attempt-hash", "2026-10-19T00:00:00Z"),
		AAD("user-1", "device-B", "pred-hash", "attempt-hash", "2026-10-19T00:00:00Z"),
		AAD("user-1", "device-A", "other-pred", "attempt-hash", "2026-10-19T00:00:00Z"),
		AAD("user-1", "device-A", "pred-hash", "other-attempt", "2026-10-19T00:00:00Z"),
		AAD("user-1", "device-A", "pred-hash", "attempt-hash", "2026-10-20T00:00:00Z"),
	} {
		if _, err := k.Open(sealed, aad); err == nil {
			t.Errorf("Open must fail for rebound associated data %q", aad)
		}
	}
}

func TestOpenWithRetiredKey(t *testing.T) {
	retired := bytes.Repeat([]byte{0x02}, KeySize)
	oldRing := NewKeyring([][]byte{retired})
	aad := testAAD()

	sealed, err := oldRing.Seal([]byte("successor"), aad)
	if err != nil {
		t.Fatalf("Seal with retired key: %v", err)
	}

	// After rotation the retired key is no longer primary, but pending
	// receipts sealed under it must still open.
	primary := bytes.Repeat([]byte{0x01}, KeySize)
	newRing := NewKeyring([][]byte{primary, retired})
	plain, err := newRing.Open(sealed, aad)
	if err != nil {
		t.Fatalf("Open with retired key: %v", err)
	}
	if string(plain) != "successor" {
		t.Errorf("expected successor, got %q", plain)
	}
}

func TestOpenRejectsTamperedBlob(t *testing.T) {
	k := testKeyring(t)
	aad := testAAD()

	sealed, err := k.Seal([]byte("successor"), aad)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}

	tampered := bytes.Clone(sealed)
	tampered[len(tampered)-1] ^= 0xff
	if _, err := k.Open(tampered, aad); err == nil {
		t.Error("Open must fail for a tampered blob")
	}

	if _, err := k.Open([]byte("short"), aad); err == nil {
		t.Error("Open must fail for a truncated blob")
	}

	foreign, err := NewKeyring([][]byte{bytes.Repeat([]byte{0x03}, KeySize)}).Seal([]byte("successor"), aad)
	if err != nil {
		t.Fatalf("Seal with foreign key: %v", err)
	}
	if _, err := k.Open(foreign, aad); err == nil {
		t.Error("Open must fail for a blob sealed under an unknown key")
	}
}

func TestNilKeyringFailsClosed(t *testing.T) {
	var k *Keyring
	if _, err := k.Seal([]byte("x"), testAAD()); err == nil {
		t.Error("nil keyring Seal must fail")
	}
	if _, err := k.Open([]byte("0123456789012345"), testAAD()); err == nil {
		t.Error("nil keyring Open must fail")
	}
	if got := NewKeyring(nil); got != nil {
		t.Error("NewKeyring with no keys must return nil (recovery disabled)")
	}
}
