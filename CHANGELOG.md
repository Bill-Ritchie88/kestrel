# Changelog

Project Kestrel, an agentic AI assistant for Kenya Airways passengers whose flight is cancelled. Built in
three sprints for the ICS 4C capstone at Strathmore University. All passenger data is synthetic.

## v1.0 (Sprint III, November 2026)

The capstone release, deployed on Render, Cloudflare Pages and Supabase (see `docs/handover.md`).

### Added
- **Seat selection (FR-16):** a seat map between choosing a flight and Confirm, with "Let Kestrel choose".
  Migration 013 locks a chosen seat `FOR UPDATE NOWAIT` (409 `SEAT_TAKEN` if someone took it first) and keeps
  auto-assign on `SKIP LOCKED`. New endpoint `GET /api/flights/{flight_id}/seats`; optional `seat_id` on
  `POST /api/reaccommodate`.
- **Confirmation before the assistant rebooks (FR-17):** the assistant only proposes; the passenger confirms
  on a card in the chat. The REST tier refuses the agent tier without a signed, single-use, five-minute
  confirmation token bound to the booking, flight and seat. System prompt version 2.1.0.
- **Rate limits (NFR-05):** chat on both services, 20 requests a minute per token (burst 5); sign-in, 20 a
  minute per IP. 429 with `Retry-After`, shown in Kestrel Web as a friendly message.
- **Delete my account data (DR-01):** removes the account link and chat history, and the Supabase sign-in
  when a service-role key is set. Bookings and audit logs are kept. Unlink and Delete ask first.
- **Prompt provenance (DR-09):** migration 014 stores the system-prompt version on every assistant turn;
  the staff desk shows it.
- **Usability test kit:** facilitator script, participant sheets, SUS questionnaire, results sheets with
  scoring, findings template, test-day checklist and the test-day bookings script (`.\tasks.ps1 usability`).
- **Load test against Render:** `load_test.py --api-base`; NFR-01 met up to 25 concurrent rebookings.
- **Handover and diagrams:** `docs/handover.md`, `docs/diagrams/`, and the sign-in retest checklist.

### Changed
- The app is named **Kestrel AI assistant**.
- `deploy/README.md` names the live addresses.

### Measured
- NFR-01 on Render, p95 of concurrent rebookings: 0.40 s at 10 and 0.70 s at 25 (met), 1.27 s at 50 (not met
  at the client; server time 0.73 s). 0 double seats.
- Seat selection: with 2 and 10 passengers choosing the same seat, exactly one gets it.

## Sprint II (October 2026)

### Added
- Standalone repository with the `src/` layout, CI (GitHub Actions, pre-commit, secret scan) and locked
  dependencies.
- Database: cabin class enforced in the rebooking procedure with an audit row for every refusal (004);
  policy clauses with pgvector, vouchers, hand-off cases and cancellation reasons (005, 006); row-level
  security on flights and advisor fixes (007, 008); passenger accounts (009); chat memory and the frustration
  hand-off (010); same-route rule `DIFFERENT_ROUTE` (011); cancellation time and a chat-history cap (012).
- REST tier: deterministic entitlement rules, policy retrieval with a scope guard, hand-off and staff queue,
  signed session tokens, Google and email-code sign-in that links only on a matching verified email.
- Assistant: five tools (find flights, rebook, search policy, entitlements, hand-off), streamed replies,
  conversation memory, recommendations, "Why this flight?", quick replies and the frustration hand-off.
- Kestrel Web: the Flutter passenger app and website (Home, Help, sign-in, trip, flights, vouchers, chat) and
  the staff desk.
- Free hosting on Render and Cloudflare Pages.

### Measured
- Policy retrieval Recall@3 0.967 on 88 labelled questions; scope guard F0.5 0.918 at τ = 0.66, with five-fold
  cross-validation 0.668 ± 0.011.
- Seat integrity: 40 concurrent runs, 0 double seats. NFR-01 from the laptop: p95 10.1 s (not met).

## Sprint I (September 2026)

### Added
- The atomic rebooking procedure `reaccommodate_passenger_atomic` (001, corrected in 003), base schema, indexes
  and row-level security (000, 002).
- Synthetic dataset generator and the demo reset.
- Session authentication, SQL migrations, a test suite, the task runner and the repository README.
- Secrets removed from history; `.env` ignored.
