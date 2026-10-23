## ADDED Requirements

### Requirement: System relay surfaces attribute to Lifio

The Hide My Email sheet and any other system-rendered credential/relay attribution surface SHALL identify the requesting service as "Lifio" (or the associated domain), and SHALL NEVER render a numeric process identifier (PID) as the service name.

#### Scenario: Hide My Email sheet on a signed build

- **WHEN** a signed-in-capable user focuses the email field on the Continue-with-Email screen and opens the system Hide My Email sheet (physical device, iCloud+ active)
- **THEN** the sheet's "Create a unique address for …" sentence and its default label name "Lifio" (or the associated domain) — not a 4-digit number

#### Scenario: Saved alias label

- **WHEN** the user completes Hide My Email creation from the app and later opens Settings → Apple Account → iCloud → Hide My Email
- **THEN** the saved alias carries the "Lifio" (or associated-domain) label, not a numeric label
