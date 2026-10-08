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
Flutter client  ->  FastAPI REST tier  ->  PostgreSQL (Supabase)
  (Sprint 3)          kestrel.api.main      reaccommodate_passenger_atomic
                      kestrel.api.auth      row-level locks, audit_logs
                         ^
                         |  HTTP only, no DB credentials
                   Agent tier
                   kestrel.agent  ->  Gemini (LangChain, bounded tool loop)
```

| Tier | File | Responsibility |
|---|---|---|
| REST | `src/kestrel/api/main.py` | Endpoints, request validation, connection pool |
| Auth | `src/kestrel/api/auth.py` | PNR + surname login, HMAC session tokens, login throttling |
| Agent | `src/kestrel/agent.py` | Bounded tool-calling loop; three tools, no DB access |
| Config | `src/kestrel/config.py` | Loads `.env` once, before any module reads the environment |
| Data | `db/` | Numbered migrations and the demo reset script |
| Test data | `scripts/dataset_generator.py` | Synthetic network, passengers, bookings, disruption |

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

## Running

```bash
make api        # uvicorn kestrel.api.main:app --reload  -> http://127.0.0.1:8000/docs
make smoke      # verify the DB and the stored procedure end to end
make agent      # run the agent for a disrupted passenger (needs `make api` running)
make reset      # reset the demo data to now
```

`/health` should report `status: online` and `database: connected`.

`make smoke` discovers a disrupted PNR and a viable alternative at runtime,
calls the procedure twice to demonstrate the idempotency guard, and rolls the
transaction back so the demonstration state is unchanged.

`make agent` runs `scripts/agent_demo.py`, which picks a disrupted passenger
from the database and hands the PNR and surname to the agent. The agent has no
database access, so it cannot look one up itself. To run it for a specific
passenger: `python -m kestrel.agent --pnr IZNXXV --last-name Cowan`.

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
├── src/kestrel/                  Application package (pip install -e .)
│   ├── config.py                 Loads .env once, before anything reads it
│   ├── agent.py                  Bounded tool-calling agent   (python -m kestrel.agent)
│   └── api/
│       ├── main.py               REST tier                    (uvicorn kestrel.api.main:app)
│       └── auth.py               Session authentication and throttling
├── db/
│   ├── migrations/               000-003, applied in order
│   └── seeds/reset_demo_state.sql
├── scripts/
│   ├── dataset_generator.py      Synthetic dataset
│   ├── export_schema.py          Dump the live base schema as migration 000
│   ├── smoke_test.py             Database and stored-procedure smoke test
│   ├── reset_demo.py             Reset demo data to now (--if-stale: only when needed)
│   ├── agent_demo.py             Run the agent for a disrupted passenger
│   └── check_secrets.py          Credential guard used by CI and pre-commit
├── tests/
│   ├── unit/                     No database needed
│   └── integration/              Need DATABASE_URL; skipped without it
├── docs/
│   ├── sprints/                  Dated sprint and change records
│   └── proposals/                Proposed work awaiting approval
├── .github/workflows/ci.yml      Secret scan, lint, tests
├── pyproject.toml                Package metadata, ruff and pytest configuration
├── requirements.txt              Runtime dependencies (floors)
├── requirements-dev.txt          Test and lint dependencies
├── Makefile / tasks.ps1          Task runner (make / PowerShell)
└── .env.example                  Configuration template
```

The project report (`.docx` / `.pdf`) is not kept in this repository; it lives
in `OneDrive/Documents/Project Kestrel/report/`.

---

## Status

| Component | State |
|---|---|
| REST tier with session authentication | Implemented |
| Bounded agent tier | Implemented |
| Corrected stored procedure (migration 003) | Implemented and tested |
| Synthetic dataset generator | Implemented |
| Development environment, CI, test suite | Sprint 1 |
| Policy retrieval (pgvector RAG, FR-02) | Sprint 2 |
| Deterministic entitlement rules (FR-04) | Sprint 2 |
| Hand-off case queue | Sprint 2 |
| Flutter client | Sprint 3 |

### Known open items

- Cabin class is not enforced during seat assignment, so a disrupted economy
  passenger can be given a business seat. Fix 5, scheduled for Sprint 2.
- Login throttling is per-process and in-memory; it will not hold across
  multiple workers.
- `db/migrations/000_base_schema.sql` must be generated and committed before the
  repository can rebuild the database from nothing.
