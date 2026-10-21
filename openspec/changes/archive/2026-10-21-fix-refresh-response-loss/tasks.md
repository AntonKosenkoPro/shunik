## 1. Repro and research gates

- [x] 1.1 Complete the ctx7 research bundle and record cites or waiver reasons (OAuth rotation topic, Apple Keychain API with iOS 18 SDK via Xcode 16+ pin, Go stdlib AEAD; HIG and external-service items waived with evidence or fetched if applicable; max 5 queries; re-confirm at apply time)
- [x] 1.2 Reproduce the bug on the current tree with recorded steps and sanitized evidence (committed rotation plus truncated refresh response, retained predecessor retry, `token_reuse` family revocation, Welcome gate; preserve backend sequence plus signed-in transport-error and Welcome screenshots outside git)

## 2. Backend transactional rotation and recovery

- [x] 2.1 Add the recovery-receipt migration and transactional `RotateRefreshToken` store methods for PostgreSQL and SQLite (revoke predecessor, insert successor, upsert receipt atomically; no partial commit)
- [x] 2.2 Implement the refresh handler recovery branches (eligible same-device retry returns same successor plus fresh access token; unknown or rebound attempts keep `token_reuse`; wrong device keeps `invalid_refresh` without revocation; expired recovery keeps `refresh_expired`; DB and crypto failures return service errors without revocation)
- [x] 2.3 Add the recovery keyring config, AES-256-GCM successor sealing with account, device, predecessor, attempt, and expiry binding, plus bounded receipt closure and expiry
- [x] 2.4 Update authoritative `backend/api/openapi.yaml` (optional `refresh_attempt_id`, recovery semantics, `refresh_attempt_completed` and attempt-conflict codes) and extend backend auth, rotation, TTL, concurrency, and contract tests
- [x] 2.5 Run backend verification green (`go build ./...`, `go test ./... -cover`, `golangci-lint run`, `gofmt -l .` empty, `go vet ./...`)

## 3. iOS durable attempt and credential snapshot

- [x] 3.1 Replace split status-blind token writes with one status-checked Keychain credential snapshot that preserves the last usable pair on failure and distinguishes temporary storage errors from absent credentials
- [x] 3.2 Implement the durable refresh-attempt lifecycle (persist unpredictable attempt before send, share across concurrent callers, reuse across restart, clear only after a complete successor snapshot is saved)
- [x] 3.3 Bind refresh completion to the active account generation, drop stale completions, remove the second blind restoration refresh, and surface refresh rejection codes without signing out on transport, decoding, storage, or service failures
- [x] 3.4 Extend iOS auth tests (truncated-commit reclaim, restart mid-replacement, stale-completion drop, single-flight sharing, generation guard, genuine reuse still revokes) and run iOS verification green (`swiftlint lint --strict`, warning-as-error build, `xcodebuild test`)

## 4. Contract, docs, and final verification

- [x] 4.1 Re-check `Requirements/FURPS/Sign-up_and_Sign-in.md` F4 and F5 plus `Requirements/FURPS/Common.md` R1, S5, S8, and S10; confirm no conflicts or correct the rows
- [x] 4.2 Update `docs/project-context.md`, API and run/test notes, deployment keyring and rollback handling, and the recorded hash-storage description for the encrypted pending successor
- [x] 4.3 Re-run the identical section 1.2 repro on the fixed tree and confirm recovery without Welcome; run `openspec validate --all --strict`
