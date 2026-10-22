## ADDED Requirements

### Requirement: Account deletion fences sync and stale results
The system SHALL fence the target account's sync and local mutations while an explicit deletion outcome is unresolved and throughout confirmed cleanup. It SHALL settle or safely invalidate in-flight work before deleting that account's local storage. A timeout SHALL NOT authorize erasing storage under a live writer. Late responses SHALL be guarded by their original account and session generation and SHALL NOT merge data, revive sessions, trigger record-resurrection recovery for a deleted account, or modify another account. A cancelled or failed deletion that is confirmed to leave the account active SHALL restore normal sync availability without a second sync owner.

#### Scenario: Delete during outbox drain
- **WHEN** the user confirms deletion while the account's outbox drain is running
- **THEN** deletion and sync are coordinated so local storage is not removed under a live writer and stale work cannot restore the account after purge

#### Scenario: Late pull for deleted account
- **WHEN** a pull response arrives after its account was confirmed deleted or a different account became active
- **THEN** no returned records are merged and no other account's state is changed

#### Scenario: Active verdict after failed deletion
- **WHEN** a failed or cancelled deletion is reliably resolved as leaving the account active
- **THEN** the account can resume ordinary sync without losing its outbox or forking another cycle

### Requirement: Authentication rejection alone never drives account erasure
Sync SHALL stop normal work after conclusive session loss and delegate account-deletion resolution to the scoped lifecycle flow. Entry/category 404 resurrection and record tombstones SHALL NOT be used as account-deletion evidence or to re-create a deleted user. Offline, malformed, expired, or failed account-status checks SHALL preserve the existing lock-not-wipe behaviour and SHALL NOT be interpreted as an empty successful sync.

#### Scenario: Generic refresh rejection during sync
- **WHEN** sync cannot refresh an existing account and its deletion check returns active or is inconclusive
- **THEN** the app locks with that account's file and outbox intact instead of erasing them

#### Scenario: Deletion proven during sync recovery
- **WHEN** account-specific status proves the original account no longer exists
- **THEN** normal sync/resurrection stops and only that UUID's confirmed cleanup proceeds
