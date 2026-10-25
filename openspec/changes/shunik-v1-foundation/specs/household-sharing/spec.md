## Purpose

Two equal owners share one household's pets, events, and documents from their own logins, with attribution for who did what and lock-not-wipe revocation.

## ADDED Requirements

### Requirement: One household per user, all pets visible to both owners

The system SHALL scope every pet, event, course, intake, weight point, document, and document link to exactly one `household_id`. Every household member SHALL see every pet and every household-scoped record. A user SHALL belong to at most one household in v1.

#### Scenario: Second owner sees the same pets

- **WHEN** owner B accepts an invite into owner A's household and completes first sync
- **THEN** B's device shows the same pet list, events, and documents as A's device

#### Scenario: New pet is visible to both without extra sharing

- **WHEN** either owner creates a pet and the household syncs
- **THEN** the pet appears on both devices with no additional action

### Requirement: Invite by email, distinct identities

The system SHALL let an existing household member invite a second owner by email. The invitee SHALL authenticate through the standard passwordless flow (email-OTP; Sign in with Apple where the account supports it) and join the existing household on first accept — no separate credentials, no shared password.

#### Scenario: Invite and join

- **WHEN** A invites `b@example.com` and B signs in and accepts
- **THEN** B becomes an equal owner of A's household and B's device opens the household store after first pull

#### Scenario: Invite for an unknown address creates no oracle

- **WHEN** A invites an address with no account
- **THEN** the system accepts the invite request and the invite completes when that address next authenticates, revealing nothing about account existence beforehand

### Requirement: Attribution on every mutation

Every household-scoped row SHALL carry `updated_by` (actor of last write). Every intake status transition SHALL carry `marked_by`. List and timeline surfaces that show a taken/missed/skipped intake SHALL attribute it (e.g. "A gave it ✓").

#### Scenario: B sees who marked a dose

- **WHEN** A marks the 20:00 intake taken and the change syncs
- **THEN** B's device shows the intake as taken attributed to A and clears B's pending reminder for it

### Requirement: Revocation locks, never wipes

Removing a member SHALL lock that member's devices (auth gate, files intact — the Lifio lock-not-wipe rule) and SHALL NOT delete or alter household data for remaining members. Tombstones and history SHALL remain converged for the household.

#### Scenario: Member removed

- **WHEN** A removes B
- **THEN** B's devices return to the auth gate with local files intact, and A's data is unchanged

### Requirement: Both-phones-buzz default with per-device mute

Pending dues SHALL schedule local notifications on every member device that holds the household data. Each device SHALL offer a local-only mute toggle that never syncs.

#### Scenario: Either owner can cover a dose

- **WHEN** a dose becomes due with two member devices holding the data
- **THEN** both devices notify, and the first mark-taken syncs the clear to the other device
