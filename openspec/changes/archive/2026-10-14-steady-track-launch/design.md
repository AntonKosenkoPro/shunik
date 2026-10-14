## Context

See proposal.md (Why) for motivation. This design supersedes the change's earlier overlay direction (covered mount + readiness signal + fade): device frame analysis showed mount → load → unveil collapsing into a single render commit (no fade ever has frames to play across) and the transparent-VStack overlay letting Track paint straight through. The veil machinery is deleted; what survives from that iteration is the evidence (frame-level repro) and the measured local costs (prepare ~21 ms, first load ≤11 ms).

Current state at `main` head: `RootView` gates on `SessionStore` (restoring splash → bind spinner → shell), `TrackViewModel.load()` awaits recents/names/categories across separate turns (up to 3 progressive paints), reloads publish unconditionally. Constraints from `docs/project-context.md`: LocalStore is the single mutation chokepoint (this change performs no writes — pure reads); no new strings (none added); `Theme` colors only; bugfix rule (recorded repro before/after — the `repro/` evidence stands); iOS 18+ floor.

## Goals / Non-Goals

**Goals:**

- First visible Track paint is complete (local data) with no splash, skeleton, spinner, or fade anywhere in the launch.
- One shared snapshot query set serves gate preload and view-model load; every publish lands in a single render commit.

**Non-Goals:**

- Waiting on first-sync network data (offline launches stay instant; relay converges via the existing, now diff-guarded, sync-exit reload).
- Changing restore/auth semantics, sync activation, outbox, undo, seeding, or the D1/D10 spacing model.
- Animating the launch cut; Reduce Motion posture is satisfied by construction (nothing animates).
- Touching the OS launch screen (already a compliant solid background).

## Decisions

### 1. Optimistic mount on the cached session (no waiting UI)

At launch `AuthService.restoreSession` signs in optimistically from cache before `/me` returns, and now clears `isRestoring` at that point (instead of at `/me` resolution) — the gate proceeds on the cached session while validation continues concurrently. No-cache launches keep holding through `/me` (existing login-flash test preserved). The gate then runs bind + seed + snapshot load (all local, ~50 ms total) and mounts with snapshot in hand; no cache at all → auth flow immediately. Restore success is invisible; auth failure cuts to the gate (lock-not-wipe unchanged — local files never touched, glimpsed local data is the device owner's own under the device-unlock boundary).

- Alternative considered: holding any splash/skeleton until `/me` returns. Rejected — it trades a rare honest cut (revocation) for a branded wait on every launch, against HIG and against the user's explicit "nothing says wait".
- Alternative considered: skeleton placeholders. Rejected by the user — a skeleton is a waiting screen with better PR.

### 2. Shared snapshot loader, adopted — never duplicated

Track's queries move into one loader (TimerService-adjacent) returning a snapshot struct (recents, names, categories, draft, nameDraft). `TrackViewModel.load()` becomes `apply(await loader.loadSnapshot())` plus its existing side effects (ticker, Live-Activity re-mirror); the gate preload calls the same loader and the fresh view model adopts the snapshot instead of re-querying. One source of truth, two call sites — the duplication objection that killed conditional-mount earlier does not apply.

### 3. Single-commit publishes, diff-guarded reloads

All assignments from a resolved snapshot happen synchronously in one block (one render, not three). Reloads compare before publishing and skip identical snapshots, so no-op sync cycles render nothing. `TrackState`/snapshot values already compare by value; no new equality machinery beyond a snapshot `Equatable`.

### 4. Delete the veil (do not keep it "just in case")

`LaunchCover`, the readiness signal, timeout, settle beat, overlay, fade, and zIndex scaffolding are removed with this change — keeping them would leave dead branches plus a second, conflicting reveal contract. The unit tests written for them (`LaunchCoverTests`, signal tests) are replaced by snapshot/adopt/ordering tests. Repro/verify evidence stays in `repro/` as the record.

### 5. Neutral empty states, disabled-while-loading inputs

No skeleton anywhere means the only pre-data paint is... none (mount follows data). The ~200 ms window where a user could tap before adopt completes is closed by disabling the name row and Start until the first snapshot lands (Start is already draft-gated; the row gets the same treatment). Failure path: preload throws → mount anyway → `load()` on appear surfaces the existing banner. Mount is never gated on preload success.

## Risks / Trade-offs

- [Risk] Revocation flash: cached session + dead token shows ~0.5 s of local Track before the auth cut → Mitigation: accepted and spec'd (rare, honest, device owner's own data); alternative (hold for `/me`) was explicitly rejected.
- [Risk] Fresh sign-in bind+snapshot (~100 ms) with only the auth button loading → Mitigation: standard interaction feedback, not a waiting screen; the swap lands complete.
- [Risk] First-paint measurement settle (AdaptiveVerticalLayout zero→measured pass, a few points over 1–2 frames) → Mitigation: verify by recording; D10 reservations already bound it; fix only if visible.
- [Risk] Snapshot/view-model skew if the loader and VM drift → Mitigation: VM consumes the loader (no parallel implementation to drift); tests pin adopt-equivalence.
- [Risk] Deleting the signal removes the timeout backstop for hung loads → Mitigation: load path contains no unbounded awaits (local GRDB + local ActivityKit re-mirror); hangs were never observed, only hypothesized.

## Migration Plan

No migration: no schema, no flags, no API. Behavior is unconditional once merged. Rollback is a plain revert. The `.xcodeproj` picks up one new file (loader) and drops three (`LaunchCover`, two test files replaced by new ones) via the usual `xcodegen generate`.

## Open Questions

- None blocking. Sign-in button loading copy uses existing strings (no new L10n).
