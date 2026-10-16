# Entry Text & Categories — Use cases

Narrative flows for **entry-owned text and category tags**. Each flow maps to rows in [`FURPS/Activity_Catalog_and_Categories.md`](../FURPS/Activity_Catalog_and_Categories.md). There is no activity entity: every entry owns its trimmed text, its ordered categories, and its notes at write time; history never mutates retroactively. Sign-in (email-OTP or Sign in with Apple) is the mandatory launch gate — there is no signed-out use.

## 1. First run — seeded defaults

1. The user signs in and lands on the Track screen for the first time.
2. The app seeds a localized (EN or RU per device language) starter set of 7 categories into the account file: Work, Hobby, Sport, Education, Relax, Sleep, Entertainment. No starter entries are seeded.
3. The seeded categories are ordinary records; the user can rename, change their icons, or delete any of them later.
4. With no committed entries, the Track screen shows the idle timer and the Recents empty hint; typing any name and starting always works — no catalog lookup is ever required.

## 2. Start a timer from a Recents chip

1. On the Track screen, the user sees up to 12 most-recently-used exact entry texts as tappable chips, ranked on-device from committed entries (newest `started_at` wins per exact text) — no server round-trip, works offline. Chips show the exact text plus the first-position category icon only; category names never appear on capture.
2. The user taps a chip; the text field fills with that exact text and inherits the entry's full ordered category set (ready state). No timer starts and no entry is created.
3. The user taps **Start**; the timer runs with the name locked and the tag selector live.

## 3. Start a timer with a brand-new text

1. The user types a name into the Track plain-text field that matches no recent entry (comparison is byte-exact trimmed text, case-sensitive: `Gym` ≠ `GYM`).
2. The draft starts categoryless (unless an exact recent match inherits its ordered set); no record is created and no catalog is consulted.
3. The user taps **Start**; stopping is the only commit boundary and creates exactly one entry plus one outbox row.
4. The new text appears in Recents on future sessions.

## 4. Manage categories and undo

1. The signed-in user opens Profile and selects Categories (offline-safe: the list renders from the local store).
2. Manage Categories lists local categories alphabetically. Add opens a shared Category Editor with an empty name and the `tag` icon; selecting a row opens the same editor with current values.
3. Save trims and validates the name, enforces the 60-character limit and case-insensitive uniqueness, and persists the category plus outbox operation atomically.
4. Confirmed deletion removes only the category tag from all entries (join cascade) — entries themselves, their texts, notes, and timings stay intact. The deletion enters the durable undo buffer; no toast is shown.
5. Shaking the device surfaces the system Undo confirmation; confirming restores the newest eligible category deletion with its entry assignments. The deletion stays restorable until the app restarts; a cold launch commits it locally and enqueues the relay DELETE.

## 5. Delete an entry from its entry form

1. From a History row, the user opens the unified entry form (EDIT for `manual` entries, LOCKED read-only with delete-only for imported entries).
2. The user taps the bottom destructive Delete; the app shows a single destructive confirm naming the entry text. There is no cascade and no scope choice — one entry, one delete.
3. On confirm, the entry disappears from all lists immediately and enters the durable undo buffer (no outbox row, no toast); the form dismisses.
4. Shaking the device surfaces the system Undo confirmation; confirming restores exactly the most recent buffered deletion. If the app restarts first, the deletion commits and syncs as a hard delete with no restore path.

## 6. Work offline

1. With no connectivity, the signed-in user creates, edits, and deletes entries/categories and starts timers.
2. All changes are applied locally and queued in the transactional outbox (deletions sit in the undo buffer until restart commits them).
3. When connectivity returns, the queue syncs via the `SyncController` drain + `?modified_since=` delta pulls; conflicts resolve by last-write-wins on `updated_at`.
