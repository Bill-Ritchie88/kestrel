# Kestrel passenger app (Flutter)

The passenger interface for Project Kestrel (FR-08). It follows the Figma flow
in `kestrel-ui-design-system.md` and the wireframes M02–M15:

| Screen | File | Calls |
|---|---|---|
| M02/M03 Sign in | `lib/screens/login_screen.dart` | `POST :8000/api/auth/session`, `GET /api/me` |
| M05/M08 Chat | `lib/screens/chat_screen.dart` | `POST :8001/api/chat` (agent), `POST /api/handoff` |
| M09 Other flights | `lib/screens/alternatives_screen.dart` | `GET /api/flights/alternatives` |
| M11/M12 Confirm, rebooked | `lib/screens/confirm_screen.dart` | `POST /api/reaccommodate` (409 = sold out, pick again) |
| M13/M14 Vouchers | `lib/screens/vouchers_screen.dart` | `GET /api/entitlements` |
| M15 Hand-off | `lib/screens/handoff_screen.dart` | `POST`/`GET /api/handoff` |

M10 (seat map) is not a separate screen: the stored procedure assigns the
seat in the passenger's cabin under a row lock, which is what makes the
concurrency test pass.

## Folder structure

```
client/
├── pubspec.yaml
├── analysis_options.yaml
├── lib/
│   ├── main.dart              KestrelApp, SessionGate
│   ├── config.dart            API_BASE / AGENT_BASE
│   ├── theme.dart             design tokens (K) and ThemeData
│   ├── format.dart            local-time and money formatting
│   ├── api/
│   │   ├── kestrel_api.dart   HTTP client, ApiException
│   │   └── models.dart        Booking, Flight, Voucher, ...
│   ├── state/session.dart     token + booking, in memory only
│   ├── widgets/
│   │   ├── common.dart        Backdrop, buttons, pills, FlightLeg
│   │   ├── cards.dart         booking, flight, voucher, citation, chat
│   │   └── api_error.dart     401 → back to sign-in
│   └── screens/               one file per wireframe group
└── test/widget_test.dart
```

## Run it (Windows, PowerShell)

Both backend services must be running first (repo root, venv active):

```powershell
.\tasks.ps1 api          # terminal 1 - REST tier on :8000
.\tasks.ps1 agent-api    # terminal 2 - agent service on :8001
```

Then, in a third terminal:

```powershell
cd client
flutter create . --project-name kestrel_app --platforms web,android   # once: generates web/ and android/
flutter pub get
flutter analyze
flutter test
flutter run -d chrome --web-port 5173
```

`--web-port 5173` matters: the services only accept browser requests from
the origins in `ALLOWED_ORIGINS` (`.env`), which include
`http://localhost:5173`.

Sign in with a disrupted booking from the seed data, e.g. `A5QCWV` /
`Stephens`. Reset the demo state between runs with `.\tasks.ps1 reset`.

### Other backends

```powershell
flutter run -d chrome --web-port 5173 `
  --dart-define=API_BASE=http://127.0.0.1:8000 `
  --dart-define=AGENT_BASE=http://127.0.0.1:8001
```

The Android emulator reaches your PC at `10.0.2.2`; `config.dart` uses that
automatically on Android.

### Android (optional)

1. `flutter doctor --android-licenses` and accept.
2. Create an emulator in Android Studio (Device Manager).
3. Add to `android/app/src/main/AndroidManifest.xml`, above `<application>`:

   ```xml
   <uses-permission android:name="android.permission.INTERNET"/>
   <uses-permission android:name="android.permission.RECORD_AUDIO"/>
   <queries>
     <intent><action android:name="android.speech.RecognitionService"/></intent>
   </queries>
   ```

   and `android:usesCleartextTraffic="true"` on `<application>` (the local
   services use plain HTTP).
4. `flutter run -d emulator-5554`

## Accessibility (UI UX Pro Max checklist)

- Text contrast ≥ 4.5:1 on the dark surfaces; checked in `widget_test.dart`.
  `#6B6F7D` is never used for text, and crimson text uses `#FF2E55`.
- Touch targets ≥ 48 dp; checked with `androidTapTargetGuideline`.
- Status is never colour alone (pills always show the word).
- Errors and the "working" indicator are live regions for screen readers.
- Reduce-motion is respected by the typing indicator and auto-scroll.
- Times are shown in each airport's local time, exactly as the API sends them.
