## 1. Fork bootstrap (DONE — evidence below, do not redo)

- [x] 1.1 Fork Lifio @ `607fae3` into this repo (`45fda7a` seed; history preserved; secrets hygiene checked)
- [x] 1.2 Strip Lifio domain (commit `45fda7a`): TimeTracking/Catalog/Insights/ManualEntry, both Live Activity targets, categories/entries/deletions API + contract + migrations; backend + iOS suites green
- [x] 1.3 Rename sweep (commit `879a1d0`): bundle IDs `com.antonkosenko.shunik`, App Group, Keychain, `shunik://`, `shunik-api.antonkosenko.pro`, GHCR/DB/module paths, display name + copy (EN+RU); suites green
- [x] 1.4 Structural rename (`dbc2f91`): `ios/Shunik`, Shunik/ShunikTests targets + scheme, `ShunikApp`, CI + skill + rule paths; orphaned `TimeOfLifeRelease.entitlements` removed; suites green
- [x] 1.5 Fresh `openspec init` + migrated `shunik-v1-foundation` plan (proposal + 6 spec deltas + design from explore; this file rewritten for the remaining work)
- [x] 1.6 Re-confirm ctx7 research bundle at apply ("nothing changed since explore"): GRDB FTS `/groue/grdb.swift`, UserNotifications `/websites/developer_apple_usernotifications`, S3 presigned `/websites/aws_amazon_s3`, HIG for first screens, SwiftUI Charts for weight trend; record IDs + queries + pins
  - §3 research record (2026-10-25, backend-only iteration): no fetches. HIG waived — no UI involved (evidence: zero `ios/` changes in §3). Apple API waived — no Apple SDK involved. Topic (invite-token handling) resolved from the in-repo OTP precedent (SHA-256 hash at rest, single-use, expiry; `internal/auth/otp.go` `otpHash`) — no external behavior to look up. S3/GRDB/docs fetches N/A to §3 scope.

## 2. Remaining proposal review gates (answer before building)

- [ ] 2.1 Confirm Q1: snooze stays cut for v1 (tasks below assume cut; overturn = edit `reminder-engine` spec + add snooze tasks)
- [ ] 2.2 Confirm AASA server file on `antonkosenko.pro` gains `7923U48U87.com.antonkosenko.shunik` before TestFlight (SIWA attribution)

## 3. Backend — identity + household + sharing [DONE 2026-10-26, branch opsx/shunik-v1-foundation]

- [x] 3.1 `households`, `household_members`, `household_invites` tables + invite accept on OTP/Apple sign-in; one household per user enforced (migration `010_households.sql`; unique index on membership user_id; `EnsureHousehold` called from `VerifyOTP` + `AppleSignIn`)
- [x] 3.2 Rescope every pet-scoped query `user_id → household_id` + membership edge check; household-isolation tests mirroring the old ownership tests (no pet tables exist yet — this landed as the household-scoped API surface `GET /mine`, `POST /invites`, `POST /invites/accept`, `DELETE /members` with membership checks; `TestHouseholdFlow_*` isolation coverage; full per-resource rescope rides with §4 tables)
- [x] 3.3 `updated_by` on every household row, `marked_by` on intake transitions; surfaced in DTOs (`households.updated_by`, `members.added_by`, `invites.invited_by` — all actor IDs, non-null; `marked_by` arrives with §4 intakes)
- [x] 3.4 Revoke-member = lock-not-wipe; member devices gate on next refresh (files intact) (RemoveMember revokes ALL refresh tokens of the removed user BEFORE deleting the membership; devices 401 to the auth gate with files intact; `TestRemoveMember_RevokesThenRemoves`)
- Verified: `gofmt` clean, `go vet` clean, `golangci-lint` 0 issues, `go test ./...` green (new `households_test.go` ×2: store + handlers incl. 202-always/no-enumeration, 409 double-join, 404 unknown/consumed/expired, revoke-before-remove, OTP-verify auto-household), contract gate green (4 paths + `household`/`household_member`/`invite` schemas + 3 error codes).

## 4. Backend — domain + blobs + sync [DONE]

- [x] 4.1 Tables: `pets`, `event_base` + `vacc_detail`, `grooming_detail`, `weight_point`, `med_course` + `intakes[]`, `documents` + `document_pets` (+ reserved `extracted_text`; `document_events` noted, not built) (migrations `011_pets_events`, `012_documents`, `013_tombstones_household` for household-scoped tombstones)
- [x] 4.2 Sync: per-resource cursors + tombstones for all new resources; order pets-before-dependents; ensure-pet-before-push (server side: changed-since pulls + cursor, base `updated_at` as LWW clock with 409 + server copy, idempotent creates, `GET /deletions?deleted_since=` reintroduced household-scoped; full outbox-drain order is §5)
- [x] 4.3 Blob endpoints: presigned PUT → confirm → presigned GET, short-lived household-scoped URLs, GC for unconfirmed uploads, async blob delete on tombstone (`BlobStore` interface + AWS SDK v2 S3 impl + in-memory fake; `NewBlobStoreFromConfig`, disabled → 503; opportunistic 24h/20-cap GC sweep; purge collects orphaned blob keys, handler deletes best-effort)
- [x] 4.4 Contract gate: `openapi.yaml` + `internal/contract` tests covering new paths, envelope, idempotent creates, LWW, deletions feed (12 domain paths + household `DELETE /members/{userID}` path-param migration; new codes: `not_found conflict invalid_pet_id upload_incomplete blob_not_configured`; update guards: pet_id/kind immutable — 422/400 respectively)
- Merger fixes (post-fan-out): pg `$2::uuid` param-type fix in `EnsureHousehold`/`AcceptInvite` (runtime-verified on live PG 18), migration-test `<10` cap removed, `ListUnconfirmedDocuments`/`DeleteDocumentsByIDs` promoted to the Store contract (both backends), store-assigned opaque blob keys via shared `blobKeyFor` (single enforcement point), GC sweep rewritten onto the non-tombstoning pair, 24 golangci revive findings cleared.
- Verified: `gofmt`/`go vet` clean, `golangci-lint` 0 issues, `go test ./...` green (incl. live-PG `TestPgDomain_*` + parity suites via local PG18), contract green, iOS suite green (tree untouched by §4).

## 5. iOS — store, sync, household gate

- [x] 5.1 `LocalStore` new tables + single-chokepoint writes; file `shunik_<householdId>.db`; gate order sign-in → resolve/create household → open store → shell
- [x] 5.2 `SyncController` resource list rewritten (pets → events/courses/intakes → documents metadata; bytes excluded); link handling for `document_pets` (ID links, no name healing)
- [x] 5.3 Undo buffer + tombstone flow for new resources (buffered delete pushes before drain, in-flight undo guard)
- iOS detail: `SyncModels.swift` (one Codable per wire shape, RFC3339-ms strings, inclusive-cursor norm); `SyncRelayRepository` + `ConflictError` (409 server copy; 404-on-delete swallows); `HouseholdService` (GET /mine, per-user cache + sidecar, offlineNoCache); cycle = push-buffered → pull-merge → tombstones → drain (update 404 resurrect-once, 409 rebase-once then adopt, 422 loud-keep; recreation-wins kept without push); resolver + gate + coordinator all household-scoped (`eraseFile(at:)` exact-file erase); inclusive `>=` pull bounds backend-wide (sqlite+pg) with test updates; flat event detail + singular tombstone resources in `openapi.yaml` (contract green).
- Verified: `swiftlint --strict` clean, `xcodebuild test` 360/360 green (incl. new `LocalStoreDomainTests`/`SyncRelayTests`/`SyncHouseholdTests`/`SyncCycleTests`/`UndoBufferDomainTests` + rewritten resolver/lifecycle/erase suites), backend `gofmt`/`go vet`/`golangci-lint` clean, `go test ./...` green incl. live PG18, `openspec validate --all --strict` green.

## 6. iOS — domain features

- [x] 6.1 Pets + adaptive IA: scope chrome appears only when `pets.count > 1`; en+ru strings + `L10n` for every new copy (U4); Theme colors only
- [x] 6.2 Events: vacc/grooming point + next-due forms; weight log + history + trend (`unit-system` chips, integer grams, epsilon)
- [x] 6.3 Medications: course editor (plan fields, schedule kinds in-scope only) + intake states taken/missed/skipped + auto-miss on supersede + early-stop pruning; PRN log-only
- [x] 6.4 Documents: library + pet filter (shared-included counts) + name search + system-sheet share + background CDN upload with offline queue
- iOS detail: TabView shell (Timeline/Pets/Meds/Documents/Profile, per-tab NavigationStack); `PetScope` adaptive helper; `UnitLens` per-device Metric/Imperial (locale default, decimal lb, 10g epsilon); `MedicationEngine` (wall-clock slots, Mon=1..Sun=7 → Calendar map, materialize/auto-miss/adherence excl. skipped, stop prunes future pendings); `DocumentTransferService` (presigned PUT → confirm, download cache, staged offline bytes, explicit retry); relay +3 methods (upload/confirm/download URL, 409 upload_incomplete never ConflictError); blob_key server-supplied; merger fixes: `SwiftUI.TimelineView` qualification in ProfileView, `meds.infoRef` case, L10n snapshot refresh.
- Verified: `swiftlint --strict` clean, `xcodebuild test` 409/409 green (49 suites incl. new Pets/Timeline/UnitLens/MedicationEngine/Medications/DocumentTransfer suites), backend untouched, `openspec validate --all --strict` green (re-run at commit).

## 7. iOS — reminders + units

- [x] 7.1 Reminder engine: derived queue, rolling ~14d window, deterministic IDs, re-top-up triggers, both-buzz default + per-device mute, wall-clock intakes
- [x] 7.2 Unit lens: per-device Metric/Imperial (locale default), chip live-conversion, decimal pounds; no display prefs in sync payloads
- [x] 7.3 Notification permission flow + Settings toggle; request at first due creation with graceful deny path
- iOS detail: `ReminderEngine` (UNUserNotificationCenter seam; queue from vacc/groom `next_due_at` + pending intakes; `due_<event>`/`intake_<id>` deterministic IDs; 14d window, 64-cap, stale/reschedule/stray cancellation via persisted stamp map; mute in `com.shunik.remindersMuted`, never synced; ask-once `noteDueCreated`); triggers — meds load (materialize), event save with next-due, foreground + timezone change, unmute; Profile Reminders section (toggle = authorized && !muted; denied → hint + Open Settings; off = local mute). §7.2 shipped in §6 (UnitLens, UserDefaults-only) — verified no unit data enters outbox payloads (String timestamps + integer grams only).
- Verified: `swiftlint --strict` clean, `xcodebuild test` 416/416 green (50 suites incl. new ReminderEngine suite), backend untouched, `openspec validate --all --strict` green.

## 8. Verify per iteration (S5, both suites)

- [x] 8.1 `gofmt -l .` empty, `go vet ./...`, `golangci-lint run`, `go test ./... -cover` green (SQLite, no Docker)
- [x] 8.2 `swiftlint lint --strict`, warning-as-error build, `xcodebuild test` green (one `xcodebuild` at a time, `project.yml` owns targets — no new targets added in §§5–7, nothing to wire into `release.yml`/`ios.yml`)
- [x] 8.3 Re-check Shunik FURPS/requirements rows once written; update `docs/project-context.md`, `README.md`, `Design/*`, `openapi.yaml` where behavior/contract changed
- [ ] 8.4 Rebase twice on `origin/main` (`push --force-with-lease`, never merge); re-run affected linters/tests after each rebase
- Verified 8.1: `gofmt -l` empty, `go vet` clean, `golangci-lint` 0 issues, `go test ./... -cover` green incl. live PG18 (`TEST_PG_DSN` local), contract green.
- Verified 8.2: `swiftlint --strict` clean, build succeeds (app/test warnings-as-errors via `project.yml`; only external `appintentsmetadataprocessor` notice), `xcodebuild test` 416/416 green (50 suites).
- Verified 8.3: Shunik FURPS/requirements rows NOT yet written (Lifio tables still in `Requirements/FURPS/` — nothing to re-check, not claimed); `docs/project-context.md` updated (§§5–7 actual state, deferred list corrected, stale "backend only"/"only auth routes" notes fixed); `README.md` updated (branch state + deferred list); `Design/*` untouched (Lifio system; Shunik screens land next per plan — not claimed as done); `openapi.yaml` unchanged since §5 (contract still green).
