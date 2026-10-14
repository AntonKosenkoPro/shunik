## MODIFIED Requirements

### Requirement: Delta pull via modified_since
The sync client SHALL pull entries by following relay pagination to exhaustion: starting from `GET /entries` (with `?modified_since=<timestamp>` when a cursor exists, full pull when it does not), the client SHALL keep requesting subsequent pages with the relay's `cursor` parameter until the relay returns no `next_cursor`, and SHALL merge every page with the existing LWW rules. The client SHALL advance the entries sync cursor to the max `updated_at` over ALL pages received in the pull — never to the max of a partial page. A pull is complete only when the relay reports no further page; an empty pull (no records on any page) leaves the cursor unchanged. Cursors recorded before pagination-aware pulls existed are poisoned (a partial-page max that hides older rows from every future delta): the client SHALL discard the persisted `entry` cursor exactly once per account file — guarded by a persisted re-baseline flag — so the next cycle runs a full paged pull and re-converges the complete history through the idempotent LWW merge. `GET /categories` is full-pull by design (catalog small: seeded plus a handful of user rows, so a snapshot merge with newer-owns-the-name is cheap; entries are unbounded and need the cursor): the client SHALL fetch the full category list on every pull and SHALL NOT send a categories cursor.

#### Scenario: Incremental pull
- **WHEN** the sync client runs after a previous successful pull recorded a cursor at time T
- **THEN** it requests `GET /entries?modified_since=T` and follows `next_cursor` pages until exhausted, receiving only records with `updated_at > T` across all pages; it applies them locally with LWW merge and advances the cursor to the max `updated_at` over all pages

#### Scenario: Full-history convergence beyond one page
- **WHEN** the relay holds more entries than one page (e.g. 120 entries at the default page size) and the client runs a full pull with no cursor
- **THEN** every page is fetched and merged, the local database holds the complete set, and no record is skipped regardless of page boundaries

#### Scenario: Cursor advances over all pages
- **WHEN** a pull spans multiple pages whose per-page `updated_at` maxima differ
- **THEN** the recorded entries cursor equals the max `updated_at` across every received page, so a subsequent delta pull returns only records newer than the complete pull

#### Scenario: Delta after a complete paged pull is empty
- **WHEN** a full paged pull converged completely and no record changed since
- **THEN** the next delta pull returns no records, the cursor is unchanged, and no local updates are applied

#### Scenario: Upgrade with a poisoned cursor heals on the next cycle
- **WHEN** the account file holds an `entry` cursor recorded before pagination-aware pulls existed and the re-baseline flag is unset
- **THEN** the next cycle discards that cursor, runs a full paged pull, merges the complete history (LWW-idempotent — no duplicates, no outbox churn), advances the cursor to the global max, and sets the flag; the `deletions` cursor, categories, outbox, undo buffer, and timer state are untouched

#### Scenario: Re-baseline runs exactly once
- **WHEN** the re-baseline flag is already set (or the `entry` cursor is nil, as on fresh installs)
- **THEN** no cursor is discarded and pulls proceed as incremental or full by the normal cursor rules; a second upgrade never triggers another full re-pull

#### Scenario: Mid-pull account swap aborts before further merge
- **WHEN** the authenticated session's `userId` stops matching the cycle's bound account while pages remain unfetched
- **THEN** no further page is fetched or merged and the cycle aborts under the same-account guard, leaving already-merged pages intact and the cursor unadvanced for the incomplete pull

#### Scenario: No changes
- **WHEN** the delta pull returns no records
- **THEN** the cursor is unchanged and no local updates are applied

#### Scenario: Categories always full-pull
- **WHEN** the sync client runs a pull (first sync or delta cycle)
- **THEN** it fetches `GET /categories` with no `modified_since` parameter and merges the full snapshot (newer-owns-the-name), regardless of the entries cursor
