## Context

See proposal.md (Why) and the delta specs (`specs/manual-entry/spec.md`, `specs/entry-editor/spec.md`) for motivation and behavior. Current implementation state shaping the approach:

- `LogTimeViewModel` holds `startsAt`/`endsAt` plus `lastValidDuration`; `setStartsAt` shifts End only on collision (`endsAt <= newStart`), `setEndsAt` never moves Start. Gate and save use `endsAt > startsAt`.
- `LogTimeView` binds all four pickers (start/end × date/time, single-open) straight to the VM dates with no `in:` ranges; date and time pickers each carry a full `Date` (system preserves the unedited components).
- Invariants to preserve (`docs/project-context.md`): `LocalStore` stays the single mutation chokepoint (this change adds no store writes); `Theme` semantic colors only; user strings in EN + RU via `L10n`; no backward-compat burden for on-disk formats (no stored shape changes here at all).

## Goals / Non-Goals

**Goals:**
- Make sub-minute and end-before-start choices unpickable while keeping every previously savable stored value savable untouched.
- Keep the four-picker binding model (one open at a time) — no custom picker UI.

**Non-Goals:**
- No store, sync, outbox, or OpenAPI change (`duration_seconds` stays derived end-minus-start; S10 untouched).
- No minute-interval granularity change (wheels stay 1-minute steps); no auto-migration of stored sub-minute entries.

## Decisions

- **Always-preserve as delta-shift in `setStartsAt`.** `end = end + (newStart − oldStart)` for every Start write, date or time sourced. Rationale: one rule covers both directions and both picker kinds; collisions via Start become impossible, so Start pickers need no upper bound. Alternative considered (keep collision-only + clamp End to `start+60s` on violation): rejected — it reintroduces a second rule and contradicts the agreed always-preserve semantics. `lastValidDuration` loses its role and goes away (or stays only as the CREATE default source alongside `defaultDuration`).
- **End ranges via `DatePicker(_:selection:in:displayedComponents:)`, computed as pure view-model helpers (`endDateRange`/`endTimeRange`) so selection-vs-range consistency is unit-testable.** End date picker `in:` lower-bounded at the Start day (nil when a corrupt end-before-start selection would fall below it — unbounded picker plus disabled gate beats a clamped selection); End time picker `in:` lower-bounded at `ceil(displayStart+60s)` — minute-exact display Start makes the ceil an identity and keeps the selection inside by construction — only when the End day equals the Start day, the whole End day otherwise. Rationale: ctx7 Apple API (`/websites/developer_apple_swiftui`, "DatePicker selection in range bounds minimum maximum date") confirms the range is a closed range over full `Date` timestamps — a static full-timestamp bound would wrongly forbid e.g. 9:00 AM on a later End day, hence the conditional bound, recomputed live from the draft. A review round proved the backing-derived bound wrong (grandfathered 2:35:20–2:35:53 selected 2:36 against a 2:37 bound) — display-derived bounds closed it, with regression tests for seconds prefills, cross-day moves, and corrupt prefills. HIG (`/websites/developer_apple_design_human-interface-guidelines`, "date pickers best practices selecting date time iOS") keeps the inline/wheels presentation as-is, in context near the edited field. ActivityKit waived (no lock-screen surface involved).
- **Display mapping lives in the view bindings, not the VM dates.** The VM keeps backing `startsAt`/`endsAt` (truth) plus a `timesTouched` flag; the view's pill text and picker `selection` getters return the mapped pair (minute floor of Start; minute floor of End — except untouched sub-minute prefills, where End shows floored Start + 60s so the pair stays valid). The pill time formatter truncates seconds (verified: 23:59:34 renders 11:59 PM), so pills always agree with the mapping. The first write through any picker minute-normalizes both ends (floor both — the wheels cannot display seconds), then the gesture applies; incoming values are minute-floored as well (date pickers preserve seconds), so a touched draft is minute-exact by construction and `timesTouched` flips and the floor gate takes over. Rationale: pickers never hold a value they cannot display or that violates the range (no undefined framework behavior), the VM stays the single source of truth, and save can branch (untouched → originals by construction; touched → draft). Normalization of a ≥60s draft provably keeps ≥60s (duration ≡ endSecs−startSecs mod 60 ⇒ flooring lands on a minute multiple ≥ 60s), so it never disables the confirm action by itself. Alternative considered (normalize VM dates on open + remember originals): equivalent, but splits truth across two date pairs instead of one flag.
- **Flooring, not rounding, for the mapped Start.** `floor` to the minute; End display = floored Start + 60s. Rationale: rounding both ends of 0:00:15–0:00:25 yields the invalid 0:00–0:00 pair; flooring Start and pinning End at +60s is valid by construction. Displayed values are minute-quantized anyway (wheel granularity), so adopting them zeroes seconds — accepted and specced implicitly (mapped pair is minute-exact).
- **Subtitle reads backing truth; pills read the mapping.** Deliberate split per agreement: users see what is stored (`33s`) alongside what a touch would adopt (mapped pills). No extra copy needed — existing invalid-interval string covers the touched-below-floor safety-net path.
- **DST treatment: absolute-delta shift.** The delta is a `TimeInterval` added to End, so absolute duration is invariant; wall-clock display may shift across a DST transition. Accepted: entries are absolute intervals, and the transition case is a sub-minute-edge rarity on top of an hourly rarity.

## Risks / Trade-offs

- [Risk] `.wheel` + `in:` may snap back instead of greying out-of-range times → Mitigation: simulator spike is task 1; if wheels ignore ranges visually, the spec's "cannot be chosen" still holds only if selection is actually prevented — otherwise revisit the spec (VM clamp-back fallback) before implementing.
- [Risk] Touch-to-adopt plus delta-shift double-transform on the first Start touch (adopt mapped pair, then apply the tick) → Mitigation: define setter order (adopt snapshot first, then apply the user's value as the new Start with delta computed against the adopted Start); unit-test the 2:35:00–2:35:33 first-touch case.
- [Risk] Pills/subtitle split (mapped pills vs true `33s`) confuses → Mitigation: accepted explicitly in exploration; no new explanatory copy (keeps U4 string churn at zero unless review asks).
- [Risk] Gate now depends on `timesTouched`, not just timestamps → Mitigation: flag flips only in the time-picker setters; name/category/notes paths cannot affect it; cover with VM unit tests (untouched-save-originals, touched-requires-floor).

## Migration Plan

None. No stored shape changes, no backfill, no API change. History rows keep rendering true durations. Rollback = revert the change; drafts are transient.

## Open Questions

- Spike: exact `.wheel` rendering of `in:` bounds and same-day-boundary behavior (e.g. Start 1:00:30 → bound 1:01:30 vs minute-quantized 1:01/1:02 — wheel steps are minutes, so the effective bound quantizes; confirm what the wheel shows). Answer affects only polish/task detail, not the spec rules.
