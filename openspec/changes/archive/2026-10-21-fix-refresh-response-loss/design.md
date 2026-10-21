## Context

See `proposal.md` for motivation. The current refresh path rotates non-transactionally (revoke predecessor, then issue successor in separate store calls), retries a lost response with the bare revoked predecessor, maps every 401 to one undifferentiated client signal, writes access and refresh tokens to the Keychain in split status-blind steps, and can report a failed database lookup as `invalid_refresh`. The fix must preserve the `device-sessions` invariants: per-device families, reuse detection that revokes only the offending device, wrong-device rejection without collateral revocation, refresh TTL enforcement, lock-not-wipe, and no device quota.

Research basis (implementation must re-confirm at apply time): Context7 `/websites/rfc-editor_rfc_rfc6749_txt` — `Refresh token rotation response replacement and replay protection obligations` (rotation MAY issue a new refresh token with replacement semantics; rotation SHOULD detect reuse of an invalidated token as a breach signal); Context7 `/websites/developer_apple_de` — `Keychain Services SecItemUpdate OSStatus preserving existing item on update failure kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly iOS 18 SDK Xcode 16`, pin `iOS 18 SDK via Xcode 16+` (check `OSStatus` on add/update and leave the existing item in place on failure; generic-password identity includes service plus account). RFC 9700 §4.14.2 (direct fetch, supplements the topic research) recommends rotation with reuse detection for public clients. Go standard-library `crypto/cipher` AEAD (`NewGCMWithRandomNonce`, Go 1.24) verified via pkg.go.dev fetch; no new third-party dependency. Waivers: HIG N/A — no visible screen, layout, or interaction changes (proposal Impact); additional external service/library setup N/A — recovery uses Go stdlib and Apple Keychain only (proposal Impact).

## Goals / Non-Goals

**Goals:**
- Make an interrupted but committed rotation recoverable by the same device, predecessor, and attempt, returning the same successor plus a fresh access token without extending refresh expiry.
- Keep genuine reuse, wrong-device, expiry, logout, and revocation behavior intact and distinguishable from transport, decoding, storage, and service failures.
- Survive suspension, restart, concurrent callers, and failed credential writes without mixed token pairs or cross-account writes.

**Non-Goals:**
- No explicit acknowledge endpoint; successor consumption plus TTL expiry close receipts.
- No time-based grace window that weakens reuse detection.
- No plaintext token retention, no token/attempt/ciphertext logging, no TTL value changes, no quota/picker work.

## Decisions

- **Durable attempt per logical rotation.** The client mints one unpredictable UUIDv7 attempt before the first network send, binds it to account, device, and predecessor, persists it durably, and reuses it until a complete successor snapshot is durably saved. Concurrent refresh callers share it. Alternative (fresh ID per retry) was rejected: it is indistinguishable from theft and would keep tripping reuse detection.
- **Transactional rotation with a bounded receipt.** One database transaction consumes the predecessor, inserts the successor, and records the pending receipt keyed by attempt; commit-all or commit-nothing on both Postgres and SQLite. The receipt carries only non-secret routing metadata plus the authenticated-encrypted successor, bound to account, device, predecessor, attempt, and the successor's fixed expiry. Recovery is valid only while that expiry holds and the successor is neither consumed nor revoked. Alternative (two-call rotation plus receipt) was rejected: a crash between revoke and insert is total session loss.
- **Stable recovery result.** Before successor consumption or revocation, a matching retry returns the identical successor refresh credential and a newly minted valid access token. Duplicates and out-of-order deliveries converge on one successor; repeated loss keeps returning it. Once the successor rotates forward, the old receipt closes and a delayed duplicate returns 409 `refresh_attempt_completed` without touching the family. A rebound attempt ID on a different predecessor returns a 409 conflict without issuing credentials. Missing `refresh_attempt_id` keeps legacy behavior with no recovery. Alternative (rotate forward on every retry) was rejected: each lost response would burn another token and could never converge.
- **Encrypted pending successor, hashes unchanged.** Authentication lookups stay hash-based. Only the pending successor is recoverable, sealed with AES-256-GCM from the Go standard library, with account/device/predecessor/attempt/expiry as associated data, under a stable server-side keyring (`REFRESH_RECOVERY_KEYS`, primary plus retired keys for rotation). Plaintext re-emission and unauthenticated encryption were rejected: the former violates token-confidentiality obligations, the latter permits receipt tampering.
- **One status-checked credential snapshot on iOS.** Access token, refresh token, attempt, account, and generation persist as a single Keychain snapshot: write only complete decoded 2xx results, check `OSStatus` on add/update, preserve the last usable snapshot on failure, distinguish temporary storage errors from absent credentials, drop completions from older generations or superseded attempts, and remove the restoration-time second blind refresh so one protected request has one refresh owner. Split writes and status-blind overwrites were rejected: they produce mixed pairs that mimic response loss.
- **Explicit failure taxonomy.** `invalid_refresh`, `token_reuse`, and `refresh_expired` keep their 401 meanings and revocation rules; revoked-before-expiry ordering is preserved. New non-authentication conflicts use 409 (`refresh_attempt_completed`, attempt-rebind conflict). Database, crypto, receipt-unavailable, and uncommitted-rotation failures use 5xx service errors without revocation. Truncated or non-envelope refresh responses stay retry intent, never conclusive rejection. Collapsing everything into one unauthorized signal was rejected: the client cannot choose recovery versus the auth gate without it.

## Risks / Trade-offs

- [Recovery key loss or rotation mishandled] → Require persistent keyring config before enabling recovery; support primary plus retired keys; treat undecryptable receipts as service failures without revocation.
- [Attempt-ID write itself lost] → Fail closed to current behavior (stay signed in offline, no request sent); never acquit an unknown replay.
- [Stolen predecessor plus stolen attempt] → Accepted residual risk, equivalent to bearer-token theft today; wrong-device and unknown-attempt replays still revoke.
- [Receipt growth from clients that never return] → Bound by successor expiry plus closure on consumption, logout, and revocation; no background sweeper required beyond lazy expiry checks.
- [Legacy clients without the field] → Unchanged legacy reuse behavior; recovery is opt-in by sending the field.
- [Concurrent duplicate deliveries] → Single transaction plus stable-result rule converges them on one successor.

## Migration Plan

1. Land the receipt-table migration and keyring config first; the backend refuses to advertise recovery until both are present.
2. Deploy the backend with additive `refresh_attempt_id` support; legacy requests behave exactly as before.
3. Ship the iOS durable-attempt and snapshot changes; updated clients always send the field.
4. Roll back by disabling recovery reads while retaining receipts: new attempts behave as legacy rotations, and pending receipts expire naturally. Never delete pending receipts as part of a rollback.
5. Update `backend/api/openapi.yaml`, `docs/project-context.md`, affected FURPS rows, and run/test notes in the same change.
