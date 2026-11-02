# Sprint 2 review — Core functionality, evaluation and the Kestrel Web client

Prepared 30 October 2026. Covers Sprint 2 (25 September – 30 October 2026) and the four things the
Sprint II review brief asks to see: versioned code, a reproducible baseline or core pipeline, saved
experiment evidence, and one AI suggestion that was checked.

Requirement IDs are those in Chapter 3. The full requirement-to-evidence map is
[`docs/traceability.md`](../traceability.md).

---

## The one-line framing

> "Sprint 2 turned the Sprint 1 database into a working system — policy retrieval, entitlement
> rules, atomic rebooking, the assistant and the web client — and then measured it: the retrieval
> criteria are met on a held-out test set, and the hand-off threshold is calibrated rather than
> assumed."

---

## 1. Sprint 2 backlog: planned vs delivered

The backlog proposed at the end of Sprint 1:

| # | Planned | Delivered | Evidence |
|---|---|---|---|
| 1 | Own repository, history preserved | **Done** (1 Oct) | [01-standalone-repository-and-dataset-v2.md](01-standalone-repository-and-dataset-v2.md) |
| 2 | Commit the base schema; rebuild from nothing | **Done** | `db/migrations/000_base_schema.sql`; migrations 000–012 in [db/README.md](../../db/README.md) |
| 3 | Fix 5: cabin class enforced in the rebooking procedure | **Done** | Migration 004; `test_cabin_class_is_preserved` |
| 4 | FR-02: policy corpus and pgvector retrieval | **Done**: 120 clauses (KQ Conditions of Carriage, EU261, Montreal Convention). KCAA rules are not in the corpus | Migration 005; test log §2 |
| 5 | FR-04: deterministic entitlement rules | **Done**, kept separate from retrieval | `src/kestrel/entitlements.py`; 27 rule tests |
| 6 | Endpoint tests through FastAPI's `TestClient` | **Done** | `tests/unit/test_endpoints.py` and others |
| 7 | Backlog in GitHub Issues | **Not done**: the backlog and status were kept in `docs/` instead | `docs/sprint-3/00-status.md` |

Added during the sprint, beyond the plan:

- **The assistant** (agent service): Gemini with five tools and no database credentials; quick replies,
  streamed answers, conversation memory, "Why this flight?", suggestions and a frustration hand-off.
- **Kestrel Web**, the Flutter web client: public site, sign-in (booking reference + surname, Google, emailed
  code), trip, flights, confirm, vouchers, help and the staff desk; one responsive layout for laptops and phones.
- **Same-route rule** in the database (migration 011, refusal `DIFFERENT_ROUTE`), **cancellation time**
  recorded (migration 012).
- **AI code review** of the whole codebase (18 Oct) and the fixes for the issues it found.

## 2. The four things the review asks for

### Versioned code
- Repository `Bill-Ritchie88/kestrel`, branch `main`. 56 commits since 25 September, all under my account,
  one feature per commit, each with a message saying what and why.
- CI on every push: lint, unit tests, Flutter analyze/test/build, and a secret scan. Green on the latest
  commit.
- Dependencies pinned in `requirements.lock.txt`, so a new upstream release cannot change the test
  environment (this happened on 29 Oct and is how the lock file came about).

### A reproducible baseline / core pipeline
Every step is a script with a `tasks.ps1` target (`make` on Linux/macOS):

| Step | Command | What it does |
|---|---|---|
| Data | `.\tasks.ps1 data` | Seeded synthetic dataset (`--seed 42`): flights, seats, passengers, bookings |
| Policy corpus | `.\tasks.ps1 ingest` | Embeds the 120 policy clauses into pgvector |
| Evaluation | `.\tasks.ps1 evaluate` | Recall@3, τ sweep, test-split metrics and 5-fold cross-validation |
| Tests | `.\tasks.ps1 test-all` | 302 Python tests (unit + integration against Supabase, rolled back) |
| Load test | `.\tasks.ps1 loadtest` | Concurrent rebooking on a self-cleaning test fixture |
| Run | `.\tasks.ps1 start` then `.\tasks.ps1 web` | REST tier, assistant and the release web build on http://localhost:8080 |

**Baseline → measured improvement:** the hand-off threshold started at the fixed value τ = 0.75. On the
held-out test questions that gives F0.5 = 0.603 and hands 77 % of answerable questions to a person.
Calibrated on the calibration split, τ = 0.66 gives F0.5 = 0.918 (§3).

### Saved experiment evidence

| Evidence | File |
|---|---|
| Retrieval evaluation and τ calibration, with per-question scores | [03-retrieval-evaluation.md](03-retrieval-evaluation.md), [scores CSV](03-retrieval-evaluation-scores.csv) |
| Load test (NFR-01, NFR-03), with every run | [04-load-test.md](04-load-test.md), [runs CSV](04-load-test-runs.csv) |
| Performance, phase by phase | [performance/](performance/) (baseline, phases 2–4) |
| Every test run, with expected and actual results | [02-test-log.md](02-test-log.md) |
| AI code review and the fixes | [ai-code-review/](ai-code-review/) |

### One AI suggestion that was checked
In full in the [AI-use log](05-ai-use-log.md): an AI code review found that signing in with Google and then
entering a booking reference and surname linked that account to the passenger permanently, with no email
check. I confirmed it in the code, **accepted** the fix (link only on a matching verified email; unlink;
audit) and **rejected** the suggestion to email the passenger on every link (no mail service; the email match
already removes the risk). Commit `0b680cb`; tests RV-01 to RV-03. Ten other checked suggestions are tabled
in the same log.

## 3. Results

### Retrieval and the scope guard (NFR-04, FR-05)
88 hand-labelled questions: 44 for calibration, 44 held out for testing.

| Measure (held-out test split) | Result | Criterion | |
|---|---|---|---|
| Recall@3 | **0.967** (29 of 30 answerable questions) | ≥ 0.85 | Met |
| F0.5 of the scope guard at τ = 0.66 | **0.918** (precision 0.906, recall 0.967) | ≥ 0.80 | Met |
| F0.5 at the starting τ = 0.75 | 0.603 | — | Baseline |
| τ over 5-fold cross-validation | 0.668 ± 0.011 | — | Stable |

Errors at τ = 0.66 on the test split: one answerable question handed off (refund to the same card); three
out-of-scope questions answered (change destination to Paris, a prompt-injection "free upgrade", food through
airport security). The first two are still refused by code: the database rejects another route
(`DIFFERENT_ROUTE`) and no tool can grant an upgrade. 44 test questions is a small sample.

### Concurrency and integrity (NFR-01, NFR-03)
Run 30 October on a self-cleaning synthetic fixture (S = N / 2 free seats), 10 runs per size; every
fixture was deleted afterwards. Details and every run in [04-load-test.md](04-load-test.md).

| Measure | Result | Criterion | |
|---|---|---|---|
| Seats held by two bookings (all 40 runs) | **0** | 0 | Met |
| Successful allocations = S (all 40 runs) | **Yes** | min(N, S) | Met |
| Seat conservation (all 40 runs) | **Yes** | BOOKED seats = bookings holding a seat | Met |
| Deadlocks (all 40 runs) | **0** | 0 | Met |
| Integrity runs passing every check | N = 50: 10/10 · N = 100: **9/10** · N = 200: 10/10 | 10/10 | One failure, explained below |
| API p95, 50 concurrent `POST /api/reaccommodate` | **10.1 s** (p50 7.8 s) | ≤ 1.0 s | **Not met** |

- **N = 100, run 3:** one of the 100 calls lost its connection on the mobile hotspot before reaching the database,
  so 99 audit rows instead of 100. The database was consistent with the 99 completed calls (no partial state).
  Counted as a fail, not rerun.
- **API latency:** every API run was still correct (25 rebooked, 25 refused), but slow. The server's own timing
  matches the client's within 100 ms, so the time is inside the REST tier: 50 requests queue for its 10 database
  connections, and each rebooking makes about 8 round trips from Nairobi to the database in Frankfurt. Nothing was
  tuned to pass. The deployed service runs in Frankfurt; the API test is to be repeated there.
- The database saw at most 10 calls at a time (the free pooler's limit), not N simultaneous sessions; all N requests
  were in flight at once from the client.

### Response time (NFR-01, NFR-02)

| What the passenger does | Before | After | Change |
|---|---|---|---|
| Open the trip (all booking data) | 4 calls: 632 + 626 + 1,024 + 701 ms (p50) | 1 call, `/api/trip`: **393 ms** (p50) | One round trip instead of four |
| Tap a quick reply ("Find me another flight") | 7.1 s, through the model | **0.42 s**, no model call | 17× faster |
| Ask a typed question | 7–8 s | 4–8 s, words streamed as they arrive | **NFR-02 not met** on the free Gemini tier |

Measured on the workstation in Nairobi against Supabase in Frankfurt; not yet on the deployed service.

### Automated tests
302 Python tests (unit and integration) and 74 Flutter widget tests pass; CI green.

## 4. Changes of scope this sprint

| Change | Why | Effect on the report |
|---|---|---|
| The Android app (Kestrel App) was dropped on 29 Oct; **Kestrel Web** is the only client | Google Play registration costs money the project does not have | Chapter 1 and every "app and website" mention: one responsive web application for desktop and mobile browsers; a store app is future work |
| Hosting: Kestrel Web on **Cloudflare Pages**, back end on **Render** (free tier, Frankfurt), Cloudflare Tunnel as backup | $0 cost, no credit card | Replaces the Cloud Run plan in Chapter 3 |
| Sign-in widened from booking reference + surname to also Google and emailed code | Passengers can return without the reference | New requirement rows in Chapter 3; migration 009 |

## 5. Open items — say these before they are asked

- **Not deployed yet**; all measurements so far are on the workstation.
- **NFR-01 (API p95 ≤ 1.0 s) not met** on the workstation: 10.1 s under 50 concurrent rebookings (§3).
- **NFR-02 (typed questions ≤ 10 s) is only partly met:** quick replies answer in 0.4 s, but a typed question
  waits for the free Gemini tier (4–8 s, sometimes longer, and about 20 requests a day).
- **KCAA consumer rules are not in the policy corpus**: questions about them are handed off.
- **No usability test with real users yet.**
- **No account deletion** — only unlinking a booking from an account.
- The assistant can rebook when asked for "the next available flight" without a separate confirmation step;
  the web Confirm screen does ask. Needs a decision.
- No per-user rate limit on the chat endpoints (sign-in is throttled).
- GitHub Issues were not used for the backlog (planned item 7).

## 6. Proposed Sprint 3 backlog

1. Deploy: back end on Render, Kestrel Web on Cloudflare Pages, tunnel backup; test every screen live.
2. Usability test with 3–5 representative users: task success, SUS, problems found and fixes.
3. Confirmation before the assistant rebooks; per-user rate limit on chat; pin the Gemini model in config.
4. Account deletion (web), with what audit data is kept stated.
5. Report: Chapters 4–6, diagrams (architecture, ERD, deployment), results, handover document.

## Before the meeting — run these

```powershell
.\tasks.ps1 start        # REST tier :8000 and assistant :8001
.\tasks.ps1 web          # Kestrel Web on http://localhost:8080
.\tasks.ps1 test         # unit tests, no database needed
.\tasks.ps1 evaluate     # retrieval evaluation (about 2 minutes)
```
Demo bookings: ZPEJBL / Mueller (Mombasa, several flights), UNGMR3 / Martinez, QW3UYQ / Ferguson (New York).
