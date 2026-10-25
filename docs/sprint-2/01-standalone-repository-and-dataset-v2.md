# Standalone repository, fixes and dataset v2

Recorded 1 October 2026. Follows the [Sprint 1 review](../sprint-1/sprint-1-review.md).

---

## 1. The project now has its own repository

Until 1 October, Project Kestrel lived at `Project Kestrel/project/` inside a
repository that also held all other fourth-year coursework, with its CI and
pre-commit configuration scoped to that nested path.

It is now a standalone repository, laid out as an installable Python package
(`pip install -e .`). See the README for the full tree.

| Area | Location |
|---|---|
| Application package | `src/kestrel/` (`api/main.py`, `api/auth.py`, `agent.py`, `config.py`) |
| Database | `db/migrations/000-003`, `db/seeds/reset_demo_state.sql` |
| Tooling | `scripts/` (dataset generator, reset, smoke test, agent demo, schema export, secret scan) |
| Tests | `tests/unit/`, `tests/integration/` |
| Project report (`.docx` / `.pdf`) | Kept out of the repository, in OneDrive |

**History.** The 11 Kestrel commits were carried over, authorship unchanged.
They were rewritten to remove two leaks: the `.env` committed in two commits,
and a Supabase connection string with its password hardcoded in an early
version of the dataset generator. Neither appears anywhere in the new
history. **The old coursework repository on GitHub still contains both**, so
that password must be treated as public; it was rotated on 24 September.

Run commands changed with the package layout:

| Task | Command |
|---|---|
| API | `uvicorn kestrel.api.main:app --reload` (`make api` / `.\tasks.ps1 api`) |
| Agent demo | `python scripts/dev/agent_demo.py` (`make agent`) |
| Agent, chosen passenger | `python -m kestrel.agent --pnr <PNR> --last-name <surname>` |
| Smoke test | `python scripts/evaluation/smoke_test.py` (`make smoke`) |
| Reset demo data | `python scripts/data/reset_demo.py` (`make reset`) |

---

## 2. Defects found and fixed

| Defect | Effect | Fix |
|---|---|---|
| `SESSION_SECRET` was read before `.env` was loaded, and `.env` did not define it (it defined the unused `JWT_SECRET`) | Every bearer token was invalidated on each API restart | `kestrel/config.py` loads `.env` once, first; `SESSION_SECRET` added. Verified: a token issued before a restart is accepted after it |
| `DATABASE_URL` still had the `[ ]` from Supabase's `[YOUR-PASSWORD]` template, and pointed at the direct host | No database connection was possible | Brackets removed; switched to the session pooler (direct host does not resolve on IPv4) |
| Integration tests loaded `.env` only if another test happened to import `kestrel` first | Whether they ran depended on test ordering | `tests/conftest.py` loads configuration explicitly |
| `make test` documented as "no database" but ran integration tests against the live database when `.env` existed | Unit runs touched the live database | `test` runs `tests/unit`; `test-all` runs everything |
| Smoke test and test fixtures picked any disrupted booking, then looked for a flight | Could land on a route with no free seats even with fresh data | Booking and alternative flight chosen in one query |
| Agent demo hardcoded PNR `KQX89A` / `Otieno` | Failed whenever the dataset was regenerated | Agent takes `--pnr` / `--last-name`; `agent_demo.py` finds a disrupted passenger |
| Demo data expired (all flights in the past) | Smoke test and integration tests could not run | See section 3 |
| 16 lint findings already in the code | CI lint stage would fail | 11 auto-fixed; 5 fixed by hand (exception chaining, absolute `git` path) |

`JWT_SECRET` and `SESSION_TTL_MINUTES` were removed from `.env`: nothing reads
them (token lifetime is fixed at 15 minutes in `auth.py`).

---

## 3. Demo data that cannot go stale

The schedule covers a fixed window, so it expires; rebooking passengers during
demos also uses the disruption up. `scripts/data/reset_demo.py` applies
`db/seeds/reset_demo_state.sql`, and with `--if-stale` only when no disrupted
passenger has an alternative flight with a free seat departing at least six
hours out. `make smoke`, `make agent` and `make test-all` run that check first,
so the data repairs itself.

The reset now shifts the schedule by **whole days**, so departures keep their
Nairobi local times, and cancels three flights to match the generator. It keeps
`audit_logs`.

---

## 4. Dataset generator v2

The v2 generator, previously only a Colab notebook, is now
`scripts/data/generate_dataset.py`, with a `--dry-run` option. Generated on
1 October with `--truncate --days 7 --seed 42` (`audit_logs` backed up first,
since `--truncate` clears it):

| | Value |
|---|---|
| Routes | 30 |
| Flights | 966 (lower than the ~1,020 nominal because the run was in the Nairobi evening, so most of that day's departures were dropped) |
| Seats | 162,536 |
| Passengers | 71,623 (34,979 with more than one booking) |
| Bookings | 134,432; average load factor 0.825 |
| Disruption | 3 long-haul flights cancelled (JFK, BKK, AMS), 922 passengers disrupted, 6 alternatives on each route |
| Integrity | 0 double-booked seats, 0 seat/flight mismatches |

---

## 5. Verification, 1 October

| Check | Result |
|---|---|
| Unit + integration tests | 34 / 34 pass |
| Smoke test | First call succeeds, repeat call refused, rolled back |
| Lint, format, secret scan | Clean |
| API | Health, login, refusal of bad surname / malformed input / missing or forged token, token survives restart |
| End-to-end agent demo | Passenger A57TFZ authenticated, Gemini called the search tool then the rebooking tool, moved from cancelled KQ3 to the next KQ3, seat 1A; booking `REACCOMMODATED`, audit row `PASSENGER:A57TFZ / AUTOMATED_REACCOMMODATION` |

**Observed open defect (Fix 5).** A BLUE-tier economy passenger was assigned
business seat 1A, because cabin class is not enforced during seat assignment.
Dataset v2 makes this visible by design. Scheduled for Sprint 2.

---

## 6. Proposed next step

A classical supervised ML component, flight-cancellation prediction trained on
public US BTS data, is proposed in
[../proposals/ml-disruption-prediction.md](../future-work/ml-disruption-prediction.md),
pending supervisor approval.
