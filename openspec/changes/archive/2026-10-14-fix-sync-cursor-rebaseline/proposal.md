## Why

The pagination fix (`fix-sync-entry-truncation`, shipped in 0.2.2) converges full history only for pulls that start with a nil `entry` cursor. Every device that synced with the pre-fix client carries a poisoned cursor — the max `updated_at` of a single truncated page — and the new client treats it as complete: delta pulls can never see the rows below it, so History stays capped at ~50 entries forever despite the fix. TestFlight 0.2.2 confirmed this on an upgraded device while fresh sign-ins converge fully.

## What Changes

- On first run of the fixed client, the sync layer performs a one-time re-baseline: it clears the persisted `entry` sync cursor (and only that cursor) so the next cycle runs a full paged pull and re-converges the complete history via the existing idempotent LWW merge.
- The re-baseline runs exactly once per account file, guarded by a persisted flag; later launches and fresh installs (nil cursor) behave exactly as today.
- `deletions` cursor, category snapshot, outbox, undo buffer, and timer state are untouched — tombstones were never paginated and need no reset.
- Regression coverage: a test that writes a poisoned cursor (partial-page max over a multi-page relay history), runs a cycle, and asserts full convergence with the cursor landing on the global max.

## Capabilities

### New Capabilities

(none — behavior fix within the existing sync contract)

### Modified Capabilities

- `sync-client`: the delta-pull requirement gains a one-time entry-cursor re-baseline — a cursor recorded before pagination-aware pulls existed is discarded once, forcing a full re-pull that heals the truncated tail.

## Impact

- iOS: `SyncController` activation/first-pull path (re-baseline gate + flag), `LocalStore` cursor primitives if a new persistence point is needed (same chokepoint rule applies — no raw GRDB writes outside `LocalStore`).
- No relay change, no endpoint change, no `openapi.yaml` change (pagination contract already covers it).
- Tests: new `SyncControllerTests` upgrade-path regression; existing suite must stay green.
- Cost: one full re-pull per upgraded account (paged, `limit=200`, LWW-idempotent — no duplicates, no outbox churn).
- Non-goals: re-pulling categories/deletions state, version-gated migrations for on-disk formats (pre-release policy stands — the flag is a lightweight default-false marker, not a schema migration), healing devices that never synced pre-fix (nothing to heal).
