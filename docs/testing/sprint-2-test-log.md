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
| IT-02 | Regression guard added: every `SQL_*` statement in the REST tier (20) is prepared against the live schema | All 20 prepare | 20 prepare cleanly on the rebuilt schema (local) | Pass locally; to be confirmed on the workstation in the next `test-all` |

Passing integration tests in IT-01 that cover Sprint 2 work: cabin class
preserved on rebooking (Fix 5), confirmed booking refused and audited,
cancelled-target rejection audited, vouchers written once per type with stable
codes and an `ENTITLEMENTS_ISSUED` audit row, and policy-store ordering on the
120 ingested clauses.

## Pending in this sprint

- Re-run `tasks.ps1 test-all` after the hand-off fix (expect 142 passed).
- End-to-end agent runs for PNR A27Z99 (business, GOLD, KQ886 TECHNICAL):
  entitlements question, rebooking, out-of-scope question.
- Retrieval evaluation and tau calibration on the labelled question set.
- Flutter client acceptance runs.
