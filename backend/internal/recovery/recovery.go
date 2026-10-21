// Package recovery seals pending refresh successors for response-loss
// recovery (fix-refresh-response-loss). A committed rotation stores one
// receipt holding the successor refresh credential encrypted with
// AES-256-GCM from the Go standard library, bound to account, device,
// predecessor, attempt, and fixed expiry as associated data. The server
// never persists plaintext tokens — only the sealed blob plus hashes —
// and never logs tokens, attempts, ciphertext, or keys.
package recovery

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"errors"
	"fmt"
)

// KeySize is the required AES-256 key length in bytes.
const KeySize = 32

// NonceSize is the GCM nonce length in bytes.
const NonceSize = 12

// Keyring holds the recovery encryption keys. Keys[0] is the primary key
// used for sealing; all keys are tried when opening, so retired keys keep
// decrypting pending receipts across rotation.
type Keyring struct {
	keys [][]byte
}

// NewKeyring builds a Keyring from 32-byte keys. It returns nil when no
// keys are configured (recovery disabled — refresh attempts are ignored and
// legacy behavior applies).
func NewKeyring(keys [][]byte) *Keyring {
	if len(keys) == 0 {
		return nil
	}
	dup := make([][]byte, len(keys))
	for i, k := range keys {
		c := make([]byte, len(k))
		copy(c, k)
		dup[i] = c
	}
	return &Keyring{keys: dup}
}

// AAD builds the associated data binding a sealed successor to its account,
// device, predecessor hash, attempt hash, and fixed expiry. All inputs are
// non-secret (hashes and timestamps, never raw tokens). Separator bytes make
// the concatenation unambiguous.
func AAD(userID, deviceID, predecessorHash, attemptHash, expiresAt string) []byte {
	aad := make([]byte, 0, len(userID)+len(deviceID)+len(predecessorHash)+len(attemptHash)+len(expiresAt)+4)
	aad = append(aad, userID...)
	aad = append(aad, 0)
	aad = append(aad, deviceID...)
	aad = append(aad, 0)
	aad = append(aad, predecessorHash...)
	aad = append(aad, 0)
	aad = append(aad, attemptHash...)
	aad = append(aad, 0)
	aad = append(aad, expiresAt...)
	return aad
}

// Seal encrypts plaintext with the primary key under aad. The output is
// nonce || ciphertext with a fresh random nonce per call.
func (k *Keyring) Seal(plaintext, aad []byte) ([]byte, error) {
	if k == nil || len(k.keys) == 0 {
		return nil, errors.New("recovery keyring not configured")
	}
	gcm, err := gcmForKey(k.keys[0])
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, NonceSize)
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("generate seal nonce: %w", err)
	}
	out := make([]byte, 0, NonceSize+len(plaintext)+gcm.Overhead())
	out = append(out, nonce...)
	out = gcm.Seal(out, nonce, plaintext, aad)
	return out, nil
}

// Open decrypts a sealed blob sealed by Seal, trying each key in turn so
// retired keys keep working. It returns an error when no key authenticates
// the blob — the caller must surface a service failure (never an
// authentication rejection) without revoking the family.
func (k *Keyring) Open(sealed, aad []byte) ([]byte, error) {
	if k == nil || len(k.keys) == 0 {
		return nil, errors.New("recovery keyring not configured")
	}
	if len(sealed) < NonceSize {
		return nil, errors.New("sealed blob too short")
	}
	nonce, ciphertext := sealed[:NonceSize], sealed[NonceSize:]
	for _, key := range k.keys {
		gcm, err := gcmForKey(key)
		if err != nil {
			continue
		}
		if plaintext, err := gcm.Open(nil, nonce, ciphertext, aad); err == nil {
			return plaintext, nil
		}
	}
	return nil, errors.New("sealed blob failed authentication")
}

func gcmForKey(key []byte) (cipher.AEAD, error) {
	if len(key) != KeySize {
		return nil, fmt.Errorf("recovery key must be %d bytes, got %d", KeySize, len(key))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("create seal cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("create seal GCM: %w", err)
	}
	return gcm, nil
}
