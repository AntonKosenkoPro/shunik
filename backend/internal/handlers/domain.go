package handlers

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/antonkosenko/shunik/backend/internal/db"
)

// Shunik v1 domain HTTP layer (pets, events, medication intakes, deletions
// timeline). Every handler resolves the caller's household via EnsureHousehold
// (self-heal: a household always exists post-sign-in) and scopes all store
// calls to it; updated_by/marked_by always come from the authenticated
// userID, never the client body.

// ---------- shared domain helpers ----------

// resolveHousehold enforces auth and returns the caller's self-healed
// household scope for every domain endpoint.
func (h *Handler) resolveHousehold(w http.ResponseWriter, r *http.Request) (userID, householdID string, ok bool) {
	userID, ok = h.requireUserID(w, r)
	if !ok {
		return "", "", false
	}
	household, err := h.store.EnsureHousehold(r.Context(), userID)
	if err != nil {
		h.writeInternalError(w, r, "failed to resolve household", err)
		return "", "", false
	}
	return userID, household.ID, true
}

// parseSinceQuery parses an optional RFC3339 query param (modified_since /
// deleted_since). Absent means no lower bound; malformed is 400 invalid_body.
func parseSinceQuery(r *http.Request, key string) (*time.Time, error) {
	s := strings.TrimSpace(r.URL.Query().Get(key))
	if s == "" {
		return nil, nil
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return nil, err
	}
	return &t, nil
}

// conflictWithServer writes the 409 stale-write envelope with the current
// server object under details.server so the client can converge.
func conflictWithServer(w http.ResponseWriter, message string, server any) {
	writeError(w, http.StatusConflict, "conflict", message, map[string]any{"server": server})
}

// nonEmptyList normalizes a possibly-nil store result so lists always encode
// as JSON arrays, never null.
func nonEmptyList[T any](in []T) []T {
	if in == nil {
		return []T{}
	}
	return in
}

// ---------- pets ----------

type petReq struct {
	ID        string     `json:"id"`
	Name      string     `json:"name"`
	Species   string     `json:"species"`
	Birthdate *time.Time `json:"birthdate"`
	Notes     string     `json:"notes"`
}

type petPatchReq struct {
	BaseUpdatedAt time.Time  `json:"base_updated_at"`
	Name          string     `json:"name"`
	Species       string     `json:"species"`
	Birthdate     *time.Time `json:"birthdate"`
	Notes         string     `json:"notes"`
}

// CreatePet handles POST /api/v1/pets: idempotent insert (201 new, 200 replay).
func (h *Handler) CreatePet(w http.ResponseWriter, r *http.Request) {
	userID, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}

	var req petReq
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}
	if strings.TrimSpace(req.ID) == "" || strings.TrimSpace(req.Name) == "" || strings.TrimSpace(req.Species) == "" {
		writeError(w, http.StatusBadRequest, "invalid_body", "id, name, and species are required", nil)
		return
	}

	pet, created, err := h.store.CreatePet(r.Context(), householdID, db.PetInput{
		ID:        strings.TrimSpace(req.ID),
		Name:      strings.TrimSpace(req.Name),
		Species:   strings.TrimSpace(req.Species),
		Birthdate: req.Birthdate,
		Notes:     req.Notes,
	}, userID)
	if err != nil {
		h.writeInternalError(w, r, "failed to create pet", err)
		return
	}
	if created {
		writeJSON(w, http.StatusCreated, pet)
		return
	}
	writeJSON(w, http.StatusOK, pet)
}

// ListPets handles GET /api/v1/pets?modified_since=: delta pull with the
// max-updated_at cursor ("" when empty).
func (h *Handler) ListPets(w http.ResponseWriter, r *http.Request) {
	_, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}

	since, err := parseSinceQuery(r, "modified_since")
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid modified_since (RFC3339 required)", nil)
		return
	}

	pets, err := h.store.ListPetsChangedSince(r.Context(), householdID, since)
	if err != nil {
		h.writeInternalError(w, r, "failed to list pets", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"pets":   nonEmptyList(pets),
		"cursor": petCursor(pets),
	})
}

func petCursor(pets []db.Pet) string {
	var latest time.Time
	for _, p := range pets {
		if p.UpdatedAt.After(latest) {
			latest = p.UpdatedAt
		}
	}
	if latest.IsZero() {
		return ""
	}
	return latest.UTC().Format(time.RFC3339)
}

// GetPet handles GET /api/v1/pets/{id}.
func (h *Handler) GetPet(w http.ResponseWriter, r *http.Request) {
	_, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}

	pet, err := h.store.GetPet(r.Context(), householdID, strings.TrimSpace(chi.URLParam(r, "id")))
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "Pet not found", nil)
			return
		}
		h.writeInternalError(w, r, "failed to load pet", err)
		return
	}
	writeJSON(w, http.StatusOK, pet)
}

// UpdatePet handles PATCH /api/v1/pets/{id}: full-replace guarded by
// base_updated_at (LWW). Stale writes get 409 with the server copy.
func (h *Handler) UpdatePet(w http.ResponseWriter, r *http.Request) {
	userID, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}
	id := strings.TrimSpace(chi.URLParam(r, "id"))

	var req petPatchReq
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}
	if req.BaseUpdatedAt.IsZero() {
		writeError(w, http.StatusBadRequest, "invalid_body", "base_updated_at is required", nil)
		return
	}
	if strings.TrimSpace(req.Name) == "" || strings.TrimSpace(req.Species) == "" {
		writeError(w, http.StatusBadRequest, "invalid_body", "name and species are required", nil)
		return
	}

	pet, err := h.store.UpdatePet(r.Context(), householdID, id, db.PetInput{
		ID:        id,
		Name:      strings.TrimSpace(req.Name),
		Species:   strings.TrimSpace(req.Species),
		Birthdate: req.Birthdate,
		Notes:     req.Notes,
	}, req.BaseUpdatedAt, userID)
	if err != nil {
		switch {
		case errors.Is(err, db.ErrNotFound):
			writeError(w, http.StatusNotFound, "not_found", "Pet not found", nil)
		case errors.Is(err, db.ErrConflict):
			current, gerr := h.store.GetPet(r.Context(), householdID, id)
			if gerr != nil {
				h.writeInternalError(w, r, "failed to load pet after conflict", gerr)
				return
			}
			conflictWithServer(w, "Pet was modified by another device", current)
		default:
			h.writeInternalError(w, r, "failed to update pet", err)
		}
		return
	}
	writeJSON(w, http.StatusOK, pet)
}

// DeletePet handles DELETE /api/v1/pets/{id} (store cascades + tombstones).
func (h *Handler) DeletePet(w http.ResponseWriter, r *http.Request) {
	userID, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}

	if err := h.store.DeletePet(r.Context(), householdID, strings.TrimSpace(chi.URLParam(r, "id")), userID); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "Pet not found", nil)
			return
		}
		h.writeInternalError(w, r, "failed to delete pet", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------- events ----------

var validEventKinds = map[string]bool{
	"vaccination": true,
	"grooming":    true,
	"weight":      true,
	"med_course":  true,
}

// validateEventInput enforces kind membership, exactly-one matching detail,
// and per-kind required fields. Route defaults to "oral" when empty.
func validateEventInput(in *db.EventInput) error {
	if strings.TrimSpace(in.ID) == "" {
		return errors.New("event id is required")
	}
	if strings.TrimSpace(in.PetID) == "" {
		return errors.New("pet_id is required")
	}
	if !validEventKinds[in.Kind] {
		return errors.New("unknown event kind")
	}
	if in.OccurredAt.IsZero() {
		return errors.New("occurred_at is required")
	}
	details := 0
	if in.Vaccination != nil {
		details++
	}
	if in.Grooming != nil {
		details++
	}
	if in.Weight != nil {
		details++
	}
	if in.Course != nil {
		details++
	}
	if details != 1 {
		return errors.New("exactly one kind detail is required")
	}
	switch in.Kind {
	case "vaccination":
		if in.Vaccination == nil {
			return errors.New("vaccination detail is required for kind vaccination")
		}
		if strings.TrimSpace(in.Vaccination.Vaccine) == "" {
			return errors.New("vaccination.vaccine is required")
		}
	case "grooming":
		if in.Grooming == nil {
			return errors.New("grooming detail is required for kind grooming")
		}
		if strings.TrimSpace(in.Grooming.Service) == "" {
			return errors.New("grooming.service is required")
		}
	case "weight":
		if in.Weight == nil {
			return errors.New("weight detail is required for kind weight")
		}
		if in.Weight.Grams <= 0 {
			return errors.New("weight.grams must be positive")
		}
	case "med_course":
		if in.Course == nil {
			return errors.New("course detail is required for kind med_course")
		}
		if err := validateMedCourse(in.Course); err != nil {
			return err
		}
	}
	return nil
}

var validScheduleKinds = map[string]bool{"daily": true, "weekdays": true, "prn": true}
var validCourseStatuses = map[string]bool{"active": true, "paused": true, "done": true, "stopped": true}

// validateMedCourse enforces the medication-course contract: named drug with
// a positive decimal dose, a known schedule kind (non-prn schedules carry
// valid HH:MM times; weekday lists stay within ISO 1..7).
func validateMedCourse(c *db.MedCourseInput) error {
	if strings.TrimSpace(c.DrugName) == "" {
		return errors.New("course.drug_name is required")
	}
	amount, err := strconv.ParseFloat(strings.TrimSpace(c.DoseAmount), 64)
	if err != nil || amount <= 0 {
		return errors.New("course.dose_amount must be a positive number")
	}
	if strings.TrimSpace(c.DoseUnit) == "" {
		return errors.New("course.dose_unit is required")
	}
	if !validScheduleKinds[c.ScheduleKind] {
		return errors.New("course.schedule_kind must be daily, weekdays, or prn")
	}
	if c.ScheduleKind != "prn" {
		if strings.TrimSpace(c.ScheduleTimes) == "" {
			return errors.New("course.schedule_times is required for scheduled courses")
		}
	}
	if strings.TrimSpace(c.ScheduleTimes) != "" {
		for _, t := range strings.Split(c.ScheduleTimes, ",") {
			if !validHHMM(strings.TrimSpace(t)) {
				return errors.New("course.schedule_times entries must be HH:MM")
			}
		}
	}
	if strings.TrimSpace(c.ScheduleWeekdays) != "" {
		for _, d := range strings.Split(c.ScheduleWeekdays, ",") {
			n, err := strconv.Atoi(strings.TrimSpace(d))
			if err != nil || n < 1 || n > 7 {
				return errors.New("course.schedule_weekdays entries must be 1..7")
			}
		}
	}
	if c.Status != "" && !validCourseStatuses[c.Status] {
		return errors.New("course.status must be active, paused, done, or stopped")
	}
	return nil
}

// validHHMM reports whether s is a strict HH:MM wall-clock entry.
func validHHMM(s string) bool {
	if len(s) != 5 || s[2] != ':' {
		return false
	}
	h, err := strconv.Atoi(s[:2])
	if err != nil || h < 0 || h > 23 {
		return false
	}
	m, err := strconv.Atoi(s[3:])
	if err != nil || m < 0 || m > 59 {
		return false
	}
	return true
}

type eventPatchReq struct {
	BaseUpdatedAt time.Time        `json:"base_updated_at"`
	PetID         string           `json:"pet_id"`
	Kind          string           `json:"kind"`
	OccurredAt    time.Time        `json:"occurred_at"`
	NextDueAt     *time.Time       `json:"next_due_at"`
	Title         string           `json:"title"`
	Vaccination   *db.VaccDetail   `json:"vaccination"`
	Grooming      *db.GroomDetail  `json:"grooming"`
	Weight        *db.WeightDetail `json:"weight"`
	Course        *db.MedCourse    `json:"course"`
}

// CreateEvent handles POST /api/v1/events: idempotent insert (201/200).
// Unknown pets (or cross-household pets, indistinguishable) are 422.
func (h *Handler) CreateEvent(w http.ResponseWriter, r *http.Request) {
	userID, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}

	var in db.EventInput
	if err := decodeJSON(r, &in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}
	in.ID = strings.TrimSpace(in.ID)
	in.PetID = strings.TrimSpace(in.PetID)
	if in.Course != nil && strings.TrimSpace(in.Course.Route) == "" {
		in.Course.Route = "oral"
	}
	if err := validateEventInput(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body", err.Error(), nil)
		return
	}

	event, created, err := h.store.CreateEvent(r.Context(), householdID, in, userID)
	if err != nil {
		if errors.Is(err, db.ErrInvalidPetID) {
			writeError(w, http.StatusUnprocessableEntity, "invalid_pet_id", "Unknown pet reference", nil)
			return
		}
		h.writeInternalError(w, r, "failed to create event", err)
		return
	}
	if created {
		writeJSON(w, http.StatusCreated, event)
		return
	}
	writeJSON(w, http.StatusOK, event)
}

// ListEvents handles GET /api/v1/events?modified_since=&pet_id=.
func (h *Handler) ListEvents(w http.ResponseWriter, r *http.Request) {
	_, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}

	since, err := parseSinceQuery(r, "modified_since")
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid modified_since (RFC3339 required)", nil)
		return
	}

	events, err := h.store.ListEventsChangedSince(r.Context(), householdID, since, strings.TrimSpace(r.URL.Query().Get("pet_id")))
	if err != nil {
		h.writeInternalError(w, r, "failed to list events", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"events": nonEmptyList(events),
		"cursor": eventCursor(events),
	})
}

func eventCursor(events []db.Event) string {
	var latest time.Time
	for _, e := range events {
		if e.UpdatedAt.After(latest) {
			latest = e.UpdatedAt
		}
	}
	if latest.IsZero() {
		return ""
	}
	return latest.UTC().Format(time.RFC3339)
}

// GetEvent handles GET /api/v1/events/{id}.
func (h *Handler) GetEvent(w http.ResponseWriter, r *http.Request) {
	_, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}

	event, err := h.store.GetEvent(r.Context(), householdID, strings.TrimSpace(chi.URLParam(r, "id")))
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "Event not found", nil)
			return
		}
		h.writeInternalError(w, r, "failed to load event", err)
		return
	}
	writeJSON(w, http.StatusOK, event)
}

// UpdateEvent handles PATCH /api/v1/events/{id}: full-replace guarded by
// base_updated_at. The pet link and kind are immutable (single-pet,
// single-kind base rows); stale writes get 409 with the server copy.
func (h *Handler) UpdateEvent(w http.ResponseWriter, r *http.Request) {
	userID, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}
	id := strings.TrimSpace(chi.URLParam(r, "id"))

	var req eventPatchReq
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}
	if req.BaseUpdatedAt.IsZero() {
		writeError(w, http.StatusBadRequest, "invalid_body", "base_updated_at is required", nil)
		return
	}
	in := db.EventInput{
		ID:          id,
		PetID:       strings.TrimSpace(req.PetID),
		Kind:        req.Kind,
		OccurredAt:  req.OccurredAt,
		NextDueAt:   req.NextDueAt,
		Title:       req.Title,
		Vaccination: req.Vaccination,
		Grooming:    req.Grooming,
		Weight:      req.Weight,
		Course:      req.Course,
	}
	if in.Course != nil && strings.TrimSpace(in.Course.Route) == "" {
		in.Course.Route = "oral"
	}
	if err := validateEventInput(&in); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body", err.Error(), nil)
		return
	}

	current, err := h.store.GetEvent(r.Context(), householdID, id)
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "Event not found", nil)
			return
		}
		h.writeInternalError(w, r, "failed to load event", err)
		return
	}
	if in.PetID != current.PetID {
		writeError(w, http.StatusUnprocessableEntity, "invalid_pet_id", "pet_id is immutable", nil)
		return
	}
	if in.Kind != current.Kind {
		writeError(w, http.StatusBadRequest, "invalid_body", "kind is immutable", nil)
		return
	}

	event, err := h.store.UpdateEvent(r.Context(), householdID, id, in, req.BaseUpdatedAt, userID)
	if err != nil {
		switch {
		case errors.Is(err, db.ErrNotFound):
			writeError(w, http.StatusNotFound, "not_found", "Event not found", nil)
		case errors.Is(err, db.ErrInvalidPetID):
			writeError(w, http.StatusUnprocessableEntity, "invalid_pet_id", "Unknown pet reference", nil)
		case errors.Is(err, db.ErrConflict):
			serverCopy, gerr := h.store.GetEvent(r.Context(), householdID, id)
			if gerr != nil {
				serverCopy = current
			}
			conflictWithServer(w, "Event was modified by another device", serverCopy)
		default:
			h.writeInternalError(w, r, "failed to update event", err)
		}
		return
	}
	writeJSON(w, http.StatusOK, event)
}

// DeleteEvent handles DELETE /api/v1/events/{id}.
func (h *Handler) DeleteEvent(w http.ResponseWriter, r *http.Request) {
	_, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}

	if err := h.store.DeleteEvent(r.Context(), householdID, strings.TrimSpace(chi.URLParam(r, "id"))); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "Event not found", nil)
			return
		}
		h.writeInternalError(w, r, "failed to delete event", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------- medication intakes ----------

type intakeReq struct {
	ID           string     `json:"id"`
	CourseID     string     `json:"course_id"`
	DueAt        *time.Time `json:"due_at"`
	DoseSnapshot string     `json:"dose_snapshot"`
	Note         string     `json:"note"`
}

type intakePatchReq struct {
	BaseUpdatedAt time.Time  `json:"base_updated_at"`
	Status        string     `json:"status"`
	TakenAt       *time.Time `json:"taken_at"`
	Note          *string    `json:"note"`
	DoseSnapshot  *string    `json:"dose_snapshot"`
}

var validIntakeStatuses = map[string]bool{
	"pending": true,
	"taken":   true,
	"missed":  true,
	"skipped": true,
}

// CreateIntake handles POST /api/v1/intakes: idempotent insert (201/200).
// Unknown courses share the 422 invalid_pet_id "unknown reference" shape.
func (h *Handler) CreateIntake(w http.ResponseWriter, r *http.Request) {
	userID, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}

	var req intakeReq
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}
	if strings.TrimSpace(req.ID) == "" || strings.TrimSpace(req.CourseID) == "" {
		writeError(w, http.StatusBadRequest, "invalid_body", "id and course_id are required", nil)
		return
	}

	intake, created, err := h.store.CreateIntake(r.Context(), householdID, db.IntakeInput{
		ID:           strings.TrimSpace(req.ID),
		CourseID:     strings.TrimSpace(req.CourseID),
		DueAt:        req.DueAt,
		DoseSnapshot: req.DoseSnapshot,
		Note:         req.Note,
	}, userID)
	if err != nil {
		if errors.Is(err, db.ErrInvalidPetID) {
			writeError(w, http.StatusUnprocessableEntity, "invalid_pet_id", "Unknown course reference", nil)
			return
		}
		h.writeInternalError(w, r, "failed to create intake", err)
		return
	}
	if created {
		writeJSON(w, http.StatusCreated, intake)
		return
	}
	writeJSON(w, http.StatusOK, intake)
}

// ListIntakes handles GET /api/v1/intakes?modified_since=&course_id=.
func (h *Handler) ListIntakes(w http.ResponseWriter, r *http.Request) {
	_, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}

	since, err := parseSinceQuery(r, "modified_since")
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid modified_since (RFC3339 required)", nil)
		return
	}

	intakes, err := h.store.ListIntakesChangedSince(r.Context(), householdID, strings.TrimSpace(r.URL.Query().Get("course_id")), since)
	if err != nil {
		h.writeInternalError(w, r, "failed to list intakes", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"intakes": nonEmptyList(intakes),
		"cursor":  intakeCursor(intakes),
	})
}

func intakeCursor(intakes []db.MedIntake) string {
	var latest time.Time
	for _, in := range intakes {
		if in.UpdatedAt.After(latest) {
			latest = in.UpdatedAt
		}
	}
	if latest.IsZero() {
		return ""
	}
	return latest.UTC().Format(time.RFC3339)
}

// GetIntake handles GET /api/v1/intakes/{id}.
func (h *Handler) GetIntake(w http.ResponseWriter, r *http.Request) {
	_, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}

	intake, err := h.store.GetIntake(r.Context(), householdID, strings.TrimSpace(chi.URLParam(r, "id")))
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "Intake not found", nil)
			return
		}
		h.writeInternalError(w, r, "failed to load intake", err)
		return
	}
	writeJSON(w, http.StatusOK, intake)
}

// UpdateIntake handles PATCH /api/v1/intakes/{id}: partial mutable-field
// update guarded by base_updated_at. Omitted fields keep the server value.
func (h *Handler) UpdateIntake(w http.ResponseWriter, r *http.Request) {
	userID, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}
	id := strings.TrimSpace(chi.URLParam(r, "id"))

	var req intakePatchReq
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}
	if req.BaseUpdatedAt.IsZero() {
		writeError(w, http.StatusBadRequest, "invalid_body", "base_updated_at is required", nil)
		return
	}
	status := strings.TrimSpace(req.Status)
	if status != "" && !validIntakeStatuses[status] {
		writeError(w, http.StatusBadRequest, "invalid_body", "status must be pending, taken, missed, or skipped", nil)
		return
	}

	current, err := h.store.GetIntake(r.Context(), householdID, id)
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "Intake not found", nil)
			return
		}
		h.writeInternalError(w, r, "failed to load intake", err)
		return
	}
	update := db.IntakeUpdate{
		Status:       current.Status,
		TakenAt:      current.TakenAt,
		Note:         current.Note,
		DoseSnapshot: current.DoseSnapshot,
	}
	if status != "" {
		update.Status = status
	}
	if req.TakenAt != nil {
		update.TakenAt = req.TakenAt
	}
	if req.Note != nil {
		update.Note = *req.Note
	}
	if req.DoseSnapshot != nil {
		update.DoseSnapshot = *req.DoseSnapshot
	}

	intake, err := h.store.UpdateIntake(r.Context(), householdID, id, update, req.BaseUpdatedAt, userID)
	if err != nil {
		switch {
		case errors.Is(err, db.ErrNotFound):
			writeError(w, http.StatusNotFound, "not_found", "Intake not found", nil)
		case errors.Is(err, db.ErrConflict):
			serverCopy, gerr := h.store.GetIntake(r.Context(), householdID, id)
			if gerr != nil {
				serverCopy = current
			}
			conflictWithServer(w, "Intake was modified by another device", serverCopy)
		default:
			h.writeInternalError(w, r, "failed to update intake", err)
		}
		return
	}
	writeJSON(w, http.StatusOK, intake)
}

// DeleteIntake handles DELETE /api/v1/intakes/{id}.
func (h *Handler) DeleteIntake(w http.ResponseWriter, r *http.Request) {
	_, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}

	if err := h.store.DeleteIntake(r.Context(), householdID, strings.TrimSpace(chi.URLParam(r, "id"))); err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "Intake not found", nil)
			return
		}
		h.writeInternalError(w, r, "failed to delete intake", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------- deletions timeline ----------

type deletionView struct {
	Resource  string    `json:"resource"`
	RecordID  string    `json:"record_id"`
	DeletedAt time.Time `json:"deleted_at"`
}

// ListDeletions handles GET /api/v1/deletions?deleted_since=: the caller's
// household tombstones for hard-delete propagation.
func (h *Handler) ListDeletions(w http.ResponseWriter, r *http.Request) {
	_, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}

	since, err := parseSinceQuery(r, "deleted_since")
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid deleted_since (RFC3339 required)", nil)
		return
	}

	tombs, err := h.store.ListHouseholdDeletions(r.Context(), householdID, since)
	if err != nil {
		h.writeInternalError(w, r, "failed to list deletions", err)
		return
	}
	views := make([]deletionView, 0, len(tombs))
	var latest time.Time
	for _, t := range tombs {
		views = append(views, deletionView{Resource: t.Resource, RecordID: t.ID, DeletedAt: t.DeletedAt})
		if t.DeletedAt.After(latest) {
			latest = t.DeletedAt
		}
	}
	cursor := ""
	if !latest.IsZero() {
		cursor = latest.UTC().Format(time.RFC3339)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"deletions": views,
		"cursor":    cursor,
	})
}
