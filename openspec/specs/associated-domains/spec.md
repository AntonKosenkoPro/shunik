# associated-domains Specification

## Purpose

Binds the Lifio iOS app to its apex domain for system credential and relay attribution, so Apple-rendered surfaces (Hide My Email, password AutoFill) resolve a stable service identity instead of a numeric process fallback.

## Requirements

### Requirement: App declares webcredentials association with antonkosenko.pro

The app SHALL declare an Associated Domains entitlement containing exactly `webcredentials:antonkosenko.pro` (apex domain, no `?mode=developer` qualifier on production builds), and the apex host SHALL serve a valid `apple-app-site-association` file binding the domain to the app.

#### Scenario: Entitlement present on device builds

- **WHEN** the built app's code signature is inspected (Release / TestFlight)
- **THEN** its entitlements include `com.apple.developer.associated-domains` with the single entry `webcredentials:antonkosenko.pro`

#### Scenario: Association file served correctly

- **WHEN** any client requests `https://antonkosenko.pro/.well-known/apple-app-site-association`
- **THEN** the server responds `200` with `Content-Type: application/json`, no redirects, and a body of `{"webcredentials":{"apps":["7923U48U87.com.antonkosenko.timeoflifeapp"]}}`

#### Scenario: Association verifies on device

- **WHEN** the app is installed on a device with network access (fresh install or update)
- **THEN** the system Shared Web Credentials daemon (`swcd`) marks the `webcredentials:antonkosenko.pro` association as verified (observable in device Console `swcd` logs)

### Requirement: Association is attribution-only

The `webcredentials` association SHALL NOT enable website-login credential sharing: no website SHALL offer Lifio app credentials, and no app SHALL consume website passwords. Its sole purpose is giving system attribution surfaces a stable service identity.

#### Scenario: No password sharing side effects

- **WHEN** a user with saved Lifio credentials opens any website in Safari
- **THEN** no Lifio credential is offered, and Safari behavior is unchanged
