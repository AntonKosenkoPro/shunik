package handlers

// Domain handler tests (pets, events, intakes, deletions). The store fake
// below is deliberately hermetic: it implements db.Store in-memory so these
// tests exercise the HTTP layer without depending on any engine
// implementation.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/antonkosenko/shunik/backend/internal/db"
)

// stubDomainStore is an in-memory db.Store for domain handler tests. It
// mirrors the documented store semantics the handlers rely on: idempotent
// creates, household scoping (ErrNotFound across households), LWW conflict
// detection (ErrConflict), ErrInvalidPetID for unknown references, and
// tombstones on deletes. Second-precision conflict comparison matches the
// RFC3339 wire format clients echo back.
type stubDomainStore struct {
	db.Store
	householdID string
	userID      string
	pets        map[string]db.Pet
	events      map[string]db.Event
	intakes     map[string]db.MedIntake
	docs        map[string]db.Document
	tombs       []db.Tombstone
	purgeResult db.PurgeResult
	purgeErr    error
}

var _ db.Store = (*stubDomainStore)(nil)

func newStubDomainStore() *stubDomainStore {
	return &stubDomainStore{
		householdID: "hh-test",
		userID:      "user-test",
		pets:        map[string]db.Pet{},
		events:      map[string]db.Event{},
		intakes:     map[string]db.MedIntake{},
		docs:        map[string]db.Document{},
	}
}

func staleConflict(base, stored time.Time) bool {
	return !base.UTC().Truncate(time.Second).Equal(stored.UTC().Truncate(time.Second))
}

func conflictErr() error { return fmt.Errorf("stale write: %w", db.ErrConflict) }

func (s *stubDomainStore) tomb(resource, id string) {
	s.tombs = append(s.tombs, db.Tombstone{Resource: resource, ID: id, DeletedAt: time.Now().UTC()})
}

func (s *stubDomainStore) EnsureHousehold(_ context.Context, _ string) (db.Household, error) {
	return db.Household{ID: s.householdID, CreatedAt: time.Now().UTC(), UpdatedAt: time.Now().UTC()}, nil
}

func (s *stubDomainStore) GetUserByID(_ context.Context, _ string) (db.User, error) {
	return db.User{ID: s.userID, Email: "test@example.com", EmailVerified: true}, nil
}

func (s *stubDomainStore) PurgeUser(_ context.Context, _, _ string, _ func(string) string) (db.PurgeResult, error) {
	if s.purgeErr != nil {
		return db.PurgeResult{}, s.purgeErr
	}
	return s.purgeResult, nil
}

// --- pets ---

func (s *stubDomainStore) CreatePet(_ context.Context, householdID string, in db.PetInput, updatedBy string) (db.Pet, bool, error) {
	if p, ok := s.pets[householdID+"/"+in.ID]; ok {
		return p, false, nil
	}
	now := time.Now().UTC()
	p := db.Pet{ID: in.ID, HouseholdID: householdID, Name: in.Name, Species: in.Species,
		Birthdate: in.Birthdate, Notes: in.Notes, CreatedAt: now, UpdatedAt: now, UpdatedBy: updatedBy}
	s.pets[householdID+"/"+in.ID] = p
	return p, true, nil
}

func (s *stubDomainStore) GetPet(_ context.Context, householdID, petID string) (db.Pet, error) {
	p, ok := s.pets[householdID+"/"+petID]
	if !ok || p.HouseholdID != householdID {
		return db.Pet{}, fmt.Errorf("get pet: %w", db.ErrNotFound)
	}
	return p, nil
}

func (s *stubDomainStore) ListPetsChangedSince(_ context.Context, householdID string, since *time.Time) ([]db.Pet, error) {
	var out []db.Pet
	for _, p := range s.pets {
		if p.HouseholdID != householdID {
			continue
		}
		if since != nil && !p.UpdatedAt.After(*since) {
			continue
		}
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].UpdatedAt.Before(out[j].UpdatedAt) })
	return out, nil
}

func (s *stubDomainStore) UpdatePet(_ context.Context, householdID, petID string, in db.PetInput, base time.Time, updatedBy string) (db.Pet, error) {
	p, ok := s.pets[householdID+"/"+petID]
	if !ok || p.HouseholdID != householdID {
		return db.Pet{}, fmt.Errorf("update pet: %w", db.ErrNotFound)
	}
	if staleConflict(base, p.UpdatedAt) {
		return db.Pet{}, conflictErr()
	}
	p.Name, p.Species, p.Birthdate, p.Notes = in.Name, in.Species, in.Birthdate, in.Notes
	p.UpdatedAt, p.UpdatedBy = time.Now().UTC(), updatedBy
	s.pets[householdID+"/"+petID] = p
	return p, nil
}

func (s *stubDomainStore) DeletePet(_ context.Context, householdID, petID, _ string) error {
	p, ok := s.pets[householdID+"/"+petID]
	if !ok || p.HouseholdID != householdID {
		return fmt.Errorf("delete pet: %w", db.ErrNotFound)
	}
	for id, e := range s.events {
		if e.HouseholdID == householdID && e.PetID == petID {
			for iid, in := range s.intakes {
				if in.HouseholdID == householdID && in.CourseID == id {
					delete(s.intakes, iid)
					s.tomb("intake", in.ID)
				}
			}
			delete(s.events, id)
			s.tomb("event", e.ID)
		}
	}
	for id, d := range s.docs {
		if d.HouseholdID != householdID {
			continue
		}
		kept := d.PetIDs[:0:0]
		for _, pid := range d.PetIDs {
			if pid != petID {
				kept = append(kept, pid)
			}
		}
		d.PetIDs = kept
		d.UpdatedAt = time.Now().UTC()
		s.docs[id] = d
	}
	delete(s.pets, householdID+"/"+petID)
	s.tomb("pet", petID)
	return nil
}

// --- events ---

func (s *stubDomainStore) CreateEvent(_ context.Context, householdID string, in db.EventInput, updatedBy string) (db.Event, bool, error) {
	if _, ok := s.pets[householdID+"/"+in.PetID]; !ok {
		return db.Event{}, false, fmt.Errorf("create event: %w", db.ErrInvalidPetID)
	}
	if e, ok := s.events[householdID+"/"+in.ID]; ok {
		return e, false, nil
	}
	now := time.Now().UTC()
	e := db.Event{ID: in.ID, HouseholdID: householdID, PetID: in.PetID, Kind: in.Kind,
		OccurredAt: in.OccurredAt, NextDueAt: in.NextDueAt, Title: in.Title,
		Vaccination: in.Vaccination, Grooming: in.Grooming, Weight: in.Weight,
		CreatedAt: now, UpdatedAt: now, UpdatedBy: updatedBy}
	if in.Course != nil {
		c := *in.Course
		e.Course = &c
	}
	s.events[householdID+"/"+in.ID] = e
	return e, true, nil
}

func (s *stubDomainStore) GetEvent(_ context.Context, householdID, eventID string) (db.Event, error) {
	e, ok := s.events[householdID+"/"+eventID]
	if !ok || e.HouseholdID != householdID {
		return db.Event{}, fmt.Errorf("get event: %w", db.ErrNotFound)
	}
	return e, nil
}

func (s *stubDomainStore) ListEventsChangedSince(_ context.Context, householdID string, since *time.Time, petID string) ([]db.Event, error) {
	var out []db.Event
	for _, e := range s.events {
		if e.HouseholdID != householdID {
			continue
		}
		if petID != "" && e.PetID != petID {
			continue
		}
		if since != nil && !e.UpdatedAt.After(*since) {
			continue
		}
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].UpdatedAt.Before(out[j].UpdatedAt) })
	return out, nil
}

func (s *stubDomainStore) UpdateEvent(_ context.Context, householdID, eventID string, in db.EventInput, base time.Time, updatedBy string) (db.Event, error) {
	e, ok := s.events[householdID+"/"+eventID]
	if !ok || e.HouseholdID != householdID {
		return db.Event{}, fmt.Errorf("update event: %w", db.ErrNotFound)
	}
	if staleConflict(base, e.UpdatedAt) {
		return db.Event{}, conflictErr()
	}
	if _, ok := s.pets[householdID+"/"+in.PetID]; !ok {
		return db.Event{}, fmt.Errorf("update event: %w", db.ErrInvalidPetID)
	}
	e.PetID, e.Kind, e.OccurredAt, e.NextDueAt, e.Title = in.PetID, in.Kind, in.OccurredAt, in.NextDueAt, in.Title
	e.Vaccination, e.Grooming, e.Weight = in.Vaccination, in.Grooming, in.Weight
	e.Course = nil
	if in.Course != nil {
		c := *in.Course
		e.Course = &c
	}
	e.UpdatedAt, e.UpdatedBy = time.Now().UTC(), updatedBy
	s.events[householdID+"/"+eventID] = e
	return e, nil
}

func (s *stubDomainStore) DeleteEvent(_ context.Context, householdID, eventID string) error {
	e, ok := s.events[householdID+"/"+eventID]
	if !ok || e.HouseholdID != householdID {
		return fmt.Errorf("delete event: %w", db.ErrNotFound)
	}
	delete(s.events, householdID+"/"+eventID)
	s.tomb("event", eventID)
	return nil
}

// --- intakes ---

func (s *stubDomainStore) CreateIntake(_ context.Context, householdID string, in db.IntakeInput, _ string) (db.MedIntake, bool, error) {
	if i, ok := s.intakes[householdID+"/"+in.ID]; ok {
		return i, false, nil
	}
	course, ok := s.events[householdID+"/"+in.CourseID]
	if !ok || course.HouseholdID != householdID || course.Kind != "med_course" {
		return db.MedIntake{}, false, fmt.Errorf("create intake: %w", db.ErrInvalidPetID)
	}
	now := time.Now().UTC()
	i := db.MedIntake{ID: in.ID, HouseholdID: householdID, CourseID: in.CourseID, DueAt: in.DueAt,
		Status: "pending", DoseSnapshot: in.DoseSnapshot, Note: in.Note, CreatedAt: now, UpdatedAt: now}
	s.intakes[householdID+"/"+in.ID] = i
	return i, true, nil
}

func (s *stubDomainStore) GetIntake(_ context.Context, householdID, intakeID string) (db.MedIntake, error) {
	i, ok := s.intakes[householdID+"/"+intakeID]
	if !ok || i.HouseholdID != householdID {
		return db.MedIntake{}, fmt.Errorf("get intake: %w", db.ErrNotFound)
	}
	return i, nil
}

func (s *stubDomainStore) ListIntakesChangedSince(_ context.Context, householdID, courseID string, since *time.Time) ([]db.MedIntake, error) {
	var out []db.MedIntake
	for _, i := range s.intakes {
		if i.HouseholdID != householdID {
			continue
		}
		if courseID != "" && i.CourseID != courseID {
			continue
		}
		if since != nil && !i.UpdatedAt.After(*since) {
			continue
		}
		out = append(out, i)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].UpdatedAt.Before(out[j].UpdatedAt) })
	return out, nil
}

func (s *stubDomainStore) UpdateIntake(_ context.Context, householdID, intakeID string, in db.IntakeUpdate, base time.Time, markedBy string) (db.MedIntake, error) {
	i, ok := s.intakes[householdID+"/"+intakeID]
	if !ok || i.HouseholdID != householdID {
		return db.MedIntake{}, fmt.Errorf("update intake: %w", db.ErrNotFound)
	}
	if staleConflict(base, i.UpdatedAt) {
		return db.MedIntake{}, conflictErr()
	}
	i.Status, i.TakenAt, i.Note, i.DoseSnapshot = in.Status, in.TakenAt, in.Note, in.DoseSnapshot
	if i.Status == "taken" && i.TakenAt == nil {
		now := time.Now().UTC()
		i.TakenAt = &now
	}
	i.MarkedBy = markedBy
	i.UpdatedAt = time.Now().UTC()
	s.intakes[householdID+"/"+intakeID] = i
	return i, nil
}

func (s *stubDomainStore) DeleteIntake(_ context.Context, householdID, intakeID string) error {
	i, ok := s.intakes[householdID+"/"+intakeID]
	if !ok || i.HouseholdID != householdID {
		return fmt.Errorf("delete intake: %w", db.ErrNotFound)
	}
	delete(s.intakes, householdID+"/"+intakeID)
	s.tomb("intake", intakeID)
	return nil
}

// --- documents ---

func (s *stubDomainStore) CreateDocument(_ context.Context, householdID string, in db.DocumentInput, updatedBy string) (db.Document, bool, error) {
	if d, ok := s.docs[householdID+"/"+in.ID]; ok {
		return d, false, nil
	}
	for _, pid := range in.PetIDs {
		if _, ok := s.pets[householdID+"/"+pid]; !ok {
			return db.Document{}, false, fmt.Errorf("create document: %w", db.ErrInvalidPetID)
		}
	}
	now := time.Now().UTC()
	petIDs := append([]string{}, in.PetIDs...)
	d := db.Document{ID: in.ID, HouseholdID: householdID, Title: in.Title, Mime: in.Mime,
		SizeBytes: in.SizeBytes, Filename: in.Filename, BlobKey: "stub/" + in.ID,
		Ready: false, PetIDs: petIDs, CreatedAt: now, UpdatedAt: now, UpdatedBy: updatedBy}
	s.docs[householdID+"/"+in.ID] = d
	return d, true, nil
}

func (s *stubDomainStore) GetDocument(_ context.Context, householdID, docID string) (db.Document, error) {
	d, ok := s.docs[householdID+"/"+docID]
	if !ok || d.HouseholdID != householdID {
		return db.Document{}, fmt.Errorf("get document: %w", db.ErrNotFound)
	}
	return d, nil
}

func (s *stubDomainStore) ListDocumentsChangedSince(_ context.Context, householdID string, since *time.Time) ([]db.Document, error) {
	var out []db.Document
	for _, d := range s.docs {
		if d.HouseholdID != householdID {
			continue
		}
		if since != nil && !d.UpdatedAt.After(*since) {
			continue
		}
		out = append(out, d)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].UpdatedAt.Before(out[j].UpdatedAt) })
	return out, nil
}

func (s *stubDomainStore) UpdateDocument(_ context.Context, householdID, docID, title string, petIDs []string, base time.Time, updatedBy string) (db.Document, error) {
	d, ok := s.docs[householdID+"/"+docID]
	if !ok || d.HouseholdID != householdID {
		return db.Document{}, fmt.Errorf("update document: %w", db.ErrNotFound)
	}
	if staleConflict(base, d.UpdatedAt) {
		return db.Document{}, conflictErr()
	}
	for _, pid := range petIDs {
		if _, ok := s.pets[householdID+"/"+pid]; !ok {
			return db.Document{}, fmt.Errorf("update document: %w", db.ErrInvalidPetID)
		}
	}
	d.Title = title
	d.PetIDs = append([]string{}, petIDs...)
	d.UpdatedAt, d.UpdatedBy = time.Now().UTC(), updatedBy
	s.docs[householdID+"/"+docID] = d
	return d, nil
}

func (s *stubDomainStore) DeleteDocument(_ context.Context, householdID, docID string) (db.Document, error) {
	d, ok := s.docs[householdID+"/"+docID]
	if !ok || d.HouseholdID != householdID {
		return db.Document{}, fmt.Errorf("delete document: %w", db.ErrNotFound)
	}
	delete(s.docs, householdID+"/"+docID)
	s.tomb("document", docID)
	return d, nil
}

func (s *stubDomainStore) ConfirmDocument(_ context.Context, householdID, docID string) (db.Document, error) {
	d, ok := s.docs[householdID+"/"+docID]
	if !ok || d.HouseholdID != householdID {
		return db.Document{}, fmt.Errorf("confirm document: %w", db.ErrNotFound)
	}
	d.Ready = true
	d.UpdatedAt = time.Now().UTC()
	s.docs[householdID+"/"+docID] = d
	return d, nil
}

func (s *stubDomainStore) ListUnconfirmedDocuments(_ context.Context, olderThan time.Time, limit int) ([]db.Document, error) {
	var out []db.Document
	for _, d := range s.docs {
		if d.Ready || !d.CreatedAt.Before(olderThan) {
			continue
		}
		out = append(out, db.Document{ID: d.ID, BlobKey: d.BlobKey})
		if len(out) >= limit && limit > 0 {
			break
		}
	}
	return out, nil
}

func (s *stubDomainStore) DeleteDocumentsByIDs(_ context.Context, ids []string) error {
	for _, id := range ids {
		for k, d := range s.docs {
			if d.ID == id {
				delete(s.docs, k)
			}
		}
	}
	return nil
}

func (s *stubDomainStore) ListHouseholdDeletions(_ context.Context, householdID string, since *time.Time) ([]db.Tombstone, error) {
	var out []db.Tombstone
	for _, t := range s.tombs {
		if since != nil && !t.DeletedAt.After(*since) {
			continue
		}
		out = append(out, t)
	}
	_ = householdID
	sort.Slice(out, func(i, j int) bool { return out[i].DeletedAt.Before(out[j].DeletedAt) })
	return out, nil
}

// --- test scaffolding ---

func newDomainTestSetup(t *testing.T, withBlob bool) (*Handler, *stubDomainStore, *fakeDocBlobStore) {
	t.Helper()
	stub := newStubDomainStore()
	var fb *fakeDocBlobStore
	var opts []HandlerOption
	if withBlob {
		fb = &fakeDocBlobStore{objects: map[string]bool{}}
		opts = append(opts, WithBlobStore(fb))
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := NewHandler(stub, nil, nil, nil, &RateLimiterGroup{}, nil, HandlerConfig{}, logger, nil, opts...)
	return h, stub, fb
}

// domRequest builds a JSON request carrying the authenticated user id. An
// empty userID leaves the request unauthenticated (401 path).
func domRequest(t *testing.T, method, path string, body any, userID string) *http.Request {
	t.Helper()
	var reader *bytes.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("marshal body: %v", err)
		}
		reader = bytes.NewReader(raw)
	} else {
		reader = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, path, reader)
	req.Header.Set("Content-Type", "application/json")
	if userID == "" {
		return req
	}
	return req.WithContext(context.WithValue(req.Context(), ContextKeyUserID, userID))
}

// domRequestWithID adds a chi {id} URL param to the request.
func domRequestWithID(t *testing.T, method, path, param, id string, body any, userID string) *http.Request {
	t.Helper()
	req := domRequest(t, method, path, body, userID)
	routeCtx := chi.NewRouteContext()
	routeCtx.URLParams.Add(param, id)
	return req.WithContext(context.WithValue(req.Context(), chi.RouteCtxKey, routeCtx))
}

func domDecode(t *testing.T, w *httptest.ResponseRecorder, v any) {
	t.Helper()
	if err := json.Unmarshal(w.Body.Bytes(), v); err != nil {
		t.Fatalf("decode response %q: %v", w.Body.String(), err)
	}
}

func domErrCode(t *testing.T, w *httptest.ResponseRecorder) string {
	t.Helper()
	var env struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	domDecode(t, w, &env)
	return env.Error.Code
}

func domConflictServer(t *testing.T, w *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var env struct {
		Error struct {
			Details map[string]any `json:"details"`
		} `json:"error"`
	}
	domDecode(t, w, &env)
	server, ok := env.Error.Details["server"].(map[string]any)
	if !ok {
		t.Fatalf("expected details.server object, got %s", w.Body.String())
	}
	return server
}

// --- pets ---

func TestPets_CRUD(t *testing.T) {
	h, _, _ := newDomainTestSetup(t, false)
	const uid = "user-test"

	w := httptest.NewRecorder()
	h.CreatePet(w, domRequest(t, http.MethodPost, "/api/v1/pets",
		map[string]any{"id": "pet-1", "name": "Barsik", "species": "cat", "notes": "fluffy"}, uid))
	if w.Code != http.StatusCreated {
		t.Fatalf("create: expected 201, got %d (%s)", w.Code, w.Body.String())
	}

	w = httptest.NewRecorder()
	h.GetPet(w, domRequestWithID(t, http.MethodGet, "/api/v1/pets/pet-1", "id", "pet-1", nil, uid))
	if w.Code != http.StatusOK {
		t.Fatalf("get: expected 200, got %d", w.Code)
	}
	var pet db.Pet
	domDecode(t, w, &pet)
	if pet.Name != "Barsik" || pet.Species != "cat" {
		t.Fatalf("unexpected pet: %+v", pet)
	}

	w = httptest.NewRecorder()
	h.ListPets(w, domRequest(t, http.MethodGet, "/api/v1/pets", nil, uid))
	if w.Code != http.StatusOK {
		t.Fatalf("list: expected 200, got %d", w.Code)
	}
	var list struct {
		Pets   []db.Pet `json:"pets"`
		Cursor string   `json:"cursor"`
	}
	domDecode(t, w, &list)
	if len(list.Pets) != 1 || list.Cursor == "" {
		t.Fatalf("expected one pet + cursor, got %+v", list)
	}
	if _, err := time.Parse(time.RFC3339, list.Cursor); err != nil {
		t.Fatalf("cursor is not RFC3339: %q", list.Cursor)
	}

	w = httptest.NewRecorder()
	h.UpdatePet(w, domRequestWithID(t, http.MethodPatch, "/api/v1/pets/pet-1", "id", "pet-1",
		map[string]any{"base_updated_at": pet.UpdatedAt.Format(time.RFC3339), "name": "Barsik II", "species": "cat"}, uid))
	if w.Code != http.StatusOK {
		t.Fatalf("patch: expected 200, got %d (%s)", w.Code, w.Body.String())
	}
	domDecode(t, w, &pet)
	if pet.Name != "Barsik II" {
		t.Fatalf("expected rename, got %+v", pet)
	}

	w = httptest.NewRecorder()
	h.UpdatePet(w, domRequestWithID(t, http.MethodPatch, "/api/v1/pets/pet-1", "id", "pet-1",
		map[string]any{"base_updated_at": time.Now().Add(-time.Hour).Format(time.RFC3339), "name": "Stale", "species": "cat"}, uid))
	if w.Code != http.StatusConflict {
		t.Fatalf("stale patch: expected 409, got %d (%s)", w.Code, w.Body.String())
	}
	if domErrCode(t, w) != "conflict" {
		t.Fatalf("expected conflict code, got %s", w.Body.String())
	}
	if got := domConflictServer(t, w)["name"]; got != "Barsik II" {
		t.Fatalf("expected server copy in details, got %v", got)
	}

	w = httptest.NewRecorder()
	h.DeletePet(w, domRequestWithID(t, http.MethodDelete, "/api/v1/pets/pet-1", "id", "pet-1", nil, uid))
	if w.Code != http.StatusNoContent {
		t.Fatalf("delete: expected 204, got %d", w.Code)
	}

	w = httptest.NewRecorder()
	h.GetPet(w, domRequestWithID(t, http.MethodGet, "/api/v1/pets/pet-1", "id", "pet-1", nil, uid))
	if w.Code != http.StatusNotFound || domErrCode(t, w) != "not_found" {
		t.Fatalf("get after delete: expected 404 not_found, got %d (%s)", w.Code, w.Body.String())
	}
}

func TestPets_ReplayAndValidation(t *testing.T) {
	h, _, _ := newDomainTestSetup(t, false)
	const uid = "user-test"

	body := map[string]any{"id": "pet-r", "name": "Rex", "species": "dog"}
	w := httptest.NewRecorder()
	h.CreatePet(w, domRequest(t, http.MethodPost, "/api/v1/pets", body, uid))
	if w.Code != http.StatusCreated {
		t.Fatalf("first create: expected 201, got %d", w.Code)
	}
	w = httptest.NewRecorder()
	h.CreatePet(w, domRequest(t, http.MethodPost, "/api/v1/pets", body, uid))
	if w.Code != http.StatusOK {
		t.Fatalf("replay: expected 200, got %d (%s)", w.Code, w.Body.String())
	}

	for _, bad := range []map[string]any{
		{"id": "x", "name": "", "species": "dog"},
		{"id": "x", "name": "Rex", "species": ""},
		{"id": "", "name": "Rex", "species": "dog"},
	} {
		w = httptest.NewRecorder()
		h.CreatePet(w, domRequest(t, http.MethodPost, "/api/v1/pets", bad, uid))
		if w.Code != http.StatusBadRequest || domErrCode(t, w) != "invalid_body" {
			t.Fatalf("bad create %+v: expected 400 invalid_body, got %d (%s)", bad, w.Code, w.Body.String())
		}
	}

	w = httptest.NewRecorder()
	h.CreatePet(w, domRequest(t, http.MethodPost, "/api/v1/pets", body, ""))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("unauth: expected 401, got %d", w.Code)
	}

	req := domRequest(t, http.MethodGet, "/api/v1/pets?modified_since=not-a-time", nil, uid)
	w = httptest.NewRecorder()
	h.ListPets(w, req)
	if w.Code != http.StatusBadRequest || domErrCode(t, w) != "invalid_body" {
		t.Fatalf("bad cursor: expected 400 invalid_body, got %d (%s)", w.Code, w.Body.String())
	}

	w = httptest.NewRecorder()
	h.ListPets(w, domRequest(t, http.MethodGet, "/api/v1/pets", nil, ""))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("unauth list: expected 401, got %d", w.Code)
	}
}

// --- events ---

func seedPet(t *testing.T, h *Handler, uid, id string) {
	t.Helper()
	w := httptest.NewRecorder()
	h.CreatePet(w, domRequest(t, http.MethodPost, "/api/v1/pets",
		map[string]any{"id": id, "name": "N-" + id, "species": "cat"}, uid))
	if w.Code != http.StatusCreated {
		t.Fatalf("seed pet %s: %d (%s)", id, w.Code, w.Body.String())
	}
}

func vaccBody(id, petID string) map[string]any {
	return map[string]any{
		"id": id, "pet_id": petID, "kind": "vaccination",
		"occurred_at": time.Now().UTC().Format(time.RFC3339),
		"title":       "Nobivac",
		"vaccination": map[string]any{"vaccine": "Nobivac Tricat", "batch": "b1"},
	}
}

func courseBody(id, petID string) map[string]any {
	return map[string]any{
		"id": id, "pet_id": petID, "kind": "med_course",
		"occurred_at": time.Now().UTC().Format(time.RFC3339),
		"title":       "Antibiotics",
		"course": map[string]any{
			"drug_name": "Amoxicillin", "dose_amount": "0.5", "dose_unit": "ml",
			"schedule_kind": "daily", "schedule_times": "08:00,20:00",
		},
	}
}

func TestEvents_CRUDAndValidation(t *testing.T) {
	h, _, _ := newDomainTestSetup(t, false)
	const uid = "user-test"
	seedPet(t, h, uid, "pet-1")

	w := httptest.NewRecorder()
	h.CreateEvent(w, domRequest(t, http.MethodPost, "/api/v1/events", vaccBody("ev-1", "pet-1"), uid))
	if w.Code != http.StatusCreated {
		t.Fatalf("create vacc: expected 201, got %d (%s)", w.Code, w.Body.String())
	}
	var ev db.Event
	domDecode(t, w, &ev)
	if ev.Vaccination == nil || ev.Vaccination.Vaccine != "Nobivac Tricat" {
		t.Fatalf("detail not joined: %+v", ev)
	}

	w = httptest.NewRecorder()
	h.CreateEvent(w, domRequest(t, http.MethodPost, "/api/v1/events", vaccBody("ev-1", "pet-1"), uid))
	if w.Code != http.StatusOK {
		t.Fatalf("replay: expected 200, got %d", w.Code)
	}

	w = httptest.NewRecorder()
	h.CreateEvent(w, domRequest(t, http.MethodPost, "/api/v1/events", courseBody("ev-course", "pet-1"), uid))
	if w.Code != http.StatusCreated {
		t.Fatalf("create course: expected 201, got %d (%s)", w.Code, w.Body.String())
	}
	domDecode(t, w, &ev)
	if ev.Course == nil || ev.Course.Route != "oral" {
		t.Fatalf("expected route default oral, got %+v", ev.Course)
	}

	badKind := vaccBody("ev-x", "pet-1")
	badKind["kind"] = "surgery"
	twoDetails := vaccBody("ev-y", "pet-1")
	twoDetails["weight"] = map[string]any{"grams": 100}
	noDetail := vaccBody("ev-z", "pet-1")
	delete(noDetail, "vaccination")
	emptyVaccine := vaccBody("ev-w", "pet-1")
	emptyVaccine["vaccination"] = map[string]any{"vaccine": ""}
	badWeight := map[string]any{"id": "ev-v", "pet_id": "pet-1", "kind": "weight",
		"occurred_at": time.Now().UTC().Format(time.RFC3339), "weight": map[string]any{"grams": 0}}
	badDose := courseBody("ev-u", "pet-1")
	badDose["course"].(map[string]any)["dose_amount"] = "zero"
	badTimes := courseBody("ev-t", "pet-1")
	badTimes["course"].(map[string]any)["schedule_times"] = "8am"
	for i, bad := range []map[string]any{badKind, twoDetails, noDetail, emptyVaccine, badWeight, badDose, badTimes} {
		w = httptest.NewRecorder()
		h.CreateEvent(w, domRequest(t, http.MethodPost, "/api/v1/events", bad, uid))
		if w.Code != http.StatusBadRequest || domErrCode(t, w) != "invalid_body" {
			t.Fatalf("bad event %d: expected 400 invalid_body, got %d (%s)", i, w.Code, w.Body.String())
		}
	}

	unknownPet := vaccBody("ev-np", "ghost")
	w = httptest.NewRecorder()
	h.CreateEvent(w, domRequest(t, http.MethodPost, "/api/v1/events", unknownPet, uid))
	if w.Code != http.StatusUnprocessableEntity || domErrCode(t, w) != "invalid_pet_id" {
		t.Fatalf("unknown pet: expected 422 invalid_pet_id, got %d (%s)", w.Code, w.Body.String())
	}

	req := domRequest(t, http.MethodGet, "/api/v1/events?pet_id=pet-1", nil, uid)
	w = httptest.NewRecorder()
	h.ListEvents(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("list: expected 200, got %d", w.Code)
	}
	var list struct {
		Events []db.Event `json:"events"`
		Cursor string     `json:"cursor"`
	}
	domDecode(t, w, &list)
	if len(list.Events) != 2 || list.Cursor == "" {
		t.Fatalf("expected two events + cursor, got %+v", list)
	}

	patch := map[string]any{
		"base_updated_at": list.Events[0].UpdatedAt.Format(time.RFC3339),
		"pet_id":          "pet-1", "kind": "vaccination",
		"occurred_at": list.Events[0].OccurredAt.Format(time.RFC3339),
		"title":       "Nobivac renewed",
		"vaccination": map[string]any{"vaccine": "Nobivac Tricat"},
	}
	w = httptest.NewRecorder()
	h.UpdateEvent(w, domRequestWithID(t, http.MethodPatch, "/api/v1/events/ev-1", "id", "ev-1", patch, uid))
	if w.Code != http.StatusOK {
		t.Fatalf("patch: expected 200, got %d (%s)", w.Code, w.Body.String())
	}

	stale := map[string]any{
		"base_updated_at": time.Now().Add(-time.Hour).Format(time.RFC3339),
		"pet_id":          "pet-1", "kind": "vaccination",
		"occurred_at": time.Now().UTC().Format(time.RFC3339),
		"title":       "Stale",
		"vaccination": map[string]any{"vaccine": "X"},
	}
	w = httptest.NewRecorder()
	h.UpdateEvent(w, domRequestWithID(t, http.MethodPatch, "/api/v1/events/ev-1", "id", "ev-1", stale, uid))
	if w.Code != http.StatusConflict || domErrCode(t, w) != "conflict" {
		t.Fatalf("stale: expected 409 conflict, got %d (%s)", w.Code, w.Body.String())
	}
	if got := domConflictServer(t, w)["title"]; got != "Nobivac renewed" {
		t.Fatalf("expected server copy in details, got %v", got)
	}

	seedPet(t, h, uid, "pet-2")
	moved := map[string]any{
		"base_updated_at": time.Now().UTC().Format(time.RFC3339),
		"pet_id":          "pet-2", "kind": "vaccination",
		"occurred_at": time.Now().UTC().Format(time.RFC3339),
		"title":       "Moved",
		"vaccination": map[string]any{"vaccine": "X"},
	}
	w = httptest.NewRecorder()
	h.UpdateEvent(w, domRequestWithID(t, http.MethodPatch, "/api/v1/events/ev-1", "id", "ev-1", moved, uid))
	if w.Code != http.StatusUnprocessableEntity || domErrCode(t, w) != "invalid_pet_id" {
		t.Fatalf("pet move: expected 422 invalid_pet_id, got %d (%s)", w.Code, w.Body.String())
	}

	w = httptest.NewRecorder()
	h.DeleteEvent(w, domRequestWithID(t, http.MethodDelete, "/api/v1/events/ev-1", "id", "ev-1", nil, uid))
	if w.Code != http.StatusNoContent {
		t.Fatalf("delete: expected 204, got %d", w.Code)
	}
	w = httptest.NewRecorder()
	h.GetEvent(w, domRequestWithID(t, http.MethodGet, "/api/v1/events/ev-1", "id", "ev-1", nil, uid))
	if w.Code != http.StatusNotFound {
		t.Fatalf("get after delete: expected 404, got %d", w.Code)
	}
}

// --- intakes ---

func TestIntakes_CRUD(t *testing.T) {
	h, _, _ := newDomainTestSetup(t, false)
	const uid = "user-test"
	seedPet(t, h, uid, "pet-1")

	w := httptest.NewRecorder()
	h.CreateEvent(w, domRequest(t, http.MethodPost, "/api/v1/events", courseBody("ev-course", "pet-1"), uid))
	if w.Code != http.StatusCreated {
		t.Fatalf("seed course: %d (%s)", w.Code, w.Body.String())
	}

	body := map[string]any{"id": "in-1", "course_id": "ev-course", "dose_snapshot": "0.5 ml", "note": "with food"}
	w = httptest.NewRecorder()
	h.CreateIntake(w, domRequest(t, http.MethodPost, "/api/v1/intakes", body, uid))
	if w.Code != http.StatusCreated {
		t.Fatalf("create: expected 201, got %d (%s)", w.Code, w.Body.String())
	}
	var intake db.MedIntake
	domDecode(t, w, &intake)
	if intake.Status != "pending" || intake.MarkedBy != "" {
		t.Fatalf("pending intake must be unmarked, got %+v", intake)
	}

	w = httptest.NewRecorder()
	h.CreateIntake(w, domRequest(t, http.MethodPost, "/api/v1/intakes", body, uid))
	if w.Code != http.StatusOK {
		t.Fatalf("replay: expected 200, got %d", w.Code)
	}

	ghost := map[string]any{"id": "in-x", "course_id": "ghost", "dose_snapshot": "0.5 ml"}
	w = httptest.NewRecorder()
	h.CreateIntake(w, domRequest(t, http.MethodPost, "/api/v1/intakes", ghost, uid))
	if w.Code != http.StatusUnprocessableEntity || domErrCode(t, w) != "invalid_pet_id" {
		t.Fatalf("unknown course: expected 422 invalid_pet_id, got %d (%s)", w.Code, w.Body.String())
	}

	// A non-course event id is also an unknown course reference.
	w = httptest.NewRecorder()
	h.CreateEvent(w, domRequest(t, http.MethodPost, "/api/v1/events", vaccBody("ev-v", "pet-1"), uid))
	if w.Code != http.StatusCreated {
		t.Fatalf("seed vacc: %d", w.Code)
	}
	notCourse := map[string]any{"id": "in-y", "course_id": "ev-v", "dose_snapshot": "x"}
	w = httptest.NewRecorder()
	h.CreateIntake(w, domRequest(t, http.MethodPost, "/api/v1/intakes", notCourse, uid))
	if w.Code != http.StatusUnprocessableEntity {
		t.Fatalf("non-course ref: expected 422, got %d (%s)", w.Code, w.Body.String())
	}

	take := map[string]any{"base_updated_at": intake.UpdatedAt.Format(time.RFC3339), "status": "taken"}
	w = httptest.NewRecorder()
	h.UpdateIntake(w, domRequestWithID(t, http.MethodPatch, "/api/v1/intakes/in-1", "id", "in-1", take, uid))
	if w.Code != http.StatusOK {
		t.Fatalf("take: expected 200, got %d (%s)", w.Code, w.Body.String())
	}
	domDecode(t, w, &intake)
	if intake.Status != "taken" || intake.MarkedBy != uid || intake.TakenAt == nil {
		t.Fatalf("taken mark must stamp taken_at + marked_by, got %+v", intake)
	}

	badStatus := map[string]any{"base_updated_at": intake.UpdatedAt.Format(time.RFC3339), "status": "eventually"}
	w = httptest.NewRecorder()
	h.UpdateIntake(w, domRequestWithID(t, http.MethodPatch, "/api/v1/intakes/in-1", "id", "in-1", badStatus, uid))
	if w.Code != http.StatusBadRequest || domErrCode(t, w) != "invalid_body" {
		t.Fatalf("bad status: expected 400, got %d (%s)", w.Code, w.Body.String())
	}

	stale := map[string]any{"base_updated_at": time.Now().Add(-time.Hour).Format(time.RFC3339), "status": "missed"}
	w = httptest.NewRecorder()
	h.UpdateIntake(w, domRequestWithID(t, http.MethodPatch, "/api/v1/intakes/in-1", "id", "in-1", stale, uid))
	if w.Code != http.StatusConflict || domErrCode(t, w) != "conflict" {
		t.Fatalf("stale: expected 409 conflict, got %d (%s)", w.Code, w.Body.String())
	}
	if got := domConflictServer(t, w)["status"]; got != "taken" {
		t.Fatalf("expected server copy in details, got %v", got)
	}

	req := domRequest(t, http.MethodGet, "/api/v1/intakes?course_id=ev-course", nil, uid)
	w = httptest.NewRecorder()
	h.ListIntakes(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("list: expected 200, got %d", w.Code)
	}
	var list struct {
		Intakes []db.MedIntake `json:"intakes"`
		Cursor  string         `json:"cursor"`
	}
	domDecode(t, w, &list)
	if len(list.Intakes) != 1 || list.Cursor == "" {
		t.Fatalf("expected one intake + cursor, got %+v", list)
	}

	w = httptest.NewRecorder()
	h.DeleteIntake(w, domRequestWithID(t, http.MethodDelete, "/api/v1/intakes/in-1", "id", "in-1", nil, uid))
	if w.Code != http.StatusNoContent {
		t.Fatalf("delete: expected 204, got %d", w.Code)
	}
	w = httptest.NewRecorder()
	h.GetIntake(w, domRequestWithID(t, http.MethodGet, "/api/v1/intakes/in-1", "id", "in-1", nil, uid))
	if w.Code != http.StatusNotFound {
		t.Fatalf("get after delete: expected 404, got %d", w.Code)
	}
}

// --- deletions ---

func TestDeletions_Timeline(t *testing.T) {
	h, _, _ := newDomainTestSetup(t, false)
	const uid = "user-test"
	seedPet(t, h, uid, "pet-1")

	w := httptest.NewRecorder()
	h.CreateEvent(w, domRequest(t, http.MethodPost, "/api/v1/events", vaccBody("ev-1", "pet-1"), uid))
	if w.Code != http.StatusCreated {
		t.Fatalf("seed event: %d", w.Code)
	}
	w = httptest.NewRecorder()
	h.DeleteEvent(w, domRequestWithID(t, http.MethodDelete, "/api/v1/events/ev-1", "id", "ev-1", nil, uid))
	if w.Code != http.StatusNoContent {
		t.Fatalf("delete event: %d", w.Code)
	}
	w = httptest.NewRecorder()
	h.DeletePet(w, domRequestWithID(t, http.MethodDelete, "/api/v1/pets/pet-1", "id", "pet-1", nil, uid))
	if w.Code != http.StatusNoContent {
		t.Fatalf("delete pet: %d", w.Code)
	}

	w = httptest.NewRecorder()
	h.ListDeletions(w, domRequest(t, http.MethodGet, "/api/v1/deletions", nil, uid))
	if w.Code != http.StatusOK {
		t.Fatalf("list: expected 200, got %d", w.Code)
	}
	var list struct {
		Deletions []struct {
			Resource string `json:"resource"`
			RecordID string `json:"record_id"`
			Deleted  string `json:"deleted_at"`
		} `json:"deletions"`
		Cursor string `json:"cursor"`
	}
	domDecode(t, w, &list)
	if len(list.Deletions) < 2 || list.Cursor == "" {
		t.Fatalf("expected tombstones + cursor, got %+v", list)
	}
	if _, err := time.Parse(time.RFC3339, list.Cursor); err != nil {
		t.Fatalf("cursor is not RFC3339: %q", list.Cursor)
	}
	if strings.Contains(w.Body.String(), `"id":`) && !strings.Contains(w.Body.String(), `"record_id":`) {
		t.Fatal("deletions must use record_id, not id")
	}

	future := time.Now().Add(time.Hour).UTC().Format(time.RFC3339)
	req := domRequest(t, http.MethodGet, "/api/v1/deletions?deleted_since="+future, nil, uid)
	w = httptest.NewRecorder()
	h.ListDeletions(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("filtered list: expected 200, got %d", w.Code)
	}
	var filtered struct {
		Deletions []any  `json:"deletions"`
		Cursor    string `json:"cursor"`
	}
	domDecode(t, w, &filtered)
	if filtered.Deletions == nil {
		t.Fatal("deletions must encode as an array, never null")
	}
	if len(filtered.Deletions) != 0 || filtered.Cursor != "" {
		t.Fatalf("expected empty page, got %+v", filtered)
	}

	req = domRequest(t, http.MethodGet, "/api/v1/deletions?deleted_since=bogus", nil, uid)
	w = httptest.NewRecorder()
	h.ListDeletions(w, req)
	if w.Code != http.StatusBadRequest || domErrCode(t, w) != "invalid_body" {
		t.Fatalf("bad param: expected 400, got %d (%s)", w.Code, w.Body.String())
	}

	w = httptest.NewRecorder()
	h.ListDeletions(w, domRequest(t, http.MethodGet, "/api/v1/deletions", nil, ""))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("unauth: expected 401, got %d", w.Code)
	}
}
