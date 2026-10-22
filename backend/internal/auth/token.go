// Package auth provides JWT access token and OTP code services.
package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// TokenService handles JWT access tokens and opaque refresh tokens.
type TokenService struct {
	jwtSecret       []byte
	accessTokenTTL  time.Duration
	RefreshTokenTTL time.Duration
}

// NewTokenService creates a new TokenService.
func NewTokenService(jwtSecret string, accessTokenTTL, refreshTokenTTL time.Duration) *TokenService {
	return &TokenService{
		jwtSecret:       []byte(jwtSecret),
		accessTokenTTL:  accessTokenTTL,
		RefreshTokenTTL: refreshTokenTTL,
	}
}

// AccessTokenClaims represents the JWT claims for an access token.
// AuthLineage/AuthTimeUnix bind Apple sessions to the authorization lineage
// that issued them (empty/zero = email-OTP or pre-lineage session). The
// middleware enforces them against a set Apple consent cutoff; they are
// never consulted when no cutoff exists.
type AccessTokenClaims struct {
	Email        string `json:"email"`
	AuthLineage  string `json:"auth_lineage,omitempty"`
	AuthTimeUnix *int64 `json:"auth_time,omitempty"`
	jwt.RegisteredClaims
}

// CreateAccessToken creates a signed JWT access token for the given user.
func (s *TokenService) CreateAccessToken(userID, email string) (string, error) {
	return s.CreateAccessTokenWithAuth(userID, email, time.Time{}, "")
}

// CreateAccessTokenWithAuth creates an access token bound to the Apple
// authorization lineage that issued the session (authTime/authLineage empty
// for email-OTP sessions, which fail closed under a set Apple consent
// cutoff — see VerifyOTP's cutoff fence).
func (s *TokenService) CreateAccessTokenWithAuth(userID, email string, authTime time.Time, authLineage string) (string, error) {
	now := time.Now()
	claims := AccessTokenClaims{
		Email: email,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   userID,
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(s.accessTokenTTL)),
		},
	}
	if authLineage != "" {
		claims.AuthLineage = authLineage
		unix := authTime.Unix()
		claims.AuthTimeUnix = &unix
	}

	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	signed, err := token.SignedString(s.jwtSecret)
	if err != nil {
		return "", fmt.Errorf("sign access token: %w", err)
	}
	return signed, nil
}

// ValidateAccessToken validates a JWT access token string and returns the
// userID and email embedded in its claims.
func (s *TokenService) ValidateAccessToken(tokenStr string) (userID, email string, err error) {
	claims, err := s.ValidateAccessTokenDetailed(tokenStr)
	if err != nil {
		return "", "", err
	}
	return claims.Subject, claims.Email, nil
}

// ValidateAccessTokenDetailed validates an access token and returns its full
// claims, including the Apple auth lineage binding enforced against a set
// consent cutoff. A status credential (different issuer/audience/purpose
// shape) can never pass here: the payload is sniffed for the status-only
// `purpose` claim before signature verification, so cross-acceptance fails
// even if both secrets ever coincided.
func (s *TokenService) ValidateAccessTokenDetailed(tokenStr string) (*AccessTokenClaims, error) {
	if hasStatusPurpose(tokenStr) {
		return nil, fmt.Errorf("parse access token: status credential is not an access token")
	}
	token, err := jwt.ParseWithClaims(tokenStr, &AccessTokenClaims{}, func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
		}
		return s.jwtSecret, nil
	},
		jwt.WithValidMethods([]string{"HS256"}),
		jwt.WithExpirationRequired(),
	)
	if err != nil {
		return nil, fmt.Errorf("parse access token: %w", err)
	}

	claims, ok := token.Claims.(*AccessTokenClaims)
	if !ok || !token.Valid {
		return nil, fmt.Errorf("invalid access token claims")
	}
	// Required-claim check per jwt/v5 guidance: a token without a subject
	// authorizes nothing, even if the signature verifies.
	if claims.Subject == "" {
		return nil, fmt.Errorf("invalid access token claims: missing subject")
	}

	return claims, nil
}

// hasStatusPurpose reports whether a JWT payload carries the status-only
// `purpose` claim. The check runs before signature verification and only
// gates which validator may accept the token — it discloses nothing.
func hasStatusPurpose(tokenStr string) bool {
	parts := strings.Split(tokenStr, ".")
	if len(parts) != 3 {
		return false
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return false
	}
	var claims map[string]any
	if err := json.Unmarshal(payload, &claims); err != nil {
		return false
	}
	_, ok := claims["purpose"]
	return ok
}

// GenerateRefreshToken creates a new opaque refresh token.
// It returns the raw token (to give to the client) and its SHA-256 hash
// (to store in the database).
func (s *TokenService) GenerateRefreshToken() (rawToken, hash string, err error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", "", fmt.Errorf("generate refresh token: %w", err)
	}
	rawToken = hex.EncodeToString(b)
	hash = HashToken(rawToken)
	return rawToken, hash, nil
}

// HashToken returns the SHA-256 hex digest of the given token string.
func HashToken(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}
