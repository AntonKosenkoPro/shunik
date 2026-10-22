package auth

import (
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	testStatusSecret = "test-status-secret-at-least-32-bytes!"
	testJWTOuter     = "test-jwt-secret-also-at-least-32-bytes!"
)

func TestStatus_MintValidateRoundTrip(t *testing.T) {
	svc := NewStatusService(testStatusSecret)
	token, exp, err := svc.Mint("user-123")
	if err != nil {
		t.Fatalf("Mint: %v", err)
	}
	if time.Until(exp) > StatusTTL || time.Until(exp) < StatusTTL-time.Minute {
		t.Fatalf("expected ~30d expiry, got %v", exp)
	}
	sub, err := svc.Validate(token)
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if sub != "user-123" {
		t.Fatalf("expected subject echo, got %q", sub)
	}
}

func TestStatus_Rejects(t *testing.T) {
	svc := NewStatusService(testStatusSecret)
	other := NewStatusService("a-different-status-secret-32bytes!!")

	valid, _, err := svc.Mint("user-123")
	if err != nil {
		t.Fatalf("Mint: %v", err)
	}
	cases := map[string]string{
		"empty":        "",
		"garbage":      "not-a-token",
		"wrong key":    mustMint(t, other, "user-123"),
		"access token": mustAccessToken(t, "user-123"),
		"tampered":     valid[:len(valid)-2] + "xx",
	}
	for name, token := range cases {
		if _, err := svc.Validate(token); err == nil {
			t.Errorf("%s: expected rejection, got nil", name)
		}
	}
}

// mustMint mints with another service (wrong-key case).
func mustMint(t *testing.T, svc *StatusService, sub string) string {
	t.Helper()
	token, _, err := svc.Mint(sub)
	if err != nil {
		t.Fatalf("Mint: %v", err)
	}
	return token
}

// mustAccessToken builds a normal access token under the STATUS secret: it
// must still fail status validation (issuer/audience/purpose pinning), and
// vice versa the status token must fail access validation.
func mustAccessToken(t *testing.T, sub string) string {
	t.Helper()
	ts := NewTokenService(testJWTOuter, 15*time.Minute, 7*24*time.Hour)
	token, err := ts.CreateAccessToken(sub, "user@example.com")
	if err != nil {
		t.Fatalf("CreateAccessToken: %v", err)
	}
	return token
}

func TestStatus_CrossRejection(t *testing.T) {
	// A status credential never passes access-token validation, even when
	// both secrets coincide in a test (production forbids equality).
	shared := "shared-test-secret-at-least-32-bytes!"
	statusSvc := NewStatusService(shared)
	accessSvc := NewTokenService(shared, 15*time.Minute, 7*24*time.Hour)

	statusCred, _, err := statusSvc.Mint("user-1")
	if err != nil {
		t.Fatalf("Mint: %v", err)
	}
	if _, _, err := accessSvc.ValidateAccessToken(statusCred); err == nil {
		t.Error("status credential must never validate as an access token")
	}
	if _, err := accessSvc.ValidateAccessTokenDetailed(statusCred); err == nil {
		t.Error("status credential must never validate as detailed access claims")
	}

	accessCred, err := statusSvc.Validate(mustAccessTokenFor(t, accessSvc))
	if err == nil {
		t.Errorf("access token must never validate as status, got %q", accessCred)
	}
}

func mustAccessTokenFor(t *testing.T, svc *TokenService) string {
	t.Helper()
	token, err := svc.CreateAccessToken("user-1", "user@example.com")
	if err != nil {
		t.Fatalf("CreateAccessToken: %v", err)
	}
	return token
}

func TestStatus_ExpiryEnforced(t *testing.T) {
	svc := NewStatusService(testStatusSecret)
	claims := StatusClaims{
		Purpose: StatusPurpose,
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    StatusIssuer,
			Audience:  jwt.ClaimStrings{StatusAudience},
			Subject:   "user-1",
			IssuedAt:  jwt.NewNumericDate(time.Now().Add(-2 * time.Hour)),
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(-time.Hour)),
		},
	}
	signed, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(testStatusSecret))
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	if _, err := svc.Validate(signed); err == nil {
		t.Error("expired status credential must be rejected")
	}
}

func TestStatus_WrongPurposeRejected(t *testing.T) {
	claims := StatusClaims{
		Purpose: "login",
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    StatusIssuer,
			Audience:  jwt.ClaimStrings{StatusAudience},
			Subject:   "user-1",
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
		},
	}
	signed, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(testStatusSecret))
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	if _, err := NewStatusService(testStatusSecret).Validate(signed); err == nil {
		t.Error("wrong-purpose credential must be rejected")
	}
}

func TestAccessToken_LineageRoundTrip(t *testing.T) {
	svc := NewTokenService(testJWTOuter, 15*time.Minute, 7*24*time.Hour)
	at := time.Now().Add(-time.Hour).UTC().Truncate(time.Second)
	token, err := svc.CreateAccessTokenWithAuth("user-9", "u@example.com", at, "lin-9")
	if err != nil {
		t.Fatalf("CreateAccessTokenWithAuth: %v", err)
	}
	claims, err := svc.ValidateAccessTokenDetailed(token)
	if err != nil {
		t.Fatalf("ValidateAccessTokenDetailed: %v", err)
	}
	if claims.Subject != "user-9" || claims.AuthLineage != "lin-9" {
		t.Fatalf("unexpected claims: %+v", claims)
	}
	if claims.AuthTimeUnix == nil || *claims.AuthTimeUnix != at.Unix() {
		t.Fatalf("expected auth time %d, got %+v", at.Unix(), claims.AuthTimeUnix)
	}
	// Legacy tokens carry no lineage.
	legacy, err := svc.CreateAccessToken("user-9", "u@example.com")
	if err != nil {
		t.Fatalf("CreateAccessToken: %v", err)
	}
	legacyClaims, err := svc.ValidateAccessTokenDetailed(legacy)
	if err != nil {
		t.Fatalf("legacy validate: %v", err)
	}
	if legacyClaims.AuthLineage != "" || legacyClaims.AuthTimeUnix != nil {
		t.Fatalf("legacy token must not bind lineage: %+v", legacyClaims)
	}
}
