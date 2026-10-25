# Sprint 2 test log

Record of every Sprint 2 test that has actually been run: what was expected,
what happened, and any correction made. Entries are added only after a run;
nothing here is projected. Times are East Africa Time (UTC+3).

Environments:
- **Local fixture** - PostgreSQL 16 in the development sandbox, built from the
  migrations (pgvector emulated). Used before anything touched Supabase.
- **Supabase** - project `Project-Kestrel` (PostgreSQL 17, eu-central-1),
  synthetic dataset v2 (966 flights, 162,536 seats, 134,432 bookings).
- **Workstation** - Windows laptop, Python 3.13 virtual environment, REST tier
  on :8000 and agent service on :8001.

## 1. Database migrations

| ID | Test | Expected | Actual | Result / correction |
|---|---|---|---|---|
| DB-01 | Reproduce Fix 5 on procedure v2 (local fixture): economy passenger rebooked onto a flight with free business and economy seats | Economy seat (shows the defect if not) | Seat **1A (business)** | Defect reproduced before fixing |
| DB-02 | Same call on procedure v3 (migration 004) | Economy seat, natural order | Seat **9A (economy)** | Pass |
| DB-03 | Business passenger on v3 | Business seat | **1A** | Pass |
| DB-04 | Previous seat released | `AVAILABLE` | `AVAILABLE` | Pass |
| DB-05 | Repeat request for the same flight | Refused, audited `ALREADY_ON_TARGET_FLIGHT` | As expected | Pass |
| DB-06 | CONFIRMED (not disrupted) booking | Refused, audited `BOOKING_NOT_DISRUPTED` | As expected | Pass (guard was commented out in v2) |
| DB-07 | Cancelled target flight | Refused **and audited** `FLIGHT_NOT_SCHEDULED` | As expected | Pass. v2 returned without an audit row - corrected in 004 |
| DB-08 | Departed target flight | Refused and audited `FLIGHT_DEPARTED` | As expected | Pass. Same correction as DB-07 |
| DB-09 | Unknown PNR | Refused and audited `INVALID_PNR` | As expected | Pass |
| DB-10 | Economy cabin full on target | Refused `NO_SEATS_IN_CABIN` | "No economy seats remaining on the target flight." | Pass |
| DB-11 | Migrations 005-006 and the reset seed on the local fixture; 006 run twice | Apply cleanly; second run is a no-op | As expected | Pass |
| DB-12 | Apply 004-008 to Supabase (MCP `apply_migration`) | All recorded in `supabase_migrations` | 004, 005, 006, 007, 008 recorded | Pass after correction: 006 was cancelled twice at the destructive-statement confirmation (it dropped the empty Sprint 1 `vouchers` placeholder). Rewritten to rename the placeholder instead, so no destructive statement is needed |
| DB-13 | Supabase security advisor after 006 | No critical findings | **Critical: RLS disabled on `flights`** (missed by 002) | Fixed by migration 007; advisor re-run clean of critical findings |
| DB-14 | Supabase advisors (security, performance) | Warnings addressed or justified | Mutable `search_path` on the procedure; 4 unindexed foreign keys on `pnr_bookings` | Fixed by migration 008. RLS-without-policy (intended) and pgvector-in-public (deferred) documented in 008 |
| DB-15 | Rebuild from nothing: 000 then 001-008 on an empty database | All apply; 8 tables; RLS on every table | All applied; 8 tables; RLS on all | Pass |
| DB-16 | Demo reset on Supabase (`tasks.ps1 reset`) | Schedule moved to today; 3 busiest future flights cancelled with reasons | KQ886 NBO-BKK (TECHNICAL, 308 pax), KQ3 NBO-JFK (WEATHER, 308), KQ116 NBO-AMS (ATC, 306); 922 disrupted; schedule to 17 Oct | Pass |

## 2. Policy corpus (FR-02)

| ID | Test | Expected | Actual | Result / correction |
|---|---|---|---|---|
| PC-01 | Chunk the Kenya Airways Conditions of Carriage saved as PDF | All articles | PDF held **one page** (part of Article 1) | Browser print captured one page only. Corrected by saving the page as plain text |
| PC-02 | Chunk the three text sources (dry run) | One chunk per article; ids unique | 120 chunks: KQ CoC 36, EU261 24, Montreal 60 | Pass after correction: both EUR-Lex copies began with text injected by a browser chat extension. The chunker now starts each document at its official identifier; regression test added |
| PC-03 | First live ingest | 120 chunks stored | **HTTP 429** from Gemini: all 120 texts sent in one request exceeded the free-tier per-minute quota | Embedder now sends batches of 20, waits for the API's `retryDelay`, stops at once on a daily quota, and stores batch by batch |
| PC-04 | Ingest after the fix | 120 chunks | 120 chunks | Pass |
| PC-05 | Stored vectors (Supabase) | 768 dimensions, one model, unit length, no injected text | 768; `gemini-embedding-001`; norm 1.0000-1.0000; 0 contaminated | Pass |
| PC-06 | Retrieval sanity: EU261 Art. 9 (Right to care) as the query | Itself first, then related care clauses | Art. 9 (1.000), Art. 6 Delay (0.897), Art. 11 (0.870) | Pass. Observation: unrelated clauses also score high (Art. 9 vs Art. 7: 0.839), so tau = 0.75 is likely too permissive - to be calibrated (Section 4) |

## 3. Configuration and services

| ID | Test | Expected | Actual | Result / correction |
|---|---|---|---|---|
| SV-01 | Scripts run with the system Python | - | `ModuleNotFoundError: kestrel` | Operator error: the virtual environment was not active. README already says to activate it; `tasks.ps1` targets use the venv automatically |
| SV-02 | Load `.env` | All variables parse | `python-dotenv could not parse statement starting at line 42` | `STAFF_API_KEY` held placeholder text containing quotes. Replaced with a generated key; all 9 variables parse |
| SV-03 | `GET :8000/health` | online, database connected, policy search ready | `{"status":"online","version":"0.1.0","database":"connected","policy_search":"ready"}` | Pass |
| SV-04 | `GET :8001/health` | online, model and REST tier named | `{"status":"online","version":"0.1.0","model":"gemini-flash-latest","rest_tier":"http://127.0.0.1:8000"}` | Pass |

## 4. Concurrency (NFR-01, NFR-02)

| ID | Test | Expected | Actual | Result |
|---|---|---|---|---|
| LT-01 | `tasks.ps1 loadtest`: 12 business passengers from cancelled KQ886 rebook simultaneously onto the alternative with the fewest free business seats, each in its own transaction held open until all finish (rolled back) | No seat held twice; successes <= free seats; p95 < 2 s | KQ886 alternative with **1** free business seat: **1** succeeded, **11** refused ("No business seats remaining on the target flight."); **0** duplicate seats; p50 422 ms, **p95 430 ms**, max 438 ms | **Pass** |

## 5. Automated suite

| ID | Test | Expected | Actual | Result / correction |
|---|---|---|---|---|
| UT-01 | Unit tests in the development sandbox (no database, no network) | All pass | 110 passed | Pass |
| IT-01 | `tasks.ps1 test-all` on the workstation: unit + integration against Supabase (rolled back), 9 Oct 2026 | All pass | **121 passed, 1 failed** in 67 s. Failed: `test_handoff_case_round_trip` - `AmbiguousParameterError: inconsistent types deduced for parameter $1 (text versus character varying)` | **Defect in production code**, not the test: the hand-off INSERT used the PNR parameter both as a SELECT output (inferred `text`) and in a comparison with a `varchar` column. Every hand-off (passenger request, low similarity, step limit, no alternatives) would have failed at runtime. The unit tests could not see it because they use a fake connection. Fixed by casting every parameter in `handoff.py`; reproduced and verified with `PREPARE` on the rebuilt schema |
| IT-02 | Regression guard added: every `SQL_*` statement in the REST tier (20) is prepared against the live schema | All 20 prepare | 20 prepare cleanly on the rebuilt schema (local) | Pass locally; confirmed on the workstation in IT-03 |
| IT-03 | `tasks.ps1 test-all` after the hand-off fix and the latency/local-time changes, 9 Oct 2026 | All pass | **146 passed** in 96.6 s (114 unit, 12 integration, 20 statement-preparation) | **Pass** |
| AG-01 | Three chat turns via the agent service, `gemini-flash-latest`, 15 Oct 07:46-07:55 | Each turn completes; NFR-02 target 10 s | All failed: Gemini `504 DEADLINE_EXCEEDED` / `503 UNAVAILABLE` ("high demand"), 30-58 s per turn. Before the fix the SDK's 6 retries stretched a turn past the client's 45 s limit | **Fail.** Calls now bounded (2 attempts, 20 s each, `GEMINI_MAX_ATTEMPTS`/`GEMINI_TIMEOUT_S`); every turn logged to `logs/agent-turns.jsonl`; a quota error returns a clear 503 |
| AG-02 | Same three turns, `GEMINI_MODEL=gemini-3.6-flash`, 15 Oct 07:57 | <= 10 s each | Find another flight **6.4 s** (2 model calls 2.0+3.1 s, 1 tool 1.3 s); entitlements **6.0 s**; refund question **10.9 s** (policy search tool 5.7 s) | 2 of 3 within target. Remaining: the policy-search tool (embedding call) |
| CL-01 | Flutter client CI (Linux): `flutter analyze`, `flutter test`, `flutter build web --release`, 15 Oct | No issues; all tests pass; web build compiles | First run: analyze clean, 7 of 8 tests; failing test showed "Talk to a person" off-screen in the sideways chip row on a 412 px phone | Chips now wrap; **analyze clean, 8 of 8 tests, web build passes** (CI run 38705502949) |
| CL-02 | Widget tests at phone (412x915) and laptop (1440x900, 1920x1080) sizes | Sign-in, greeting, desktop side panel, chat column <= 760 px, 48 dp targets, 4.5:1 contrast | All pass in CI | Pass. Earlier local failures were the 800x600 default test window being shorter than the sign-in form |

Passing integration tests in IT-01 that cover Sprint 2 work: cabin class
preserved on rebooking (Fix 5), confirmed booking refused and audited,
cancelled-target rejection audited, vouchers written once per type with stable
codes and an `ENTITLEMENTS_ISSUED` audit row, and policy-store ordering on the
120 ingested clauses.

## 6. End-to-end agent runs (FR-02, FR-03, FR-04, FR-05)

Passenger A27Z99 (Edwards): GOLD tier, business seat 5G on KQ886 NBO-BKK,
cancelled for a TECHNICAL reason. REST tier, agent CLI, Gemini and Supabase
all live; results checked afterwards in the database. 9 Oct 2026, ~01:00.

| ID | Request | Expected | Actual | Result / correction |
|---|---|---|---|---|
| E2E-01 | "What am I entitled to now that my flight was cancelled?" | Agent calls `get_entitlements_tool` and reports only its output: re-routing, meal voucher, 3,000 goodwill points (GOLD, controllable cause), hotel to be decided on rebooking, no EU261 compensation (NBO departure, non-Community carrier) | Exactly that, including the Art. 3(1) reason for no compensation | Pass |
| E2E-02 | "Rebook me on the next available flight" | Search, then rebook with a returned id; business seat; old seat released; vouchers issued and reported | Rebooked to KQ886 next day, seat **1C BUSINESS**; 5G back to AVAILABLE; vouchers KQ-MV-0496-VC (4 meals x KES 2,500), KQ-HT-4836-FG (1 night), KQ-TR-0426-JQ (transfer), KQ-AP-4395-UF (3,000 pts); audit rows AUTOMATED_REACCOMMODATION (cabin BUSINESS) then ENTITLEMENTS_ISSUED, actor PASSENGER:A27Z99 | Pass on data. **Defect:** the reply gave the departure as "13:21", which is UTC; local Nairobi time is 16:21. Corrected: the API now returns `departure_local` / `arrival_local` in each airport's time zone, and only those reach the model |
| E2E-03 | "Can I bring my pet parrot in the cabin?" | Answer from KQ CoC Art. 8.9 (Animals: "dogs, cats, household birds and other pets") - or hand off if not retrieved | Retrieval ranked **KQ CoC Art. 8 (part 5)**, which contains 8.9, first - but at similarity **0.6645**, below tau = 0.75, so the question was handed off (case #2, LOW_SIMILARITY) | **False hand-off.** Retrieval was right; the threshold was wrong. Question-to-clause similarities sit around 0.6-0.7, lower than clause-to-clause (~0.84), so tau = 0.75 is too strict, not too lenient as first assumed (PC-06). Resolved by calibrating tau on the labelled question set (Section 7) |
| E2E-04 | Response time of E2E-01..03 | NFR-01: a full agent turn within 15 s | Observed by the operator as slow; not measured | Corrected: each turn now records model and tool times (`[TIMING]` line); `thinking_level` set to `low`; the rebooking tool returns its vouchers so a rebooking needs one model call fewer; tool payloads trimmed to the fields the model uses. To be re-measured |

## 7. Performance (PF)

Measured with `scripts/measure_latency.py` (report: `docs/sprint-2/performance/0-baseline.md`)
on the workstation over a phone hotspot, REST tier and agent service local, Supabase in
eu-central-1 (Frankfurt). Booking A27Z99 (Edwards, DISRUPTED). REST calls x10 and assistant
questions x3 (15 s apart), times in ms as p50 / p90. The REST tier's own Server-Timing is
within a few ms of what the client waited, so the time is spent inside the API, almost all of
it on round trips to the database.

| ID | Test | Expected | Actual | Result / correction |
|---|---|---|---|---|
| PF-01 | Baseline `GET /api/me`, 18 Oct 13:10 | Recorded (target after Phase 2: p50 < 400) | 632 / 748 | Baseline |
| PF-02 | Baseline `GET /api/flights/alternatives` | Recorded | 626 / 642 | Baseline |
| PF-03 | Baseline `GET /api/entitlements` (two queries in sequence) | Recorded | 1,024 / 1,031 | Baseline |
| PF-04 | Baseline `GET /api/handoff` | Recorded | 701 / 772 | Baseline |
| PF-05 | Baseline assistant "What are my options?" (`gemini-3.6-flash`, thinking low) | Recorded (target after Phase 3: first words < 2 s, 90% of answers < 6 s) | 7,123 / 7,469; first words p50 2,580; 2 model calls each | Baseline |
| PF-06 | Baseline assistant "What am I entitled to?" | Recorded | 7,737 / 8,386; first words p50 3,135 | Baseline |
| PF-07 | Baseline assistant "Can I get a refund instead?" | Recorded | Not measured: all three runs **429 RESOURCE_EXHAUSTED** (free tier `generate_content_free_tier_requests`, limit 20, `gemini-3.6-flash`: exactly 20 model calls had succeeded today, so this is the daily quota). The first, unpaced attempt (13:05) also hit the per-minute limit after 6 calls; its one completed refund turn took 11,407 ms | The script now spaces questions 15 s apart (`--chat-pause`) for the per-minute limit. Live assistant measurements in later phases are kept few, and compared within one run on the same model |

Start-up of the website (Phase 1). Release build served by `.\tasks.ps1 web`
(`scripts/serve_web.py`). "First screen" is `window.kestrelFirstFrameMs`, recorded by
`web/index.html` on Flutter's `flutter-first-frame` event. Measured in **headless Chrome 155**
(puppeteer-core driving the installed Chrome, 1280 x 576): first visits in a fresh profile
(x3), repeat visits by reloading (x7). The interactive Chrome window first used for this was
found to be drawing about one frame a second (two idle `requestAnimationFrame`s took 2 s:
the window was occluded or the display asleep), which inflated every frame-based time taken
in it (4.8-7.7 s first visits) and also made the WebAssembly build look slower than it is;
those readings are discarded. No start-up measurement was taken before Phase 1.

| ID | Test | Expected | Actual | Result / correction |
|---|---|---|---|---|
| PF-08 | First paint: the branded loader in `index.html` (inline HTML/CSS only) | Immediate | First contentful paint 187-206 ms (Lighthouse; 1,341 ms on its very first run) | Pass |
| PF-09 | Requests to `gstatic.com` / `fonts.googleapis.com` while the page starts | None | **0** external requests (17 in all, Lighthouse; none in the screen tour either); fonts (Inter, JetBrains Mono, Roboto fallback) and the renderers all from the site | Pass. Before: Inter and JetBrains Mono were fetched by `google_fonts` at run time, CanvasKit from the CDN |
| PF-10 | Time to first screen, **WebAssembly** build (kept in `tasks.ps1 web`) | < 2 s | First visit median **852 ms** (772-1,398); repeat visit median **294 ms** (278-343) | Pass |
| PF-11 | Time to first screen, JavaScript build (other browsers) | < 2 s | First visit median 1,655 ms (1,550-1,733; a second run 1,254-2,461); repeat visit median 590 ms. Lighthouse desktop (cache cleared, no simulated throttling): Speed Index 2.5-4.5 s, Time to Interactive 2.4-4.5 s | Pass in Chrome's own timing; Lighthouse's time-to-interactive above 2 s. Defects found and fixed while measuring: (1) `serve_web.py` gzipped on first request (CanvasKit took 5.2 s): now all compressed at start-up; (2) it listened on IPv4 only and browsers try `localhost` over IPv6 first (200 ms per connection in curl): now both; (3) Flutter's default `flutter_bootstrap.js` registers its deprecated service worker and waits up to 4 s for it: a custom bootstrap starts the app at once |
| PF-12 | `flutter build web --wasm` and every screen in Chrome | Builds; every screen works | Builds. Screen tour of the WebAssembly build (headless): Home, Help, sign-in, guest sign-in, My trip, Flights, Confirm, Vouchers, Help, Assistant, sign-out, staff desk with its cases (a test staff key given to a local API instance; the real key was not used) - **no page errors, no external requests**. With COOP/COEP (second render thread) no faster: first visit median 1,032 ms, repeat 285 ms | Pass: `--wasm` kept in `tasks.ps1 web`, without COOP/COEP |
| PF-13 | Staff desk loaded only when staff sign in (deferred library) | Not downloaded by passengers | JavaScript build: passenger session (sign-in, all five sections) never requested `main.dart.js_1.part.js`; staff sign-in submitted: requested once, 15 KB. WebAssembly build: dart2wasm keeps the deferred library inside `main.dart.wasm` | Pass for the JavaScript build; not split in the WebAssembly build (which still starts faster) |

Instant screens (Phase 2). REST times by `scripts/measure_latency.py --chat-runs 0` (report:
`docs/sprint-2/performance/2-warm-pool-trip-endpoint-gzip.md`), x10, p50 / p90 in ms; section switches in headless
Chrome as above (click to the frame that shows the section).

| ID | Test | Expected | Actual | Result / correction |
|---|---|---|---|---|
| PF-14 | `GET /api/trip`: booking, top five alternatives, entitlements, cases, suggestions; four queries at once on four pooled connections | p50 < 400 | **393 / 404** (a first run 395 / 401) | Pass. Replaces four calls that took 632 + 626 + 1,024 + 701 ms at baseline |
| PF-15 | Single endpoints after the pool changes (no reset round trip on release) | p50 < 400 | `/api/me` **391** (632); `/api/handoff` **393** (701); `/api/flights/alternatives` 406 (626); `/api/entitlements` 787 (1,024: two queries in sequence, unchanged; the client no longer calls it) | `/api/me`, `/api/handoff` pass; alternatives 6 ms over; entitlements over. The floor from the workstation is one query = two round trips to Frankfurt (~390 ms) |
| PF-16 | First `/api/trip` after the REST tier starts | No connect cost | With `min_size=3`: **4,837 ms** (the fourth connection opened on demand). With four connections ready: **409 ms** | Pass after correction: `POOL_MIN_SIZE = 4` (the prompt said 3) and a `SELECT 1` on the ready connections every 60 s, because asyncpg closes connections idle for 5 minutes even within `min_size` |
| PF-17 | Section switch (My trip, Assistant, Flights, Vouchers, Help), 15 switches x 2 runs | < 300 ms, no request | Median **117-127 ms**, max 159-165 ms; **0** API requests | Pass |
| PF-18 | Guest sign-in to My trip with data (headless) | Recorded | 661 ms (sign-in 430 ms, then `/api/trip` 399 ms; the layout and skeletons show after the first) | Recorded |

Faster, smarter assistant (Phase 3). `scripts/measure_latency.py` with `--stream-runs`,
`--quick-runs` (reports `docs/sprint-2/performance/3a-streaming-and-quick-replies.md`, `3b-model-client-reuse-parallel-entitlements.md`). The
baseline model `gemini-3.6-flash` had used its free daily quota (PF-07); `gemini-3.5-flash` is
served from the same quota, so these runs used **`gemini-3.8-flash`** (also free tier, 20 a
day), thinking level low, few runs each. Model-free paths (quick replies) were run x10.

| ID | Test | Expected | Actual | Result / correction |
|---|---|---|---|---|
| PF-19 | Quick replies (`intent`, tool only, no model): "Find me another flight", "What am I entitled to?" | < 1 s | p50 **421 / 425 ms** (p90 444 / 1,118: two slow round trips to Frankfurt); model calls 0 | Pass. Before: the same questions went through the model, 7.1 / 7.7 s (PF-05, PF-06) |
| PF-20 | "What are my options?" / "What am I entitled to?" answered from CONTEXT | One model call | 1 model call each (baseline: 2, with `find_alternative_flights_tool` / `get_entitlements_tool`); agent time 3.6-5.7 s | Pass |
| PF-21 | Streamed replies: first words | < 2 s | p50 **3.7-6.3 s** (`gemini-3.8-flash`): the model writes its short answer only after its thinking step, so the first `delta` comes near the end | **Not met.** Streaming works (status lines from the first tool, words as they come); the wait is the model's. Instant answers come from quick replies and the deterministic briefing (Phase 4) |
| PF-22 | Full answers | 90% < 6 s | Options 5.5-6.6 s, entitlements 3.7-6.0 s, refund question 9.7-14.5 s (two model calls + policy search) | **Not met** for the refund question on this model today; one model call of the refund turn took 9.6-19.6 s |
| PF-23 | Policy search: question vector cache, keep-alive embedding client, common questions pre-embedded at start-up | Second ask makes no embedding call | Unit tests: a repeated question makes one HTTP call; 10 common questions embedded in one request at start-up (`[INFO] Pre-embedded 10 common policy questions.`) | Pass |
| PF-24 | Speculative policy search | Reused when the model asks the same question | Unit tests: one `/api/policy/search` call for the turn (with `handoff=false`); a different question gets its own; an out-of-scope result is not reused, so the case is still opened | Pass |
| PF-25 | Two corrections found while measuring | - | (1) `get_llm()` built a new Gemini client every turn: now one per process, prepared when the agent service starts (the first turn after a restart had ~3 s of import and connection); (2) `GET /api/entitlements` read the booking and the vouchers one after the other: now at once - **410 ms** (was 787-1,024) | Corrected |

Intelligent features (Phase 4; `docs/design/assistant-intelligence-features.md`). REST x10 and quick replies x10
(`docs/sprint-2/performance/4-recommendations-suggestions-memory.md`; the hotspot was noisy, p90 up to 1-2 s; p50 shown).

| ID | Test | Expected | Actual | Result / correction |
|---|---|---|---|---|
| PF-26 | `GET /api/trip` with reasons, badges, `wait_hours` and `includes` on each alternative | No slower than Phase 2 | p50 427 ms (Server-Timing 423; Phase 2: 393) - the explanation is a pure function | Pass. Live example (A27Z99): KQ886 `EARLIEST_ARRIVAL`, `NEXT_DAY_HOTEL`; "Leaves on a later day, so 2 hotel nights and airport transfers come with it." - the rules engine's answer for that option |
| PF-27 | "Kestrel recommends" on My trip and as the assistant's first message | Instant, no model, no extra request | Built in the client from the trip already loaded; live text: "Your best option is KQ886 today at 16:26 - the earliest arrival in Bangkok, 28 seats left. You're owed 4 meal vouchers, 2 hotel nights, transfers and 3,000 Asante points." + **Review and confirm** | Pass |
| PF-28 | Quick replies with conversation memory saving each turn | Still < 1 s | p50 408 / 412 ms: the turns are saved after the reply (after `done`; a background task for `/api/chat`) | Pass |
| PF-29 | Measurement side effect found: the agent service saved every measured turn to the demo booking's conversation | - | 86 test messages on A27Z99 (deleted); `measure_latency.py` now deletes what a run added when the booking had no saved conversation before | Corrected |

## 8. Review fixes, 18 Oct (security and correctness)

From `docs/sprint-2/ai-code-review/issues-found-and-fixed.md`. Unit tests need no database; IN = integration (live
Supabase, rolled back).

| ID | Issue | Test | Expected | Result |
|---|---|---|---|---|
| RV-01 | #1 | `test_reference_and_surname_of_someone_else_signs_in_without_linking` | Reference + surname of another passenger's booking: token for that booking, `linked: false`, no link row, no audit | Pass |
| RV-02 | #1 | `test_reference_and_surname_under_the_verified_email_links`, `test_case_of_the_email_does_not_matter` | Linked only when the passenger's email equals the verified email (case-insensitive); `ACCOUNT_LINKED` audited | Pass |
| RV-03 | #1 | `test_unlink_removes_only_the_signed_in_accounts_link_and_audits_it`, `..._without_a_link_...`, `..._needs_a_valid_account_token` | `DELETE /api/auth/account/link` removes only the id Supabase vouches for; `ACCOUNT_UNLINKED` audited; bad token 401, no query | Pass |
| RV-04 | #2 | IN `test_flight_on_another_route_is_refused_and_audited` | Procedure refuses another route's flight, audit reason `DIFFERENT_ROUTE`, booking unchanged | Pass |
| RV-05 | #2 | `test_flight_on_another_route_is_409_with_the_procedures_message`, `test_a_flight_on_another_route_is_refused_and_the_model_is_told_why` | 409 with the procedure's message and `X-Refusal-Reason: DIFFERENT_ROUTE`; the agent tool returns `DIFFERENT_ROUTE`, "Nothing was changed" | Pass |
| RV-06 | #3 | `test_ten_guesses_at_once_reach_the_database_at_most_five_times` | 10 concurrent wrong guesses (`asyncio.gather`) → ≤ 5 lookups, the rest 429 | Pass (before: 10 lookups) |
| RV-07 | #31 | `test_concurrent_account_guesses_...`, `test_one_account_cannot_try_many_bookings` | Same limit on `/api/auth/account`, per booking and per account | Pass |
| RV-08 | #4 | `test_choosing_a_flight_after_the_offer_is_not_a_handoff` | "yes the first one", "ok KQ116 please", "please book the first flight" → not a hand-off; "yes please", "ok, connect me" → hand-off | Pass |
| RV-09 | #5 | `test_the_briefing_is_fetched_on_every_turn`; Flutter "a rebooking on the Confirm page rewrites the untouched greeting" | `/api/trip` on every turn; no stale "Shall I book it?" after a rebooking | Pass |
| RV-10 | #6 | `test_the_staff_queue_is_newest_first`; Flutter staff desk test | Newest first; the desk asks `OPEN` and `RESOLVED`, never `ALL` | Pass |
| RV-11 | #7, #8 | `test_repeating_a_short_reply_is_not_a_repeat`, `test_three_chip_taps_are_not_an_earlier_signal`, `test_a_policy_answer_counts_as_shown` | Short replies and chip taps are not frustration; the refund chip is not offered again right after its answer | Pass |
| RV-12 | #9 | `test_a_second_signal_with_a_case_already_open_reminds_instead_of_a_new_case` | No second case; a reminder naming the open case | Pass |
| RV-13 | #10 | `test_policy_search_embeds_before_taking_a_connection` | Embedding before `pool.acquire()`; `max_retries=0` | Pass |
| RV-14 | #11 | `test_successful_turn_is_logged_with_timing`, `test_tool_results_are_never_printed` | No message text in the turn log; no tool results or voucher codes on the console | Pass |
| RV-15 | #12 | `test_a_passenger_token_cannot_store_an_assistant_turn`, `test_without_a_configured_key_...`, `test_both_turns_are_saved_after_the_reply` | `role: assistant` needs `X-Agent-Key` (403 otherwise); the agent service sends it on assistant turns only. 100-turn cap: migration 012 trigger (applied 18 Oct) | Pass |
| RV-16 | #13 | `test_the_answer_does_not_change_with_the_day_you_ask` | Compensation decided from `flights.cancelled_at`, the same 15 days or 1 hour before departure | Pass |
| RV-17 | #14 | `test_hand_off_replies_say_only_what_staff_can_see` | "They can see your booking and your last question" | Pass |
| RV-18 | #15 | `test_the_issue_endpoint_is_gone` | `POST /api/entitlements/issue` 404/405 | Pass |
| RV-19 | #16 | `test_codes_have_four_letters`, `test_a_clashing_code_is_retried_with_fresh_codes`, `..._after_three_tries` | `KQ-XX-0000-ABCD`; a clash retried with new codes | Pass |
| RV-20 | #17 | `test_keep_warm_survives_any_error` | Still running after `InterfaceError` and `TimeoutError` | Pass |
| RV-21 | #20 | `test_open_case_locks_the_booking_before_it_looks` | `SELECT ... FOR UPDATE` first in the transaction | Pass |
| RV-22 | #21 | `test_only_whole_rights_words_start_a_speculative_search` | No search for "cancelled", "alright", "careful", "delay" | Pass |
| RV-23 | #22 | `test_a_network_error_is_an_embedding_error` | `httpx.HTTPError` → `EmbeddingError` (502) | Pass |
| RV-24 | #25 | `test_an_earlier_flight_says_before_not_minus` | "48 hours before your original flight" | Pass |
| RV-25 | #26 | IN `test_statement_prepares_against_the_live_schema` | Skips naming migration 009/010/012 when its table or column is missing | Pass |
| RV-26 | #30 | `test_one_http_client_serves_every_sign_in` | One client to Supabase for every sign-in | Pass |
| RV-27 | #34, #38 | `test_city_names_and_the_date_format_have_one_copy_each`; Flutter "airport names come from the server" | One date formatter; one airport list (`kestrel/airports.py`, sent as `cities`) | Pass |
| RV-28 | #36 | `test_the_login_limit_dictionary_does_not_keep_every_guess` | Checking stores nothing; stale keys swept | Pass |
| RV-29 | #37 | `test_a_slow_rebooking_is_not_cut_off_at_ten_seconds` | Agent HTTP read timeout ≥ 30 s | Pass |
| RV-30 | #39 | `test_each_request_is_logged_with_ids_masked_and_no_query` | Unmatched paths keep only the app's own words; an all-letter reference is masked | Pass |
| RV-31 | - | Flutter "assistant bubbles drop Markdown bold markers" | No `**` shown in replies (plus a plain-text rule in the prompt) | Pass |

## Pending in this sprint

- Re-measure agent response time after the latency changes (E2E-04).
- Retrieval evaluation and tau calibration on the labelled question set.
- Flutter client acceptance runs.
- PF-05/06/07, PF-21/22 like-for-like on `gemini-3.6-flash` once its daily quota allows
  (`scripts/measure_latency.py --stream-runs 3 --quick-runs 10`).
- `docker build -f deploy/Dockerfile .` on a machine with Docker (not installed on the
  workstation); then the Frankfurt deployment (`deploy/README.md`).
