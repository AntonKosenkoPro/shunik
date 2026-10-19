## 1. Spec artifacts

- [x] 1.1 Proposal, delta spec, design written and validated (`openspec validate --change fix-live-activity-category-icon`)

## 2. Core implementation

- [x] 2.1 Add `ContentState.liveIconSymbol` helper in `LifioLiveActivityCore` (first chip or `"timer"` fallback)
- [x] 2.2 Point banner, compact leading, and minimal faces at the live icon (expanded chips row untouched)
- [x] 2.3 Add regression tests: reorder changes icon, removal falls back to `timer`, chips preserved, stopped face unaffected

## 3. Verification

- [x] 3.1 `swiftlint lint --strict` clean (ios/TimeOfLife)
- [x] 3.2 `openspec validate --all` green
- [x] 3.3 Current-tree repro on the fixed tree verified by parent: xcodebuild TEST SUCCEEDED, 692 Swift-Testing passes / 0 failures on iPhone16Pro sim F132A44E (log `/private/var/folders/8c/pwh55jk140g1shxfnwm7zxf80000gn/T/opencode/verify-icon.log`)
- [x] 3.4 Fixed UI verified by parent: user acceptance of all four fixes on physical iPhone from combined Release build
- [x] 3.5 `xcodebuild` build + full test suite green per parent evidence above (single-writer resource — run by parent verifier, not this worker)

## 4. Backend verification (no backend files in scope)

- [x] 4.1 Backend verifier PASS on base `f5aa180` (backend tree `cda3b835947ae847a6282e56f120f7a96aee588d`): `gofmt`/`go vet`/`golangci-lint`/`go test -cover`/build green — log: `/private/var/folders/8c/pwh55jk140g1shxfnwm7zxf80000gn/T/opencode/backend-verify-fix-live-activity-category-icon.log`. This change touches iOS + specs-docs only; no `backend/` files modified.
