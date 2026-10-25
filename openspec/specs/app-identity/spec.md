# app-identity Specification

## Purpose

Defines the product identity contract for the Lifio personal time-tracking iOS app: the user-facing name is Lifio everywhere, while bundle, storage, and backend identifiers stay on their stable legacy values.

## Requirements

### Requirement: Product presents itself as Lifio
The system SHALL identify the product to the user as "Lifio" in every user-visible surface: the Home-screen display name (`CFBundleDisplayName`) SHALL be "Lifio", the Welcome-screen brand title (`L10n.appName` / `app.name`) SHALL render "Lifio", and the `app.name` localization value SHALL be "Lifio" in both English and Russian (brand name is invariant across locales).

#### Scenario: Home-screen name
- **WHEN** the user views the installed app on the Home screen or in system search
- **THEN** the system shows the name "Lifio" under the app icon

#### Scenario: Welcome brand title in English
- **WHEN** a signed-out user opens the Welcome screen with the device locale set to English
- **THEN** the brand title reads "Lifio"

#### Scenario: Welcome brand title in Russian
- **WHEN** a signed-out user opens the Welcome screen with the device locale set to Russian
- **THEN** the brand title still reads "Lifio" (not a translated product name)

### Requirement: Stable identifiers remain unchanged
The rename SHALL NOT change any machine identifier: the bundle identifier (`com.antonkosenko.timeoflifeapp`), the App Group (`group.com.antonkosenko.timeoflifeapp`), Keychain service and session keys (`com.timeoflife.*`), the GRDB file name (`timeoflife.sqlite`), Grand Central Dispatch queue/label strings, backend database and Docker/image names, the production API domain, or the Xcode scheme/target/module names (`TimeOfLife`). No data migration SHALL be required.

#### Scenario: Reinstall keeps working without migration
- **WHEN** a developer installs a Lifio-branded build over an existing pre-release install (or fresh)
- **THEN** the app reads the existing App Group container, Keychain items, and local database in place with no migration step

#### Scenario: Sync and backend addressing unchanged
- **WHEN** the renamed app syncs against the relay
- **THEN** it uses the same API base URLs, bundle-scoped auth audience values, and protocol as before the rename

### Requirement: Product references name Lifio
Product prose that names the app — spec purposes and scenarios, user-facing documentation, and in-code product comments — SHALL refer to "Lifio", never "Time of Life", except for historical archive records that describe the rename itself.

#### Scenario: Spec and doc consistency
- **WHEN** a maintainer reads the active specs or user-facing docs
- **THEN** every product-name reference says "Lifio"

### Requirement: Welcome screen shows the Lifio brand mark
The system SHALL render the Lifio product glyph (`^▬` brand mark, `BrandMark` asset) above the "Lifio" brand title on the Welcome screen, in place of the generic timer symbol. The mark SHALL be single-color in the accent voice, identical in shape and size to the restoring splash mark, and hidden from VoiceOver as decorative.

#### Scenario: Welcome brand mark in English
- **WHEN** a signed-out user opens the Welcome screen with the device locale set to English
- **THEN** the product glyph renders above the "Lifio" title in the accent color

#### Scenario: Welcome brand mark in Russian
- **WHEN** a signed-out user opens the Welcome screen with the device locale set to Russian
- **THEN** the product glyph renders above the "Lifio" title exactly as in English (mark is locale-invariant)

#### Scenario: Mark is decorative for assistive technology
- **WHEN** VoiceOver focuses the Welcome-screen brand region
- **THEN** the mark itself is skipped and the "Lifio" title remains announced

### Requirement: System relay surfaces attribute to Lifio

The Hide My Email sheet and any other system-rendered credential/relay attribution surface SHALL identify the requesting service as "Lifio" (or the associated domain), and SHALL NEVER render a numeric process identifier (PID) as the service name.

#### Scenario: Hide My Email sheet on a signed build
- **WHEN** a signed-in-capable user focuses the email field on the Continue-with-Email screen and opens the system Hide My Email sheet (physical device, iCloud+ active)
- **THEN** the sheet's "Create a unique address for …" sentence and its default label name "Lifio" (or the associated domain) — not a 4-digit number

#### Scenario: Saved alias label
- **WHEN** the user completes Hide My Email creation from the app and later opens Settings → Apple Account → iCloud → Hide My Email
- **THEN** the saved alias carries the "Lifio" (or associated-domain) label, not a numeric label
