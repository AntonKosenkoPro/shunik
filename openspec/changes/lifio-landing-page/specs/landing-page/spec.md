## Purpose

Defines the public web presence for the Lifio personal time-tracking iOS app: a minimal static landing site that gives Apple reviewers and external testers reachable support and privacy-policy URLs and presents consistent Lifio branding.

## ADDED Requirements

### Requirement: Landing page served at the canonical domain
The system SHALL serve a static landing page at `https://lifio.antonkosenko.pro/` (root path, HTTP 200, valid TLS). The page SHALL identify the product as "Lifio" (brand name invariant, matching the `app-identity` contract) and SHALL state in one line what the product does (personal time-tracking) and its local-first nature.

#### Scenario: Root serves the landing
- **WHEN** a visitor opens `https://lifio.antonkosenko.pro/`
- **THEN** the server responds 200 with the Lifio landing page over valid TLS

#### Scenario: Brand consistency
- **WHEN** a visitor reads any page of the site
- **THEN** the product name reads "Lifio" (never "Time of Life")

### Requirement: Support contact reachable from the site
The landing page SHALL present a support contact (email) that a reviewer or tester can use to reach the developer. The contact address SHALL be a working mailbox under the developer's control.

#### Scenario: Reviewer finds support
- **WHEN** a reviewer looks for a way to contact the developer from the landing page
- **THEN** a support email address is visible without login or interaction beyond scrolling

### Requirement: Full privacy policy at a stable URL
The system SHALL serve a full privacy policy at `https://lifio.antonkosenko.pro/privacy` (HTTP 200). The policy SHALL truthfully describe data handling that the shipped app plus its relay implement: the login email as account identifier, per-account entries synced to the EU-hosted relay, local-first storage on device, and in-app account deletion. The policy SHALL name a contact for privacy questions.

#### Scenario: Policy reachable
- **WHEN** a reviewer opens `https://lifio.antonkosenko.pro/privacy`
- **THEN** the server responds with the privacy policy text (HTTP 200 directly or via the host's canonical trailing-slash redirect to `/privacy/`)

#### Scenario: Policy claims match the product
- **WHEN** a reader compares the policy against the app's Auth/Profile behavior
- **THEN** every data claim in the policy (what is collected, where it lives, how to delete it) holds true for the shipped build

### Requirement: TestFlight slot labeled honestly
Until a public TestFlight link exists, the landing page SHALL present the TestFlight entry point as explicitly forthcoming ("coming soon" or equivalent) and SHALL NOT link a dead or placeholder URL as if it were a join link. Once the public link exists, the same slot SHALL link it directly.

#### Scenario: Pre-public TestFlight slot
- **WHEN** a visitor views the landing page before the public TestFlight link exists
- **THEN** the TestFlight slot states availability is forthcoming and no link pretends to join

#### Scenario: Post-public TestFlight slot
- **WHEN** a visitor views the landing page after the public TestFlight link exists
- **THEN** the TestFlight slot links the live public URL

### Requirement: English-only v1 scope is explicit
The v1 site SHALL be English-only. Russian localization is an explicit fast-follow and SHALL NOT be implied as present (no language switcher pointing nowhere, no mixed-locale chrome).

#### Scenario: Single language presented
- **WHEN** a visitor views any page of the v1 site
- **THEN** all content reads English with no control suggesting another locale exists
