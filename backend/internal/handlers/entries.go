package handlers

import (
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/antonkosenko/time-of-life/backend/internal/db"
)

// ---------- Entries ----------

// ListEntries handles GET /entries (filters: from,to,category_id,limit,cursor,modified_since).
func (h *Handler) ListEntries(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.requireUserID(w, r)
	if !ok {
		return
	}
	q := r.URL.Query()
	errs := validationErrs{}
	f := db.EntryFilter{
		CategoryID: q.Get("category_id"),
		Cursor:     q.Get("cursor"),
	}
	if v := q.Get("from"); v != "" {
		if t, ok := parseRFC3339(v); ok {
			f.From = &t
		} else {
			errs.add("from", "from must be a valid RFC 3339 timestamp")
		}
	}
	if v := q.Get("to"); v != "" {
		if t, ok := parseRFC3339(v); ok {
			f.To = &t
		} else {
			errs.add("to", "to must be a valid RFC 3339 timestamp")
		}
	}
	if v := q.Get("limit"); v != "" {
		n, ok := parseLimitParam(v, 200, errs)
		if ok {
			f.Limit = n
		}
	}
	if v := q.Get("modified_since"); v != "" {
		if t, ok := parseRFC3339(v); ok {
			f.ModifiedSince = &t
		} else {
			errs.add("modified_since", "modified_since must be a valid RFC 3339 timestamp")
		}
	}
	if !errs.ok() {
		writeValidation(w, errs)
		return
	}

	items, next, err := h.store.ListEntries(r.Context(), userID, f)
	if err != nil {
		h.writeInternalError(w, r, "list entries failed", err)
		return
	}
	if items == nil {
		items = []db.Entry{}
	}
	resp := map[string]any{"items": items}
	if next != "" {
		resp["next_cursor"] = next
	}
	writeJSON(w, http.StatusOK, resp)
}

// ListRecents handles GET /entries/recents (the recents experience, D5):
// up to 6 entries, one per exact activity_text (the group's newest wins),
// newest-first. Recents are otherwise computed client-side — this endpoint
// just mirrors the shared query for signed-in devices.
func (h *Handler) ListRecents(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.requireUserID(w, r)
	if !ok {
		return
	}
	limit := 6
	if v := r.URL.Query().Get("limit"); v != "" {
		errs := validationErrs{}
		n, ok := parseLimitParam(v, 20, errs)
		if !ok {
			writeValidation(w, errs)
			return
		}
		limit = n
	}
	items, err := h.store.ListRecents(r.Context(), userID, limit)
	if err != nil {
		h.writeInternalError(w, r, "list recents failed", err)
		return
	}
	if items == nil {
		items = []db.Entry{}
	}
	writeJSON(w, http.StatusOK, items)
}

// CreateEntry handles POST /entries (idempotent on id). The entry owns its
// activity_text, ordered category_ids, and notes; unknown category ids are
// rejected with 422 on create (merges prune instead).
func (h *Handler) CreateEntry(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.requireUserID(w, r)
	if !ok {
		return
	}
	var req entryCreateReq
	if err := decodeJSON(r, &req); err != nil {
		h.logger.Warn("invalid create entry body", "error", err)
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}
	// An empty ended_at string means "no value" (running timer), not a present
	// zero-time timestamp. Normalize it to omitted so it is not stored as
	// year-0001 with a hugely negative duration_seconds.
	req.EndedAt = emptyToNil(req.EndedAt)

	text := strings.TrimSpace(req.ActivityText)
	errs := validationErrs{}
	validateID(req.ID, errs)
	validateEntryText(text, errs)
	if req.Notes != nil {
		validateNotes(*req.Notes, errs)
	}
	// Malformed ids can never match a category, so on create they prune to
	// nothing at the store (they cannot be "unknown category, keep remainder"
	// candidates) — the loud format check is unnecessary; ownership is the
	// real create-time gate and it fails with 422 ErrInvalidCategoryID.
	validateTimestamp("started_at", req.StartedAt, true, errs)
	if req.EndedAt != nil {
		validateTimestamp("ended_at", *req.EndedAt, false, errs)
	}
	// source is optional; when present it must be a known provenance value.
	// source_ref is optional and free-form (an external identifier for the
	// source, e.g. a Screen Time callback uuid or Garmin activity id).
	if req.Source != "" && !validEntrySources[req.Source] {
		errs.add("source", "source must be one of: manual, widget, siri, control, screentime, garmin, calendar, healthkit")
	}
	// ended_at must be after started_at when both are present and valid. The
	// store independently guards the partial-PATCH merged value (and direct
	// store calls); here we surface the plain both-present case with precise
	// field-level details for the common create path.
	if req.EndedAt != nil && req.StartedAt != "" {
		if st, ok1 := parseRFC3339(req.StartedAt); ok1 {
			if et, ok2 := parseRFC3339(*req.EndedAt); ok2 && !et.After(st) {
				errs.add("ended_at", "ended_at must be after started_at")
			}
		}
	}
	if !errs.ok() {
		writeValidation(w, errs)
		return
	}

	startedAt, _ := parseRFC3339(req.StartedAt)
	var endedAt *time.Time
	if req.EndedAt != nil {
		et, _ := parseRFC3339(*req.EndedAt)
		endedAt = &et
	}
	var notes string
	if req.Notes != nil {
		notes = *req.Notes
	}
	e := db.Entry{
		ID:           req.ID,
		UserID:       userID,
		ActivityText: text,
		Notes:        notes,
		StartedAt:    startedAt,
		EndedAt:      endedAt,
		Source:       req.Source,
		SourceRef:    req.SourceRef,
	}
	if req.CategoryIDs != nil {
		e.Categories = entryTags(req.CategoryIDs)
	}
	created, isNew, err := h.store.CreateEntry(r.Context(), e)
	if err != nil {
		h.writeCatalogStoreErr(w, r, err, "create entry", versionDetails(created.UpdatedAt), nil)
		return
	}
	status := http.StatusCreated
	if !isNew {
		status = http.StatusOK
	}
	h.logger.Info("entry saved", "userID", userID, "entryID", created.ID, "created", isNew)
	writeJSON(w, status, created)
}

// GetEntry handles GET /entries/{id}.
func (h *Handler) GetEntry(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.requireUserID(w, r)
	if !ok {
		return
	}
	e, err := h.store.GetEntry(r.Context(), userID, chi.URLParam(r, "id"))
	if err != nil {
		h.writeCatalogStoreErr(w, r, err, "get entry", versionDetails(e.UpdatedAt), nil)
		return
	}
	writeJSON(w, http.StatusOK, e)
}

// UpdateEntry handles PATCH /entries/{id} (partial, LWW; recomputes duration).
// category_ids, if present, is a full replace; unknown ids are pruned.
func (h *Handler) UpdateEntry(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.requireUserID(w, r)
	if !ok {
		return
	}
	var req entryUpdateReq
	if err := decodeJSON(r, &req); err != nil {
		h.logger.Warn("invalid update entry body", "error", err)
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}

	errs := validationErrs{}
	if req.ActivityText != nil {
		t := strings.TrimSpace(*req.ActivityText)
		validateEntryText(t, errs)
		req.ActivityText = &t
	}
	if req.Notes != nil {
		validateNotes(*req.Notes, errs)
	}
	// Malformed category ids can never match a category (any format), so they
	// prune on merge (D7) — no loud format check here either.
	req.StartedAt = emptyToNil(req.StartedAt)
	if req.StartedAt != nil {
		validateTimestamp("started_at", *req.StartedAt, false, errs)
	}
	// Empty-string means omitted, matching started_at above and the create
	// path — without this, ended_at:"" 422s while started_at:"" is ignored.
	if req.EndedAt.Empty {
		req.EndedAt = optTime{}
	}
	if req.EndedAt.Set && req.EndedAt.Bad {
		errs.add("ended_at", "ended_at must be a valid RFC 3339 timestamp")
	}
	validateTimestamp("updated_at", req.UpdatedAt, true, errs)
	if !errs.ok() {
		writeValidation(w, errs)
		return
	}

	var patch db.EntryPatch
	if req.ActivityText != nil {
		patch.ActivityText = req.ActivityText
	}
	if req.Notes != nil {
		patch.Notes = req.Notes
	}
	if req.CategoryIDs != nil {
		tags := entryTags(*req.CategoryIDs)
		patch.CategoryIDs = &tags
	}
	var startedAt *time.Time
	if req.StartedAt != nil {
		st, _ := parseRFC3339(*req.StartedAt)
		startedAt = &st
	}
	patch.StartedAt = startedAt
	if req.EndedAt.Set {
		patch.EndedAt = db.NullableTime{Set: true, Valid: req.EndedAt.Valid, Value: req.EndedAt.Value}
	}
	updatedAt, _ := parseRFC3339(req.UpdatedAt)
	patch.UpdatedAt = updatedAt
	updated, err := h.store.UpdateEntry(r.Context(), userID, chi.URLParam(r, "id"), patch)
	if err != nil {
		h.writeCatalogStoreErr(w, r, err, "update entry", versionDetails(updated.UpdatedAt), nil)
		return
	}
	writeJSON(w, http.StatusOK, updated)
}

// DeleteEntry handles DELETE /entries/{id} (hard delete).
func (h *Handler) DeleteEntry(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.requireUserID(w, r)
	if !ok {
		return
	}
	if err := h.store.DeleteEntry(r.Context(), userID, chi.URLParam(r, "id")); err != nil {
		h.writeCatalogStoreErr(w, r, err, "delete entry", nil, nil)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
