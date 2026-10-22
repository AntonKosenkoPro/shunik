package auth

import (
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Account-status credential contract (explicit account deletion evidence):
// a narrow HS256 bearer whose ONLY authority is asking whether the immutable
// account UUID in its subject still exists. It is issued on successful
// sign-in/refresh alongside the normal session, stored in a separate
// Keychain item, and accepted solely by POST /auth/account/status. It can
// never authenticate sync, refresh, logout, deletion, or another account,
// and status requests never renew it.
const (
	// StatusIssuer pins the credential origin.
	StatusIssuer = "lifio"
	// StatusAudience pins the credential audience.
	StatusAudience = "account-status"
	// StatusPurpose pins the credential purpose, enforced separately from
	// the access-token claims so cross-acceptance is impossible.
	StatusPurpose = "account-status"
	// StatusTTL is the fixed 30-day evidence lifetime. Devices offline
	// beyond expiry keep their files (lock-not-wipe); no relaxed checks.
	StatusTTL = 30 * 24 * time.Hour
)

// ErrInvalidStatusToken is returned when an account-status credential fails
// validation. Handlers surface it as a generic 401 unauthorized with no
// existence disclosure.
var ErrInvalidStatusToken = errors.New("invalid account status credential")

// StatusClaims is the account-status credential claim set. No email claim
// (the credential must not carry identity beyond the UUID), short fixed
// fields, exact subject echo on the status endpoint.
type StatusClaims struct {
	Purpose string `json:"purpose"`
	jwt.RegisteredClaims
}

// StatusService mints and validates account-status credentials under a
// dedicated signing key that MUST differ from the access-token JWT secret
// (config preflight enforces this).
type StatusService struct {
	secret []byte
}

// NewStatusService creates a StatusService. An empty secret fails closed at
// first use rather than minting unverifiable credentials.
func NewStatusService(secret string) *StatusService {
	return &StatusService{secret: []byte(secret)}
}

// Mint issues a status credential for userID, valid for StatusTTL from now.
// It also returns the exact expiry for the account_status_expires_at wire
// field so clients can stop retrying at expiry instead of polling forever.
func (s *StatusService) Mint(userID string) (token string, expiresAt time.Time, err error) {
	if len(s.secret) == 0 {
		return "", time.Time{}, fmt.Errorf("mint status credential: %w", ErrInvalidStatusToken)
	}
	now := time.Now()
	expiresAt = now.Add(StatusTTL)
	claims := StatusClaims{
		Purpose: StatusPurpose,
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    StatusIssuer,
			Audience:  jwt.ClaimStrings{StatusAudience},
			Subject:   userID,
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(expiresAt),
		},
	}
	signed, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(s.secret)
	if err != nil {
		return "", time.Time{}, fmt.Errorf("mint status credential: %w", err)
	}
	return signed, expiresAt, nil
}

// Validate parses and validates a status credential, returning the verified
// subject UUID. It pins the algorithm, issuer, audience, purpose, and
// expiry; an access token (different claims shape/secret) can never pass,
// and a status credential can never pass access-token validation.
func (s *StatusService) Validate(tokenStr string) (string, error) {
	if len(s.secret) == 0 {
		return "", ErrInvalidStatusToken
	}
	var claims StatusClaims
	token, err := jwt.ParseWithClaims(tokenStr, &claims, func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
		}
		return s.secret, nil
	},
		jwt.WithValidMethods([]string{"HS256"}),
		jwt.WithIssuer(StatusIssuer),
		jwt.WithAudience(StatusAudience),
		jwt.WithExpirationRequired(),
	)
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrInvalidStatusToken, err)
	}
	got, ok := token.Claims.(*StatusClaims)
	if !ok || !token.Valid {
		return "", ErrInvalidStatusToken
	}
	if got.Purpose != StatusPurpose {
		return "", ErrInvalidStatusToken
	}
	if got.Subject == "" {
		return "", ErrInvalidStatusToken
	}
	return got.Subject, nil
}
