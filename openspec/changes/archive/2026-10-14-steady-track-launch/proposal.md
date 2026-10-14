## Why

Device frame analysis killed the overlay approach: the splash-to-Track swap routinely collapses into a single render commit, so no fade ever has frames to play across — and the transparent-VStack overlay even let Track paint straight through it. At the same time, every waiting UI (spinner, brand splash, skeleton) exists to cover ~50 ms of local I/O, which is fast enough to simply do before the first paint. The HIG-conformant answer is not a better veil but no waiting UI at all: the first visible Track paint already carries complete local data.

## What Changes

- The launch gate reads the cached session synchronously and, when an account is cached, binds the store, seeds, and loads the full Track snapshot (recents, names, categories, running draft) BEFORE mounting the shell — all local, ~50 ms. The first Track paint is complete by construction: no splash, no skeleton, no spinner, no fade, no empty flash, no pop-in.
- Session restore (`/me`) verifies in the background: success is invisible; an auth failure cuts to the auth flow (rare, honest — lock-not-wipe semantics unchanged). No cached session → auth flow immediately.
- `TrackViewModel.load()` is refactored onto a shared snapshot loader: the gate preload and the view-model load consume the same query set, published in a single commit (locals-then-assign) so even post-mount reloads fill in one render instead of three progressive paints.
- Sync-exit reloads skip publishes whose snapshot is unchanged, so no-op syncs render literally nothing.
- Deletes the entire veil apparatus from this change's earlier direction: `LaunchCover`, the readiness signal, the timeout, the settle beat, the overlay, its fade, and the zIndex scaffolding. Fresh OTP sign-in shows the standard auth-button loading state during bind+snapshot, then swaps to the complete shell once.
- The branded splash view and its overlay use are removed; Welcome keeps its brand (auth/onboarding is where HIG places branding).

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `app-shell`: optimistic launch — shell mounts only after bind, seed, AND first Track snapshot; no restoring splash for cached sessions (background-verified restore, auth cut only on auth failure); auth flow immediately when nothing is cached.
- `timer-capture-experience`: first paint carries the full local snapshot (recents + icons + running draft) via a single-commit fill; reloads publish once and skip unchanged snapshots.

## Impact

- iOS only: new snapshot loader (TimerService-adjacent), `TrackViewModel` adopt path, `RootView.beginSignIn` preload ordering, deletion of `LaunchCover.swift` + signal + overlay code, auth-button loading during fresh sign-in bind. No backend, OpenAPI, store schema, navigation, or `project.yml` changes.
- No new user-facing strings; `Theme` colors only; nothing animates at launch (Reduce Motion compliant by construction).
- Tests: drop `LaunchCoverTests`; rewrite signal tests as snapshot/adopt/ordering tests (preload-before-mount, restore-failure gating, single-commit fill, no-op reload suppression).
- Docs: `docs/project-context.md` launch-sequence line only if it names the splash (it doesn't — verify); no `Design/*.md` changes (no new components; the gate visual simply disappears).

### Non-goals

- Waiting on first-sync network data (offline launches stay instant; relay convergence keeps the sync-exit reload path, now diff-guarded).
- Changing restore/auth semantics, sync activation timing, outbox, undo buffer, or seeding — all stay exactly where they are.
- Animating the launch cut itself: with identical backgrounds and complete first paint, the OS-launch→Track swap is a single clean cut by design.
- Touching the OS launch screen (already a compliant solid background).

### External docs

- No new external-dependency behavior: the loader uses the existing GRDB stack and `SessionCache`/`UserDefaults` synchronous read (repo-internal APIs). Prior ctx7 citation (`/websites/developer_apple_swiftui`, opacity transition) is retired with the fade. Apple HIG "Launching" (launch visuals nearly identical to first screen; no logo splash) motivates the direction; cited from the guideline text, no fetch needed beyond what was already retrieved.
