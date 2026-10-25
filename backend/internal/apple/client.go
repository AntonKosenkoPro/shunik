// Package apple verifies Sign in with Apple identity tokens and speaks the
// Sign in with Apple REST API (token exchange, token revocation, and
// server-to-server notifications) for explicit account deletion with
// automatic unlinking.
//
// Official references (reconfirmed 2026-10-21 via developer.apple.com):
//   - TN3194 (rev 2025-10-03): /auth/revoke is the only programmatic
//     invalidation; it needs a valid refresh or access token. Flow: transmit
//     identity token + authorization code, verify the identity token,
//     validate the code via /auth/token, store the token response.
//   - generate-and-validate-tokens: POST https://appleid.apple.com/auth/token,
//     form-urlencoded, client_id + client_secret (ES256 JWT) + code (single
//     use, 5 min) + grant_type=authorization_code / refresh_token.
//   - revoke-tokens: POST https://appleid.apple.com/auth/revoke,
//     form-urlencoded, client_id + client_secret + token +
//     token_type_hint; 200 with an empty body acknowledges (including
//     already-invalid tokens).
//   - processing-changes: server-to-server notifications arrive as
//     {"payload": <JWS>}; validate the JWS signature with Apple's public key
//     (algorithm from the header), then dispatch on events.type
//     (consent-revoked, email-enabled/disabled, account-deleted).
package apple

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// appleAPI is the production Sign in with Apple REST endpoint base.
const appleAPIBase = "https://appleid.apple.com"

// ErrInvalidGrant is returned when Apple rejects an authorization code or
// token (HTTP 400): the presented credential is consumed, unknown, or
// expired. Callers map it to an authentication failure, not a service error.
var ErrInvalidGrant = errors.New("apple rejected the authorization code or token")

// ErrAppleUnavailable is returned on transport failures and non-400 Apple
// responses. Callers map it to a retryable service failure.
var ErrAppleUnavailable = errors.New("apple service unavailable")

// ParsePrivateKey decodes a PEM-encoded PKCS#8 Sign in with Apple private
// key (.p8) and requires ECDSA P-256 (the only curve Apple accepts for
// client secrets). The input may carry literal "\n" escapes (single-quoted
// env rendering) or real newlines. The key material never leaves the server.
func ParsePrivateKey(pemData []byte) (*ecdsa.PrivateKey, error) {
	s := strings.TrimSpace(string(pemData))
	if s == "" {
		return nil, errors.New("apple private key is empty")
	}
	if !strings.Contains(s, "\n") && strings.Contains(s, `\n`) {
		s = strings.ReplaceAll(s, `\n`, "\n")
	}
	block, _ := pem.Decode([]byte(s))
	if block == nil {
		return nil, errors.New("apple private key is not valid PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse apple private key: %w", err)
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("apple private key must be ECDSA, got %T", parsed)
	}
	if key.Curve != elliptic.P256() {
		return nil, errors.New("apple private key must be ECDSA P-256")
	}
	return key, nil
}

// TokenResponse is the decoded Apple /auth/token response. Only the refresh
// token is retained server-side (sealed); the rest is verified and dropped.
type TokenResponse struct {
	AccessToken  string `json:"access_token"`
	TokenType    string `json:"token_type"`
	ExpiresIn    int    `json:"expires_in"`
	RefreshToken string `json:"refresh_token"`
	IDToken      string `json:"id_token"`
}

// Client exchanges authorization codes and revokes Apple tokens. The fake in
// tests implements the same surface; production uses RESTClient.
type Client interface {
	ExchangeCode(ctx context.Context, code string) (TokenResponse, error)
	RevokeToken(ctx context.Context, refreshToken string) error
}

// RESTClient is the production Apple REST client.
type RESTClient struct {
	clientID    string
	teamID      string
	keyID       string
	privateKey  *ecdsa.PrivateKey
	baseURL     string
	redirectURI string
	http        *http.Client
	now         func() time.Time
}

// NewRESTClient builds the production client. baseURL is
// https://appleid.apple.com in production and a fake-server URL in tests;
// redirectURI is sent only when non-empty and must match the URI used in the
// native authorization request, if any.
func NewRESTClient(clientID, teamID, keyID string, privateKey *ecdsa.PrivateKey, baseURL, redirectURI string, httpClient *http.Client) *RESTClient {
	if baseURL == "" {
		baseURL = appleAPIBase
	}
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 10 * time.Second}
	}
	return &RESTClient{
		clientID:    clientID,
		teamID:      teamID,
		keyID:       keyID,
		privateKey:  privateKey,
		baseURL:     strings.TrimSuffix(baseURL, "/"),
		redirectURI: redirectURI,
		http:        httpClient,
		now:         time.Now,
	}
}

// clientSecret builds the ES256 client-secret JWT: iss=team, sub=client,
// aud=appleid, short expiry, kid=key id. Minted per request (no caching, no
// persistence) so no rotation or storage machinery is needed.
func (c *RESTClient) clientSecret() (string, error) {
	now := c.now()
	claims := jwt.RegisteredClaims{
		Issuer:    c.teamID,
		Subject:   c.clientID,
		Audience:  jwt.ClaimStrings{appleIssuer},
		IssuedAt:  jwt.NewNumericDate(now),
		ExpiresAt: jwt.NewNumericDate(now.Add(5 * time.Minute)),
	}
	token := jwt.NewWithClaims(jwt.SigningMethodES256, claims)
	token.Header["kid"] = c.keyID
	signed, err := token.SignedString(c.privateKey)
	if err != nil {
		return "", fmt.Errorf("sign apple client secret: %w", err)
	}
	return signed, nil
}

// ExchangeCode validates a single-use authorization code with Apple's
// /auth/token endpoint and returns the token response. An Apple 400 maps to
// ErrInvalidGrant (authentication failure); anything else maps to
// ErrAppleUnavailable (retryable service failure).
func (c *RESTClient) ExchangeCode(ctx context.Context, code string) (TokenResponse, error) {
	secret, err := c.clientSecret()
	if err != nil {
		return TokenResponse{}, fmt.Errorf("%w: %v", ErrAppleUnavailable, err)
	}
	form := url.Values{
		"client_id":     {c.clientID},
		"client_secret": {secret},
		"code":          {code},
		"grant_type":    {"authorization_code"},
	}
	if c.redirectURI != "" {
		form.Set("redirect_uri", c.redirectURI)
	}
	var out TokenResponse
	if err := c.postForm(ctx, "/auth/token", form, &out); err != nil {
		return TokenResponse{}, err
	}
	if out.RefreshToken == "" {
		return TokenResponse{}, fmt.Errorf("%w: token response carried no refresh token", ErrInvalidGrant)
	}
	return out, nil
}

// RevokeToken invalidates an Apple refresh token via /auth/revoke. Apple's
// documented success (HTTP 200, empty body) includes already-invalid tokens.
func (c *RESTClient) RevokeToken(ctx context.Context, refreshToken string) error {
	secret, err := c.clientSecret()
	if err != nil {
		return fmt.Errorf("%w: %v", ErrAppleUnavailable, err)
	}
	form := url.Values{
		"client_id":       {c.clientID},
		"client_secret":   {secret},
		"token":           {refreshToken},
		"token_type_hint": {"refresh_token"},
	}
	return c.postForm(ctx, "/auth/revoke", form, nil)
}

// postForm performs one form-encoded Apple request. A 400 response maps to
// ErrInvalidGrant (with Apple's error body for operators); any other
// non-200 maps to ErrAppleUnavailable. Response bodies are drained and never
// logged (they may echo tokens).
func (c *RESTClient) postForm(ctx context.Context, path string, form url.Values, out *TokenResponse) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+path, strings.NewReader(form.Encode()))
	if err != nil {
		return fmt.Errorf("%w: %v", ErrAppleUnavailable, err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrAppleUnavailable, err)
	}
	defer func() {
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
	}()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if err != nil {
		return fmt.Errorf("%w: %v", ErrAppleUnavailable, err)
	}
	if resp.StatusCode == http.StatusBadRequest {
		return fmt.Errorf("%w: apple responded 400: %s", ErrInvalidGrant, appleErrorCode(body))
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%w: apple responded %d", ErrAppleUnavailable, resp.StatusCode)
	}
	if out != nil {
		if err := json.Unmarshal(body, out); err != nil {
			return fmt.Errorf("%w: decode token response: %v", ErrAppleUnavailable, err)
		}
	}
	return nil
}

// appleErrorCode extracts Apple's machine-readable error code from a 400
// body, allowlisted to the documented token/revoke set. Anything else —
// including bodies that echo request material (tokens, codes) — maps to a
// fixed placeholder. Error strings from this client are logged by handlers
// and persisted into revocation-job last_error, so they must never carry
// Apple response bytes that might echo secrets.
func appleErrorCode(body []byte) string {
	var v struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(body, &v); err != nil {
		return "invalid_request"
	}
	switch v.Error {
	case "invalid_request", "invalid_client", "invalid_grant",
		"unauthorized_client", "unsupported_grant_type", "invalid_scope":
		return v.Error
	default:
		return "invalid_request"
	}
}

// SubjectDigestKey derives the rotation-stable purpose-separated HMAC key
// for Apple subject digests from the account-status secret. Token-encryption
// keys rotate by prepending, which would change digests keyed by the primary
// token key and silently break the signup fence; deriving from the stable
// status secret (itself rotation-gated by outstanding status evidence)
// keeps digests stable across APPLE_TOKEN_KEYS rotation. Operational rule:
// rotate ACCOUNT_STATUS_SECRET only after the revocation job table drains.
func SubjectDigestKey(statusSecret []byte) []byte {
	mac := hmac.New(sha256.New, statusSecret)
	mac.Write([]byte("shunik/v1/apple-subject-digest-key"))
	return mac.Sum(nil)
}

// SubjectDigest returns the hex HMAC-SHA256 of an Apple subject under the
// purpose-separated digest key. The digest indexes revocation jobs and
// fences signups without ever retaining the subject itself.
func SubjectDigest(digestKey []byte, subject string) string {
	mac := hmac.New(sha256.New, digestKey)
	mac.Write([]byte("shunik/v1/apple-revocation-subject\x00"))
	mac.Write([]byte(subject))
	return hex.EncodeToString(mac.Sum(nil))
}

// VaultAAD builds the domain-bound associated data sealing a stored Apple
// refresh credential: purpose prefix plus (lineage, auth time). The lineage
// is 128-bit random per authorization, so a blob cannot move across
// lineages; no account identifier enters the AAD, and the revocation worker
// reconstructs exactly this tuple from the job row (which carries the same
// lineage + time copied at purge). The leading domain makes cross-use with
// refresh-recovery receipts impossible.
func VaultAAD(lineageID string, authTime time.Time) []byte {
	aad := []byte("shunik-apple-vault\x00")
	aad = append(aad, lineageID...)
	aad = append(aad, 0)
	aad = append(aad, authTime.UTC().Format(time.RFC3339)...)
	return aad
}

// RetryAfter returns the worker backoff after a failed revoke attempt:
// 1m * 2^(attempts-1) capped at one hour. Never drops unresolved work; the
// >24h / high-attempt alert is the worker's escalation path.
func RetryAfter(attempts int) time.Duration {
	if attempts < 1 {
		attempts = 1
	}
	d := time.Duration(1<<uint(attempts-1)) * time.Minute
	if d > time.Hour || d <= 0 {
		return time.Hour
	}
	return d
}
