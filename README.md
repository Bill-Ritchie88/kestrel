# Project Kestrel

An agentic passenger re-accommodation system for Kenya Airways. When a flight
is cancelled, a passenger authenticates with their PNR and surname, asks
questions in natural language, and is rebooked onto an alternative flight with
a seat assigned atomically.

The design pairs a **non-deterministic LLM** with a **deterministic transaction
layer**. The agent decides *what* to do; a PL/pgSQL stored procedure decides
*whether it is allowed* and performs it under row-level locks. The agent has no
database credentials and cannot write to the database except through the REST
tier.

> Undergraduate capstone project. No real passenger data is used at any point;
> the entire dataset is synthetic.

---

## Architecture

```
Flutter client  ->  FastAPI REST tier  ->  PostgreSQL (Supabase)
  (Sprint 3)          main.py               reaccommodate_passenger_atomic
                      auth.py               row-level locks, audit_logs
                         ^
                         |  HTTP only, no DB credentials
                   Agent tier
                   agent.py  ->  Gemini (LangChain, bounded tool loop)
```

| Tier | File | Responsibility |
|---|---|---|
| REST | `main.py` | Endpoints, request validation, connection pool |
| Auth | `auth.py` | PNR + surname login, HMAC session tokens, login throttling |
| Agent | `agent.py` | Bounded tool-calling loop; three tools, no DB access |
| Data | `sql/` | Base schema, the stored procedure and its corrections |
| Test data | `scripts/dataset_generator.py` | Synthetic network, passengers, bookings, disruption |

---

## Setup

Requires **Python 3.13** and a Supabase project.

```bash
cd "Project Kestrel/project"

# 1. Virtual environment and dependencies
python -m venv .venv
.venv\Scripts\activate          # Windows
# source .venv/bin/activate      # macOS / Linux
pip install -r requirements.txt -r requirements-dev.txt

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
| `DATABASE_URL` | `main.py`, `database.py`, `scripts/` | Supabase **session pooler**, port 5432. Port 6543 is the transaction pooler and cannot run `COPY`. |
| `GOOGLE_API_KEY` | `agent.py` | Falls back to `GEMINI_API_KEY`. |
| `SESSION_SECRET` | `auth.py` | Signs bearer tokens. If unset the API still starts but every token is invalidated on restart, and it prints a `[WARN]`. |
| `FASTAPI_BASE_URL` | `agent.py` | Where the agent's tools send HTTP requests. |
| `ALLOWED_ORIGINS` | `main.py` | Comma-separated CORS allow-list. |

---

## Database

Apply the migrations **in this order** in the Supabase SQL editor:

| # | File | Contents |
|---|---|---|
| 000 | `sql/000_base_schema.sql` | Tables and enum types. Generate with `python scripts/export_schema.py`. |
| 001 | `sql/baseline_reaccommodate_passenger_atomic.sql` | The procedure as first deployed. Kept unchanged as an auditable baseline. |
| 002 | `sql/schema.sql` | Indexes for auth, seat claiming and alternative search; row-level security. |
| 003 | `sql/reaccommodate_passenger_atomic_v2.sql` | The corrected procedure. |
| 004 | `sql/Reset_demo_state.sql` | Repeatable reset to a known disrupted state. |

Migration 003 corrects five defects in 001, each covered by a test in
`tests/test_reaccommodation_integration.py`:

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

**Between test runs**, do not regenerate — run `sql/Reset_demo_state.sql`
instead. It reschedules flights relative to `now()`, frees seats, restores
bookings and re-creates the disruption, and it preserves `audit_logs`.

---

## Running

```bash
make api        # uvicorn main:app --reload    -> http://127.0.0.1:8000/docs
make smoke      # verify the DB and the stored procedure end to end
make agent      # run the agent against the running API
```

`/health` should report `status: online` and `database: connected`.

`make smoke` discovers a disrupted PNR and a viable alternative at runtime,
calls the procedure twice to demonstrate the idempotency guard, and rolls the
transaction back so the demonstration state is unchanged.

---

## Development

```bash
make test       # unit tests, no database required
make test-all   # adds integration tests (needs DATABASE_URL)
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
| `.github/workflows/ci.yml` | Secret scan, lint and tests on every push and pull request touching the project |
| `scripts/check_secrets.py` | Fails if a `.env` is tracked, a `.gitignore` is UTF-16, or any tracked file contains a credential |

The secret scan exists because of a real incident: the project `.gitignore`
files were saved as UTF-16, which Git cannot parse, so every rule in them was
inert and a `.env` containing live credentials was committed twice. The
credentials were rotated on 2026-09-24 and the scan now makes the same class of
mistake fail the build.

---

## Repository layout

```
Project Kestrel/project/
├── main.py                  REST tier
├── auth.py                  Session authentication and throttling
├── agent.py                 Bounded tool-calling agent
├── database.py              Database and stored-procedure smoke test
├── requirements.txt         Direct dependencies (floors)
├── requirements-dev.txt     Test and lint dependencies
├── pyproject.toml           ruff and pytest configuration
├── Makefile / tasks.ps1     Task runner (make / PowerShell)
├── .env.example             Configuration template
├── scripts/
│   ├── dataset_generator.py Synthetic dataset
│   ├── export_schema.py     Dump the live base schema as migration 000
│   └── check_secrets.py     Credential guard used by CI and pre-commit
├── sql/                     Migrations 000-004
└── tests/                   Unit and integration tests
```

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
- `sql/000_base_schema.sql` must be generated and committed before the
  repository can rebuild the database from nothing.
