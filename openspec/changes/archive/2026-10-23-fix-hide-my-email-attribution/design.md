## Context

See `proposal.md` (Why) for motivation. Current state constraining the approach:

- Entitlements today: `com.apple.developer.applesignin` + App Group only; no `com.apple.developer.associated-domains` anywhere (verified by repo grep).
- `CFBundleDisplayName` is `Lifio` in both Release and Debug plists and SpringBoard renders it correctly — the bundle record is healthy; only the out-of-process daemon attribution degrades to PID (proven by `getpid()` match, stable-per-run / fresh-per-launch).
- XcodeGen-managed project: capabilities must be declared in `project.yml` (`SystemCapabilities`, normalized by `scripts/normalize-system-capabilities.py`); never hand-edit `.pbxproj`. The `.entitlements` file itself is source-controlled and authoritative for entitlement keys.
- Signing split Debug (unsigned) / Release (team `7923U48U87`); verification happens on internal TestFlight, so no `?mode=developer` qualifier.
- Apex `antonkosenko.pro` is user-controlled infra outside this repo; our nginx fronts only `timeoflife-api.antonkosenko.pro`.
- Preserved invariants (`docs/project-context.md`): LocalStore chokepoint (untouched), OpenAPI contract (untouched — no backend change), no on-disk format changes, R1 (no secrets; AASA contains only Team ID + Bundle ID, both public).

## Goals / Non-Goals

**Goals:**
- Give the system attribution path a stable, verifiable service identity for the app via the cheapest supported mechanism (`webcredentials`).
- Keep the experiment falsifiable: one TestFlight build answers PID-vs-name, with a pre-committed stop condition (Apple Feedback, no further app change).

**Non-Goals:**
- Website-login credential sharing, universal links (`applinks`), passkeys: no `apple-app-site-association` sections beyond `webcredentials`, no server-side credential endpoints.
- Any SwiftUI/auth-flow code change: `EmailEntryView` already uses the documented trigger (`.textContentType(.emailAddress)`); the sheet takes no app-supplied name.

## Decisions

### 1. Associate the apex domain, not the API subdomain

**Why:** `webcredentials` formally asserts "this app shares credentials with this website." There is no website login on `timeoflife-api.antonkosenko.pro`; the apex is the honest, user-controlled identity to bind. **Alternative considered:** API subdomain (we serve it from repo-managed nginx, so iteration is faster) — rejected on semantics; the apex owner confirmed full control, removing the operational advantage.

### 2. `webcredentials` only; no `applinks`, no other services

**Why:** Each AASA service grants the OS a behavior (universal-link interception, handoff, credential sharing). We want exactly one: attribution identity. Minimal entitlement surface = minimal review and side-effect risk. **Alternative considered:** adding `applinks` for future `lifio://` deep-link parity — rejected; out of scope, and `CFBundleURLTypes` already covers the custom scheme.

### 3. Wire the capability through `project.yml`, keys in the source-controlled `.entitlements` file

**Why:** Repo rule — Xcode writes capabilities into gitignored `.pbxproj` `SystemCapabilities`, so UI-added capabilities are wiped by the next `xcodegen generate` (this previously broke Sign in with Apple). Follow the App Group / SIWA pattern: `SystemCapabilities` entry + `CODE_SIGN_ENTITLEMENTS` file regeneration. **Alternative considered:** hand-editing Xcode capabilities — rejected by precedent.

### 4. Serve AASA from apex infra, verified by contract not by repo code

**Why:** The file lives outside this repo; the contract (exact path, JSON content type, no redirects, `7923U48U87.com.antonkosenko.timeoflifeapp`) is specified in `specs/associated-domains/spec.md` and checked with `curl` in tasks. No backend code serves it. **Alternative considered:** serving from the API host via repo nginx — rejected per Decision 1.

### 5. Verification-gated change: TestFlight verdict decides ship vs abandon

**Why:** The mechanism is inferred (no Apple doc states the PID fallback); shipping blind would be superstition. If the sheet still shows PID, the correct outcome is an Apple Feedback filing with the recorded evidence (PID match, per-app scoping, TF-signed repro, iOS 27.2) — not more config guessing. The change is archived with deltas only on a positive verdict.

## Risks / Trade-offs

- [Risk] AASA mis-served (redirect, wrong content type, CDN caching) → association stays unverified, experiment inconclusive → Mitigation: `curl -svo` checks for status/headers/body in tasks before uploading any build.
- [Risk] Portal App ID missing Associated Domains → provisioning/signature error at archive time → Mitigation: confirm capability on the App ID record + inspect archive build log; automatic signing surfaces this early.
- [Risk] Experiment fails (still PID) → small sunk cost (one entitlement + one static file) → Mitigation: pre-committed stop condition; file removal reverts fully (entitlement additive, no migrations, no on-disk state).
- [Risk] `webcredentials` causes unexpected password-offer surfacing → Mitigation: attribution-only requirement in specs; there are no shared web credentials server-side, so there is nothing to offer — verified by the no-side-effects scenario.
- [Trade-off] Apex file lives outside repo review (portal + DNS/hosting changes are invisible to CI) → Mitigation: contract + curl transcript recorded in the change; `openspec.yml` still gates the in-repo half.

## ctx7 constraints applied

- `/websites/developer_apple_de` — "UITextContentType emailAddress autofill suggestions": system-owned suggestions, no app name parameter (justifies Non-Goal on SwiftUI changes).
- `/websites/developer_apple_de` — "supporting associated domains webcredentials autofill app attribution": `com.apple.developer.associated-domains` + `webcredentials` service shape (justifies Decisions 1–2).
- HIG waived: no app-owned UI changes (sheet is system-rendered; corroborated by Firefox iOS engineers' public statement that no API influences it).
- AASA serving contract per web best-practice sources (exact path, JSON, no redirects, `<TEAM_ID>.<BUNDLE_ID>`); `?mode=developer` inapplicable (verifying on TestFlight, not dev builds).
- Pin: iOS 18 SDK via Xcode 16+.
