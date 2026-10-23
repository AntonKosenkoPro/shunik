## Why

On the Continue-with-Email screen, the system Hide My Email sheet attributes the generated relay address to a random 4-digit number ("Create a unique address for 7800") instead of the product name. The number was proven to be the app process PID (`p (int)getpid()` match; stable per run, new on every cold launch), it reproduces on production-signed TestFlight builds, and every other app on the same device (iOS 27.2, iCloud+) attributes correctly — so the failure is specific to our app's configuration and it erodes trust on the mandatory sign-in gate. The leading hypothesis, reached by eliminating every build-time constant and every code path (the sheet is fully system-owned; our field passes only `.emailAddress`), is that iOS cannot derive a stable service identity for the app because we declare no Associated Domains (`webcredentials`) at all.

## What Changes

- Declare `webcredentials:antonkosenko.pro` in the app entitlement (via `project.yml`, XcodeGen-managed) and enable Associated Domains on the App ID.
- Publish `/.well-known/apple-app-site-association` on the apex domain (`antonkosenko.pro`, user-controlled infra outside this repo) listing `7923U48U87.com.antonkosenko.timeoflifeapp` under `webcredentials`.
- Verify on an internal TestFlight build on a physical device with iCloud+: the sheet attributes to Lifio (or the domain) instead of the PID.
- If verification still shows the PID, stop: file Apple Feedback with the recorded evidence and make no further app change (the fallback is then a system bug, not a configuration gap).

## Capabilities

### New Capabilities

- `associated-domains`: the app declares a `webcredentials` association with `antonkosenko.pro` (entitlement + portal App ID + apex AASA file contract) so system credential/relay attribution resolves to a stable service identity.

### Modified Capabilities

- `app-identity`: extend "presents itself as Lifio in every user-visible surface" to cover system autofill/relay attribution surfaces — the Hide My Email sheet SHALL attribute generated addresses to Lifio (or the associated domain), never to a numeric process fallback.

## Impact

- iOS: `ios/TimeOfLife/project.yml` (capability wiring), `TimeOfLife/Configuration/TimeOfLife.entitlements` (associated-domains array), regen via `xcodegen generate`; Release re-sign unaffected (same team `7923U48U87`).
- Apex web host (outside this repo): one static extensionless JSON file at the exact `.well-known` path, `Content-Type: application/json`, no redirects; no backend (`backend/`) or OpenAPI changes.
- Apple Developer portal: Associated Domains on the `com.antonkosenko.timeoflifeapp` App ID (automatic signing handles provisioning).
- Verification is manual on-device (internal TestFlight + iCloud+); no new automated tests can cover a system sheet.

## Non-goals

- No website login or shared-web-credential password flows: `applinks`/universal links are out of scope; the association exists solely for relay/credential attribution.
- No changes to the email-OTP flow, `EmailEntryView`, or any SwiftUI: the sheet is Apple's UI and takes no app-supplied name.
- No backend, OpenAPI, Design-system, or localization changes (no new user-facing strings; HIG waived — evidence: sheet is system-owned, Firefox iOS engineers confirm no public API influences it).
- No fallback work beyond the Apple Feedback filing if the experiment fails.

## Research bundle (ctx7, iOS 18 SDK via Xcode 16+)

- Library: `npx ctx7@latest library "Apple Developer" "Hide My Email autofill email text content type"` → `/websites/developer_apple_de` (53.4 benchmark, High reputation).
- Docs `/websites/developer_apple_de` — "Hide My Email app name UITextContentType emailAddress" + "Associated Domains webcredentials Hide My Email label" + "UITextContentType emailAddress autofill suggestions" + "supporting associated domains webcredentials autofill app attribution": `.textContentType(.emailAddress)` exists so the system offers suggestions (no name parameter); `com.apple.developer.associated-domains` `webcredentials` = shared web credentials binding.
- HIG (`/websites/developer_apple_design_human-interface-guidelines`): waived — no app-owned UI changes; the sheet is system-rendered.
- Best practice (web sources, no ctx7 bundle entry): AASA must live at exact `/.well-known/apple-app-site-association`, JSON content type, no redirects, `{"webcredentials":{"apps":["<TEAM_ID>.<BUNDLE_ID>"]}}` (LoginID / PasskeyMe / Purse Identity docs); dev builds may need `?mode=developer` (not applicable — verifying on TestFlight).
