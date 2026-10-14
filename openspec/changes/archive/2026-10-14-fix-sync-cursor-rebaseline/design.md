## Context

See proposal.md (Why). Current state (v0.2.2, includes `fix-sync-entry-truncation`):

- `SyncController.pull` follows entry pagination to exhaustion and advances the `entry` cursor to the max `updated_at` over all pages — but only over the pull it actually runs. When a stored cursor exists, the pull is a `modified_since` delta; the loop pages within that delta.
- Cursors persist per account file in `LocalStore.sync_state` (`resource` → `last_synced_at`; `lastSyncedAt`/`setLastSyncedAt`, `LocalStore.swift:1521-1543`). The file survives app updates — only explicit per-account Erase deletes it.
- Devices that synced pre-fix hold a poisoned `entry` cursor (partial-page max). Their next cycle deltas from it and never sees the truncated tail — the recorded repro-1.2 dynamic. Fresh installs (nil cursor) converge fully, which is why the bug report splits simulator-vs-device.
- Same-account guard, LWW idempotent merge, tombstones (never paginated), and category full-pull are all in place and unaffected.

## Goals / Non-Goals

**Goals:**

- Heal poisoned `entry` cursors exactly once per account file via a full paged re-pull through the existing idempotent merge.
- No new tables, no schema migration, no relay or contract change, no behavior change for nil cursors.

**Non-Goals:**

- Detecting "poisoned vs healthy" cursors heuristically (any detector can misfire; one unconditional re-baseline per file is simpler and safe).
- Resetting `deletions`/category state, touching outbox/undo/timer, or changing the steady-state delta path.

## Decisions

1. **Unconditional one-time re-baseline per account file over poison detection.**
   A healthy cursor costs one redundant full pull (paged, `limit=200`, LWW-idempotent — no duplicates, no outbox churn); a poisoned one heals. Any "is this cursor poisoned?" heuristic (e.g. comparing cursor against oldest local `updated_at`) adds a misfire mode with no upside. Alternative (heuristic gate) rejected.

2. **Flag lives in `sync_state` as a timestamp row, no schema change.**
   New `LocalStore` method `rebaselineEntryCursorIfNeeded()` (single write, chokepoint rule intact): if `sync_state` holds no `entry_rebaseline` row, DELETE the `entry` cursor row and INSERT `entry_rebaseline` = now, returning true; else no-op returning false. A date fits the table shape honestly ("when we rebased") and rides the per-account file automatically — unlike UserDefaults/Keychain, which are not per-account and would suppress healing for a second account. Alternative (dedicated table/column) rejected: heavier, same effect.

3. **Gate as the first guarded stage inside the cycle body, after the connectivity check.**
   In `runCycle` after the binding, connectivity gate, and `.syncing` mark, before any pull reads the cursor. Offline cycles skip it entirely (the next online cycle re-baselines instead) — no pointless clear-then-fail. The existing per-page same-account guards are untouched. Alternative (gating in `activate`) rejected: `activate` early-returns when already active, so a re-activation path could skip it; cycle entry runs for every generation.

4. **Flag-before-pull ordering (flag set with the clear, not after success).**
   Offline cycles never reach the gate (connectivity check first), so the only post-clear failure mode is a mid-cycle error — and the next cycle then simply runs the full pull: at-most-twice full pull, exactly-once flag. Alternative (set flag only after a successful full pull) rejected: a crash between clear and flag-set would loop full pulls, and adds state to thread through the cycle.

## Risks / Trade-offs

- [Risk] One full re-pull per upgraded account costs N pages on metered connections → Mitigation: paged at `limit=200`, runs on the existing triggers only (no new background work); personal-scale histories converge in a handful of requests.
- [Risk] Re-baseline races an in-flight cycle (activate → re-activate) → Mitigation: single-flight generation discipline already serializes cycles; the method itself is idempotent (second call no-ops on the flag).
- [Risk] Mid-re-baseline account swap → Mitigation: gate sits after the binding guard; a swap aborts the cycle before any pull, and the cleared cursor just means the next complete cycle for that account starts full — safe by construction.
- [Risk] A device that never synced pre-fix pays one redundant full pull → Mitigation: accepted (Decision 1); bounded and invisible.

## Migration Plan

No migration: no schema change, no endpoint change. Rollback is a plain revert — worst case a device reverts to delta-from-poisoned-cursor behavior until the flag row is ignored (unknown `sync_state` rows are inert to old code — `lastSyncedAt` only reads its own resource keys).

## Open Questions

None — cursor storage, guard placement, and merge idempotency are all established by the cited code and the prior change's tests.
