# Kestrel handover

Project Kestrel is an agentic AI assistant that helps Kenya Airways passengers whose flight has been cancelled. It explains what they are entitled to, issues vouchers and Asante Rewards points, and rebooks them on another flight. The rule throughout is that the AI decides and the code enforces: the language model only requests actions, and the REST tier and the database decide whether they happen.

- **Author:** Otieno Bill Ritchie (163362), Strathmore University, ICS 4C
- **Supervisor:** Mr. Kelvin Ouma
- **Repository:** github.com/Bill-Ritchie88/kestrel (branch `main`)
- **State on 10 November 2026:** deployed and tested live; seat selection (FR-16) and the load test against Render added since the 5 November presentation

This is a research prototype. It is not an official Kenya Airways service, and all passenger data is synthetic.

## 1. Live system

| Part | Address | Host |
|---|---|---|
| Kestrel AI assistant (web app) | https://kestrel-web-a20.pages.dev | Cloudflare Pages |
| REST tier | https://kestrel-myd3.onrender.com (`/health`) | Render free web service, Frankfurt |
| Assistant service | https://kestrel-agent.onrender.com (`/health`) | Render free web service, Frankfurt |
| Database and sign-in | Supabase project `Project-Kestrel` | Supabase, eu-central-1 (Frankfurt) |

### Free-tier behaviour

- **Render:** both services sleep after 15 minutes without traffic. The first request then takes about a minute while they wake. Before a demo, open both `/health` pages.
- **Gemini:** the free tier allows about 20 model requests a day. The quick-reply buttons do not call the model; typed questions do.
- **Supabase:** the free tier pauses a project after about a week without activity. Restore it from the Supabase dashboard.

### Demo data (10 November 2026)

- Flight KQ606, Nairobi to Mombasa, 11:45 on 30 November, is cancelled with a technical problem.
- It has 8 disrupted economy bookings: KX4T7P Wanjiru, KW8R2M Otieno, KR6N3D Akinyi, KM9V5H Mwangi, KJ2P8W Chebet, KF7L4B Kiprop, KH3Q9T Njeri and KD5Z6R Kamau. None is rebooked yet.
- Later the same day: KQ608, KQ610, KQ612 and KQ614. The Kestrel Recommends card shows the earliest same-route flight, which is now on an earlier day (KQ600 on 11 November), because KQ606 sits on the last day of the schedule.
- `.\tasks.ps1 reset` re-anchors the whole schedule and cancels the three busiest flights instead, so it does **not** recreate this KQ606 set-up. Use it only after the presentation.
- The staff desk is signed into with the shared staff key (`STAFF_API_KEY`).

## 2. Architecture

See `diagrams/architecture.png`, `diagrams/deployment.png`, `diagrams/erd.png` and `diagrams/sequence-rebooking.png`.

1. **Kestrel Web** (`kestrel_client/`) is a Flutter app built to WebAssembly. It works in laptop and phone browsers. It has screens for sign-in, trip, assistant, flights, seat map, vouchers and help, plus the staff desk.
   - **Seat map (FR-16):** after choosing a flight, the passenger sees the cabin as a grid with aisles and a legend (free, taken, selected), picks a seat or taps **Let Kestrel choose**, and the Confirm screen shows the seat. If someone takes the seat first, the app says "That seat was just taken. Please pick another", reloads the map and stays on it.
2. **The assistant** (`src/kestrel/agent_service.py`, `src/kestrel/agent/`) uses FastAPI, LangChain and Gemini.
   - It has five tools:
     - find alternative flights;
     - rebook;
     - search policy;
     - get entitlements;
     - hand off to a person.
   - Its other features are quick replies, streamed answers, conversation memory and a hand-off when the passenger is frustrated.
   - It holds no database credentials. It calls the REST tier with the passenger's bearer token.
3. **The REST tier** (`src/kestrel/api/main.py`) uses FastAPI and asyncpg. Its jobs are:
   - signed session tokens (HMAC-SHA256);
   - same-route alternatives;
   - policy retrieval with the scope guard (τ = 0.66);
   - deterministic entitlement rules (`src/kestrel/entitlements.py`) that issue vouchers;
   - hand-off cases and the staff queue.

   | Endpoint | Requirement | Purpose |
   |---|---|---|
   | `GET /health` | — | Liveness, database and retrieval status |
   | `POST /api/auth/session` | FR-01, FR-06 | Booking reference and surname → bearer token |
   | `POST /api/auth/account` | FR-01 | Google or email-code sign-in (Supabase), linked once → bearer token |
   | `GET /api/me`, `GET /api/trip` | FR-08 | Booking and flights; the trip screen in one call |
   | `GET /api/flights/alternatives` | FR-03 | Same route, same cabin, seats left |
   | **`GET /api/flights/{flight_id}/seats`** (new) | FR-16 | Seat map of the passenger's cabin on one of their alternatives; any other flight is 404 |
   | `POST /api/reaccommodate/proposal` | FR-17 | The assistant's proposal: the flight and a signed 5-minute, single-use confirmation token; changes nothing |
   | `POST /api/reaccommodate` (**new optional `seat_id`, `confirmation_token`**) | FR-03, FR-07, FR-16, FR-17 | Atomic rebooking and entitlements; a chosen seat taken first is **409 `SEAT_TAKEN`**; from the agent tier only with a valid token (else **403**) |
   | `GET /api/policy/search` | FR-02, FR-05 | Grounded clauses or a hand-off |
   | `GET /api/entitlements`, `GET /api/vouchers` | FR-04 | What the rules give, with reasons; issued vouchers |
   | `GET`/`POST /api/chat/history` | FR-05, FR-08 | Conversation memory |
   | `GET`/`POST /api/handoff` | FR-05 | Passenger or assistant asks for a person |
   | `GET /api/staff/cases`, `POST /api/staff/cases/{id}/resolve` | FR-09 | Staff queue (`X-Staff-Key`) |
4. **The database** is Postgres with pgvector, holding 120 policy clauses: Kenya Airways Conditions of Carriage, EU261 and the Montreal Convention.
   - Row-level security is on for every table.
   - Rebooking happens only inside `reaccommodate_passenger_atomic`. That procedure:
     - locks the booking `FOR UPDATE`;
     - checks that the flight is on the same route and has not departed;
     - takes the first free seat in the cabin with `FOR UPDATE SKIP LOCKED`, or, when the passenger chose one (migration 013, `p_seat_id`), locks that seat `FOR UPDATE NOWAIT` and refuses with `SEAT_TAKEN` if it is booked or locked;
     - writes the audit row.

## 3. Repository layout

| Path | Contents |
|---|---|
| `src/kestrel/` | Python back end: `api/` (REST tier), `agent/` and `agent_service.py` (assistant), `entitlements.py` |
| `kestrel_client/` | Kestrel Web (Flutter) |
| `db/migrations/000–014` | Database schema, procedure, row-level security, policy retrieval, accounts, chat memory, same-route rule, seat selection, prompt version per assistant turn (014, applied to live 11 November 2026) |
| `scripts/data/` | Dataset generator, demo reset, policy ingestion, schema export |
| `scripts/evaluation/` | Retrieval evaluation, load test, latency, smoke test |
| `scripts/ci/` | Secret scan, Flutter annotations |
| `tests/` | 394 Python tests (unit and integration); 93 Flutter tests in `kestrel_client/test/` |
| `deploy/` | Dockerfile (`SERVICE=api` or `agent`) and the hosting guide |
| `docs/` | Sprint records (`sprint-1/`, `sprint-2/`, `sprint-3/`), design, future work, traceability |

## 4. Running it locally (Windows, PowerShell, from the repo folder)

```powershell
.\tasks.ps1 setup        # create .venv and install requirements.lock.txt
# copy .env.example to .env and fill in the values (section 5)
.\tasks.ps1 up           # REST tier on :8000 and assistant on :8001 (two windows)
.\tasks.ps1 web          # Kestrel Web on http://localhost:8080
.\tasks.ps1 down         # stop both services
```

Other targets:

| Command | What it does |
|---|---|
| `.\tasks.ps1 test` | Unit tests |
| `.\tasks.ps1 test-all` | All tests |
| `.\tasks.ps1 lint` | Static analysis |
| `.\tasks.ps1 data` | Regenerate the synthetic dataset (7 days, seed 42) |
| `.\tasks.ps1 reset` | Reset the demo bookings |
| `.\tasks.ps1 ingest` | Re-embed the policy clauses |
| `.\tasks.ps1 evaluate` | Retrieval evaluation (Recall@3, F0.5, τ sweep) |
| `.\tasks.ps1 loadtest` | Concurrency and API load test |
| `.\tasks.ps1 smoke` | End-to-end smoke test |

Flutter tests: `cd kestrel_client; flutter test`.

## 5. Configuration

Settings are read from `.env` locally, and from each service's environment on Render. Never commit `.env`. The variable names are in `.env.example`:

| Variable | Used by | Purpose |
|---|---|---|
| `DATABASE_URL` | REST | Supabase session-pooler connection string |
| `GOOGLE_API_KEY`, `GEMINI_MODEL`, `GEMINI_THINKING_LEVEL`, `GEMINI_MAX_ATTEMPTS`, `GEMINI_TIMEOUT_S` | Assistant | Gemini access. The model is pinned to `gemini-3.6-flash` on Render. |
| `EMBEDDING_MODEL`, `POLICY_TAU` | REST | Query embeddings (`gemini-embedding-001`) and the scope-guard threshold (0.66) |
| `SESSION_SECRET` | REST | Signs session tokens |
| `STAFF_API_KEY` | REST | Staff desk access |
| `AGENT_HISTORY_KEY` | Both | Must be the same on both services, or assistant turns are not saved |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | REST and web build | Google and email-code sign-in |
| `FASTAPI_BASE_URL` | Assistant | Address of the REST tier |
| `ALLOWED_ORIGINS` | Both | CORS: `https://kestrel-web-a20.pages.dev,http://localhost:8080` |

## 6. Deploying

- **Services (Render):**
  - Both are web services from the same repository, using `deploy/Dockerfile`, Frankfurt region. The REST tier has `SERVICE=api` and the assistant has `SERVICE=agent`.
  - A push to `main` redeploys them.
  - Environment changes are made in the Render dashboard and restart the service.
- **Web app (Cloudflare Pages, project `kestrel-web`):**
  - From the repo folder on the laptop, run `.sprint2-tmp\deploy-site.cmd`. It runs `build-site.ps1` (Flutter release build pointed at the two Render services) and then `wrangler pages deploy … --project-name kestrel-web --branch main`.
  - The new version can take a minute to appear at the main address.
- **Database:** apply new files in `db/migrations/` in order, through the Supabase SQL editor or the Supabase CLI.
- **New web address:** if the web app moves to a new address, add it to `ALLOWED_ORIGINS` on both Render services and to the Supabase Auth redirect URLs.

## 7. Measured results (Sprints II and III)

| Measure | Target | Result | Status |
|---|---|---|---|
| Recall@3, policy retrieval (88 questions) | ≥ 0.85 | 0.967 | Met |
| Scope guard F0.5 at τ = 0.66 | ≥ 0.80 | 0.918 (0.603 at the planned τ = 0.75) | Met |
| τ, 5-fold cross-validation | stable | 0.668 ± 0.011 | Met |
| Seat integrity, 40 concurrent runs | 0 double seats | 0 double seats, 0 deadlocks | Met |
| API p95, 50 concurrent rebookings (NFR-01), Sprint II | ≤ 1.0 s | 10.1 s from the laptop | Not met |
| API p95 on Render, 10 / 25 concurrent rebookings (NFR-01), November 2026 | ≤ 1.0 s | 0.40 s / 0.70 s | Met |
| API p95 on Render, 50 concurrent rebookings (NFR-01), November 2026 | ≤ 1.0 s | 1.27 s at the client (server 0.73 s); 0 double seats in 30 runs | Not met at the client |
| Seat selection, 2 and 10 passengers choosing the same seat | exactly 1 succeeds | exactly 1 succeeds, the rest `SEAT_TAKEN`, 0 double seats | Met |
| Trip screen | — | 4 calls → 1 call, 393 ms | Improved |
| Quick replies | — | 7.1 s → 0.42 s | Improved |
| Typed assistant answer (NFR-02) | — | 4–8 s, streamed | Partly met |

The evidence is in `docs/sprint-2/`: `03-retrieval-evaluation.md`, `04-load-test.md` (including "Rerun against Render (November 2026)"), `performance/`, `02-test-log.md` and `05-ai-use-log.md`; seat selection in `docs/sprint-3/02-seat-selection.md`.

At 50 concurrent rebookings the time goes to queueing for the REST tier's pool of 10 database connections and about 210 ms of network between Nairobi and Frankfurt per request. The next steps are one database round trip per rebooking, a bigger pool (Supabase transaction pooler or a paid tier) and a paid Render instance.

## 8. Known limitations and next steps

1. A usability test with 3–5 users is still to be done. The kit (script, sheets, SUS, scoring, test-day bookings) is in `docs/sprint-3/usability/`.
2. NFR-01 is met on Render up to 25 concurrent rebookings, not at 50 (see section 7).
3. Closed (DR-01, NFR-05): "Delete my account data" removes the account link and chat history and keeps bookings and audit logs; until `SUPABASE_SERVICE_ROLE_KEY` is set on the REST tier, the Supabase Auth user is removed by hand (`docs/sprint-3/04-account-deletion.md`). Chat and sign-in are rate limited per token and per IP, in memory per process, so each service must keep one instance and one worker.
4. Closed (FR-17): the assistant only proposes a rebooking; the passenger confirms it on a card in the chat, and the REST tier refuses the agent tier without that confirmation's token. Used tokens are remembered per process, so with several REST replicas a replay is stopped only by the procedure refusing a second rebooking.
5. KCAA consumer protection rules are not yet in the policy corpus.
6. The entitlement amounts are project assumptions pending Kenya Airways confirmation.
7. The free tiers limit speed and the daily number of model calls. A paid plan or a self-hosted model would remove the sleep and the quota.
8. Set up a Cloudflare Tunnel from the laptop as a backup, if the hosted services are unavailable.
