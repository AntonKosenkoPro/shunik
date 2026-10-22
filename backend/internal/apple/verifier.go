// Package apple verifies Sign in with Apple identity tokens.
//
// Apple's identity token is a JWT signed with RS256 (RSA). Verification fetches
// Apple's public keys from its JWKS endpoint, checks the signature, and
// validates the issuer, audience (the app's Bundle ID for a native iOS app),
// and expiry. The stable user identifier is the `sub` claim; `email` is only
// guaranteed on the first authorization and is treated as a best-effort bonus.
package apple

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/MicahParks/keyfunc/v3"
	"github.com/golang-jwt/jwt/v5"
)

// appleIssuer is the issuer claim Apple puts in its identity tokens.
const appleIssuer = "https://appleid.apple.com"

// Claims holds the Apple identity-token claims we consume.
type Claims struct {
	Sub           string       `json:"sub"`
	Email         string       `json:"email"`
	EmailVerified flexibleBool `json:"email_verified"`
	jwt.RegisteredClaims
}

// IsEmailVerified reports whether Apple verified the user's email. Apple sends
// `email_verified` as a JSON boolean or the string "true"/"false" on the wire.
func (c Claims) IsEmailVerified() bool { return bool(c.EmailVerified) }

// flexibleBool unmarshals a JSON bool or the string "true"/"false" (Apple's
// documented "Boolean" is delivered as a string on the wire).
type flexibleBool bool

// UnmarshalJSON accepts a JSON bool, a quoted/unquoted "true"/"false"
// (and "1"/"0"), or null (absent field → false). Any other shape is an
// error rather than a silent false, so unexpected Apple payloads fail
// verification loudly instead of downgrading email trust.
func (b *flexibleBool) UnmarshalJSON(data []byte) error {
	s := strings.TrimSpace(strings.Trim(string(data), `"`))
	switch s {
	case "true", "1":
		*b = true
		return nil
	case "false", "0", "null":
		*b = false
		return nil
	default:
		return fmt.Errorf("flexibleBool: unexpected value %q", string(data))
	}
}

// ErrInvalidToken is returned when an identity token fails verification.
var ErrInvalidToken = errors.New("invalid apple identity token")

// Verifier verifies Apple identity tokens and returns their claims.
type Verifier interface {
	Verify(ctx context.Context, identityToken string) (Claims, error)
}

// keyfuncVerifier verifies tokens against Apple's JWKS via keyfunc.
type keyfuncVerifier struct {
	clientID string
	kf       keyfunc.Keyfunc
	leeway   time.Duration
}

// NewVerifier constructs a Verifier that fetches Apple's public keys from
// jwksURL and validates tokens for the given clientID (the app's Bundle ID).
// The background refresh goroutine lives for the lifetime of the returned
// verifier; pass a context that outlives the server.
func NewVerifier(ctx context.Context, clientID, jwksURL string) (Verifier, error) {
	if clientID == "" {
		return nil, errors.New("apple client ID is required")
	}
	kf, err := keyfunc.NewDefaultCtx(ctx, []string{jwksURL})
	if err != nil {
		return nil, fmt.Errorf("create apple JWKS keyfunc: %w", err)
	}
	return NewIdentityVerifier(clientID, kf), nil
}

// NewSharedKeyfunc fetches Apple's public keys once and refreshes them in
// the background. One instance serves both the identity-token and the
// notification verifiers so the process runs a single JWKS refresh loop.
func NewSharedKeyfunc(ctx context.Context, jwksURL string) (keyfunc.Keyfunc, error) {
	kf, err := keyfunc.NewDefaultCtx(ctx, []string{jwksURL})
	if err != nil {
		return nil, fmt.Errorf("create apple JWKS keyfunc: %w", err)
	}
	return kf, nil
}

// NewIdentityVerifier validates identity tokens against an existing JWKS
// keyfunc (see NewSharedKeyfunc).
func NewIdentityVerifier(clientID string, kf keyfunc.Keyfunc) Verifier {
	return &keyfuncVerifier{clientID: clientID, kf: kf, leeway: 30 * time.Second}
}

// Verify validates the identity token and returns its claims.
func (v *keyfuncVerifier) Verify(_ context.Context, identityToken string) (Claims, error) {
	if identityToken == "" {
		return Claims{}, ErrInvalidToken
	}
	var claims Claims
	_, err := jwt.ParseWithClaims(identityToken, &claims, v.kf.Keyfunc,
		jwt.WithValidMethods([]string{"RS256"}),
		jwt.WithIssuer(appleIssuer),
		jwt.WithAudience(v.clientID),
		jwt.WithExpirationRequired(),
		jwt.WithLeeway(v.leeway),
	)
	if err != nil {
		return Claims{}, fmt.Errorf("%w: %v", ErrInvalidToken, err)
	}
	if claims.Sub == "" {
		return Claims{}, ErrInvalidToken
	}
	return claims, nil
}

// ensure flexibleBool satisfies json.Unmarshaler at compile time.
var _ json.Unmarshaler = (*flexibleBool)(nil)
