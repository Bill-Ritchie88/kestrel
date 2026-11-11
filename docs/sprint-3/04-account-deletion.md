# Account unlink and deletion (DR-01)

Closes the Sprint III gap "No account deletion: only unlinking a booking" (plan §7.6, §8.6), which blocked a
Google Play release. Added 11 November 2026.

## What the passenger can do

Both actions are in the **Account** menu of Kestrel Web, shown only when the signed-in Google or email account is
linked to the open booking. Each asks first in a dialog that says what will happen, with **Cancel** and the
action in red; both sign the passenger out afterwards.

| Action | Endpoint | Removes | Keeps |
|---|---|---|---|
| Unlink this booking | `DELETE /api/auth/account/link` | The account's `passenger_accounts` row | Everything else |
| Delete my account data | `DELETE /api/auth/account` | The `passenger_accounts` row; every `chat_messages` row of the linked passenger's bookings; the Supabase Auth user, when the server can (below) | `pnr_bookings`, `audit_logs`, vouchers, hand-off cases |

Both endpoints take the Supabase access token and ask Supabase whose it is (`verify_supabase_user`). The request
names no passenger or booking; anything it adds is ignored, so an account can only ever delete its own data. An
invalid token is 401, before any query. The deletion runs in one transaction and writes an
`ACCOUNT_DATA_DELETED` audit row (actor `ACCOUNT:<provider>:<auth user id>`, details: the passenger id and how
many chat messages were deleted).

## Why bookings and audit logs are kept

- **The booking is the airline's record, not the app account's.** A booking exists because a ticket was sold;
  the passenger can still open it at the desk or with the booking reference and surname. Deleting it would also
  delete the seat, vouchers and rebooking history that staff and the airline need.
- **Audit integrity (NFR-03).** `audit_logs` is append-only evidence of every rebooking and every change of
  link, including this deletion. Removing rows would break the trail the rebooking procedure relies on, and the
  deletion itself must be provable. The rows hold an account id and a passenger id, not chat text.
- **What the app account added is deleted.** The link and the conversation exist only because of the app; they go.

## The Supabase sign-in identity

Deleting a Supabase Auth user needs the project's **service-role key** (Supabase admin API,
`DELETE /auth/v1/admin/users/{id}`). The REST tier uses it only if `SUPABASE_SERVICE_ROLE_KEY` is set in its
environment; the key must never reach Kestrel Web.

On 11 November 2026 no service-role key is configured (checked by name in `.env`). Until one is set:

- The endpoint still deletes the link and the chat history, and answers `"sign_in_identity_deleted": false` with
  a `manual_step` message that Kestrel Web shows after signing out: the sign-in identity must be removed manually.
- **Manual step (owner):** Supabase dashboard → *Authentication* → *Users* → find the user by email (or by the id
  in the `ACCOUNT_DATA_DELETED` audit row) → *Delete user*. While no key is set, do this for every
  `ACCOUNT_DATA_DELETED` row (`SELECT actor, "timestamp" FROM audit_logs WHERE action = 'ACCOUNT_DATA_DELETED'`).
- To make it automatic: add `SUPABASE_SERVICE_ROLE_KEY` (Supabase → *Project Settings* → *API*) to the REST
  tier's environment on Render only, then restart it. A failed admin call (refused, unreachable) falls back to
  the manual step; it never undoes the deletion already committed.

## Checked by

- `tests/unit/test_accounts.py`: delete removes the link and the chat history of the linked passenger only (a
  passenger or booking in the body is ignored), audits it, and runs no other delete or update (bookings and
  audit kept); with a service-role key the admin API is called for the token's user; a refused admin call falls
  back to the manual step; no link deletes nothing; invalid token 401. Unlink tests as before.
- `tests/integration/test_sql_statements.py` prepares the two new statements against the live schema (could not
  run on 11 November 2026: the database was unreachable from the development laptop).
- `kestrel_client/test/widget_test.dart`: both actions ask first, Cancel changes nothing, the delete button is
  red with ≥ 48 px targets, no overflow at 375 px, phone and laptop.
