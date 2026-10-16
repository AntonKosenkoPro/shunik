package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/antonkosenko/time-of-life/backend/internal/db"
)

// The catalog feature introduces the catalog/entries endpoints. Unlike the auth handlers
// (inline boolean validators → 400 invalid_body), these use a field→message
// accumulator that returns 422 validation_error with details = {field: message},
// matching the OpenAPI ValidationError response. Error codes are declared as
// constants to keep the string literals in one place.

const (
	codeValidation      = "validation_error"
	codeNotFound        = "not_found"
	codeConflict        = "conflict"
	codeCategoryExists  = "category_exists"
	codeDuplicateImport = "duplicate_import"
)

// validIcons is the allowed SF Symbol set for catalog icons. This must match
// the authoritative `Category.icon` enum in backend/api/openapi.yaml exactly;
// the contract test TestSpec_CategoryIconEnumMatchesGo fails when the lists
// drift. The iOS CatalogIcon type mirrors the same set, and Design/TOKENS.md
// documents it.
var validIcons = map[string]bool{
	"clock": true, "laptopcomputer": true, "briefcase": true,
	"book": true, "pencil.and.ruler": true, "brain.head.profile": true,
	"figure.walk": true, "figure.run": true, "figure.strengthtraining": true,
	"figure.yoga": true, "figure.cycling": true, "figure.swimming": true,
	"figure.soccer": true, "figure.basketball": true, "figure.tennis": true,
	"figure.gymnastics": true, "figure.mindandbody": true, "figure.core.training": true,
	"dumbbell": true, "bicycle": true,
	"books": true, "graduationcap": true,
	"desktopcomputer": true, "keyboard": true,
	"gamecontroller": true, "fork.knife": true, "cup.and.saucer": true,
	"bed.double": true, "moon.stars": true, "moon.zzz": true,
	"film": true, "music.note": true, "guitar": true, "camera": true,
	"tv": true, "musicalnotes": true,
	"paintbrush": true, "house": true,
	"car.fill": true, "airplane": true, "cart": true, "phone": true,
	"hammer": true, "heart": true, "leaf": true, "sparkles": true,
	"pawprint": true, "dog": true, "cat": true, "fish": true, "bird": true,
	"washer": true, "dryer": true, "dishwasher": true, "refrigerator": true,
	"sofa": true, "shower": true, "lamp.table": true,
	"person.2": true, "figure.and.child.holdinghands": true,
	"stethoscope": true, "pill": true,
	"tag": true,
}

// ValidIcons returns a copy of the authoritative category icon set so the
// OpenAPI contract tests can compare it against the spec's CategoryIcon enum.
func ValidIcons() (map[string]bool, error) {
	out := make(map[string]bool, len(validIcons))
	for k := range validIcons {
		out[k] = true
	}
	return out, nil
}

const (
	maxNameLen  = 60
	maxNotesLen = 2000
)

// validEntrySources is the allowed provenance set for entries (entry-provenance
// spec). The backend is the authoritative validator; the client keeps the
// union. Future sources (e.g. a new integration) extend this list.
var validEntrySources = map[string]bool{
	"manual": true, "widget": true, "siri": true, "control": true,
	"screentime": true, "garmin": true, "calendar": true, "healthkit": true,
}

var uuidV7Regex = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

// validateUUIDv7 reports whether id is a canonical lowercase UUID v7.
func validateUUIDv7(id string) bool {
	return uuidV7Regex.MatchString(strings.ToLower(id))
}

// validationErrs accumulates field→message pairs; the first message per field wins.
type validationErrs map[string]string

func (v validationErrs) add(field, msg string) {
	if _, ok := v[field]; !ok {
		v[field] = msg
	}
}
func (v validationErrs) ok() bool { return len(v) == 0 }

// writeValidation writes a 422 validation_error response with the field map.
func writeValidation(w http.ResponseWriter, errs validationErrs) {
	writeError(w, http.StatusUnprocessableEntity, codeValidation, "Validation failed", errs)
}

// parseRFC3339 parses an RFC 3339 timestamp. RFC3339Nano already accepts
// whole-second inputs (the fractional section is optional in Go layouts),
// so no fallback layout is needed.
func parseRFC3339(s string) (time.Time, bool) {
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		return time.Time{}, false
	}
	return t, true
}

// optTime is an optional, nullable timestamp: Set=false leaves it unchanged,
// Set=true with Valid=false sets NULL, Set=true with Valid=true sets Value.
// Bad=true marks a present-but-unparseable value so the validator can emit a
// 422 (UnmarshalJSON deliberately never errors, so a bad timestamp does not
// surface as a 400 invalid_body). Empty=true marks a present-but-empty string,
// which handlers normalize to unset (matching emptyToNil for *string fields,
// so "" means "omitted" everywhere). It maps directly onto db.NullableTime.
type optTime struct {
	Set   bool
	Valid bool
	Bad   bool
	Empty bool
	Value time.Time
}

// UnmarshalJSON is only called when the field is present in the JSON. It
// deliberately never returns an error: a present-but-unparseable value is
// recorded as Bad so the validator can emit a 422 (rather than surfacing as a
// 400 invalid_body from decodeJSON).
func (o *optTime) UnmarshalJSON(b []byte) error {
	o.Set = true
	if string(b) == "null" {
		return nil
	}
	var s string
	if err := json.Unmarshal(b, &s); err == nil {
		if s == "" {
			o.Empty = true
			return nil
		}
		if t, ok := parseRFC3339(s); ok {
			o.Valid = true
			o.Value = t
			return nil
		}
	}
	o.Bad = true
	return nil
}

// requireUserID writes a 401 and returns false when the request is not authed.
func (h *Handler) requireUserID(w http.ResponseWriter, r *http.Request) (string, bool) {
	userID, ok := UserIDFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized", "Not authenticated", nil)
	}
	return userID, ok
}

type categoryCreateReq struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Icon string `json:"icon"`
}

type categoryUpdateReq struct {
	Name      *string `json:"name"`
	Icon      *string `json:"icon"`
	UpdatedAt string  `json:"updated_at"`
}

type entryCreateReq struct {
	ID           string   `json:"id"`
	ActivityText string   `json:"activity_text"`
	Notes        *string  `json:"notes"`
	CategoryIDs  []string `json:"category_ids"`
	StartedAt    string   `json:"started_at"`
	EndedAt      *string  `json:"ended_at"`
	Source       string   `json:"source"`
	SourceRef    *string  `json:"source_ref"`
}

type entryUpdateReq struct {
	ActivityText *string   `json:"activity_text"`
	Notes        *string   `json:"notes"`
	CategoryIDs  *[]string `json:"category_ids"`
	StartedAt    *string   `json:"started_at"`
	EndedAt      optTime   `json:"ended_at"`
	UpdatedAt    string    `json:"updated_at"`
}

func validateName(field, name string, errs validationErrs) {
	n := strings.TrimSpace(name)
	if n == "" {
		errs.add(field, "Name must not be empty")
	} else if utf8.RuneCountInString(n) > maxNameLen {
		errs.add(field, "Name must be 60 characters or fewer")
	}
}

// validateEntryText validates an entry's owned display text: trimmed,
// non-empty, max 60 chars. Identity is case-sensitive (`Gym` ≠ `GYM`) — no
// uniqueness or normalization beyond trimming.
func validateEntryText(text string, errs validationErrs) {
	if text == "" {
		errs.add("activity_text", "activity_text must not be empty")
	} else if utf8.RuneCountInString(text) > maxNameLen {
		errs.add("activity_text", "activity_text must be 60 characters or fewer")
	}
}

// entryTags converts client-supplied ordered category ids into the CategoryTag
// shape the store join-writer consumes (only ids; names/icons resolve from the
// categories table on read).
func entryTags(ids []string) []db.CategoryTag {
	tags := make([]db.CategoryTag, 0, len(ids))
	for _, id := range ids {
		tags = append(tags, db.CategoryTag{ID: id})
	}
	return tags
}

func validateNotes(n string, errs validationErrs) {
	if utf8.RuneCountInString(strings.TrimSpace(n)) > maxNotesLen {
		errs.add("notes", fmt.Sprintf("Notes must be %d characters or fewer", maxNotesLen))
	}
}

func validateIcon(i string, errs validationErrs) {
	if !validIcons[i] {
		errs.add("icon", "Icon is not in the allowed set")
	}
}

func validateID(id string, errs validationErrs) {
	if !validateUUIDv7(id) {
		errs.add("id", "id must be a valid UUID v7")
	}
}

func validateTimestamp(field, s string, required bool, errs validationErrs) {
	if s == "" {
		if required {
			errs.add(field, field+" is required")
		}
		return
	}
	if _, ok := parseRFC3339(s); !ok {
		errs.add(field, field+" must be a valid RFC 3339 timestamp")
	}
}

// emptyToNil normalizes an empty optional timestamp to omitted (nil), so ""
// means "no value" rather than a present zero time. Used for ended_at on
// create (a running timer) and for optional update fields.
func emptyToNil(s *string) *string {
	if s != nil && *s == "" {
		return nil
	}
	return s
}

// parseLimitParam validates a ?limit= query value against [1, maxLimit]. It
// returns the parsed limit, or ok=false when the handler must answer 422.
func parseLimitParam(v string, maxLimit int, errs validationErrs) (limit int, ok bool) {
	n, err := strconv.Atoi(v)
	if err != nil || n < 1 || n > maxLimit {
		errs.add("limit", fmt.Sprintf("limit must be between 1 and %d", maxLimit))
		return 0, false
	}
	return n, true
}
