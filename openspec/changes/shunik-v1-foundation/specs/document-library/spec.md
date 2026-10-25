## Purpose

Documents are the household's paper trail — an account-rooted library where files link to zero, one, or several pets, bytes live on a CDN outside the sync path, and search and sharing each grow in explicit stages.

## ADDED Requirements

### Requirement: Library rooted at the account with optional pet links

Documents SHALL belong to the household library, not to a pet. A document SHALL link to zero or more pets via `document_pets` (ID links, no name matching). Documents with no pet links SHALL be valid and visible. Filtering by a pet SHALL return that pet's documents plus shared ones; pet counts SHALL include shared documents on each linked pet (overlap is by design, totals deduplicate).

#### Scenario: Shared receipt appears under both pets

- **WHEN** a petsitting receipt links Rex and Bella
- **THEN** it appears under Rex's filter, under Bella's filter, and once in the unfiltered library

#### Scenario: Unlinked household paperwork is not homeless

- **WHEN** aviatickets link no pet
- **THEN** they appear in the unfiltered library and are never hidden as orphans

### Requirement: Bytes on CDN, metadata in sync

File bytes SHALL upload/download via short-lived presigned PUT/GET against S3-compatible storage and SHALL never travel through the outbox or Postgres. Document metadata (title, pet links, readiness, extracted text) SHALL sync through the standard outbox + LWW + tombstone path. A metadata row SHALL NOT be treated as ready before its bytes confirm. Unconfirmed uploads SHALL be garbage-collected server-side.

#### Scenario: Offline capture syncs later

- **WHEN** a photo is captured offline
- **THEN** its metadata queues in the outbox and bytes upload on connectivity, becoming visible to the household only when both confirm

#### Scenario: Delete removes both planes

- **WHEN** a document is deleted
- **THEN** its metadata tombstones through sync and its bytes are deleted asynchronously without blocking the sync cycle

### Requirement: Search grows in stages, v1 is name-only

V1 search SHALL cover document titles only. The schema SHALL reserve an `extracted_text` column (populated by PDF text extraction in stage 2 and on-device OCR in stage 3) indexed for full-text search, without requiring a migration when those stages land.

#### Scenario: v1 finds by name

- **WHEN** the owner searches "passport"
- **THEN** documents titled with "passport" match; content-only matches are explicitly out of scope until stage 2

### Requirement: Sharing grows in stages, v1 is the system sheet

V1 sharing SHALL be the local file via the system share sheet (no backend links, no access tokens). Time-boxed vet links SHALL be a named future stage and SHALL NOT be designed here beyond reserving the direction.

#### Scenario: Share a lab result today

- **WHEN** the owner shares a lab PDF
- **THEN** the system sheet sends the locally cached file; no account, token, or backend step is involved

### Requirement: Document-to-event links are deferred

V1 SHALL NOT link documents to events. The `document_events` direction is reserved as a named future step and SHALL NOT constrain the v1 schema beyond keeping puntevent linkage additive.

#### Scenario: Prescription photo serves as drug info

- **WHEN** a course references its prescription photo
- **THEN** the reference is a free-text/document-pointer on the course, not a synced join row
