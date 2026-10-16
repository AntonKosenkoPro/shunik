# History Screen — Roadmap (archived)

> **Archived.** The deferred History follow-ups below (filtering, History-row swipe delete, undo polish + bulk-delete cap) are tracked in a single home: `docs/project-context.md` → "Incomplete / deferred". This file is preserved as archaeology — its "Activity" references are stale (the activities layer is gone).

> Note (`remove-activities-layer`): the activities layer is gone — no activity
> definitions, no Manage Activities, no activity detail sheet, no activity
> editor. Entries own their exact text, ordered categories, and notes; History
> row taps open the unified entry form directly. The exploration below is
> preserved as archaeology; "Activity" references in it are stale.

Captures the deferred decisions and future steps for the History experience,
extracted from an explore-mode session. Step 1 (read-only entry list grouped
by day) is tracked separately as its own OpenSpec change; this file holds
everything after it, to be discussed and sequenced into later changes.

The architectural lean from exploration:

- **History is a list of entries (timed intervals), not activities.** An
  activity is a definition; an entry is an event. "What did I spend time on
  and when?" is answered by entries. Activities belong to
  Manage-Activities (definition management); entries belong to History
  (retrospective review).
- **Entries are first-class objects.** They deserve their own detail/editor
  surfaces, distinct from the activity editor. Reusing `ActivityEditor` for
  an entry would conflate two mutation chokepoints (`refineActivity` vs
  `updateEntry`) and two different objects (definition vs event).
- **Each surface has one job.** History = global chronology.
  ActivityDetail (if built) = "everything about one activity".
  EntryDetail = "one interval". Editor sheets stay focused mutation surfaces.

## Target shape (reference)

```
        ManageActivities                 History
              |                            |
              v tap row                    v tap entry row
        ActivityDetail                EntryDetail
         |       |                     |       |
         |       +-[Edit]-> ActivityEditor    +-[Edit]-> EntryEditor
         |              (def sheet)              (event sheet)
         |
         +- entries list (tap -> EntryDetail, same screen as from History)
```

`EntryDetail` is the single shared destination for "one entry" regardless of
where it was opened from (History row or ActivityDetail entries list).

## Deferred items

### 1. History filtering

- Filters by Activity, Date range, and Source (provenance).
- Affects History VM query shape — may need store-level filter support
  beyond the current `entries()` (which returns all, newest-first).
- Day grouping must coexist with filters (filter narrows the set, grouping
  buckets the result).
- Open question: filter bar UI pattern (chips vs. a filter sheet). The
  existing `TagSelector` chip pattern is a candidate for Activity/Source
  multi-select.

### 2. Running / in-progress session in History

- A running timer has a `timer_state` row but no `entries` row until stop
  (`createEntry` fires on stop). So History shows only committed sessions.
- Open question: should a running session appear at the top of History as
  read-only "in progress"? Currently it's only visible via the compact timer.
  Probably defer — the compact timer already covers cross-tab awareness.

### 3. Entry delete/undo from History — remainder

- Entry deletion lives on the unified entry form (bottom destructive Delete → durable undo buffer → DEFAULT system Undo confirmation, shake → prompt → confirm); there is no UndoToast.
- Still deferred: History-row swipe-to-delete (History rows stay swipe/long-press-free) and the remaining undo work — supersession UX polish + the bulk-delete cap (`local-first-sync-architecture` tasks 3.3–3.6).

## Sequencing lean (to revisit)

1. History filtering.
2. Running-session visibility in History (if it earns its place).
3. History-row swipe-to-delete + undo polish/cap.

Each step is its own OpenSpec change; do not bundle.
