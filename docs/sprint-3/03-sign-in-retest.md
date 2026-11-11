# Google and email sign-in: retest (November 2026)

FR-01 sign-in, issue #1 (link only under the verified email). Checked on 11 November 2026 against the live
system after the seat-selection release (`main` at `571c578`).

## 1. Configuration, checked read-only

| Check | How | Result |
|---|---|---|
| Google provider enabled in Supabase Auth | `GET <SUPABASE_URL>/auth/v1/settings` with the public anon key | Enabled |
| Email (one-time code) enabled | Same response | Enabled; sign-ups allowed; addresses are confirmed by the code (no auto-confirm) |
| Redirect URLs include `https://kestrel-web-a20.pages.dev` and `http://localhost:8080` | Not readable without dashboard access | **Manual:** Supabase → Authentication → URL Configuration (item 0 below) |
| `ALLOWED_ORIGINS` on both Render services contains the Pages address | CORS preflight from `Origin: https://kestrel-web-a20.pages.dev` to each `/health` | REST tier and assistant both answer `access-control-allow-origin: https://kestrel-web-a20.pages.dev` |
| The web build was made with `SUPABASE_URL` and `SUPABASE_ANON_KEY` | The live `main.dart.js` contains the project's Supabase host (checked by host, values not printed); `build-site.ps1` refuses to build without both | Yes |

## 2. What was tested automatically

- **The linking rule** (`src/kestrel/api/main.py` `POST /api/auth/account`, `src/kestrel/api/accounts.py`): an
  account is linked to a passenger only when the booking's email equals the email Supabase verified. A booking
  reference and surname for someone else's booking opens that booking for the visit and links nothing; a
  reference alone under another email is 403; an unverified email is 401; a booking already linked to another
  account is 409. Covered by `tests/unit/test_accounts.py`: 22 passed on 11 November 2026.
- **Requesting an email code for a synthetic `@example.com` address was not sent.** `example.com` has no mail
  server, so the message would bounce, and Supabase's built-in mailer restricts projects with bounces and allows
  only a few emails an hour, which would get in the way of the manual test below. The request path is the
  Supabase client library's own; item 2 below covers it with a real inbox.

## 3. Manual checklist (phone and laptop)

Use a Gmail account that is **not** linked to any demo booking (not the account linked to Kristina Edwards or
Charles Mueller), and a booking reference that is not a demo booking. On test day, the spare usability
booking (P6) works; otherwise ask Claude for a synthetic one.

| # | Step | Expected | Phone | Laptop |
|---|---|---|---|---|
| 0 | Supabase → Authentication → URL Configuration | Site URL and redirect URLs include `https://kestrel-web-a20.pages.dev` and `http://localhost:8080` | — | ☐ |
| 1 | https://kestrel-web-a20.pages.dev → **Sign in with Google or email** → Google, with a Gmail account that has no booking | Back in Kestrel, signed in, with the "link a booking" state and no suggested bookings | ☐ | ☐ |
| 1a | Enter the booking reference and surname | That booking opens. It is **not** linked (the email differs): signing out and in again asks for a booking again | ☐ | ☐ |
| 2 | Sign out, then **Sign in with Google or email** → email → your own address → enter the code from the email | Signed in, same "link a booking" state as 1 | ☐ | ☐ |
| 3 | **Sign out** from the account menu | Back on the public home page; the browser's back button does not reopen the trip | ☐ | ☐ |
| 4 | **Unlink** (only if an account is linked: it needs a booking under that account's own email, see note) | The link is removed; the next sign-in asks for a booking again | ☐ | ☐ |

Note on step 4: a real link needs a booking whose passenger email is the tester's own address. The demo
data has none apart from the demo accounts, which must not be used. Ask Claude to create a synthetic booking
under your address for the test and to remove it afterwards, or test unlinking with the automated tests only.

Record any failure with the step number, device, browser and the message shown.
