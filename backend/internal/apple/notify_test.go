package apple

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"testing"
	"time"

	"github.com/MicahParks/keyfunc/v3"
	"github.com/golang-jwt/jwt/v5"
)

func testECKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate EC key: %v", err)
	}
	return key
}

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// testJWKS builds a JWKS keyfunc for key with kid.
func testJWKS(t *testing.T, key *ecdsa.PrivateKey, kid string) keyfunc.Keyfunc {
	t.Helper()
	jwks, err := json.Marshal(map[string]any{"keys": []any{map[string]any{
		"kty": "EC", "crv": "P-256", "alg": "ES256", "kid": kid, "use": "sig",
		"x": b64url(key.X.Bytes()), "y": b64url(key.Y.Bytes()),
	}}})
	if err != nil {
		t.Fatalf("marshal jwks: %v", err)
	}
	kf, err := keyfunc.NewJWKSetJSON(jwks)
	if err != nil {
		t.Fatalf("NewJWKSetJSON: %v", err)
	}
	return kf
}

func signNotification(t *testing.T, key *ecdsa.PrivateKey, kid, iss, aud string, iat time.Time, exp *time.Time, events map[string]any, jti string) string {
	t.Helper()
	claims := jwt.MapClaims{
		"iss": iss, "aud": aud, "iat": iat.Unix(), "jti": jti, "events": events,
	}
	if exp != nil {
		claims["exp"] = exp.Unix()
	}
	token := jwt.NewWithClaims(jwt.SigningMethodES256, claims)
	token.Header["kid"] = kid
	signed, err := token.SignedString(key)
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return signed
}

func consentEvents(sub string, eventTime *int64) map[string]any {
	ev := map[string]any{"type": "consent-revoked", "sub": sub}
	if eventTime != nil {
		ev["event_time"] = *eventTime
	}
	return ev
}

func TestVerifyNotification_ConsentRevoked(t *testing.T) {
	key := testECKey(t)
	v := NewNotificationVerifier("com.test.app", testJWKS(t, key, "kid-1"))
	et := time.Now().Add(-time.Minute).Unix()
	payload := signNotification(t, key, "kid-1", appleIssuer, "com.test.app",
		time.Now().Add(-time.Minute), nil, consentEvents("sub-1", &et), "jti-1")

	ev, err := v.VerifyNotification(t.Context(), payload)
	if err != nil {
		t.Fatalf("VerifyNotification: %v", err)
	}
	if ev.Type != EventConsentRevoked || ev.Sub != "sub-1" || ev.JTI != "jti-1" {
		t.Fatalf("unexpected event: %+v", ev)
	}
	if !ev.HasEventTime || ev.EventTime.Unix() != et {
		t.Fatalf("expected event time %d, got %+v", et, ev)
	}
}

func TestVerifyNotification_Rejects(t *testing.T) {
	key := testECKey(t)
	other := testECKey(t)
	v := NewNotificationVerifier("com.test.app", testJWKS(t, key, "kid-1"))
	now := time.Now()

	cases := map[string]func() string{
		"wrong audience": func() string {
			return signNotification(t, key, "kid-1", appleIssuer, "com.evil.app", now, nil, consentEvents("s", nil), "j1")
		},
		"wrong issuer": func() string {
			return signNotification(t, key, "kid-1", "https://evil.example", "com.test.app", now, nil, consentEvents("s", nil), "j1")
		},
		"wrong key": func() string {
			return signNotification(t, other, "kid-1", appleIssuer, "com.test.app", now, nil, consentEvents("s", nil), "j1")
		},
		"missing type": func() string {
			return signNotification(t, key, "kid-1", appleIssuer, "com.test.app", now, nil, map[string]any{"sub": "s"}, "j1")
		},
		"missing jti": func() string {
			return signNotification(t, key, "kid-1", appleIssuer, "com.test.app", now, nil, consentEvents("s", nil), "")
		},
		"expired": func() string {
			exp := now.Add(-time.Hour)
			return signNotification(t, key, "kid-1", appleIssuer, "com.test.app", now.Add(-2*time.Hour), &exp, consentEvents("s", nil), "j1")
		},
		"garbage": func() string { return "not-a-jwt" },
		"empty":   func() string { return "" },
	}
	for name, make := range cases {
		if _, err := v.VerifyNotification(t.Context(), make()); err == nil {
			t.Errorf("%s: expected error, got nil", name)
		}
	}
}

func TestVerifyNotification_StringEventTime(t *testing.T) {
	key := testECKey(t)
	v := NewNotificationVerifier("com.test.app", testJWKS(t, key, "kid-1"))
	et := time.Now().Add(-time.Minute).Unix()
	// Apple occasionally delivers numeric fields quoted.
	claims := jwt.MapClaims{
		"iss": appleIssuer, "aud": "com.test.app", "iat": time.Now().Add(-time.Minute).Unix(),
		"jti": "jti-q",
		"events": map[string]any{
			"type": "consent-revoked", "sub": "sub-q",
			"event_time": json.Number(big.NewInt(et).String()),
		},
	}
	token := jwt.NewWithClaims(jwt.SigningMethodES256, claims)
	token.Header["kid"] = "kid-1"
	signed, err := token.SignedString(key)
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	ev, err := v.VerifyNotification(t.Context(), signed)
	if err != nil {
		t.Fatalf("VerifyNotification: %v", err)
	}
	if !ev.HasEventTime || ev.EventTime.Unix() != et {
		t.Fatalf("expected quoted event time %d, got %+v", et, ev)
	}
}

func TestFlexibleInt_StrictConsumption(t *testing.T) {
	for _, ok := range []string{`123`, `"123"`, `0`, `-5`} {
		var f flexibleInt
		if err := json.Unmarshal([]byte(ok), &f); err != nil {
			t.Errorf("%s: expected accept, got %v", ok, err)
		}
	}
	// Prefix-parse traps: Sscanf %d would accept 12, 1, 1 from these.
	for _, bad := range []string{`"12x"`, `1e3`, `1.5`, `"1.5"`, `""`, `"  "`, `12x`} {
		var f flexibleInt
		if err := json.Unmarshal([]byte(bad), &f); err == nil {
			t.Errorf("%s: expected reject, got %d", bad, f)
		}
	}
}

func TestVerifyNotification_MissingSub(t *testing.T) {
	key := testECKey(t)
	v := NewNotificationVerifier("com.test.app", testJWKS(t, key, "kid-1"))
	payload := signNotification(t, key, "kid-1", appleIssuer, "com.test.app",
		time.Now().Add(-time.Minute), nil, map[string]any{"type": "consent-revoked"}, "jti-nosub")
	if _, err := v.VerifyNotification(t.Context(), payload); err == nil {
		t.Error("missing events.sub: expected error, got nil")
	}
}
