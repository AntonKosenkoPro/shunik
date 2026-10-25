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

## 4. Backend — domain + blobs + sync

- [ ] 4.1 Tables: `pets`, `event_base` + `vacc_detail`, `grooming_detail`, `weight_point`, `med_course` + `intakes[]`, `documents` + `document_pets` (+ reserved `extracted_text`; `document_events` noted, not built)
- [ ] 4.2 Sync: per-resource cursors + tombstones for all new resources; order pets-before-dependents; ensure-pet-before-push
- [ ] 4.3 Blob endpoints: presigned PUT → confirm → presigned GET, short-lived household-scoped URLs, GC for unconfirmed uploads, async blob delete on tombstone
- [ ] 4.4 Contract gate: `openapi.yaml` + `internal/contract` tests covering new paths, envelope, idempotent creates, LWW, deletions feed

## 5. iOS — store, sync, household gate

- [ ] 5.1 `LocalStore` new tables + single-chokepoint writes; file `shunik_<householdId>.db`; gate order sign-in → resolve/create household → open store → shell
- [ ] 5.2 `SyncController` resource list rewritten (pets → events/courses/intakes → documents metadata; bytes excluded); link handling for `document_pets` (ID links, no name healing)
- [ ] 5.3 Undo buffer + tombstone flow for new resources (buffered delete pushes before drain, in-flight undo guard)

## 6. iOS — domain features

- [ ] 6.1 Pets + adaptive IA: scope chrome appears only when `pets.count > 1`; en+ru strings + `L10n` for every new copy (U4); Theme colors only
- [ ] 6.2 Events: vacc/grooming point + next-due forms; weight log + history + trend (`unit-system` chips, integer grams, epsilon)
- [ ] 6.3 Medications: course editor (plan fields, schedule kinds in-scope only) + intake states taken/missed/skipped + auto-miss on supersede + early-stop pruning; PRN log-only
- [ ] 6.4 Documents: library + pet filter (shared-included counts) + name search + system-sheet share + background CDN upload with offline queue

## 7. iOS — reminders + units

- [ ] 7.1 Reminder engine: derived queue, rolling ~14d window, deterministic IDs, re-top-up triggers, both-buzz default + per-device mute, wall-clock intakes
- [ ] 7.2 Unit lens: per-device Metric/Imperial (locale default), chip live-conversion, decimal pounds; no display prefs in sync payloads
- [ ] 7.3 Notification permission flow + Settings toggle; request at first due creation with graceful deny path

## 8. Verify per iteration (S5, both suites)

- [ ] 8.1 `gofmt -l .` empty, `go vet ./...`, `golangci-lint run`, `go test ./... -cover` green (SQLite, no Docker)
- [ ] 8.2 `swiftlint lint --strict`, warning-as-error build, `xcodebuild test` green (one `xcodebuild` at a time, `project.yml` owns targets — wire any new target into `release.yml` + `ios.yml` same PR)
- [ ] 8.3 Re-check Shunik FURPS/requirements rows once written; update `docs/project-context.md`, `README.md`, `Design/*`, `openapi.yaml` where behavior/contract changed
- [ ] 8.4 Rebase twice on `origin/main` (`push --force-with-lease`, never merge); re-run affected linters/tests after each rebase
