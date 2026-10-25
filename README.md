# Project Kestrel

An agentic passenger re-accommodation system for Kenya Airways. When a flight
is cancelled, a passenger authenticates with their PNR and surname, asks
questions in natural language, and is rebooked onto an alternative flight with
a seat assigned atomically.

The design pairs a non-deterministic LLM with a deterministic transaction
layer. The agent decides what to do; a PL/pgSQL stored procedure decides
whether it is allowed and performs it under row-level locks. The agent has no
database credentials and cannot write to the database except through the REST
tier.

>  No real passenger data is used at any point;
> the entire dataset is synthetic.

---

## Architecture

```
Flutter web client  ->  REST tier (FastAPI, :8000)  ->  PostgreSQL (Supabase)
 client/                 kestrel.api.main              reaccommodate_passenger_atomic
 Home, Help, sign-in,    sign-in, trip, rebooking,     row-level locks, audit_logs
 passenger app,          vouchers, policy search,      pgvector policy clauses
 staff desk              hand-off cases, staff queue
        |                        ^
        |  chat (SSE)            |  HTTP only, the passenger's own token
        v                        |
 Agent service (:8001)  ---------+
 kestrel.agent_service  ->  Gemini (bounded tool loop, no database credentials)
```

The AI decides; the code enforces. The model only proposes a flight or a
question; the stored procedure decides whether a rebooking is allowed (same
route, same cabin, a disrupted booking, a free seat) and the entitlement rules
in `kestrel.entitlements` decide what the passenger gets.

| Part | Where | Responsibility |
|---|---|---|
| Client | `client/` | Home, Help, sign-in (Google, emailed code, booking reference, staff key), the passenger app (My trip, Assistant, Flights, Vouchers, Help) and the staff desk. See `client/README.md`. |
| REST tier | `src/kestrel/api/` | Endpoints, session tokens and login limits (`auth.py`), account sign-in (`accounts.py`), booking and vouchers (`booking.py`), flight reasons (`explain.py`), conversation memory (`history.py`) |
| Agent service | `src/kestrel/agent_service.py`, `agent.py` | Chat turns, streamed; quick replies without the model; frustration hand-off (`frustration.py`) |
| Rules | `src/kestrel/entitlements.py`, `handoff.py`, `policy/` | Entitlements, hand-off cases, policy retrieval |
| Database | `db/migrations/` | Numbered migrations 000-012 |

---

## Setup

Requires **Python 3.13** and a Supabase project.

```bash
git clone <repo-url> kestrel && cd kestrel

# 1. Virtual environment and dependencies
python -m venv .venv
.venv\Scripts\activate          # Windows
# source .venv/bin/activate      # macOS / Linux
pip install -r requirements-dev.txt -e .

# 2. Configuration
copy .env.example .env           # cp on macOS / Linux
#    then fill in DATABASE_URL, GOOGLE_API_KEY and SESSION_SECRET

# 3. Commit hooks
pre-commit install
```

Or, with the task runner:

```bash
make setup          # macOS / Linux / Git Bash
.\tasks.ps1 setup   # Windows PowerShell
```

### Configuration

Every variable below is read by the code; `.env.example` is the authoritative
list. `.env` is ignored by Git and must never be committed.

| Variable | Used by | Notes |
|---|---|---|
| `DATABASE_URL` | `kestrel.api.main`, `scripts/` | Supabase **session pooler**, port 5432. Port 6543 is the transaction pooler and cannot run `COPY`. |
| `GOOGLE_API_KEY` | `kestrel.agent` | Falls back to `GEMINI_API_KEY`. |
| `SESSION_SECRET` | `kestrel.api.auth` | Signs bearer tokens. If unset the API still starts but every token is invalidated on restart, and it prints a `[WARN]`. |
| `FASTAPI_BASE_URL` | `kestrel.agent` | Where the agent's tools send HTTP requests. |
| `ALLOWED_ORIGINS` | `kestrel.api.main` | Comma-separated CORS allow-list. |
| `STAFF_API_KEY` | `kestrel.api.main` | The staff desk's shared key. Unset: staff endpoints answer 503. |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | `kestrel.api.accounts`, `tasks.ps1 web` | Google and emailed-code sign-in. |
| `AGENT_HISTORY_KEY` | REST tier and agent service | Shared secret the agent service sends to save assistant turns (`X-Agent-Key`). |

---

## Database

Apply the migrations **in this order** in the Supabase SQL editor:

| # | File | Contents |
|---|---|---|
| 000 | `db/migrations/000_base_schema.sql` | Tables and enum types. Generate with `python scripts/export_schema.py`. |
| 001 | `db/migrations/001_baseline_reaccommodate_passenger_atomic.sql` | The procedure as first deployed. Kept unchanged as an auditable baseline. |
| 002 | `db/migrations/002_indexes_and_rls.sql` | Indexes for auth, seat claiming and alternative search; row-level security. |
| 003 | `db/migrations/003_reaccommodate_passenger_atomic_v2.sql` | The corrected procedure. |
| 004 | `db/migrations/004_reaccommodate_cabin_class.sql` | Procedure v3: same-cabin seats (Fix 5), disrupted bookings only, every refusal audited. |
| 005 | `db/migrations/005_policy_retrieval.sql` | `policy_chunks` (pgvector) and the upsert/match functions (FR-02). |
| 006 | `db/migrations/006_entitlements_and_handoff.sql` | `vouchers` (final shape), `handoff_cases`, `flights.disruption_reason` (FR-04, FR-05, FR-09). |
| 007 | `db/migrations/007_flights_rls.sql` | Row-level security on `flights`, missed in 002. |
| 008 | `db/migrations/008_advisor_fixes.sql` | Procedure `search_path`; foreign-key indexes on `pnr_bookings`. |
| 009 | `db/migrations/009_passenger_accounts.sql` | `passenger_accounts`: a Supabase account linked to one passenger. |
| 010 | `db/migrations/010_chat_memory_and_frustration.sql` | `chat_messages` (conversation memory) and the `FRUSTRATION` hand-off trigger. |
| 011 | `db/migrations/011_rebooking_same_route.sql` | Procedure: refuses a flight on another route (`DIFFERENT_ROUTE`). |
| 012 | `db/migrations/012_cancelled_at_and_history_cap.sql` | `flights.cancelled_at` (set by a trigger) and a 100-turn cap per booking on `chat_messages`. |
| — | `db/seeds/reset_demo_state.sql` | Repeatable reset to a known disrupted state. Not a migration; run with `make reset`. |

Migration 003 corrects five defects in 001, each covered by a test in
`tests/integration/test_reaccommodation.py`:

1. The passenger's previous seat was never released back to `AVAILABLE`.
2. The target flight was never validated for existence, status or departure time.
3. A repeat call issued a second seat instead of being refused.
4. Failed attempts wrote no audit row.
5. `ORDER BY seat_number` sorted lexicographically, so `10A` preceded `2A`.

### Generating test data

```bash
python scripts/dataset_generator.py --truncate --days 7 --seed 42
```

Produces roughly 1,020 flights, 171,500 seats, 141,600 bookings and 75,500
passengers, then cancels the three busiest future flights. `--days 3` gives a
smaller dataset. `--dry-run` prints the shape without touching the database.

**Between test runs**, do not regenerate — run `make reset`
(`python scripts/reset_demo.py`) instead. It applies
`db/seeds/reset_demo_state.sql`, which reschedules flights relative to `now()`,
frees seats, restores bookings and re-creates the disruption, and it preserves
`audit_logs`.

The schedule only covers the generator's `--days` window, so the demo data goes
stale once that window has passed (and is used up as passengers are rebooked).
You rarely need to reset by hand: `make smoke`, `make agent` and `make test-all`
check first and reset automatically when no disrupted passenger has a usable
alternative flight (`reset_demo.py --if-stale`).

---

## Running the system

From the repo root, in PowerShell:

```powershell
.	asks.ps1 start    # REST tier on :8000 and agent service on :8001 (two windows)
.	asks.ps1 web      # release build of the client, served on http://localhost:8080
```

Open http://localhost:8080. Every screen shows data from the REST tier, which
reads Supabase; nothing is sample data except the table on Home labelled
"Example". Sign in as a guest with a disrupted booking's reference and
surname, or as staff with your name and `STAFF_API_KEY`.

Once, before the first run: add `http://localhost:8080` to `ALLOWED_ORIGINS`
in `.env`, and `http://localhost:8080/**` to Supabase → Authentication → URL
Configuration → Redirect URLs (for Google sign-in).

`.	asks.ps1 down` stops both services. `/health` on :8000 should report
`database: connected`. Other targets: `.	asks.ps1 help`.

---

## Development

```bash
make test       # unit tests, no database required
make test-all   # adds integration tests (needs DATABASE_URL; resets stale demo data)
make lint       # ruff
make fmt        # ruff --fix and format
make lock       # pin exact versions into requirements.lock.txt
make help       # every target
```

Tests marked `integration` skip themselves when `DATABASE_URL` is unset, so the
suite passes on a machine with no credentials — which is how CI runs it.
Integration tests run inside a transaction that is always rolled back.

### Automation

| Where | What |
|---|---|
| `.pre-commit-config.yaml` | ruff, line-ending and large-file checks, private-key detection, and the project secret scan — before each commit |
| `.github/workflows/ci.yml` | Secret scan, lint and tests on every push and pull request |
| `scripts/check_secrets.py` | Fails if a `.env` is tracked, a `.gitignore` is UTF-16, or any tracked file contains a credential |

The secret scan exists because of a real incident: the project `.gitignore`
files were saved as UTF-16, which Git cannot parse, so every rule in them was
inert and a `.env` containing live credentials was committed twice. The
credentials were rotated on 2026-09-24 and the scan now makes the same class of
mistake fail the build.

---

## Repository layout

```
kestrel/
├── client/                       Flutter web client (see client/README.md)
├── src/kestrel/                  Python package (pip install -e .)
│   ├── api/                      REST tier (uvicorn kestrel.api.main:app)
│   ├── agent.py, agent_service.py  Agent tier (uvicorn kestrel.agent_service:app)
│   ├── entitlements.py, handoff.py, frustration.py, suggestions.py
│   └── policy/                   Policy chunking, embeddings, retrieval
├── db/migrations/                000-012, applied in order
├── db/seeds/reset_demo_state.sql
├── deploy/                       Dockerfile, Cloud Run and Fly.io configuration
├── scripts/                      Dataset, reset, ingestion, evaluation, smoke and latency scripts
├── tests/unit/, tests/integration/
├── docs/                         Sprint records, test log, performance measurements
├── .github/workflows/ci.yml      Secret scan, lint, tests, Flutter analyze and test
└── Makefile / tasks.ps1          Task runner (make / PowerShell)
```

The project report (`.docx` / `.pdf`) is not kept in this repository; it lives
in `OneDrive/Documents/Project Kestrel/report/`.

### Known limits

- Login throttling is per-process and in-memory; it will not hold across
  multiple workers or replicas.
- `/api/trip` runs four queries at once on four of the ten pooled
  connections (see `docs/design/database-connection-pool.md`).
