# Account — identity, device data, and permanent deletion

Implements the `app-shell` (Account page) and `account-deletion` (initiation surface) delta specs of OpenSpec change `add-account-deletion`. Account is a signed-in-only pushed page, one normal push below Profile on the originating tab's own navigation path — the same nesting pattern Manage Categories already uses. Planned contract (matches the change deltas, not yet implemented — Profile still hosts Sign out and Erase local data directly until the UI worker lands this page).

## Hierarchy

```
Profile (pushed page, per-tab path, tab bar hidden)
  ├─ Account >            <-- NEW: pushed page, system Back, no Done/sheet
  ├─ Sync status / Sync now   (stays on Profile — convenient, no Account entry needed)
  ├─ Categories >             (stays on Profile)
  └─ Version                  (stays on Profile)
Account
  ├─ ACCOUNT
  │    ├─ Email (read-only, full wrapping)
  │    └─ Sign out (one confirmation; keeps ProfileSignOutButton id)
  ├─ THIS DEVICE
  │    └─ Delete local data (single confirmation; server-untouched)
  └─ PERMANENT DELETION
       └─ Delete account and local data (one explicit alert; irreversible)
```

- Account pushes from Profile on the same tab path (`Account >` row, `accessibilityIdentifier("ProfileAccountRow")`); Back returns to Profile without resetting the tab's root state. The tab bar stays hidden at every nested depth.
- Profile retains sync status/Sync now, Categories navigation, and version. Sign out, local-only erase, and permanent deletion live ONLY in Account — no duplicates on Profile, no integrations/export/appearance/privacy placeholder rows anywhere.
- The email is the server-stored account email from the cached session (`CachedSession.email`), available offline with no network request. Read-only: no editing, no inferred personal email — an Apple Hide My Email relay address displays as-is.

## Screen: AccountView

- **File**: `ios/TimeOfLife/TimeOfLife/Features/AppShell/Views/AccountView.swift`
- **Route**: pushed from `ProfileView` on the presenting tab's `NavigationStack` path
- **State**: `AccountViewModel` (email from session cache, deletion submission state, progress/error)

### Layout

1. `List` with native grouped sections, system Back, `.inline` title (`L10n.accountTitle`: EN "Account" / RU "Аккаунт").
2. **ACCOUNT** section (`L10n.accountIdentitySection`):
   - Email row: full stored address, read-only wrapping text, `.accessibilityIdentifier("AccountEmailValue")`. Static text, never a field.
   - Sign out row: existing `ListRow` geometry (leading icon `rectangle.portrait.and.arrow.right`, danger tint), keeps `ProfileSignOutButton` so existing tests keep passing. Tap opens one confirmation naming the sign-out; confirming signs out, account files are kept.
   - Footer helper (`L10n.accountIdentityFooter`): EN "Signing out keeps this device's data. Signing back in restores it." / RU "Выход сохраняет данные на этом устройстве. Повторный вход восстановит их."
3. **THIS DEVICE** section (`L10n.accountThisDeviceSection`: EN "This Device" / RU "Это устройство"):
   - Delete local data row (`ListRow`, `trash` icon, danger tint, `accessibilityIdentifier("AccountDeleteLocalDataButton")`; renamed from "Erase local data", existing `ProfileEraseLocalDataButton` id retired with the move).
   - Single confirmation alert (existing title/message keys, retargeted): deletes only this account's local file (state + outbox + undo buffer + cursors); dormant accounts untouched; relay data untouched; signs out after.
   - Footer helper (`L10n.accountThisDeviceFooter`): EN "Removes only this account's data from this device and signs you out. Synced data stays on the relay." / RU "Удаляет с этого устройства только данные этого аккаунта и выводит вас из аккаунта. Синхронизированные данные остаются на сервере."
4. **PERMANENT DELETION** section (`L10n.accountPermanentSection`: EN "Permanent Deletion" / RU "Безвозвратное удаление"), visually separated from the groups above:
   - Delete account and local data row (`ListRow`, `person.crop.circle.badge.xmark` icon, danger tint, `accessibilityIdentifier("AccountDeleteAccountButton")`).
   - Exactly ONE confirmation alert (see Behaviors). No second confirmation anywhere.
   - Footer helper (`L10n.accountPermanentFooter`): EN "Permanently deletes your Lifio account and synced data, plus this account's data on this device. Your other devices are signed out." / RU "Навсегда удаляет ваш аккаунт Lifio и синхронизированные данные, а также данные этого аккаунта с этого устройства. Другие ваши устройства будут выведены из аккаунта."
5. All three destructive rows share one visual contract: shared `ListRow` geometry (leading icon + label), `Theme.danger` tint. No new shared component — reuse `ListRow` (`COMPONENTS.md` unchanged).

### Behaviors

- **One explicit alert.** Tapping Delete account and local data presents a single `.alert`:
  - Title: EN "Delete account and local data?" / RU "Удалить аккаунт и локальные данные?"
  - Message: EN "This permanently deletes your Lifio account and all synced entries, categories, and notes, and removes this account's local data from this device. Your other devices will be signed out." / RU "Это навсегда удалит ваш аккаунт Lifio и все синхронизированные записи, категории и заметки, а также удалит данные этого аккаунта с этого устройства. Ваши другие устройства будут выведены из аккаунта."
  - Buttons: destructive EN "Delete account and local data" / RU "Удалить аккаунт и локальные данные"; secondary Cancel (`role: .cancel`, existing key) — Cancel sends no request and changes nothing.
- **Apple authorization is authentication, not a second alert.** Apple-created accounts without a stored revocable credential present the native Apple authorization sheet for the SAME identity before DELETE is sent (endpoint `POST /auth/apple/deletion-credential`). Dismissing that sheet cancels the flow — no request is sent. Email-only accounts skip this step entirely.
- **In-flight protection.** While a deletion submission is running: the destructive button shows an inline `ProgressView` with an accessible progress label (`accessibilityIdentifier("AccountDeletionProgress")`), duplicate submissions are disabled, and conflicting account actions (Sign out, Delete local data, Sync now for this account) are unavailable. An error/result notice afterward is information, never a second confirmation.
- **No completion claim on ambiguity.** If the response is lost after send, the client resolves via the read-only account-status check before announcing anything (see `INTERACTIONS.md` → Account deletion resolution). Never report success merely because the alert was accepted.
- **Offline.** Account renders fully offline (cached email, Sign out works). Deletion submit is disabled offline with a non-field error banner; the status check cannot run offline either.

### Accessibility

- Email, helper copy, and destructive labels wrap at accessibility Dynamic Type sizes; nothing consequential truncates. The three actions stay visually distinguishable (section separation + footers) at the largest sizes.
- VoiceOver: email is a static text element; each destructive row is a button with its localized label; progress announces "Deleting account…" (`L10n.accountDeletingProgress`).
- Stable identifiers: `ProfileAccountRow` (Profile link), `AccountEmailValue`, `AccountDeleteLocalDataButton`, `AccountDeleteAccountButton`, `AccountDeletionProgress`, plus the kept `ProfileSignOutButton`.

### Implementation checklist

- [ ] All colors use `Theme.*` tokens.
- [ ] All strings use `L10n.*` keys in English and Russian.
- [ ] Account pushes on the originating tab's path; tab bar hidden; system Back; no Done/sheet.
- [ ] Email is read-only cached session state; relay addresses shown as-is.
- [ ] Exactly one deletion-confirmation alert with the specified copy; Cancel sends nothing.
- [ ] In-flight: progress visible, duplicates/conflicting actions disabled.
- [ ] Sign out keeps its id with one confirmation; local erase keeps single-confirm + server-untouched scope.
- [ ] VoiceOver, Dynamic Type, Reduce Motion, light/dark, and iOS 18 are tested.
- [ ] SwiftLint and warning-as-error builds pass.
