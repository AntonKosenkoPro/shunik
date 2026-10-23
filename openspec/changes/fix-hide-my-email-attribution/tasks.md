## 1. Repro and research (joint gate — implementation starts only after both)

- [x] 1.1 Record the repro on the current tree: internal TestFlight build, physical device with iCloud+, Continue-with-Email → email field → Hide My Email sheet. Capture: the "for XXXX" number, `p (int)getpid()` match from an attached Xcode run, PID change across one cold relaunch, SpringBoard label, iOS version. Keep captures out of git (no binaries in git — `/tmp` or attached only).
- [x] 1.2 Complete the ctx7 research bundle (max 5, cites in proposal.md): topic (Hide My Email third-party attribution) + Apple API (Associated Domains `webcredentials` entitlement, AASA contract) + best practice (AASA serving: exact path, JSON content type, no redirects); HIG waived with reason (no app-owned UI — sheet is system-rendered). Re-confirm bundle freshness at apply time; on quota error run `npx ctx7@latest login`, never silently fall back.
- [x] 1.3 Confirm apex serving capability: `curl -svo https://antonkosenko.pro/.well-known/apple-app-site-association` path is servable as static extensionless JSON on the apex host (placeholder 404 acceptable pre-change — this task only proves the path is controllable).

## 2. Association wiring (in-repo)

- [x] 2.1 Add `webcredentials:antonkosenko.pro` to `TimeOfLife/Configuration/TimeOfLife.entitlements` + `SystemCapabilities` wiring in `ios/TimeOfLife/project.yml` (single writer; never hand-edit `.pbxproj`); run `xcodegen generate` and confirm the post-generation normalization keeps the capability.
- [ ] 2.2 Enable Associated Domains on the `com.antonkosenko.timeoflifeapp` App ID in the portal (automatic signing provisions it); confirm no Debug/Release signing drift (team `7923U48U87` on Release, Debug stays unsigned).
- [x] 2.3 Publish the AASA file on the apex host with body `{"webcredentials":{"apps":["7923U48U87.com.antonkosenko.timeoflifeapp"]}}`; verify `200` + `application/json` + body via `curl` and record the transcript (not committed).
- [x] 2.4 Run iOS verify: `swiftlint lint --strict`, warning-as-error `xcodebuild` build, `xcodebuild test` per `docs/ios-test-loop.md` (one `xcodebuild` at a time, booted-sim-by-ID). Backend verify N/A with reason: zero `backend/` changes, no OpenAPI touch.

## 3. Device verification and verdict (manual, physical device + iCloud+)

- [ ] 3.1 Confirm `swcd` marks `webcredentials:antonkosenko.pro` verified after install (device Console `swcd` logs); reinstall fresh if the association predates verification.
- [ ] 3.2 Re-run the identical 1.1 repro on the internal TestFlight build carrying the entitlement: PASS = sheet and saved-alias label show Lifio/domain; FAIL = PID persists.
- [ ] 3.3 On PASS: confirm no side effects — OTP request/verify flow unchanged, no Lifio credential offered in Safari, Live Activities + sync smoke green; re-check `Requirements/FURPS/Sign-up_and_Sign-in.md` rows.
- [ ] 3.4 On FAIL: stop implementation, file Apple Feedback with the 1.1 evidence + per-app scoping + iOS version, revert the entitlement/AASA (fully additive — removal is complete rollback), and abandon the change without archiving deltas.

## 4. Close-out (PASS branch only)

- [ ] 4.1 Update `docs/project-context.md` (Associated Domains now declared; Sign in with Apple section cross-ref) and `README.md` manual smoke checklist if the sheet check belongs there permanently.
- [ ] 4.2 Run `openspec validate --all --strict`, rebase twice on `origin/main` with affected linters/tests re-run after each rebase, open PR (`push --force-with-lease`, never merge main).
