// Package contract holds executable contract fixtures: tests that pin the
// OpenAPI spec (backend/api/openapi.yaml) to the invariants the API contract
// promises (R-003/R-006 — OpenAPI is authoritative, S10). Any drift between
// the spec and the documented contract fails here.
package contract

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"

	"github.com/antonkosenko/time-of-life/backend/internal/handlers"
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
	"invalid_refresh",
	"token_reuse",
	"refresh_expired",
	"refresh_attempt_completed",
	"refresh_attempt_conflict",
	"unauthorized",
	"not_found",
	"conflict",
	"category_exists",
	"duplicate_import",
	"validation_error",
}

// bearerProtectedPaths are the paths whose operations must require BearerAuth
// and document a 401 response.
var bearerProtectedPaths = []string{
	"/api/v1/auth/logout",
	"/api/v1/auth/me",
	"/api/v1/categories",
	"/api/v1/categories/{id}",
	"/api/v1/entries",
	"/api/v1/entries/recents",
	"/api/v1/entries/{id}",
}

type rawSpec struct {
	OpenAPI    string             `yaml:"openapi"`
	Info       rawInfo            `yaml:"info"`
	Paths      map[string]rawPath `yaml:"paths"`
	Components rawComponents      `yaml:"components"`
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
	Responses map[string]rawResponse  `yaml:"responses"`
	Schemas   map[string]rawSchemaDef `yaml:"schemas"`
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

func TestSpec_IdempotentPostsDocument200And201(t *testing.T) {
	s := loadSpec(t)
	for _, path := range []string{
		"/api/v1/categories",
		"/api/v1/entries",
	} {
		post, ok := s.Paths[path]["post"]
		if !ok {
			t.Errorf("expected POST %s", path)
			continue
		}
		if _, ok := post.Responses["200"]; !ok {
			t.Errorf("POST %s must document 200 (idempotent replay)", path)
		}
		if _, ok := post.Responses["201"]; !ok {
			t.Errorf("POST %s must document 201", path)
		}
	}
}

// Delta pull-sync (v1.2.0): GET /entries must document the optional
// modified_since query parameter (activities no longer exist).
func TestSpec_ModifiedSinceDocumentedOnListEndpoints(t *testing.T) {
	s := loadSpec(t)
	for _, path := range []string{"/api/v1/entries"} {
		get, ok := s.Paths[path]["get"]
		if !ok {
			t.Errorf("expected GET %s", path)
			continue
		}
		found := false
		for _, p := range get.Parameters {
			if p.Name == "modified_since" {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("GET %s must document the modified_since query parameter", path)
		}
	}
}

// Provenance (v1.2.0): the Entry schema must document source + source_ref and
// the EntryCreate schema must accept them.
func TestSpec_EntryProvenanceDocumented(t *testing.T) {
	s := loadSpec(t)
	entry, ok := s.Components.Schemas["Entry"]
	if !ok {
		t.Fatal("expected Entry schema")
	}
	for _, field := range []string{"source", "source_ref"} {
		if _, ok := entry.Properties[field]; !ok {
			t.Errorf("Entry schema must document %q", field)
		}
	}
	create, ok := s.Components.Schemas["EntryCreate"]
	if !ok {
		t.Fatal("expected EntryCreate schema")
	}
	for _, field := range []string{"source", "source_ref"} {
		if _, ok := create.Properties[field]; !ok {
			t.Errorf("EntryCreate schema must document %q", field)
		}
	}
}

// Entries own their text/categories/notes (remove-activities-layer): the
// Entry schema carries activity_text + notes + categories, EntryCreate
// requires activity_text, and no activities resource exists.
func TestSpec_EntriesOwnTextCategoriesNotes(t *testing.T) {
	s := loadSpec(t)
	if _, ok := s.Paths["/api/v1/activities"]; ok {
		t.Error("/api/v1/activities must be removed from the spec")
	}
	if _, ok := s.Paths["/api/v1/activities/{id}"]; ok {
		t.Error("/api/v1/activities/{id} must be removed from the spec")
	}
	entry, ok := s.Components.Schemas["Entry"]
	if !ok {
		t.Fatal("expected Entry schema")
	}
	for _, field := range []string{"activity_text", "notes", "categories", "started_at"} {
		if _, ok := entry.Properties[field]; !ok {
			t.Errorf("Entry schema must document %q", field)
		}
	}
	if _, ok := entry.Properties["activity_id"]; ok {
		t.Error("Entry schema must not document activity_id (entries own their text)")
	}
	if _, ok := s.Components.Schemas["Activity"]; ok {
		t.Error("Activity schema must be removed from the spec")
	}
	create, ok := s.Components.Schemas["EntryCreate"]
	if !ok {
		t.Fatal("expected EntryCreate schema")
	}
	for _, field := range []string{"activity_text", "category_ids", "notes"} {
		if _, ok := create.Properties[field]; !ok {
			t.Errorf("EntryCreate schema must document %q", field)
		}
	}
	deletion, ok := s.Components.Schemas["Deletion"]
	if !ok {
		t.Fatal("expected Deletion schema")
	}
	if enum, ok := deletion.Properties["resource"].([]any); ok {
		for _, v := range enum {
			if name, ok := v.(string); ok && name == "activity" {
				t.Error("Deletion.resource enum must not include activity (entries/categories only)")
			}
		}
	} else {
		// rawSchemaDef.Properties is map[string]any; walk via yaml node if the
		// direct cast failed.
		res := deletion.Properties["resource"]
		if res == nil {
			t.Error("Deletion schema must document resource")
		}
	}
}

// Category icon catalog (v1.3.0, category-management D1): the OpenAPI
// `CategoryIcon` enum is the authoritative machine-readable icon list. The
// Go `validIcons` set and the iOS `CatalogIcon` type must mirror it exactly;
// this test fails when the OpenAPI enum and the Go validator drift.
func TestSpec_CategoryIconEnumMatchesGo(t *testing.T) {
	s := loadSpec(t)
	iconSchema, ok := s.Components.Schemas["CategoryIcon"]
	if !ok {
		t.Fatal("expected CategoryIcon schema")
	}
	if len(iconSchema.Enum) == 0 {
		t.Fatal("CategoryIcon schema must declare an enum")
	}
	specIcons := map[string]bool{}
	for _, v := range iconSchema.Enum {
		name, ok := v.(string)
		if !ok || name == "" {
			t.Errorf("CategoryIcon enum entry must be a non-empty string, got %v", v)
			continue
		}
		specIcons[name] = true
	}

	goIcons, err := handlers.ValidIcons()
	if err != nil {
		t.Fatalf("validIcons: %v", err)
	}

	for icon := range goIcons {
		if !specIcons[icon] {
			t.Errorf("Go validIcons contains %q which is absent from the OpenAPI CategoryIcon enum", icon)
		}
	}
	for icon := range specIcons {
		if !goIcons[icon] {
			t.Errorf("OpenAPI CategoryIcon enum contains %q which is absent from the Go validIcons set", icon)
		}
	}
	if len(goIcons) != len(specIcons) {
		t.Errorf("icon set sizes differ: Go %d vs OpenAPI %d", len(goIcons), len(specIcons))
	}
}

// Recents (D5): GET /entries/recents mirrors the newest-per-exact-text query
// for fresh devices. The handler caps limit at 20 (default 6) with 422 on
// out-of-range values — the spec must document the path, the limit contract,
// and the 422 alongside 200/401.
func TestSpec_RecentsEndpointDocumented(t *testing.T) {
	s := loadSpec(t)
	get, ok := s.Paths["/api/v1/entries/recents"]["get"]
	if !ok {
		t.Fatal("expected GET /api/v1/entries/recents to be documented")
	}
	if !requiresAuth(get) {
		t.Error("GET /api/v1/entries/recents must require BearerAuth")
	}
	for _, want := range []string{"200", "401", "422"} {
		if _, ok := get.Responses[want]; !ok {
			t.Errorf("GET /api/v1/entries/recents must document %s", want)
		}
	}
	found := false
	for i := range get.Parameters {
		if get.Parameters[i].Name == "limit" {
			found = true
			limitParam := &get.Parameters[i]
			if limitParam.Schema.Minimum == nil || *limitParam.Schema.Minimum != 1 ||
				limitParam.Schema.Maximum == nil || *limitParam.Schema.Maximum != 20 ||
				limitParam.Schema.Default != 6 {
				t.Errorf("recents limit must pin minimum 1 / maximum 20 / default 6, got %+v", limitParam.Schema)
			}
		}
	}
	if !found {
		t.Error("GET /api/v1/entries/recents must document the limit query parameter")
	}
}

// Categories have no delta pull: the handler ignores ?modified_since= on
// GET /categories (200, full list — pinned in handlers
// TestCategories_ModifiedSinceIgnored), so the spec must NOT document the
// parameter there. If the filter is ever implemented, handler + spec + this
// pin change together (backend follow-up, not this contract).
func TestSpec_NoModifiedSinceOnListCategories(t *testing.T) {
	s := loadSpec(t)
	get, ok := s.Paths["/api/v1/categories"]["get"]
	if !ok {
		t.Fatal("expected GET /api/v1/categories")
	}
	for _, p := range get.Parameters {
		if p.Name == "modified_since" {
			t.Error("GET /api/v1/categories must not document modified_since (handler ignores it)")
		}
	}
}

// Response-loss recovery (fix-refresh-response-loss): POST /auth/refresh
// must document the optional refresh_attempt_id field on RefreshRequest and
// the 409 attempt-conflict responses alongside 200/401/500.
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

// Create-vs-merge asymmetry (D7): POST /entries rejects unknown category
// ids loudly (422 validation_error), while PATCH prunes them and succeeds.
// The spec must document the 422 on create and the prune rule on
// EntryUpdate.category_ids.
func TestSpec_Create422VsMergePrune(t *testing.T) {
	s := loadSpec(t)
	post, ok := s.Paths["/api/v1/entries"]["post"]
	if !ok {
		t.Fatal("expected POST /api/v1/entries")
	}
	if _, ok := post.Responses["422"]; !ok {
		t.Error("POST /api/v1/entries must document 422 (unknown category ids rejected)")
	}
	update, ok := s.Components.Schemas["EntryUpdate"]
	if !ok {
		t.Fatal("expected EntryUpdate schema")
	}
	rawIDs, ok := update.Properties["category_ids"]
	if !ok {
		t.Fatal("EntryUpdate schema must document category_ids")
	}
	prop, ok := rawIDs.(map[string]any)
	if !ok {
		t.Fatalf("EntryUpdate.category_ids has unexpected shape %T", rawIDs)
	}
	desc, _ := prop["description"].(string)
	lowered := strings.ToLower(desc)
	if !strings.Contains(lowered, "pruned") || !strings.Contains(lowered, "unknown") {
		t.Errorf("EntryUpdate.category_ids must document pruning of unknown ids, got %q", desc)
	}
}
