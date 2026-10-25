package apple

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/MicahParks/keyfunc/v3"
	"github.com/golang-jwt/jwt/v5"
)

// Server-to-server notification event types (official
// processing-changes contract). Only consent-revoked changes Shunik session
// state — and even then as sign-out, never deletion. email-enabled/disabled
// are no-ops; account-deleted (permanent deletion of the user's entire Apple
// Account) is explicitly out of scope and a no-op here.
const (
	EventConsentRevoked = "consent-revoked"
	EventEmailEnabled   = "email-enabled"
	EventEmailDisabled  = "email-disabled"
	EventAccountDeleted = "account-deleted"
)

// NotificationEvent is a decoded, validated server-to-server notification.
type NotificationEvent struct {
	// Type is events.type (consent-revoked, email-enabled, ...).
	Type string
	// Sub is events.sub, Apple's stable subject for the affected user.
	Sub string
	// Email is events.email, best-effort (may be absent on later events).
	Email string
	// EventTime is events.event_time (seconds since epoch) when present.
	// Absent means the caller should treat the event as immediate.
	EventTime time.Time
	// HasEventTime reports whether EventTime came from the payload.
	HasEventTime bool
	// JTI is the top-level jti: the unique notification id for replay
	// protection.
	JTI string
}

// flexibleInt unmarshals a JSON number or a quoted numeric string (Apple's
// documented numeric fields occasionally arrive quoted).
type flexibleInt int64

// UnmarshalJSON accepts a JSON number or a quoted/unquoted numeric string.
// Parsing is strict full-string consumption: a quoted "12x", scientific
// 1e3, or fractional 1.5 is rejected rather than prefix-parsed, so a
// malformed event_time can never silently decide a consent cutoff.
func (f *flexibleInt) UnmarshalJSON(data []byte) error {
	s := strings.Trim(string(data), `"`)
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return fmt.Errorf("flexibleInt: unexpected value %q", string(data))
	}
	*f = flexibleInt(v)
	return nil
}

// Ensure flexibleInt satisfies json.Unmarshaler at compile time.
var _ json.Unmarshaler = (*flexibleInt)(nil)

// notificationPayload is the signed JWS body Apple POSTs as {payload: JWS}.
type notificationPayload struct {
	Events struct {
		Type      string      `json:"type"`
		Sub       string      `json:"sub"`
		Email     string      `json:"email"`
		EventTime flexibleInt `json:"event_time"`
		HasTime   bool        `json:"-"`
	} `json:"events"`
	jwt.RegisteredClaims
}

// UnmarshalJSON tracks whether event_time was present (zero is a valid
// epoch, so presence needs its own bit).
func (p *notificationPayload) UnmarshalJSON(data []byte) error {
	type raw notificationPayload
	var r struct {
		raw
		Events struct {
			Type      string       `json:"type"`
			Sub       string       `json:"sub"`
			Email     string       `json:"email"`
			EventTime *flexibleInt `json:"event_time"`
		} `json:"events"`
	}
	if err := json.Unmarshal(data, &r); err != nil {
		return err
	}
	p.Events.Type = r.Events.Type
	p.Events.Sub = r.Events.Sub
	p.Events.Email = r.Events.Email
	if r.Events.EventTime != nil {
		p.Events.EventTime = *r.Events.EventTime
		p.Events.HasTime = true
	}
	p.RegisteredClaims = r.RegisteredClaims
	return nil
}

// Ensure notificationPayload satisfies json.Unmarshaler at compile time.
var _ json.Unmarshaler = (*notificationPayload)(nil)

// NotificationVerifier validates Apple server-to-server notification JWS
// payloads. The fake in tests implements the same surface.
type NotificationVerifier interface {
	VerifyNotification(ctx context.Context, payload string) (NotificationEvent, error)
}

// notificationVerifier validates notification JWS payloads against Apple's
// JWKS. Notifications are ES256-signed; RS256 is also accepted (same JWKS,
// same issuer/audience pinning — the audience check is what binds the
// payload to this relay, not the curve).
type notificationVerifier struct {
	clientID string
	kf       keyfunc.Keyfunc
	leeway   time.Duration
}

// NewNotificationVerifier constructs a verifier sharing the caller's keyfunc
// (one JWKS background refresh per process; see verifier.go for the identity
// twin). clientID must be the app's Bundle ID — the notification aud.
func NewNotificationVerifier(clientID string, kf keyfunc.Keyfunc) NotificationVerifier {
	return &notificationVerifier{clientID: clientID, kf: kf, leeway: 30 * time.Second}
}

// VerifyNotification validates the JWS signature, issuer, audience, issued
// time, and expiry (when the exp claim is present), then extracts the event.
// It never upserts, deletes, or otherwise mutates: dispatch is the handler's
// job. Malformed, misissued, or mis-audienced payloads fail loudly.
func (v *notificationVerifier) VerifyNotification(_ context.Context, payload string) (NotificationEvent, error) {
	if payload == "" {
		return NotificationEvent{}, fmt.Errorf("%w: empty payload", ErrInvalidToken)
	}
	var claims notificationPayload
	_, err := jwt.ParseWithClaims(payload, &claims, v.kf.Keyfunc,
		jwt.WithValidMethods([]string{"ES256", "RS256"}),
		jwt.WithIssuer(appleIssuer),
		jwt.WithAudience(v.clientID),
		jwt.WithIssuedAt(),
		jwt.WithLeeway(v.leeway),
	)
	if err != nil {
		return NotificationEvent{}, fmt.Errorf("%w: %v", ErrInvalidToken, err)
	}
	if claims.Events.Type == "" {
		return NotificationEvent{}, fmt.Errorf("%w: missing events.type", ErrInvalidToken)
	}
	// Sub binds the event to the affected user; without it the event can
	// never be applied, so a user-binding event without a subject is
	// malformed rather than a verified no-op (an empty-sub dispatch would
	// consume the jti receipt with no cutoff applied).
	if claims.Events.Sub == "" {
		return NotificationEvent{}, fmt.Errorf("%w: missing events.sub", ErrInvalidToken)
	}
	// Issued-at is required (replay-window bound); ParseWithClaims checks
	// its freshness when present, this check pins its presence.
	if claims.IssuedAt == nil {
		return NotificationEvent{}, fmt.Errorf("%w: missing iat", ErrInvalidToken)
	}
	ev := NotificationEvent{
		Type:  claims.Events.Type,
		Sub:   claims.Events.Sub,
		Email: claims.Events.Email,
		JTI:   claims.ID,
	}
	if claims.Events.HasTime {
		ev.EventTime = time.Unix(int64(claims.Events.EventTime), 0).UTC()
		ev.HasEventTime = true
	}
	// Expiry is enforced when documented/present rather than assumed:
	// notifications without exp stay valid under the signature + iat checks.
	if claims.ExpiresAt != nil && time.Now().After(claims.ExpiresAt.Add(v.leeway)) {
		return NotificationEvent{}, fmt.Errorf("%w: notification expired", ErrInvalidToken)
	}
	if ev.JTI == "" {
		return NotificationEvent{}, fmt.Errorf("%w: missing jti", ErrInvalidToken)
	}
	return ev, nil
}
