# Kestrel Web and Kestrel App (Flutter)

One Flutter codebase, two products. **Kestrel Web** is the website: it runs in
a desktop or laptop browser (a dashboard with a sidebar) and in a phone browser
(one column with a tab bar). **Kestrel App** is the same code built for Android.

The passenger interface for Project Kestrel (FR-08) and the staff disruption
desk (FR-09). The layout is a flight-dashboard layout (sidebar, top bar,
ticket cards, route lines, a progress tracker) in the Kestrel colours and type
from `kestrel-ui-design-system.md`; the screens cover the wireframes M02–M15:

| Screen | File | Calls |
|---|---|---|
| Home, Help (public) | `lib/screens/home_screen.dart`, `help_screen.dart` | `POST :8000/api/auth/session` (booking form on Home) |
| Sign in (account, guest or staff) | `lib/screens/login_screen.dart` | Google or an emailed code (Supabase Auth), then `POST /api/auth/account`; guest: `POST /api/auth/session`; staff: `GET /api/staff/cases` |
| Link booking (first account sign-in) | `lib/screens/link_booking_screen.dart` | `POST /api/auth/account` with `pnr_code` (links only a booking under the account's own email) |
| Layout: sidebar or tab bar, account menu | `lib/screens/passenger_shell.dart` | `POST /api/handoff` ("Need a person?"), `DELETE /api/auth/account/link` ("Unlink this booking") |
| My trip (Kestrel recommends, "Why this flight?") | `lib/screens/trip_screen.dart` | `GET /api/trip` (booking, alternatives with reasons, entitlements, cases, suggestions) |
| Assistant | `lib/screens/chat_screen.dart` | `POST :8001/api/chat/stream` (agent), `GET`/`DELETE /api/chat/history` |
| Flights | `lib/screens/alternatives_screen.dart` | from `GET /api/trip` |
| Confirm, Rebooked | `lib/screens/confirm_screen.dart` | `POST /api/reaccommodate` (409 = refused, e.g. sold out: pick again) |
| Vouchers | `lib/screens/vouchers_screen.dart` | from `GET /api/trip` |
| Help (hand-off) | `lib/screens/handoff_screen.dart` | `POST /api/handoff`; cases from `GET /api/trip` |
| Staff desk | `lib/screens/staff_desk_screen.dart` | `GET /api/staff/cases?status=OPEN` (newest first), `POST /api/staff/cases/{id}/resolve` (`X-Staff-Key`) |

Every screen shows data from the REST tier, which reads Supabase. The only
illustrative data is the table on Home, labelled "Example".

The staff desk needs `STAFF_API_KEY` set in `.env`; staff sign in with their
name (recorded as `STAFF:<name>` on the cases they resolve) and that key,
which is kept in memory only.

M10 (seat map) is not a separate screen: the stored procedure assigns the
seat in the passenger's cabin under a row lock, which is what makes the
concurrency test pass.

## Folder structure

```
kestrel_client/
├── pubspec.yaml
├── analysis_options.yaml
├── lib/
│   ├── main.dart              KestrelApp, SessionGate
│   ├── config.dart            API_BASE / AGENT_BASE, SUPABASE_URL / SUPABASE_ANON_KEY
│   ├── theme.dart             design tokens (K) and ThemeData
│   ├── format.dart            local-time and money formatting
│   ├── api/
│   │   ├── kestrel_api.dart   HTTP client, ApiException
│   │   └── models.dart        Booking, Flight, Voucher, ...
│   ├── auth/
│   │   ├── account_auth.dart           the sign-in interface the pages use (faked in tests)
│   │   └── supabase_account_auth.dart  Google and emailed codes through Supabase Auth
│   ├── state/
│   │   ├── session.dart       passenger token + booking, or staff key; in memory only
│   │   ├── public.dart        which public page shows (Home, Help, sign-in, Link booking)
│   │   ├── shell.dart         which section is showing (above the Navigator)
│   │   └── chat.dart          the conversation, kept across sections
│   ├── widgets/
│   │   ├── common.dart        Backdrop, buttons, pills, RouteLine, TicketDivider
│   │   ├── cards.dart         trip ticket, flight row, voucher, recovery tracker, chat
│   │   ├── shell.dart         sidebar, top bar, "need a person?" panel
│   │   ├── layout.dart        breakpoints and page padding
│   │   └── api_error.dart     401 → back to sign-in
│   └── screens/               one file per section or wireframe group
└── test/widget_test.dart
```

## Run it (Windows, PowerShell)

From the repo root:

```powershell
.\tasks.ps1 start    # REST tier on :8000 and agent service on :8001
.\tasks.ps1 web      # release build, served on http://localhost:8080
```

Then open **http://localhost:8080** and sign in as a guest with a disrupted
booking's reference and surname. Reset the demo state with
`.\tasks.ps1 reset`.

For development (hot reload), with the services running:

```powershell
cd kestrel_client
flutter pub get
flutter analyze
flutter test
flutter run -d chrome --web-port 5173
```

`--web-port 5173` matters: the services only accept browser requests from
the origins in `ALLOWED_ORIGINS` (`.env`), which include
`http://localhost:5173`.

### Other backends

```powershell
flutter run -d chrome --web-port 5173 `
  --dart-define=API_BASE=http://127.0.0.1:8000 `
  --dart-define=AGENT_BASE=http://127.0.0.1:8001
```

The Android emulator reaches your PC at `10.0.2.2`; `config.dart` uses that
automatically on Android.

### Sign in with Google or an email code (Supabase Auth)

Without these two settings the sign-in page offers only the booking
reference (guest) and the staff key. With them it also offers **Continue
with Google** and **a 6-digit code by email**:

```powershell
flutter run -d chrome --web-port 5173 `
  --dart-define=SUPABASE_URL=https://<project-ref>.supabase.co `
  --dart-define=SUPABASE_ANON_KEY=<anon key>
```

Both values are under Supabase → Project Settings → API (the anon key is
public by design; never put the `service_role` key in the app). Use the same
project in the repo's `.env` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`): the REST
tier checks every sign-in with Supabase before it links the account to a
booking. Add the same `--dart-define`s to `flutter build web --release`.

The first time an account signs in it is linked to one booking (the
**Link booking** page: only a booking whose passenger has the same email
address is linked; a reference and surname for someone else's booking opens
that one booking for this visit without linking it). After that it signs
straight in, and **Unlink this booking** on the account menu removes the link. The
Supabase session is kept in memory only, like the Kestrel token, and signing
out signs out of both.

**Supabase setup (once, in the Supabase dashboard):**

- [ ] **Migration 009** (`db/migrations/009_passenger_accounts.sql`) applied
      to the database: it holds the account ↔ booking links.
- [ ] **Email sign-in**: Authentication → Sign In / Providers → **Email**
      enabled, with **Confirm email** on.
- [ ] **Code expiry 600 s**: on the same Email provider page, set **Email OTP
      Expiration** to `600` (10 minutes, as the page tells passengers) and
      **Email OTP Length** to `6`.
- [ ] **Email templates send the code**: Authentication → Emails →
      Templates. In both **Magic Link** (returning users) and **Confirm
      signup** (new users), show the code with `{{ .Token }}`, e.g.
      `<p>Your Kestrel code is <strong>{{ .Token }}</strong>. It expires in
      10 minutes.</p>`. Without `{{ .Token }}` the email has only a link and
      no code.
- [ ] **Email delivery**: the built-in mailer only sends to your Supabase
      team's addresses and a few emails an hour. To send codes to anyone,
      add your own SMTP server (Authentication → Emails → SMTP Settings).
- [ ] **Google provider**: in Google Cloud Console → APIs & Services →
      Credentials, create an **OAuth client ID** (Web application) with the
      authorised redirect URI `https://<project-ref>.supabase.co/auth/v1/callback`.
      Paste its Client ID and Client Secret into Supabase → Authentication →
      Sign In / Providers → **Google**, and enable it.
- [ ] **Redirect URLs**: Authentication → URL Configuration. Set **Site URL**
      to where the site runs (`http://localhost:5173` locally) and add every
      address the app runs at to **Redirect URLs**: `http://localhost:5173`,
      the deployed site's origin, and `io.kestrel.app://login-callback` for
      the Android app. Google returns the browser to the page's own origin.
- [ ] **Android only**: Google comes back to the app through the deep link
      `io.kestrel.app://login-callback`, already declared on the main
      `<activity>` in `android/app/src/main/AndroidManifest.xml`. The email
      code needs no deep link.

### Kestrel App (Android)

1. `flutter doctor --android-licenses` and accept.
2. Create an emulator in Android Studio (Device Manager) and start it.
3. With the services running (`.	asks.ps1 start`), from `kestrel_client`:

   ```powershell
   flutter run -d emulator --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
   ```

The Android project in `android/` is versioned: the manifest already has the
internet and microphone permissions, the voice-recognition query,
`usesCleartextTraffic` (the local services use plain HTTP) and the Google
sign-in deep link. Application ID and namespace: `io.kestrel.app`.

### Demos: the release build on http://localhost:8080

`flutter run` is for development only: it serves a large, unoptimised debug
build. For a demo (or to measure start-up), use the release build, from the
repo root:

```powershell
.\tasks.ps1 web
```

It reads `SUPABASE_URL` / `SUPABASE_ANON_KEY` from `.env` (without printing
them), runs

```powershell
flutter build web --wasm --release --no-web-resources-cdn `
  --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
```

`--wasm` builds both: Chrome and Edge run the WebAssembly build (skwasm
renderer), other browsers the JavaScript one. In headless Chrome on the demo
laptop the WebAssembly build showed its first screen in 0.85 s on a first
visit and 0.29 s on a repeat visit (JavaScript: 1.65 s and 0.59 s).

It then serves `kestrel_client/build/web` on **http://localhost:8080** with
`scripts/dev/serve_web.py` (Python standard library only): gzip for
js/wasm/json/css/html, `no-cache` + ETag revalidation for `index.html` and
for Flutter's own files (their names carry no content hash, so a repeat
visit gets `304 Not Modified` instead of a download), a year's
`immutable` caching for any file whose name does carry a hash, and every
path without a file extension falls back to `index.html`.

Nothing is fetched from Google when the page starts: Inter and JetBrains
Mono are bundled (`assets/fonts/`, SIL Open Font Licence), and
`--no-web-resources-cdn` serves the renderers (CanvasKit, skwasm) from this machine instead of
`gstatic.com`. Supabase starts in the background after the first frame; the
Google and email buttons show at once and enable themselves when it is
ready. The staff desk is a deferred library: in the JavaScript build it is
a separate file (`main.dart.js_1.part.js`) downloaded only when staff sign
in; the WebAssembly compiler keeps it in `main.dart.wasm`.

Once, before the first demo:

- add `http://localhost:8080` to `ALLOWED_ORIGINS` in `.env` and restart the
  services (`.\tasks.ps1 up`) - `tasks.ps1 web` warns when it is missing;
- add `http://localhost:8080/**` to Supabase → Authentication → URL
  Configuration → **Redirect URLs**, so Google sign-in comes back to the
  release build.

### Build the website

```powershell
flutter build web --release --no-web-resources-cdn
```
The site is written to `kestrel_client/build/web/` and can be served by any static
web server. Set the service addresses at build time with
`--dart-define=API_BASE=... --dart-define=AGENT_BASE=...` (and
`--dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...` for
Google and email sign-in), add the site's origin to `ALLOWED_ORIGINS` in
`.env`, and add it to the Supabase redirect URLs.

### Layout

| Window width | Layout |
|---|---|
| under 1080 px (phones, small tablets) | one column; tab bar (Trip, Assistant, Flights, Vouchers, Help); account menu in the app bar |
| 1080 px and up (laptops) | sidebar (sections, "Need a person?", sign out) + top bar ("Ask Kestrel", booking reference, account) |
| content 980 px and wider | a second column: the recovery tracker and entitlements on My trip, the trip panel beside the chat |

Flight rows switch from a stacked card to a search-result row from 560 px of
card width. The chat card stops at 880 px and confirm/rebooked pages at 720 px,
so lines stay readable. In the chat, **Enter** sends and **Shift+Enter** adds
a new line. The staff desk shows the case detail beside the table from 1100 px
of content width; on a phone a case opens as its own page.

`web/` (page title, description, icons, dark loading screen) is part of the
source, and so is `android/` (Kestrel App).

## Accessibility (UI UX Pro Max checklist)

- Text contrast ≥ 4.5:1 on the dark surfaces; checked in `widget_test.dart`.
  `#6B6F7D` is never used for text, and crimson text uses `#FF2E55`.
- Touch targets ≥ 48 dp; checked with `androidTapTargetGuideline`.
- Status is never colour alone (pills always show the word).
- Errors and the "working" indicator are live regions for screen readers.
- Reduce-motion is respected by the typing indicator and auto-scroll.
- Times are shown in each airport's local time, exactly as the API sends them.
