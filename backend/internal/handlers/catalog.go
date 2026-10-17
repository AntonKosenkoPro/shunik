package handlers

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/antonkosenko/time-of-life/backend/internal/db"
)

// writeCatalogStoreErr maps a db store error to the catalog error contract.
// conflictDetails carries the server's current version (for a 409 conflict)
// and existsDetails the winning record (for a *_exists 409); both are
// computed by the caller with versionDetails/identityDetails below.
func (h *Handler) writeCatalogStoreErr(w http.ResponseWriter, r *http.Request, err error, action string, conflictDetails, existsDetails any) {
	switch {
	case errors.Is(err, db.ErrNotFound):
		writeError(w, http.StatusNotFound, codeNotFound, "Not found", nil)
	case errors.Is(err, db.ErrConflict):
		writeError(w, http.StatusConflict, codeConflict,
			"Outdated version; a newer record exists on the server.", conflictDetails)
	case errors.Is(err, db.ErrCategoryExists):
		writeError(w, http.StatusConflict, codeCategoryExists,
			"A category with this name already exists.", existsDetails)
	case errors.Is(err, db.ErrDuplicateImport):
		writeError(w, http.StatusConflict, codeDuplicateImport,
			"An entry with this source and source_ref already exists.", nil)
	case errors.Is(err, db.ErrEndBeforeStart):
		writeValidation(w, validationErrs{"ended_at": "ended_at must be after started_at"})
	case errors.Is(err, db.ErrInvalidCategoryID):
		writeValidation(w, validationErrs{"category_ids": "One or more categories do not exist"})
	default:
		h.writeInternalError(w, r, action+" failed", err)
	}
}

// versionDetails returns {updated_at: <server's current version>} for a 409 conflict.
func versionDetails(updatedAt time.Time) map[string]string {
	return map[string]string{"updated_at": updatedAt.UTC().Format(time.RFC3339Nano)}
}

// identityDetails returns {id, name} of the winning record for a *_exists 409.
func identityDetails(id, name string) map[string]string {
	return map[string]string{"id": id, "name": name}
}

// ---------- Categories ----------

// ListCategories handles GET /categories (ordered by name).
func (h *Handler) ListCategories(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.requireUserID(w, r)
	if !ok {
		return
	}
	cats, err := h.store.ListCategories(r.Context(), userID)
	if err != nil {
		h.writeInternalError(w, r, "list categories failed", err)
		return
	}
	if cats == nil {
		cats = []db.Category{}
	}
	writeJSON(w, http.StatusOK, cats)
}

// CreateCategory handles POST /categories (idempotent on id).
func (h *Handler) CreateCategory(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.requireUserID(w, r)
	if !ok {
		return
	}
	var req categoryCreateReq
	if err := decodeJSON(r, &req); err != nil {
		h.logger.Warn("invalid create category body", "error", err)
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}
	name := strings.TrimSpace(req.Name)
	icon := strings.ToLower(req.Icon)
	errs := validationErrs{}
	validateID(req.ID, errs)
	validateName("name", name, errs)
	validateIcon(icon, errs)
	if !errs.ok() {
		writeValidation(w, errs)
		return
	}

	c := db.Category{ID: req.ID, UserID: userID, Name: name, Icon: icon}
	created, isNew, err := h.store.CreateCategory(r.Context(), c)
	if err != nil {
		h.writeCatalogStoreErr(w, r, err, "create category", versionDetails(created.UpdatedAt), identityDetails(created.ID, created.Name))
		return
	}
	status := http.StatusCreated
	if !isNew {
		status = http.StatusOK
	}
	h.logger.Info("category saved", "userID", userID, "categoryID", created.ID, "created", isNew)
	writeJSON(w, status, created)
}

// GetCategory handles GET /categories/{id}.
func (h *Handler) GetCategory(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.requireUserID(w, r)
	if !ok {
		return
	}
	c, err := h.store.GetCategory(r.Context(), userID, chi.URLParam(r, "id"))
	if err != nil {
		h.writeCatalogStoreErr(w, r, err, "get category", versionDetails(c.UpdatedAt), nil)
		return
	}
	writeJSON(w, http.StatusOK, c)
}

// UpdateCategory handles PATCH /categories/{id} (partial, LWW).
func (h *Handler) UpdateCategory(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.requireUserID(w, r)
	if !ok {
		return
	}
	var req categoryUpdateReq
	if err := decodeJSON(r, &req); err != nil {
		h.logger.Warn("invalid update category body", "error", err)
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}
	errs := validationErrs{}
	if req.Name != nil {
		n := strings.TrimSpace(*req.Name)
		validateName("name", n, errs)
		req.Name = &n
	}
	if req.Icon != nil {
		i := strings.ToLower(*req.Icon)
		validateIcon(i, errs)
		req.Icon = &i
	}
	validateTimestamp("updated_at", req.UpdatedAt, true, errs)
	if !errs.ok() {
		writeValidation(w, errs)
		return
	}

	updatedAt, _ := parseRFC3339(req.UpdatedAt)
	patch := db.CategoryPatch{Name: req.Name, Icon: req.Icon, UpdatedAt: updatedAt}
	updated, err := h.store.UpdateCategory(r.Context(), userID, chi.URLParam(r, "id"), patch)
	if err != nil {
		h.writeCatalogStoreErr(w, r, err, "update category", versionDetails(updated.UpdatedAt), identityDetails(updated.ID, updated.Name))
		return
	}
	writeJSON(w, http.StatusOK, updated)
}

// DeleteCategory handles DELETE /categories/{id} (hard delete; entries unaffected).
func (h *Handler) DeleteCategory(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.requireUserID(w, r)
	if !ok {
		return
	}
	if err := h.store.DeleteCategory(r.Context(), userID, chi.URLParam(r, "id")); err != nil {
		h.writeCatalogStoreErr(w, r, err, "delete category", nil, nil)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------- Deletion tombstones ----------

// ListDeletions handles GET /deletions (?deleted_since= delta pull). Returns
// the user's deletion tombstones ordered by deleted_at ASC; a nil result
// serializes as [] so the client never decodes null.
func (h *Handler) ListDeletions(w http.ResponseWriter, r *http.Request) {
	userID, ok := h.requireUserID(w, r)
	if !ok {
		return
	}
	var deletedSince *time.Time
	if v := r.URL.Query().Get("deleted_since"); v != "" {
		t, ok := parseRFC3339(v)
		if !ok {
			writeValidation(w, validationErrs{"deleted_since": "deleted_since must be a valid RFC 3339 timestamp"})
			return
		}
		deletedSince = &t
	}
	tombstones, err := h.store.ListDeletions(r.Context(), userID, deletedSince)
	if err != nil {
		h.writeInternalError(w, r, "list deletions failed", err)
		return
	}
	if tombstones == nil {
		tombstones = []db.Tombstone{}
	}
	writeJSON(w, http.StatusOK, tombstones)
}
