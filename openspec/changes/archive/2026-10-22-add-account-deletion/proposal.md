## Why

Lifio currently offers local erasure and sign-out, but cannot delete an account and its relay data in-app. Issue [#186](https://github.com/AntonKosenkoPro/timeOfLife/issues/186) needs a complete deletion lifecycle before external TestFlight submission, with explicit distinctions between deleting an account, deleting only local data, and disconnecting Sign in with Apple.

## What Changes

- Add Profile → Account as a normal pushed page. Show the active account's read-only email (including an Apple relay address when applicable); move Sign out and the renamed **Delete local data** action there. Keep sync status/Sync now, Categories, and version on Profile.
- Separate permanent deletion visually from session and device-only actions. The row, confirmation-alert title, and destructive confirmation button explicitly say **Delete account and local data**; use one confirmation alert, not two. Supply English and Russian copy.
- Add authenticated account deletion that purges the user and all associated operational relay records, including OTPs, all-device sessions, refresh-recovery receipts, entries, joins, categories, and tombstones. Stop old credentials authorizing protected requests or recreating deleted content.
- Automatically revoke Apple's authorization for explicitly deleted Apple-created accounts. Extend Apple authorization-code/token handling and secure server configuration; existing Apple users without stored revocable credentials can authorize the same Apple identity during the deletion flow.
- Treat externally initiated Apple consent revocation as **sign-out only**, preserving the Lifio identity, server data, and local files. Reauthorizing the same Apple identity returns to the existing account. This is an explicit product choice, not account deletion.
- After confirmed account deletion, remove this account's local data/session artifacts and return to the auth gate. Other devices remove the deleted account's local copy only after trustworthy deletion confirmation; generic authentication rejection still locks without erasure. Offline devices cannot be wiped immediately.
- Preserve retryable state for response loss and partial cleanup; never announce success on an ambiguous outcome. Permit fresh signup after explicit deletion, with a new account ID and no restoration of deleted content.
- Update the shipped privacy page at `web/privacy/index.html` when this feature ships, including local-copy timing, encrypted Apple-token handling, and actual backup retention rather than promising immediate erasure of offline devices or backups.

## Capabilities

### New Capabilities

- `account-deletion`: Explicit deletion, complete operational server purge, reliable completion/proof, account-scoped local cleanup, failure recovery, and fresh signup.

### Modified Capabilities

- `app-shell`: Profile → Account hierarchy, account email, relocated actions, and one explicit destructive alert.
- `apple-signin`: Authorization-code exchange and secure revocable credentials; automatic revocation on deletion versus preservation on external consent revocation.
- `device-sessions`: Immediate enforcement of account/session state, all-device revocation, and the narrow confirmed-account-deletion exception to lock-not-wipe.
- `account-bound-store`: Cleanup of the specifically deleted account's local file, without touching unrelated accounts or treating sign-out as erase.
- `local-first-store`: Move and rename local-only deletion to Account; preserve its existing server-untouched semantics.
- `sync-client`: Fence account deletion against sync and prevent stale work or resurrection after deletion.

## Impact

- Backend auth, Apple client, stores (Postgres and SQLite), additive migrations, protected-request middleware, session recovery, configuration/deployment, and contract/integration tests. Account-deletion/status and Apple-notification APIs must be defined in `backend/api/openapi.yaml` together with both implementations; OpenAPI remains authoritative.
- iOS AppShell/Account UI, auth repository/service, durable credential/session lifecycle, account-local storage, sync coordination, and Live Activity cleanup. Existing stable device identity survives account cleanup; no raw local database writes outside LocalStore.
- Documentation at implementation: `Design/SCREENS/AppShell.md`, new `Design/SCREENS/Account.md`, `Design/INTERACTIONS.md`, relevant FURPS rows, `README.md`, `docs/project-context.md`, OpenSpec routing guidance, and the privacy page. Reuse existing list-row components; update `Design/COMPONENTS.md` only if a genuinely new shared component is introduced.
- Coordinate privacy wording with the active `lifio-landing-page` change; do not edit that change's artifacts or promise deletion before the matching app/backend are deployed.
- No new external runtime library is assumed. Apple private keys and recoverable Apple tokens must never be plaintext in database/logs or shipped in the app.

### Research and constraints

- Apple account-deletion policy: [5.1.1(v)](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion/); token handling and fallback: [TN3194](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple); notification semantics: [Processing changes](https://developer.apple.com/documentation/signinwithapple/processing-changes-for-sign-in-with-apple-accounts); user-facing reconnect behaviour: [Manage your apps](https://support.apple.com/en-us/102571). Reviewed 2026-10-21, native integration pinned to iOS 18 SDK via Xcode 16+.
- Context7 `/timothylock/go-signin-with-apple`: queries on Apple token revocation and on `consent-revoked` versus account deletion were fetched during exploration. This is supporting documentation, not a decision to add that library; official Apple documentation takes precedence for event names and payload validation.
- HIG research and full implementation-time SDK reconfirmation are recorded in `design.md` and the first tasks. There is no claim that external revocation retaining data guarantees App Review acceptance: Apple's user-facing reconnection documentation and TN3194 cleanup guidance are not fully aligned.

### Explicit non-goals

- Email/support-requested deletion (scenario 4), identity merging, email editing, device management/quota, a new primary tab, a general privacy-settings page, undo/restore of a deleted account, or changes to record-level deletion/undo.
- Automatically deleting a Lifio account because Apple consent was revoked, a refresh expired, a request failed, or a `401` arrived.
- A manual Apple-revocation-only implementation, immediate remote wipe of offline phones, or new handling of permanently deleting the user's entire Apple Account (a distinct Apple event, outside scenarios 1–3).
