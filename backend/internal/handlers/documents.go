package handlers

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/antonkosenko/shunik/backend/internal/blobs"
	"github.com/antonkosenko/shunik/backend/internal/db"
)

// Document library HTTP layer. Metadata syncs through the relay; bytes move
// directly between the client and S3-compatible storage via presigned URLs
// and never pass through this handler. When no blob store is wired the blob
// endpoints answer 503 blob_not_configured and purge/GC cleanup skips
// silently; everything else keeps working.

// blobURLTTL is the lifetime of presigned upload/download URLs.
const blobURLTTL = 15 * time.Minute

// unconfirmedDocAge is how long an unready document may linger before the
// opportunistic GC sweep reclaims it; unconfirmedSweepLimit bounds one sweep.
const (
	unconfirmedDocAge     = 24 * time.Hour
	unconfirmedSweepLimit = 20
)

// WithBlobStore wires object storage for document bytes. A nil store
// disables the blob endpoints (explicit 503, never a silent skip) and
// turns purge/GC byte cleanup into no-ops.
func WithBlobStore(bs blobs.Store) HandlerOption {
	return func(h *Handler) {
		h.blobStore = bs
	}
}

// requireBlobStore answers 503 when object storage is not configured.
func (h *Handler) requireBlobStore(w http.ResponseWriter) bool {
	if h.blobStore == nil {
		writeError(w, http.StatusServiceUnavailable, "blob_not_configured", "Document storage is not configured", nil)
		return false
	}
	return true
}

type documentReq struct {
	ID        string   `json:"id"`
	Title     string   `json:"title"`
	Mime      string   `json:"mime"`
	SizeBytes int64    `json:"size_bytes"`
	Filename  string   `json:"filename"`
	PetIDs    []string `json:"pet_ids"`
}

type documentPatchReq struct {
	BaseUpdatedAt time.Time `json:"base_updated_at"`
	Title         *string   `json:"title"`
	PetIDs        []string  `json:"pet_ids"`
}

// CreateDocument handles POST /api/v1/documents: idempotent metadata insert
// (201 new, 200 replay). Bytes upload separately; the row starts unready.
// Unknown pet links share the 422 invalid_pet_id shape.
func (h *Handler) CreateDocument(w http.ResponseWriter, r *http.Request) {
	userID, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}

	var req documentReq
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}
	if strings.TrimSpace(req.ID) == "" {
		writeError(w, http.StatusBadRequest, "invalid_body", "id is required", nil)
		return
	}
	if strings.TrimSpace(req.Title) == "" || strings.TrimSpace(req.Mime) == "" || strings.TrimSpace(req.Filename) == "" {
		writeError(w, http.StatusBadRequest, "invalid_body", "title, mime, and filename are required", nil)
		return
	}
	if req.SizeBytes < 0 {
		writeError(w, http.StatusBadRequest, "invalid_body", "size_bytes must not be negative", nil)
		return
	}
	petIDs := make([]string, 0, len(req.PetIDs))
	for _, p := range req.PetIDs {
		p = strings.TrimSpace(p)
		if p == "" {
			writeError(w, http.StatusBadRequest, "invalid_body", "pet_ids must not contain empty entries", nil)
			return
		}
		petIDs = append(petIDs, p)
	}

	doc, created, err := h.store.CreateDocument(r.Context(), householdID, db.DocumentInput{
		ID:        strings.TrimSpace(req.ID),
		Title:     strings.TrimSpace(req.Title),
		Mime:      strings.TrimSpace(req.Mime),
		SizeBytes: req.SizeBytes,
		Filename:  strings.TrimSpace(req.Filename),
		PetIDs:    petIDs,
	}, userID)
	if err != nil {
		if errors.Is(err, db.ErrInvalidPetID) {
			writeError(w, http.StatusUnprocessableEntity, "invalid_pet_id", "Unknown pet reference", nil)
			return
		}
		h.writeInternalError(w, r, "failed to create document", err)
		return
	}
	if created {
		writeJSON(w, http.StatusCreated, doc)
		return
	}
	writeJSON(w, http.StatusOK, doc)
}

// ListDocuments handles GET /api/v1/documents?modified_since=: metadata
// only, never bytes.
func (h *Handler) ListDocuments(w http.ResponseWriter, r *http.Request) {
	_, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}

	since, err := parseSinceQuery(r, "modified_since")
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid modified_since (RFC3339 required)", nil)
		return
	}

	docs, err := h.store.ListDocumentsChangedSince(r.Context(), householdID, since)
	if err != nil {
		h.writeInternalError(w, r, "failed to list documents", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"documents": nonEmptyList(docs),
		"cursor":    documentCursor(docs),
	})
}

func documentCursor(docs []db.Document) string {
	var latest time.Time
	for _, d := range docs {
		if d.UpdatedAt.After(latest) {
			latest = d.UpdatedAt
		}
	}
	if latest.IsZero() {
		return ""
	}
	return latest.UTC().Format(time.RFC3339)
}

// GetDocument handles GET /api/v1/documents/{id}.
func (h *Handler) GetDocument(w http.ResponseWriter, r *http.Request) {
	_, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}

	doc, err := h.store.GetDocument(r.Context(), householdID, strings.TrimSpace(chi.URLParam(r, "id")))
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "Document not found", nil)
			return
		}
		h.writeInternalError(w, r, "failed to load document", err)
		return
	}
	writeJSON(w, http.StatusOK, doc)
}

// UpdateDocument handles PATCH /api/v1/documents/{id}: replaces the title
// and pet link set (omitted fields keep the server value), guarded by
// base_updated_at. Stale writes get 409 with the server copy.
func (h *Handler) UpdateDocument(w http.ResponseWriter, r *http.Request) {
	userID, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}
	id := strings.TrimSpace(chi.URLParam(r, "id"))

	var req documentPatchReq
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body", "Invalid request body", nil)
		return
	}
	if req.BaseUpdatedAt.IsZero() {
		writeError(w, http.StatusBadRequest, "invalid_body", "base_updated_at is required", nil)
		return
	}
	if req.Title != nil && strings.TrimSpace(*req.Title) == "" {
		writeError(w, http.StatusBadRequest, "invalid_body", "title must not be empty", nil)
		return
	}
	var petIDs []string
	if req.PetIDs != nil {
		petIDs = make([]string, 0, len(req.PetIDs))
		for _, p := range req.PetIDs {
			p = strings.TrimSpace(p)
			if p == "" {
				writeError(w, http.StatusBadRequest, "invalid_body", "pet_ids must not contain empty entries", nil)
				return
			}
			petIDs = append(petIDs, p)
		}
	}

	current, err := h.store.GetDocument(r.Context(), householdID, id)
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "Document not found", nil)
			return
		}
		h.writeInternalError(w, r, "failed to load document", err)
		return
	}
	title := current.Title
	if req.Title != nil {
		title = strings.TrimSpace(*req.Title)
	}
	if petIDs == nil {
		petIDs = current.PetIDs
	}

	doc, err := h.store.UpdateDocument(r.Context(), householdID, id, title, petIDs, req.BaseUpdatedAt, userID)
	if err != nil {
		switch {
		case errors.Is(err, db.ErrNotFound):
			writeError(w, http.StatusNotFound, "not_found", "Document not found", nil)
		case errors.Is(err, db.ErrInvalidPetID):
			writeError(w, http.StatusUnprocessableEntity, "invalid_pet_id", "Unknown pet reference", nil)
		case errors.Is(err, db.ErrConflict):
			serverCopy, gerr := h.store.GetDocument(r.Context(), householdID, id)
			if gerr != nil {
				serverCopy = current
			}
			conflictWithServer(w, "Document was modified by another device", serverCopy)
		default:
			h.writeInternalError(w, r, "failed to update document", err)
		}
		return
	}
	writeJSON(w, http.StatusOK, doc)
}

// DeleteDocument handles DELETE /api/v1/documents/{id}: the row commits
// first, then the bytes are removed best-effort (failures leave orphans for
// the GC sweep, never a delete failure).
func (h *Handler) DeleteDocument(w http.ResponseWriter, r *http.Request) {
	_, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}

	doc, err := h.store.DeleteDocument(r.Context(), householdID, strings.TrimSpace(chi.URLParam(r, "id")))
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "Document not found", nil)
			return
		}
		h.writeInternalError(w, r, "failed to delete document", err)
		return
	}
	if h.blobStore != nil && doc.BlobKey != "" {
		if err := h.blobStore.Delete(r.Context(), doc.BlobKey); err != nil {
			h.logger.Warn("document blob delete failed; orphan left for GC sweep",
				"blob_key", doc.BlobKey, "error", err)
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

// DocumentUploadURL handles POST /api/v1/documents/{id}/upload-url: mints a
// fresh presigned PUT and runs the opportunistic unconfirmed-doc GC sweep.
func (h *Handler) DocumentUploadURL(w http.ResponseWriter, r *http.Request) {
	_, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}
	if !h.requireBlobStore(w) {
		return
	}

	doc, err := h.store.GetDocument(r.Context(), householdID, strings.TrimSpace(chi.URLParam(r, "id")))
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "Document not found", nil)
			return
		}
		h.writeInternalError(w, r, "failed to load document", err)
		return
	}

	url, err := h.blobStore.PresignPut(r.Context(), doc.BlobKey, doc.Mime, doc.SizeBytes, blobURLTTL)
	if err != nil {
		h.writeInternalError(w, r, "failed to presign document upload", err)
		return
	}
	h.sweepUnconfirmedDocuments(r.Context())
	writeJSON(w, http.StatusOK, map[string]any{
		"upload_url": url,
		"expires_at": time.Now().Add(blobURLTTL).UTC().Format(time.RFC3339),
	})
}

// ConfirmDocument handles POST /api/v1/documents/{id}/confirm: marks the
// row ready once the bytes exist. Confirming missing bytes is 409
// upload_incomplete (the client must PUT first).
func (h *Handler) ConfirmDocument(w http.ResponseWriter, r *http.Request) {
	_, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}
	if !h.requireBlobStore(w) {
		return
	}
	id := strings.TrimSpace(chi.URLParam(r, "id"))

	doc, err := h.store.GetDocument(r.Context(), householdID, id)
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "Document not found", nil)
			return
		}
		h.writeInternalError(w, r, "failed to load document", err)
		return
	}

	exists, err := h.blobStore.Exists(r.Context(), doc.BlobKey)
	if err != nil {
		h.writeInternalError(w, r, "failed to check document bytes", err)
		return
	}
	if !exists {
		writeError(w, http.StatusConflict, "upload_incomplete", "Document bytes have not been uploaded yet", nil)
		return
	}

	confirmed, err := h.store.ConfirmDocument(r.Context(), householdID, id)
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "Document not found", nil)
			return
		}
		h.writeInternalError(w, r, "failed to confirm document", err)
		return
	}
	h.sweepUnconfirmedDocuments(r.Context())
	writeJSON(w, http.StatusOK, confirmed)
}

// DocumentDownloadURL handles GET /api/v1/documents/{id}/download-url.
// Missing and not-yet-ready documents are indistinguishable (404).
func (h *Handler) DocumentDownloadURL(w http.ResponseWriter, r *http.Request) {
	_, householdID, ok := h.resolveHousehold(w, r)
	if !ok {
		return
	}
	if !h.requireBlobStore(w) {
		return
	}

	doc, err := h.store.GetDocument(r.Context(), householdID, strings.TrimSpace(chi.URLParam(r, "id")))
	if err != nil {
		if errors.Is(err, db.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "Document not found", nil)
			return
		}
		h.writeInternalError(w, r, "failed to load document", err)
		return
	}
	if !doc.Ready {
		writeError(w, http.StatusNotFound, "not_found", "Document not found", nil)
		return
	}

	url, err := h.blobStore.PresignGet(r.Context(), doc.BlobKey, blobURLTTL)
	if err != nil {
		h.writeInternalError(w, r, "failed to presign document download", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"download_url": url,
		"expires_at":   time.Now().Add(blobURLTTL).UTC().Format(time.RFC3339),
	})
}

// sweepUnconfirmedDocuments reclaims unready documents older than
// unconfirmedDocAge (bounded per sweep): bytes first (best-effort), then the
// rows via the non-tombstoning batch delete. Clients never saw unready rows
// (pulls filter ready=true), so no convergence risk. The sweep is
// opportunistic — failures are logged, never surfaced. A nil blob store
// skips the sweep entirely.
func (h *Handler) sweepUnconfirmedDocuments(ctx context.Context) {
	if h.blobStore == nil {
		return
	}
	docs, err := h.store.ListUnconfirmedDocuments(ctx, time.Now().Add(-unconfirmedDocAge), unconfirmedSweepLimit)
	if err != nil {
		h.logger.Warn("unconfirmed document sweep: list failed", "error", err)
		return
	}
	ids := make([]string, 0, len(docs))
	for _, d := range docs {
		if d.BlobKey != "" {
			if err := h.blobStore.Delete(ctx, d.BlobKey); err != nil {
				h.logger.Warn("unconfirmed document sweep: blob delete failed",
					"blob_key", d.BlobKey, "error", err)
			}
		}
		ids = append(ids, d.ID)
	}
	if err := h.store.DeleteDocumentsByIDs(ctx, ids); err != nil {
		h.logger.Warn("unconfirmed document sweep: row delete failed", "error", err)
	}
}

// deleteOrphanedBlobs removes purge-leftover document bytes best-effort. A
// nil blob store skips silently; failures are logged orphans for the GC
// sweep — never a purge failure.
func (h *Handler) deleteOrphanedBlobs(ctx context.Context, keys []string) {
	if h.blobStore == nil {
		return
	}
	for _, key := range keys {
		if key == "" {
			continue
		}
		if err := h.blobStore.Delete(ctx, key); err != nil {
			h.logger.Warn("orphaned blob delete failed", "blob_key", key, "error", err)
		}
	}
}
