package handlers

// Document handler tests: CRUD, presigned-URL flows, confirm-before-upload,
// opportunistic GC sweep, and purge orphan wiring.

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/antonkosenko/shunik/backend/internal/blobs"
	"github.com/antonkosenko/shunik/backend/internal/db"
)

// fakeDocBlobStore is a 20-line in-test fake of the blobs.Store interface.
type fakeDocBlobStore struct {
	objects map[string]bool
	deleted []string
}

var _ blobs.Store = (*fakeDocBlobStore)(nil)

func (f *fakeDocBlobStore) PresignPut(_ context.Context, key, _ string, _ int64, _ time.Duration) (string, error) {
	return "https://blob.test/put/" + key, nil
}

func (f *fakeDocBlobStore) PresignGet(_ context.Context, key string, _ time.Duration) (string, error) {
	return "https://blob.test/get/" + key, nil
}

func (f *fakeDocBlobStore) Exists(_ context.Context, key string) (bool, error) {
	return f.objects[key], nil
}

func (f *fakeDocBlobStore) Delete(_ context.Context, key string) error {
	f.deleted = append(f.deleted, key)
	delete(f.objects, key)
	return nil
}

func seedDoc(t *testing.T, h *Handler, uid, id string, petIDs []string) db.Document {
	t.Helper()
	w := httptest.NewRecorder()
	h.CreateDocument(w, domRequest(t, http.MethodPost, "/api/v1/documents", map[string]any{
		"id": id, "title": "T-" + id, "mime": "application/pdf",
		"size_bytes": 1234, "filename": "scan.pdf", "pet_ids": petIDs,
	}, uid))
	if w.Code != http.StatusCreated {
		t.Fatalf("seed doc %s: %d (%s)", id, w.Code, w.Body.String())
	}
	var doc db.Document
	domDecode(t, w, &doc)
	return doc
}

func TestDocuments_CRUD(t *testing.T) {
	h, stub, fb := newDomainTestSetup(t, true)
	const uid = "user-test"
	seedPet(t, h, uid, "pet-1")

	doc := seedDoc(t, h, uid, "doc-1", []string{"pet-1"})
	if doc.Ready {
		t.Fatal("new document must be unready")
	}
	// The blob key is store-assigned and opaque; the handler only flows it
	// through to presigned URLs. Shape is asserted in db/blobkeys_test.go.
	if doc.BlobKey == "" {
		t.Fatal("expected a store-assigned blob key")
	}

	w := httptest.NewRecorder()
	h.GetDocument(w, domRequestWithID(t, http.MethodGet, "/api/v1/documents/doc-1", "id", "doc-1", nil, uid))
	if w.Code != http.StatusOK {
		t.Fatalf("get: expected 200, got %d", w.Code)
	}

	w = httptest.NewRecorder()
	h.ListDocuments(w, domRequest(t, http.MethodGet, "/api/v1/documents", nil, uid))
	if w.Code != http.StatusOK {
		t.Fatalf("list: expected 200, got %d", w.Code)
	}
	var list struct {
		Documents []db.Document `json:"documents"`
		Cursor    string        `json:"cursor"`
	}
	domDecode(t, w, &list)
	if len(list.Documents) != 1 || list.Cursor == "" {
		t.Fatalf("expected one document + cursor, got %+v", list)
	}

	title := "Renamed"
	w = httptest.NewRecorder()
	h.UpdateDocument(w, domRequestWithID(t, http.MethodPatch, "/api/v1/documents/doc-1", "id", "doc-1",
		map[string]any{"base_updated_at": doc.UpdatedAt.Format(time.RFC3339), "title": title}, uid))
	if w.Code != http.StatusOK {
		t.Fatalf("patch: expected 200, got %d (%s)", w.Code, w.Body.String())
	}
	domDecode(t, w, &doc)
	if doc.Title != title || len(doc.PetIDs) != 1 {
		t.Fatalf("patch must replace title and keep links, got %+v", doc)
	}

	stale := map[string]any{"base_updated_at": time.Now().Add(-time.Hour).Format(time.RFC3339), "title": "Stale"}
	w = httptest.NewRecorder()
	h.UpdateDocument(w, domRequestWithID(t, http.MethodPatch, "/api/v1/documents/doc-1", "id", "doc-1", stale, uid))
	if w.Code != http.StatusConflict || domErrCode(t, w) != "conflict" {
		t.Fatalf("stale: expected 409 conflict, got %d (%s)", w.Code, w.Body.String())
	}
	if got := domConflictServer(t, w)["title"]; got != "Renamed" {
		t.Fatalf("expected server copy in details, got %v", got)
	}

	unknown := map[string]any{"base_updated_at": doc.UpdatedAt.Format(time.RFC3339), "pet_ids": []string{"ghost"}}
	w = httptest.NewRecorder()
	h.UpdateDocument(w, domRequestWithID(t, http.MethodPatch, "/api/v1/documents/doc-1", "id", "doc-1", unknown, uid))
	if w.Code != http.StatusUnprocessableEntity || domErrCode(t, w) != "invalid_pet_id" {
		t.Fatalf("unknown pet: expected 422, got %d (%s)", w.Code, w.Body.String())
	}

	w = httptest.NewRecorder()
	h.DeleteDocument(w, domRequestWithID(t, http.MethodDelete, "/api/v1/documents/doc-1", "id", "doc-1", nil, uid))
	if w.Code != http.StatusNoContent {
		t.Fatalf("delete: expected 204, got %d", w.Code)
	}
	if len(fb.deleted) != 1 || fb.deleted[0] != "stub/doc-1" {
		t.Fatalf("delete must remove bytes after commit, got %v", fb.deleted)
	}
	if _, ok := stub.docs["hh-test/doc-1"]; ok {
		t.Fatal("document row must be gone")
	}

	w = httptest.NewRecorder()
	h.GetDocument(w, domRequestWithID(t, http.MethodGet, "/api/v1/documents/doc-1", "id", "doc-1", nil, uid))
	if w.Code != http.StatusNotFound {
		t.Fatalf("get after delete: expected 404, got %d", w.Code)
	}
}

func TestDocuments_CreateValidation(t *testing.T) {
	h, _, _ := newDomainTestSetup(t, true)
	const uid = "user-test"
	seedPet(t, h, uid, "pet-1")

	ghost := map[string]any{"id": "d-x", "title": "T", "mime": "application/pdf",
		"size_bytes": 10, "filename": "x.pdf", "pet_ids": []string{"ghost"}}
	w := httptest.NewRecorder()
	h.CreateDocument(w, domRequest(t, http.MethodPost, "/api/v1/documents", ghost, uid))
	if w.Code != http.StatusUnprocessableEntity || domErrCode(t, w) != "invalid_pet_id" {
		t.Fatalf("unknown pet: expected 422 invalid_pet_id, got %d (%s)", w.Code, w.Body.String())
	}

	for i, bad := range []map[string]any{
		{"id": "d-1", "title": "", "mime": "application/pdf", "size_bytes": 1, "filename": "x.pdf"},
		{"id": "d-1", "title": "T", "mime": "", "size_bytes": 1, "filename": "x.pdf"},
		{"id": "d-1", "title": "T", "mime": "application/pdf", "size_bytes": 1, "filename": ""},
		{"id": "d-1", "title": "T", "mime": "application/pdf", "size_bytes": -1, "filename": "x.pdf"},
	} {
		w = httptest.NewRecorder()
		h.CreateDocument(w, domRequest(t, http.MethodPost, "/api/v1/documents", bad, uid))
		if w.Code != http.StatusBadRequest || domErrCode(t, w) != "invalid_body" {
			t.Fatalf("bad doc %d: expected 400 invalid_body, got %d (%s)", i, w.Code, w.Body.String())
		}
	}

	w = httptest.NewRecorder()
	h.CreateDocument(w, domRequest(t, http.MethodPost, "/api/v1/documents", ghost, ""))
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("unauth: expected 401, got %d", w.Code)
	}
}

func TestDocuments_BlobFlows(t *testing.T) {
	h, stub, fb := newDomainTestSetup(t, true)
	const uid = "user-test"
	seedPet(t, h, uid, "pet-1")
	doc := seedDoc(t, h, uid, "doc-1", []string{"pet-1"})

	w := httptest.NewRecorder()
	h.DocumentUploadURL(w, domRequestWithID(t, http.MethodPost, "/api/v1/documents/doc-1/upload-url", "id", "doc-1", nil, uid))
	if w.Code != http.StatusOK {
		t.Fatalf("upload-url: expected 200, got %d (%s)", w.Code, w.Body.String())
	}
	var up struct {
		UploadURL string `json:"upload_url"`
		ExpiresAt string `json:"expires_at"`
	}
	domDecode(t, w, &up)
	if up.UploadURL == "" || up.ExpiresAt == "" {
		t.Fatalf("expected upload_url + expires_at, got %+v", up)
	}

	w = httptest.NewRecorder()
	h.ConfirmDocument(w, domRequestWithID(t, http.MethodPost, "/api/v1/documents/doc-1/confirm", "id", "doc-1", nil, uid))
	if w.Code != http.StatusConflict || domErrCode(t, w) != "upload_incomplete" {
		t.Fatalf("confirm-before-upload: expected 409 upload_incomplete, got %d (%s)", w.Code, w.Body.String())
	}

	fb.objects[doc.BlobKey] = true
	w = httptest.NewRecorder()
	h.ConfirmDocument(w, domRequestWithID(t, http.MethodPost, "/api/v1/documents/doc-1/confirm", "id", "doc-1", nil, uid))
	if w.Code != http.StatusOK {
		t.Fatalf("confirm: expected 200, got %d (%s)", w.Code, w.Body.String())
	}
	var confirmed db.Document
	domDecode(t, w, &confirmed)
	if !confirmed.Ready {
		t.Fatal("confirmed document must be ready")
	}

	w = httptest.NewRecorder()
	h.DocumentDownloadURL(w, domRequestWithID(t, http.MethodGet, "/api/v1/documents/doc-1/download-url", "id", "doc-1", nil, uid))
	if w.Code != http.StatusOK {
		t.Fatalf("download-url: expected 200, got %d (%s)", w.Code, w.Body.String())
	}
	var down struct {
		DownloadURL string `json:"download_url"`
		ExpiresAt   string `json:"expires_at"`
	}
	domDecode(t, w, &down)
	if down.DownloadURL == "" || down.ExpiresAt == "" {
		t.Fatalf("expected download_url + expires_at, got %+v", down)
	}

	// Unknown and not-ready documents are indistinguishable 404s.
	w = httptest.NewRecorder()
	h.DocumentDownloadURL(w, domRequestWithID(t, http.MethodGet, "/api/v1/documents/ghost/download-url", "id", "ghost", nil, uid))
	if w.Code != http.StatusNotFound {
		t.Fatalf("missing download: expected 404, got %d", w.Code)
	}
	unready := seedDoc(t, h, uid, "doc-2", []string{"pet-1"})
	_ = unready
	w = httptest.NewRecorder()
	h.DocumentDownloadURL(w, domRequestWithID(t, http.MethodGet, "/api/v1/documents/doc-2/download-url", "id", "doc-2", nil, uid))
	if w.Code != http.StatusNotFound {
		t.Fatalf("unready download: expected 404, got %d", w.Code)
	}

	// GC sweep: backdate doc-2 past the 24h unready window, then confirm
	// doc-1 (sweep runs on confirm) and expect doc-2 reclaimed.
	d2 := stub.docs["hh-test/doc-2"]
	d2.CreatedAt = time.Now().Add(-25 * time.Hour)
	stub.docs["hh-test/doc-2"] = d2
	w = httptest.NewRecorder()
	h.ConfirmDocument(w, domRequestWithID(t, http.MethodPost, "/api/v1/documents/doc-1/confirm", "id", "doc-1", nil, uid))
	if w.Code != http.StatusOK {
		t.Fatalf("re-confirm: expected 200, got %d (%s)", w.Code, w.Body.String())
	}
	if _, ok := stub.docs["hh-test/doc-2"]; ok {
		t.Fatal("GC sweep must reclaim stale unready documents")
	}
	found := false
	for _, k := range fb.deleted {
		if k == d2.BlobKey {
			found = true
		}
	}
	if !found {
		t.Fatalf("GC sweep must delete bytes best-effort, got %v", fb.deleted)
	}
}

func TestDocuments_BlobUnconfigured(t *testing.T) {
	h, _, _ := newDomainTestSetup(t, false)
	const uid = "user-test"
	seedPet(t, h, uid, "pet-1")
	seedDoc(t, h, uid, "doc-1", []string{"pet-1"})

	for _, call := range []struct {
		name string
		fn   func(w http.ResponseWriter, r *http.Request)
		req  *http.Request
	}{
		{"upload-url", h.DocumentUploadURL, domRequestWithID(t, http.MethodPost, "/x", "id", "doc-1", nil, uid)},
		{"confirm", h.ConfirmDocument, domRequestWithID(t, http.MethodPost, "/x", "id", "doc-1", nil, uid)},
		{"download-url", h.DocumentDownloadURL, domRequestWithID(t, http.MethodGet, "/x", "id", "doc-1", nil, uid)},
	} {
		w := httptest.NewRecorder()
		call.fn(w, call.req)
		if w.Code != http.StatusServiceUnavailable || domErrCode(t, w) != "blob_not_configured" {
			t.Fatalf("%s: expected 503 blob_not_configured, got %d (%s)", call.name, w.Code, w.Body.String())
		}
	}
}

func TestDeleteAccount_PurgesOrphanBlobs(t *testing.T) {
	h, stub, fb := newDomainTestSetup(t, true)
	const uid = "user-test"
	stub.purgeResult = db.PurgeResult{UserID: uid, OrphanedBlobKeys: []string{"h/hh/d/gone.pdf", "h/hh/d/gone2.pdf"}}

	req := domRequest(t, http.MethodDelete, "/api/v1/auth/account", nil, uid)
	req.Header.Set("X-Device-Id", "device-1")
	w := httptest.NewRecorder()
	h.DeleteAccount(w, req)
	if w.Code != http.StatusNoContent {
		t.Fatalf("delete: expected 204, got %d (%s)", w.Code, w.Body.String())
	}
	if len(fb.deleted) != 2 || fb.deleted[0] != "h/hh/d/gone.pdf" || fb.deleted[1] != "h/hh/d/gone2.pdf" {
		t.Fatalf("expected orphan deletes, got %v", fb.deleted)
	}
}

func TestDeleteAccount_PurgeSkipsOrphansWithoutBlobStore(t *testing.T) {
	h, stub, _ := newDomainTestSetup(t, false)
	const uid = "user-test"
	stub.purgeResult = db.PurgeResult{UserID: uid, OrphanedBlobKeys: []string{"h/hh/d/gone.pdf"}}

	req := domRequest(t, http.MethodDelete, "/api/v1/auth/account", nil, uid)
	req.Header.Set("X-Device-Id", "device-1")
	w := httptest.NewRecorder()
	h.DeleteAccount(w, req)
	if w.Code != http.StatusNoContent {
		t.Fatalf("delete: expected 204, got %d (%s)", w.Code, w.Body.String())
	}
}

func TestDomain_UnauthenticatedIs401(t *testing.T) {
	h, _, _ := newDomainTestSetup(t, true)
	calls := []func(w *httptest.ResponseRecorder, r *http.Request){
		func(w *httptest.ResponseRecorder, r *http.Request) {
			h.CreatePet(w, r)
		},
		func(w *httptest.ResponseRecorder, r *http.Request) {
			h.ListPets(w, r)
		},
		func(w *httptest.ResponseRecorder, r *http.Request) {
			h.GetPet(w, r)
		},
		func(w *httptest.ResponseRecorder, r *http.Request) {
			h.CreateEvent(w, r)
		},
		func(w *httptest.ResponseRecorder, r *http.Request) {
			h.ListEvents(w, r)
		},
		func(w *httptest.ResponseRecorder, r *http.Request) {
			h.CreateIntake(w, r)
		},
		func(w *httptest.ResponseRecorder, r *http.Request) {
			h.ListIntakes(w, r)
		},
		func(w *httptest.ResponseRecorder, r *http.Request) {
			h.CreateDocument(w, r)
		},
		func(w *httptest.ResponseRecorder, r *http.Request) {
			h.ListDocuments(w, r)
		},
		func(w *httptest.ResponseRecorder, r *http.Request) {
			h.ListDeletions(w, r)
		},
	}
	for i, call := range calls {
		w := httptest.NewRecorder()
		call(w, domRequest(t, http.MethodGet, "/x", nil, ""))
		if w.Code != http.StatusUnauthorized || domErrCode(t, w) != "unauthorized" {
			t.Fatalf("call %d: expected 401 unauthorized, got %d (%s)", i, w.Code, w.Body.String())
		}
	}
}
