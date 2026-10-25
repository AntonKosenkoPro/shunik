package apple

import (
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

	"github.com/golang-jwt/jwt/v5"
)

const testClientID = "com.antonkosenko.shunik"

// jwksServer serves a JWKS containing the public half of key for a test.
func jwksServer(t *testing.T, key *rsa.PrivateKey, kid string) *httptest.Server {
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

// mintToken signs an Apple-shaped identity token with key.
func mintToken(t *testing.T, key *rsa.PrivateKey, kid, sub, email string, emailVerified any, aud string, exp time.Time) string {
	t.Helper()
	claims := jwt.MapClaims{
		"iss":            appleIssuer,
		"aud":            aud,
		"sub":            sub,
		"email":          email,
		"email_verified": emailVerified,
		"iat":            time.Now().Unix(),
		"exp":            exp.Unix(),
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	tok.Header["kid"] = kid
	s, err := tok.SignedString(key)
	if err != nil {
		t.Fatalf("sign token: %v", err)
	}
	return s
}

func newVerifier(t *testing.T, url string) Verifier {
	t.Helper()
	v, err := NewVerifier(context.Background(), testClientID, url)
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}
	return v
}

func TestVerify_AcceptsValidToken(t *testing.T) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	srv := jwksServer(t, key, "test-key")
	defer srv.Close()

	v := newVerifier(t, srv.URL)
	tok := mintToken(t, key, "test-key", "apple-sub-1", "r@privaterelay.appleid.com", "true", testClientID, time.Now().Add(10*time.Minute))

	claims, err := v.Verify(context.Background(), tok)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if claims.Sub != "apple-sub-1" {
		t.Fatalf("sub = %q, want apple-sub-1", claims.Sub)
	}
	if claims.Email != "r@privaterelay.appleid.com" {
		t.Fatalf("email = %q", claims.Email)
	}
	if !claims.IsEmailVerified() {
		t.Fatalf("email_verified not parsed as true (string form)")
	}
}

func TestVerify_AcceptsBoolEmailVerified(t *testing.T) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	srv := jwksServer(t, key, "k")
	defer srv.Close()

	v := newVerifier(t, srv.URL)
	tok := mintToken(t, key, "k", "sub-bool", "x@example.com", true, testClientID, time.Now().Add(time.Minute))

	claims, err := v.Verify(context.Background(), tok)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if !claims.IsEmailVerified() {
		t.Fatalf("email_verified not parsed as true (bool form)")
	}
}

func TestVerify_RejectsWrongAudience(t *testing.T) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	srv := jwksServer(t, key, "k")
	defer srv.Close()

	v := newVerifier(t, srv.URL)
	tok := mintToken(t, key, "k", "sub", "x@example.com", true, "com.other.app", time.Now().Add(time.Minute))

	if _, err := v.Verify(context.Background(), tok); err == nil {
		t.Fatal("expected error for wrong audience, got nil")
	}
}

func TestVerify_RejectsExpiredToken(t *testing.T) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	srv := jwksServer(t, key, "k")
	defer srv.Close()

	v := newVerifier(t, srv.URL)
	tok := mintToken(t, key, "k", "sub", "x@example.com", true, testClientID, time.Now().Add(-time.Hour))

	if _, err := v.Verify(context.Background(), tok); err == nil {
		t.Fatal("expected error for expired token, got nil")
	}
}

func TestVerify_RejectsTamperedSignature(t *testing.T) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	other, _ := rsa.GenerateKey(rand.Reader, 2048)
	srv := jwksServer(t, other, "k") // JWKS serves a *different* key
	defer srv.Close()

	v := newVerifier(t, srv.URL)
	tok := mintToken(t, key, "k", "sub", "x@example.com", true, testClientID, time.Now().Add(time.Minute))

	if _, err := v.Verify(context.Background(), tok); err == nil {
		t.Fatal("expected signature verification error, got nil")
	}
}

func TestVerify_RejectsEmptyToken(t *testing.T) {
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	srv := jwksServer(t, key, "k")
	defer srv.Close()

	v := newVerifier(t, srv.URL)
	if _, err := v.Verify(context.Background(), ""); err == nil {
		t.Fatal("expected error for empty token, got nil")
	}
}
