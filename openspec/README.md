# OpenSpec — this repo's workflow

This repo is **spec-driven** (`openspec/config.yaml`, `schema: spec-driven`). OpenSpec manages
change proposals as artifacts (proposal → specs → design → tasks) and folds accepted changes
into baseline specs via `openspec archive`. Use `openspec --help`; this directory is AI-editable,
but the CLI stays the source of truth.

## Concepts: baselines, deltas, archives

| Layer | Location | Meaning |
|---|---|---|
| **Baseline specs** | `openspec/specs/<capability>/spec.md` | The current merged contract. Today (25 baselines): `account-bound-store`, `account-deletion`, `app-icon`, `app-identity`, `app-shell`, `apple-signin`, `backend-database`, `category-management`, `device-sessions`, `editor-sheet-ux`, `email-otp-auth`, `entry-editor`, `entry-provenance`, `history-entry-list`, `insights-breakdown`, `live-activities`, `local-first-store`, `lock-screen-controls`, `manual-entry`, `name-picker`, `observability`, `relay-cors`, `release-versioning`, `sync-client`, and `timer-capture-experience`. **Never edit directly** — behavior changes go through a change. |
| **Active change (deltas)** | `openspec/changes/<change>/` | A proposal in flight. Its `specs/<capability>/spec.md` files are delta specs (ADDED/MODIFIED requirements) not yet in the baseline. Active changes live under `openspec/changes/` — check `openspec list`. |
| **Archives** | `openspec/changes/archive/<change>/` | Completed changes; their deltas were already folded into the baselines by `openspec archive`. Read them only for history. See `openspec/changes/archive/` for the full list. |

**Which contract is in force?** The baselines plus any active deltas under `openspec/changes/` (`openspec list`).

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
- **Incomplete UI surfaces must not be claimed done**: shake-to-undo polish + bulk-delete cap,
  and the iOS 18 lock-screen ControlWidget itself (a widget
  extension target exists for Live Activities; the Control toggle is still deferred) remain deferred.
  Entry and category deletions undo through the DEFAULT system Undo confirmation
  (archived `unify-catalog-deletion`) and do not close the app-wide undo work.
- **OpenAPI is the authoritative API contract** (`backend/api/openapi.yaml`, S10): endpoint
  changes update both sides + the spec.
- Per-iteration revising process (linters, tests, docs): `docs/project-context.md` → S5.
