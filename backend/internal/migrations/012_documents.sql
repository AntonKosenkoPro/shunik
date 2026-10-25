-- 012: account-rooted document library. Bytes live on the CDN (see
-- BlobStore); only metadata syncs. extracted_text is reserved for stage-2
-- PDF text and stage-3 OCR (a future migration adds the FTS index).
CREATE TABLE IF NOT EXISTS documents (
    id UUID PRIMARY KEY,
    household_id UUID NOT NULL REFERENCES households(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    mime TEXT NOT NULL,
    size_bytes BIGINT NOT NULL DEFAULT 0,
    filename TEXT NOT NULL DEFAULT '',
    blob_key TEXT NOT NULL DEFAULT '',
    ready BOOLEAN NOT NULL DEFAULT false,
    extracted_text TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_documents_household ON documents(household_id);

CREATE TABLE IF NOT EXISTS document_pets (
    document_id UUID NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    pet_id UUID NOT NULL REFERENCES pets(id) ON DELETE CASCADE,
    PRIMARY KEY (document_id, pet_id)
);

CREATE INDEX IF NOT EXISTS idx_document_pets_pet ON document_pets(pet_id);
