## User registration and sign-in

1. The app launches into the auth flow (mandatory sign-in gate — there is no signed-out use): the welcome screen shows the app name, tagline, **Sign in with Apple** button, and **Continue with Email** button.
2. If the user taps **Continue with Email**, they navigate to the email entry screen.
3. User types their email address into the email field.
4. User submits the email by tapping the **Continue** button or pressing the keyboard Return key.
   1. If the email is not valid, the user gets a validation error with an error message beneath the field.
   2. Otherwise, the app requests a one-time code and navigates to the OTP page.
5. On the OTP page, the user enters the 6-digit code in the box field.
   1. The app auto-submits the code when the 6th digit is entered (after a short debounce).
   2. If the code is not valid or the server rejects it, the user gets a validation or server error, and the code field is cleared so they can re-enter it.
   3. If the user realises the email is incorrect, they navigate back to the email screen, which is pre-filled with the email they entered.
   4. If the user cannot receive the code, they can resend it after waiting for 30 seconds.
      1. After waiting for 30 seconds, the **Resend code** button becomes enabled.
      2. When the code is resent, the user gets an appropriate feedback message.
    5. If the code is valid and accepted by the server, the user is signed in; `SyncController` activates and the app shell (Track) remains the root.
6. If the user chooses **Sign in with Apple** on the welcome screen, the native Apple authorization sheet appears. On success, the user is signed in; `SyncController` activates and the app shell (Track) remains the root.

## Account page and deletion (add-account-deletion change — planned, not yet implemented)

7. The signed-in user opens Profile (top-trailing person control on any tab) → **Account**. Account shows the cached account email read-only (works offline; an Apple relay address displays as-is), Sign out (one confirmation), Delete local data (this account's on-device file only, relay untouched), and the visually separate **Delete account and local data**.
8. If the user taps **Delete account and local data**, exactly one confirmation alert names both consequences and offers Cancel (Cancel sends nothing). Apple-created accounts without a stored revocable credential first complete the native Apple authorization sheet for the same identity; dismissing it cancels with no request. Email-only accounts skip that step.
9. On confirm, the app purges the relay account and its synced data, automatically revokes Apple authorization for Apple-created accounts (retrying a durable encrypted revocation job if Apple is momentarily unavailable), ends the matching Live Activity, removes this account's local copy, and returns to the auth gate. If delivery is ambiguous the app resolves via the read-only account-status check before announcing anything — success is never assumed from accepting the alert.
10. Another device of the same account learns of the deletion only through status-verified proof for the original account UUID; generic sign-in rejection locks it with files intact. An offline device keeps its local copy until it can verify. A later signup with the same email or Apple identity creates a new account (new UUID) with none of the deleted content.
11. Revoking Lifio in the Apple Settings (Apple ID → Sign in with Apple) is sign-out-only: sessions end but the Lifio identity, server data, and local files are preserved, and reauthorizing the same Apple identity returns to the existing account.
