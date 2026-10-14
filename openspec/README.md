# OpenSpec — this repo's workflow

This repo is **spec-driven** (`openspec/config.yaml`, `schema: spec-driven`). OpenSpec manages
change proposals as artifacts (proposal → specs → design → tasks) and folds accepted changes
into baseline specs via `openspec archive`. Use `openspec --help`; this directory is AI-editable,
but the CLI stays the source of truth.

## Concepts: baselines, deltas, archives

| Layer | Location | Meaning |
|---|---|---|
| **Baseline specs** | `openspec/specs/<capability>/spec.md` | The current merged contract. Today (20 baselines): `account-bound-store`, `app-icon`, `app-identity`, `app-shell`, `apple-signin`, `category-management`, `device-sessions`, `editor-sheet-ux`, `entry-editor`, `entry-provenance`, `history-entry-list`, `insights-breakdown`, `live-activities`, `local-first-store`, `lock-screen-controls`, `manual-entry`, `name-picker`, `release-versioning`, `sync-client`, and `timer-capture-experience`. **Never edit directly** — behavior changes go through a change. |
| **Active change (deltas)** | `openspec/changes/<change>/` | A proposal in flight. Its `specs/<capability>/spec.md` files are delta specs (ADDED/MODIFIED requirements) not yet in the baseline. No active change right now (umbrella archive of 8 changes landed 2026-10-10 plus `2026-10-14-steady-track-launch' (optimistic instant Track launch, folded into `app-shell` + `timer-capture-experience'): `separate-notes-editor`, `extend-notes-limit`, `fix-sync-entry-truncation`, `fix-track-empty-after-reinstall`, `fix-track-visual-glitches`, `fix-tab-bar-return-jump`, `category-chip-order-numbers`, `live-activities`) — check `openspec list`. |
| **Archives** | `openspec/changes/archive/<change>/` | Completed changes; their deltas were already folded into the baselines by `openspec archive`. Read them only for history. Today: `redesign-track-experience`, `keep-timer-position-on-stop`, `unify-activity-preparation-flow`, `refine-selected-activity-from-track`, `add-category-management`, `collapsing-editor-sheet-headers`, `integrate-app-icon`, `refine-track-recents`, `local-first-sync-architecture`, `add-manual-entry`, `history-entry-list`, `disable-start-while-saved`, `fix-stale-draft-first-start`, `fix-running-tags-title-spacing`, `fix-entry-category-sync`, `destructive-erase-row`, `fix-category-sync-loss`, `propagate-buffered-deletes`, `localize-natural-duration`, `fix-42-clear-button`, `fix-offline-banner-duplication`, `fix-entry-form-gestures`, `feat-entry-duration-subtitle`, `feat-name-field-affordances`, `fix-50-nav-buttons`, `fix-51-picker-width`, `feat-category-icons-lifedomains`, `fix-history-sync-refresh`, `account-bound-local-data`, `add-version-label-release`, `fix-category-name-field-layout`, `unify-category-editor-chrome`, `fix-profile-signout-row`, `fix-sync-status-row`, `reduce-codebase-complexity`, `separate-notes-editor`, `extend-notes-limit`, `fix-sync-entry-truncation`, `fix-track-empty-after-reinstall`, `fix-track-visual-glitches`, `fix-tab-bar-return-jump`, `category-chip-order-numbers`, and `live-activities`. |

**Which contract is in force?** The baselines (no active change right now, so no deltas).

## Workflow

1. **Read the context first**: `docs/project-context.md` is the canonical repo context
   (architecture, API contract, incomplete surfaces, standards). `openspec/config.yaml`
   injects it into artifact instructions; `AGENTS.md` is the short entrypoint.
2. **Propose** a change: `openspec new change <name>` (or the `openspec-propose` skill).
   Fill in `proposal.md`, then the delta specs (`specs/<capability>/spec.md`), `design.md`,
   and `tasks.md`. Run `openspec validate <change> --strict` to check coherence.
3. **Implement**: drive `tasks.md` to completion (see `openspec instructions apply --change <name>`).
4. **Archive** when complete: `openspec archive <change>` folds the deltas into the baseline
   specs and moves the change to `openspec/changes/archive/`. Then update
   `docs/project-context.md` (routing + "Incomplete / deferred") and this README.

## Key commands

```bash
openspec list                                  # active changes + progress
openspec list --specs                          # baseline specs
openspec status --change <change>              # artifact/task completion
openspec validate --all                         # validate every change and spec
openspec validate <change> --strict             # validate one change
openspec show <change-or-spec>                   # read an artifact
openspec context                               # resolved root context
openspec instructions <artifact|apply|archive> --change <change>   # what the CLI expects
openspec archive <change>                      # fold deltas into baselines
```

The `openspec/` directory contains this guide, `config.yaml`, baseline `specs/`, and active or
archived `changes/`. The CLI generates or updates workflow adapters on demand.

## Repo conventions that affect changes

- **Baselines never edited directly**; every behavior change adds a delta to a change.
- **Incomplete UI surfaces must not be claimed done**: app-wide UndoToast/shake-to-undo,
  "via <Source>" labels, and the iOS 18 lock-screen ControlWidget itself (a widget
  extension target exists for Live Activities; the Control toggle is still deferred —
  deferred again as excessive under `bump-ios-deployment-to-18`) remain deferred.
  Entry and category deletions undo through the DEFAULT system Undo confirmation
  (archived `unify-catalog-deletion`) and do not close the app-wide undo work.
- **OpenAPI is the authoritative API contract** (`backend/api/openapi.yaml`, S10): endpoint
  changes update both sides + the spec.
- Per-iteration revising process (linters, tests, docs): `docs/project-context.md` → S5.
