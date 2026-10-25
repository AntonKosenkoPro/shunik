// Package contract holds executable contract fixtures: tests that pin the
// OpenAPI spec (backend/api/openapi.yaml) to the invariants the API contract
// promises (R-003/R-006 — OpenAPI is authoritative, S10). Any drift between
// the spec and the documented contract fails here.
package contract

import (
	"os"
	"path/filepath"
	"testing"

	"gopkg.in/yaml.v3"
)

// canonicalErrorCodes is the set of error codes the API contract defines.
// The spec must document exactly these and no others.
var canonicalErrorCodes = []string{
	"invalid_body",
	"invalid_request",
	"internal_error",
	"rate_limited",
	"invalid_otp",
	"otp_expired",
	"otp_attempts_exceeded",
	"invalid_apple_token",
	"apple_not_configured",
	"apple_unavailable",
	"apple_credential_required",
	"apple_revocation_pending",
	"apple_email_in_use",
	"invalid_notification",
	"invalid_refresh",
	"token_reuse",
	"refresh_expired",
	"refresh_attempt_completed",
	"refresh_attempt_conflict",
	"household_not_found",
	"invite_not_found",
	"already_member",
	"unauthorized",
}

// bearerProtectedPaths are the paths whose operations must require BearerAuth
// and document a 401 response.
var bearerProtectedPaths = []string{
	"/api/v1/auth/logout",
	"/api/v1/auth/me",
	"/api/v1/auth/account",
	"/api/v1/auth/apple/deletion-credential",
	"/api/v1/households/mine",
	"/api/v1/households/invites",
	"/api/v1/households/invites/accept",
	"/api/v1/households/members",
}

type rawSpec struct {
	OpenAPI    string             `yaml:"openapi"`
	Info       rawInfo            `yaml:"info"`
	Paths      map[string]rawPath `yaml:"paths"`
	Components rawComponents      `yaml:"components"`
	Security   []map[string]any   `yaml:"security"`
}

type rawInfo struct {
	Version string `yaml:"version"`
}

type rawPath map[string]rawOperation

type rawOperation struct {
	OperationID string                 `yaml:"operationId"`
	Security    []map[string]any       `yaml:"security"`
	Parameters  []rawParameter         `yaml:"parameters"`
	Responses   map[string]rawResponse `yaml:"responses"`
}

type rawParameter struct {
	Ref    string         `yaml:"$ref"`
	Name   string         `yaml:"name"`
	Schema rawParamSchema `yaml:"schema"`
}

type rawParamSchema struct {
	Minimum *int `yaml:"minimum"`
	Maximum *int `yaml:"maximum"`
	Default int  `yaml:"default"`
}

type rawResponse struct {
	Ref         string                  `yaml:"$ref"`
	Description string                  `yaml:"description"`
	Content     map[string]rawMediaType `yaml:"content"`
}

type rawMediaType struct {
	Schema   rawSchema      `yaml:"schema"`
	Example  map[string]any `yaml:"example"`
	Examples map[string]any `yaml:"examples"`
}

type rawSchema struct {
	Ref string `yaml:"$ref"`
}

type rawComponents struct {
	Responses       map[string]rawResponse  `yaml:"responses"`
	Schemas         map[string]rawSchemaDef `yaml:"schemas"`
	Parameters      map[string]rawParameter `yaml:"parameters"`
	SecuritySchemes map[string]any          `yaml:"securitySchemes"`
}

type rawSchemaDef struct {
	Properties map[string]any `yaml:"properties"`
	Enum       []any          `yaml:"enum"`
	Required   []any          `yaml:"required"`
}

func loadSpec(t *testing.T) *rawSpec {
	t.Helper()
	path := filepath.Join("..", "..", "api", "openapi.yaml")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var s rawSpec
	if err := yaml.Unmarshal(data, &s); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	return &s
}

// documentedCodes walks every example in the spec (operation and shared
// component responses) and returns the error codes it documents.
func documentedCodes(s *rawSpec) map[string]bool {
	codes := map[string]bool{}
	collect := func(resp rawResponse) {
		for _, mt := range resp.Content {
			if code, ok := mt.Example["error"].(map[string]any); ok {
				if c, ok := code["code"].(string); ok && c != "" {
					codes[c] = true
				}
			}
			for _, ex := range mt.Examples {
				exMap, ok := ex.(map[string]any)
				if !ok {
					continue
				}
				value, ok := exMap["value"].(map[string]any)
				if !ok {
					continue
				}
				errObj, ok := value["error"].(map[string]any)
				if !ok {
					continue
				}
				if c, ok := errObj["code"].(string); ok && c != "" {
					codes[c] = true
				}
			}
		}
	}
	for _, path := range s.Paths {
		for _, op := range path {
			for _, resp := range op.Responses {
				collect(resp)
			}
		}
	}
	for _, resp := range s.Components.Responses {
		collect(resp)
	}
	return codes
}

func requiresAuth(op rawOperation) bool {
	for _, sec := range op.Security {
		if _, ok := sec["BearerAuth"]; ok {
			return true
		}
	}
	return false
}

func TestSpec_IsValidOpenAPI(t *testing.T) {
	s := loadSpec(t)
	if s.OpenAPI != "3.0.3" {
		t.Errorf("expected openapi 3.0.3, got %q", s.OpenAPI)
	}
	if s.Info.Version == "" {
		t.Error("info.version must be set")
	}
}

func TestSpec_DocumentsExactlyCanonicalErrorCodes(t *testing.T) {
	s := loadSpec(t)
	codes := documentedCodes(s)

	for _, want := range canonicalErrorCodes {
		if !codes[want] {
			t.Errorf("spec does not document error code %q", want)
		}
	}
	for got := range codes {
		found := false
		for _, want := range canonicalErrorCodes {
			if got == want {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("spec documents undocumented error code %q — add it to canonicalErrorCodes and AGENTS.md", got)
		}
	}
}

func TestSpec_BearerProtectedPathsRequireAuthAnd401(t *testing.T) {
	s := loadSpec(t)
	for _, path := range bearerProtectedPaths {
		ops, ok := s.Paths[path]
		if !ok {
			t.Errorf("expected path %s to be documented", path)
			continue
		}
		for method, op := range ops {
			if !requiresAuth(op) {
				t.Errorf("%s %s must require BearerAuth", method, path)
			}
			if _, ok := op.Responses["401"]; !ok {
				t.Errorf("%s %s must document a 401 response", method, path)
			}
		}
	}
}

func TestSpec_ErrorResponsesUseEnvelope(t *testing.T) {
	s := loadSpec(t)
	check := func(resp rawResponse, where string) {
		for status, mt := range resp.Content {
			if status == "204" {
				continue
			}
			if mt.Schema.Ref != "#/components/schemas/ErrorResponse" {
				t.Errorf("%s must reference ErrorResponse schema, got %q", where, mt.Schema.Ref)
			}
		}
	}
	for _, path := range s.Paths {
		for method, op := range path {
			for status, resp := range op.Responses {
				if resp.Ref != "" {
					continue
				}
				if status[0] == '2' {
					continue
				}
				check(resp, method+" "+status)
			}
		}
	}
}

func TestSpec_RefreshAttemptDocumented(t *testing.T) {
	s := loadSpec(t)
	refresh, ok := s.Components.Schemas["RefreshRequest"]
	if !ok {
		t.Fatal("expected RefreshRequest schema")
	}
	if _, ok := refresh.Properties["refresh_token"]; !ok {
		t.Error("RefreshRequest schema must document refresh_token")
	}
	if _, ok := refresh.Properties["refresh_attempt_id"]; !ok {
		t.Error("RefreshRequest schema must document the optional refresh_attempt_id")
	}
	// refresh_attempt_id must stay optional: promoting it to required
	// would break legacy clients, which keep working without recovery.
	for _, name := range refresh.Required {
		if s, _ := name.(string); s == "refresh_attempt_id" {
			t.Error("refresh_attempt_id must not become required (absent keeps legacy behavior)")
		}
	}

	post, ok := s.Paths["/api/v1/auth/refresh"]["post"]
	if !ok {
		t.Fatal("expected POST /api/v1/auth/refresh")
	}
	for _, want := range []string{"200", "401", "409", "500"} {
		if _, ok := post.Responses[want]; !ok {
			t.Errorf("POST /api/v1/auth/refresh must document %s", want)
		}
	}
}

// Explicit account deletion (add-account-deletion): DELETE /auth/account is
// self-only (no request-selected user), returns 204 on completion and 202
// with explicit account_deleted + apple_revocation_pending on committed
// purge with pending Apple unlink, distinguishes 409
// apple_credential_required from 503 apple_not_configured, and documents the
// rate-limited, no-store, non-renewing status endpoint plus the verified
// notification endpoint. Each response is pinned here with the implementation.
func TestSpec_AccountDeletionDocumented(t *testing.T) {
	s := loadSpec(t)

	del, ok := s.Paths["/api/v1/auth/account"]["delete"]
	if !ok {
		t.Fatal("expected DELETE /api/v1/auth/account")
	}
	if !requiresAuth(del) {
		t.Error("DELETE /api/v1/auth/account must require BearerAuth")
	}
	for _, want := range []string{"204", "202", "400", "401", "409", "503", "500"} {
		if _, ok := del.Responses[want]; !ok {
			t.Errorf("DELETE /api/v1/auth/account must document %s", want)
		}
	}
	foundDevice := false
	for _, p := range del.Parameters {
		if p.Name == "X-Device-Id" || p.Ref == "#/components/parameters/DeviceIdHeader" {
			foundDevice = true
		}
		if p.Ref == "#/components/parameters/DeviceIdHeader" {
			if _, ok := s.Components.Parameters["DeviceIdHeader"]; !ok {
				t.Error("components.parameters must define DeviceIdHeader (the $ref target of DELETE /auth/account)")
			}
		}
	}
	if !foundDevice {
		t.Error("DELETE /api/v1/auth/account must document the X-Device-Id header")
	}
	pending, ok := s.Components.Schemas["AccountDeletionPendingResponse"]
	if !ok {
		t.Fatal("expected AccountDeletionPendingResponse schema")
	}
	for _, field := range []string{"account_deleted", "apple_revocation_pending"} {
		if _, ok := pending.Properties[field]; !ok {
			t.Errorf("AccountDeletionPendingResponse must document %q", field)
		}
	}

	status, ok := s.Paths["/api/v1/auth/account/status"]["post"]
	if !ok {
		t.Fatal("expected POST /api/v1/auth/account/status")
	}
	if requiresAuth(status) {
		t.Error("POST /api/v1/auth/account/status must NOT require BearerAuth (status-only credential)")
	}
	usesStatusScheme := false
	for _, sec := range status.Security {
		if _, ok := sec["StatusAuth"]; ok {
			usesStatusScheme = true
		}
	}
	if !usesStatusScheme {
		t.Error("POST /api/v1/auth/account/status must require the StatusAuth scheme")
	}
	if _, ok := s.Components.SecuritySchemes["StatusAuth"]; !ok {
		t.Error("components.securitySchemes must define StatusAuth (referenced by /auth/account/status)")
	}
	if _, ok := s.Components.SecuritySchemes["BearerAuth"]; !ok {
		t.Error("components.securitySchemes must define BearerAuth")
	}
	for _, want := range []string{"200", "401", "429", "500"} {
		if _, ok := status.Responses[want]; !ok {
			t.Errorf("POST /api/v1/auth/account/status must document %s", want)
		}
	}
	verdict, ok := s.Components.Schemas["AccountStatusResponse"]
	if !ok {
		t.Fatal("expected AccountStatusResponse schema")
	}
	for _, field := range []string{"account_id", "state"} {
		if _, ok := verdict.Properties[field]; !ok {
			t.Errorf("AccountStatusResponse must document %q", field)
		}
	}
}

// The status credential is read-only evidence: AuthResponse and MeResponse
// carry the root account_status_credential + account_status_expires_at, and
// the User carries server-truth provider fields (never email-inferred).
func TestSpec_StatusEvidenceDocumented(t *testing.T) {
	s := loadSpec(t)
	authResp, ok := s.Components.Schemas["AuthResponse"]
	if !ok {
		t.Fatal("expected AuthResponse schema")
	}
	for _, field := range []string{"account_status_credential", "account_status_expires_at"} {
		if _, ok := authResp.Properties[field]; !ok {
			t.Errorf("AuthResponse must document %q", field)
		}
	}
	me, ok := s.Components.Schemas["MeResponse"]
	if !ok {
		t.Fatal("expected MeResponse schema")
	}
	for _, field := range []string{"user", "account_status_credential", "account_status_expires_at"} {
		if _, ok := me.Properties[field]; !ok {
			t.Errorf("MeResponse must document %q", field)
		}
	}
	user, ok := s.Components.Schemas["User"]
	if !ok {
		t.Fatal("expected User schema")
	}
	for _, field := range []string{"has_apple_identity", "apple_deletion_authorization_required"} {
		if _, ok := user.Properties[field]; !ok {
			t.Errorf("User must document %q", field)
		}
	}
	for _, name := range []string{"has_apple_identity", "apple_deletion_authorization_required"} {
		found := false
		for _, r := range user.Required {
			if str, _ := r.(string); str == name {
				found = true
			}
		}
		if !found {
			t.Errorf("User.%s must be required", name)
		}
	}
	if _, ok := s.Components.Schemas["AppleSignInRequest"]; !ok {
		t.Fatal("expected AppleSignInRequest schema")
	}
	if _, ok := s.Components.Schemas["AppleSignInRequest"].Properties["authorization_code"]; !ok {
		t.Error("AppleSignInRequest must document optional authorization_code")
	}
}

// Apple revocation plumbing: the same-subject deletion-credential endpoint
// (Bearer, no user creation) and the verified notification endpoint (no
// bearer, consent-revoked without deletion). The StatusAuth scheme itself
// must exist.
func TestSpec_AppleDeletionPlumbingDocumented(t *testing.T) {
	s := loadSpec(t)
	cred, ok := s.Paths["/api/v1/auth/apple/deletion-credential"]["post"]
	if !ok {
		t.Fatal("expected POST /api/v1/auth/apple/deletion-credential")
	}
	if !requiresAuth(cred) {
		t.Error("POST /api/v1/auth/apple/deletion-credential must require BearerAuth")
	}
	for _, want := range []string{"200", "400", "401", "503", "500"} {
		if _, ok := cred.Responses[want]; !ok {
			t.Errorf("POST /api/v1/auth/apple/deletion-credential must document %s", want)
		}
	}

	notif, ok := s.Paths["/api/v1/auth/apple/notifications"]["post"]
	if !ok {
		t.Fatal("expected POST /api/v1/auth/apple/notifications")
	}
	if requiresAuth(notif) {
		t.Error("POST /api/v1/auth/apple/notifications must NOT require BearerAuth (Apple-signed payload)")
	}
	if len(s.Security) != 0 {
		t.Error("spec must not define root-level security: it would silently add BearerAuth to bearer-less operations (/auth/apple/notifications, /auth/account/status)")
	}
	for _, want := range []string{"200", "400", "401", "429", "500"} {
		if _, ok := notif.Responses[want]; !ok {
			t.Errorf("POST /api/v1/auth/apple/notifications must document %s", want)
		}
	}
}

// POST /auth/apple documents every 401 cause (invalid identity, rejected
// or mismatched code, stale pre-cutoff authorization) and the 409
// apple_email_in_use collision (identities are never merged).
func TestSpec_AppleSignInResponsesDocumented(t *testing.T) {
	s := loadSpec(t)
	post, ok := s.Paths["/api/v1/auth/apple"]["post"]
	if !ok {
		t.Fatal("expected POST /api/v1/auth/apple")
	}
	for _, want := range []string{"200", "400", "401", "409", "429", "503", "500"} {
		if _, ok := post.Responses[want]; !ok {
			t.Errorf("POST /api/v1/auth/apple must document %s", want)
		}
	}
}
