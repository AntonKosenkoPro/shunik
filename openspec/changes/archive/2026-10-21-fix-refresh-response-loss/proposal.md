## Why

A successful refresh whose response is lost leaves the server holding a new token and the app holding the revoked predecessor; an ordinary retry then triggers reuse detection and unexpectedly returns the user to Welcome. This failure was reproduced through the real simulator UI with a local response-cutting proxy, and matches the two production reuse-revocation events reported on October 18, although the original iPhone interruption trigger remains unproven.

## What Changes

- Give each logical refresh a durable, unpredictable `refresh_attempt_id`, persisted before sending and reused after network loss, suspension, restart, or failed credential persistence.
- Make backend rotation transactional and recoverable: the same device, predecessor, and pending attempt recover the same replacement refresh credential, with a fresh access token, rather than being treated as theft.
- Keep recovery available across long suspension, up to the replacement's existing refresh TTL; retries never extend that deadline. A seconds-only grace period would not cover the observed approximately 52-minute gap.
- Preserve genuine reuse detection, wrong-device rejection without collateral revocation, per-device logout, refresh expiry, and lock-not-wipe.
- Replace split, status-blind Keychain token writes with one status-checked credential snapshot; retain pending intent on transient failures and discard stale asynchronous completions after sign-out/account changes.
- Store a bounded, authenticated-encrypted replacement credential in pending server recovery receipts. Authentication lookups remain hash-based; this explicitly changes the current **hash-only server-storage description**, without allowing plaintext token persistence or logging.
- Add narrowly scoped regression tests and safe outcome logging; distinguish database/transport/storage failures from conclusive authentication rejection.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `device-sessions`: retry-safe refresh attempts, transactional device-family rotation, bounded recovery receipts, durable client credentials, and rejection/revocation rules that distinguish interrupted delivery from genuine reuse.

## Impact

- Backend auth handlers, token issuance, config, migrations, and PostgreSQL/SQLite stores; authoritative `backend/api/openapi.yaml` gains an additive optional refresh-attempt field and explicit recovery/error semantics. Updated iOS clients always supply the field; older clients retain their existing behavior and do not gain recovery.
- iOS auth repository/models, Keychain abstraction, `AuthService`, `APIClient`, and their tests. No changes to the local account databases, outbox semantics, timer data, or visible screen layout.
- Deployment must provide a stable recovery-encryption keyring before enabling the backend change; deployment/rollback documentation must protect pending receipts across restarts/key rotation.
- Update `docs/project-context.md`, relevant FURPS security/session rows, API documentation, and run/test instructions during implementation. No new third-party runtime dependency is planned.
- Non-goals: changing production token lifetimes, disabling rotation/reuse detection, device quota/picker #46, new sign-in methods, sign-in-provider account merging, a redesigned auth/sync UI, or proving that backgrounding specifically caused the original iPhone events.

Research for this proposal: Context7 `/websites/rfc-editor_rfc_rfc6749_txt` (refresh rotation/replay obligations) and `/websites/developer_apple_de` (status-aware Keychain updates; iOS 18 SDK via Xcode 16+); RFC 9700 §4.14.2 supplements the topic/security research. Exact queries, cryptography references, waivers, evidence limitations, and implementation-time reconfirmation are recorded in `design.md`.
