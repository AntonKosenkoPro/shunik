package handlers

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/antonkosenko/shunik/backend/internal/apple"
	"github.com/golang-jwt/jwt/v5"
)

// NOTE (fix #96): AppleSignIn (auth.go:461-462) currently issues sessions with
// emailVerified=true regardless of the parsed claim, so rejecting these tokens
// costs availability (401 vs. 200), not trust — the strictness future-proofs
// the flag for when IsEmailVerified gates something.

// flexJWKS serves the public half of key as a JWKS document.
func flexJWKS(t *testing.T, key *rsa.PrivateKey, kid string) *httptest.Server {
	t.Helper()
	pub := key.Public().(*rsa.PublicKey)
	jwk := map[string]any{
		"kty": "RSA",
		"kid": kid,
		"alg": "RS256",
		"use": "sig",
		"n":   base64.RawURLEncoding.EncodeToString(pub.N.Bytes()),
		"e":   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(pub.E)).Bytes()),
	}
	body, _ := json.Marshal(map[string]any{"keys": []map[string]any{jwk}})
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(body)
	}))
}

// mintFlexToken signs an Apple-shaped token carrying a caller-chosen
// email_verified wire shape.
func mintFlexToken(t *testing.T, key *rsa.PrivateKey, kid string, emailVerified any) string {
	t.Helper()
	claims := jwt.MapClaims{
		"iss":            "https://appleid.apple.com",
		"aud":            "com.antonkosenko.shunik",
		"sub":            "apple-sub-flex",
		"email":          "r@privaterelay.appleid.com",
		"email_verified": emailVerified,
		"iat":            time.Now().Unix(),
		"exp":            time.Now().Add(10 * time.Minute).Unix(),
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	tok.Header["kid"] = kid
	s, err := tok.SignedString(key)
	if err != nil {
		t.Fatalf("sign token: %v", err)
	}
	return s
}

// A token with a garbage email_verified shape must fail verification, and the
// sign-in endpoint must answer 401 invalid_apple_token for it.
func TestAppleSignIn_GarbageEmailVerifiedReturns401(t *testing.T) {
	for _, tc := range []struct {
		name          string
		emailVerified any
	}{
		{"unknown string", "yes"},
		{"unknown number", 2},
		{"object", map[string]any{}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			key, err := rsa.GenerateKey(rand.Reader, 2048)
			if err != nil {
				t.Fatalf("generate key: %v", err)
			}
			srv := flexJWKS(t, key, "k")
			defer srv.Close()

			verifier, err := apple.NewVerifier(context.Background(), "com.antonkosenko.shunik", srv.URL)
			if err != nil {
				t.Fatalf("NewVerifier: %v", err)
			}

			store := newTestStore(t)
			h := newTestHandlerWithApple(t, store, verifier)

			w := doAppleSignIn(t, h, mintFlexToken(t, key, "k", tc.emailVerified))
			if w.Code != http.StatusUnauthorized {
				t.Fatalf("expected 401 for garbage email_verified, got %d: %s", w.Code, w.Body.String())
			}
			var resp struct {
				Error struct {
					Code string `json:"code"`
				} `json:"error"`
			}
			if err := json.NewDecoder(bytes.NewReader(w.Body.Bytes())).Decode(&resp); err != nil {
				t.Fatalf("decode error body: %v", err)
			}
			if resp.Error.Code != "invalid_apple_token" {
				t.Errorf("expected code invalid_apple_token, got %q", resp.Error.Code)
			}
		})
	}
}
