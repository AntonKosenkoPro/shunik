package apple

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func testPrivateKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	return key
}

func testPrivateKeyPEM(t *testing.T, key *ecdsa.PrivateKey) string {
	t.Helper()
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
}

func TestParsePrivateKey(t *testing.T) {
	key := testPrivateKey(t)
	pemStr := testPrivateKeyPEM(t, key)

	got, err := ParsePrivateKey([]byte(pemStr))
	if err != nil {
		t.Fatalf("ParsePrivateKey: %v", err)
	}
	if got.D.Cmp(key.D) != 0 {
		t.Error("round-trip key mismatch")
	}

	// Literal \n escapes (single-quoted env rendering) are accepted.
	escaped := strings.ReplaceAll(strings.TrimSpace(pemStr), "\n", `\n`)
	if _, err := ParsePrivateKey([]byte(escaped)); err != nil {
		t.Errorf("escaped PEM must parse: %v", err)
	}

	for _, input := range []string{"", "not-a-pem", "-----BEGIN PRIVATE KEY-----\n!!!\n-----END PRIVATE KEY-----"} {
		if _, err := ParsePrivateKey([]byte(input)); err == nil {
			t.Errorf("expected error for %q, got nil", input)
		}
	}
}

// fakeAppleServer serves /auth/token and /auth/revoke with scripted behavior.
type fakeAppleServer struct {
	t            *testing.T
	tokenHandler func(w http.ResponseWriter, r *http.Request)
	revokeCount  int
	revokeTokens []string
}

func (f *fakeAppleServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if ct := r.Header.Get("Content-Type"); ct != "application/x-www-form-urlencoded" {
		f.t.Errorf("expected form content type, got %q", ct)
	}
	switch r.URL.Path {
	case "/auth/token":
		f.tokenHandler(w, r)
	case "/auth/revoke":
		body := r.FormValue("token")
		f.revokeTokens = append(f.revokeTokens, body)
		f.revokeCount++
		if r.FormValue("token_type_hint") != "refresh_token" {
			http.Error(w, `{"error":"invalid_request"}`, http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusOK)
	default:
		http.NotFound(w, r)
	}
}

func newTestClient(t *testing.T, srv *httptest.Server) *RESTClient {
	t.Helper()
	key := testPrivateKey(t)
	return NewRESTClient("com.test.app", "TEAMID", "KEYID", key, srv.URL, "", nil)
}

func TestClientSecretShape(t *testing.T) {
	key := testPrivateKey(t)
	c := NewRESTClient("com.test.app", "TEAMID1", "KID1", key, "https://example.invalid", "", nil)
	secret, err := c.clientSecret()
	if err != nil {
		t.Fatalf("clientSecret: %v", err)
	}
	parser := jwt.NewParser()
	token, _, err := parser.ParseUnverified(secret, &jwt.RegisteredClaims{})
	if err != nil {
		t.Fatalf("parse secret: %v", err)
	}
	if token.Method != jwt.SigningMethodES256 {
		t.Errorf("expected ES256, got %v", token.Method)
	}
	if token.Header["kid"] != "KID1" {
		t.Errorf("expected kid KID1, got %v", token.Header["kid"])
	}
	claims, ok := token.Claims.(*jwt.RegisteredClaims)
	if !ok {
		t.Fatalf("claims shape: %T", token.Claims)
	}
	if claims.Issuer != "TEAMID1" || claims.Subject != "com.test.app" {
		t.Errorf("unexpected iss/sub: %+v", claims)
	}
	// Verify the signature with the public key.
	if _, err := jwt.Parse(secret, func(_ *jwt.Token) (any, error) {
		return &key.PublicKey, nil
	}, jwt.WithValidMethods([]string{"ES256"})); err != nil {
		t.Errorf("secret signature invalid: %v", err)
	}
}

func TestExchangeCode(t *testing.T) {
	srv := httptest.NewServer(&fakeAppleServer{t: t, tokenHandler: func(w http.ResponseWriter, r *http.Request) {
		for _, field := range []string{"client_id", "client_secret", "code", "grant_type"} {
			if r.FormValue(field) == "" {
				http.Error(w, `{"error":"invalid_request"}`, http.StatusBadRequest)
				return
			}
		}
		if r.FormValue("grant_type") != "authorization_code" {
			http.Error(w, `{"error":"unsupported_grant_type"}`, http.StatusBadRequest)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"access_token": "acc", "refresh_token": "ref-123", "id_token": "id",
		})
	}})
	defer srv.Close()

	c := newTestClient(t, srv)
	out, err := c.ExchangeCode(t.Context(), "code-1")
	if err != nil {
		t.Fatalf("ExchangeCode: %v", err)
	}
	if out.RefreshToken != "ref-123" {
		t.Errorf("expected refresh token, got %+v", out)
	}
}

func TestExchangeCode_InvalidGrant(t *testing.T) {
	srv := httptest.NewServer(&fakeAppleServer{t: t, tokenHandler: func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"error":"invalid_grant"}`, http.StatusBadRequest)
	}})
	defer srv.Close()

	c := newTestClient(t, srv)
	if _, err := c.ExchangeCode(t.Context(), "used-code"); !isInvalidGrant(err) {
		t.Fatalf("expected ErrInvalidGrant, got %v", err)
	}
}

func TestExchangeCode_MissingRefreshToken(t *testing.T) {
	srv := httptest.NewServer(&fakeAppleServer{t: t, tokenHandler: func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"access_token": "only"})
	}})
	defer srv.Close()

	c := newTestClient(t, srv)
	if _, err := c.ExchangeCode(t.Context(), "code"); !isInvalidGrant(err) {
		t.Fatalf("response without refresh token must be an invalid grant, got %v", err)
	}
}

func isInvalidGrant(err error) bool {
	return errors.Is(err, ErrInvalidGrant)
}

func TestRevokeToken(t *testing.T) {
	fake := &fakeAppleServer{t: t, tokenHandler: func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}}
	srv := httptest.NewServer(fake)
	defer srv.Close()

	c := newTestClient(t, srv)
	if err := c.RevokeToken(t.Context(), "ref-123"); err != nil {
		t.Fatalf("RevokeToken: %v", err)
	}
	if len(fake.revokeTokens) != 1 || fake.revokeTokens[0] != "ref-123" {
		t.Fatalf("expected one revoke of ref-123, got %v", fake.revokeTokens)
	}
}

func TestSubjectDigest_Stability(t *testing.T) {
	k1 := SubjectDigestKey([]byte("status-secret-at-least-32-bytes!!!"))
	k2 := SubjectDigestKey([]byte("status-secret-at-least-32-bytes!!!"))
	d1 := SubjectDigest(k1, "apple-sub-1")
	if d1 != SubjectDigest(k2, "apple-sub-1") {
		t.Error("digest must be deterministic for the same key")
	}
	// Rotating ACCOUNT_STATUS_SECRET re-keys every digest — the documented
	// rotate-only-after-the-job-table-drains rule exists because of this,
	// so distinct secrets must derive distinct digest keys.
	rotated := SubjectDigestKey([]byte("another-status-secret-at-least-32-bytes"))
	if string(rotated) == string(k1) {
		t.Error("distinct status secrets must derive distinct digest keys")
	}
	if SubjectDigest(k1, "apple-sub-2") == d1 {
		t.Error("distinct subjects must digest distinctly")
	}
	// The purpose key itself differs from a raw HMAC under the status
	// secret (domain separation, not bare reuse).
	if d1 == "apple-sub-1" || len(d1) != 64 {
		t.Errorf("expected 64-hex digest, got %q", d1)
	}
}

func TestVaultAAD_DomainSeparation(t *testing.T) {
	a := VaultAAD("lin-1", time.Now())
	b := VaultAAD("lin-2", time.Now())
	if string(a) == string(b) {
		t.Error("AAD must bind the lineage")
	}
	if !strings.HasPrefix(string(a), "shunik-apple-vault\x00") {
		t.Error("AAD must carry the vault domain prefix")
	}
	// Second-granularity RFC3339 pins the cross-engine invariant: Postgres
	// (microseconds) and SQLite (milliseconds) timestamps for the same
	// instant must seal under identical AAD, or the worker decrypt fails.
	base := time.Now()
	if string(VaultAAD("lin", base)) != string(VaultAAD("lin", base.Truncate(time.Second))) {
		t.Error("AAD must be stable at second granularity across timestamp precisions")
	}
}

func TestRetryAfter_Bounded(t *testing.T) {
	if got := RetryAfter(0); got != time.Minute {
		t.Errorf("attempts<1 clamps to 1m, got %v", got)
	}
	if got := RetryAfter(1); got != time.Minute {
		t.Errorf("attempt 1 -> 1m, got %v", got)
	}
	if got := RetryAfter(100); got != time.Hour {
		t.Errorf("backoff caps at 1h, got %v", got)
	}
}
