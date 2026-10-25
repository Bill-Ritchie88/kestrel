# Sprint 1 review — Data preparation and development environment

Prepared 24 September 2026. Covers the six items in the weekly progress brief.

> **Paths below are as of 24 September.** On 1 October 2026 the project moved
> out of the coursework repository into its own repository, and files were
> renamed. The record below is left as written; translate paths with this table.
> See [01-standalone-repository-and-dataset-v2.md](../sprint-2/01-standalone-repository-and-dataset-v2.md).
>
> | 24 September | Now |
> |---|---|
> | `Project Kestrel/project/` | repository root |
> | `main.py`, `auth.py` | `src/kestrel/api/main.py`, `src/kestrel/api/auth.py` |
> | `agent.py` | `src/kestrel/agent.py` |
> | `database.py` | `scripts/smoke_test.py` |
> | `sql/000_base_schema.sql` | `db/migrations/000_base_schema.sql` |
> | `sql/baseline_reaccommodate_passenger_atomic.sql` | `db/migrations/001_baseline_reaccommodate_passenger_atomic.sql` |
> | `sql/schema.sql` | `db/migrations/002_indexes_and_rls.sql` |
> | `sql/reaccommodate_passenger_atomic_v2.sql` | `db/migrations/003_reaccommodate_passenger_atomic_v2.sql` |
> | `sql/Reset_demo_state.sql` | `db/seeds/reset_demo_state.sql`, run with `scripts/reset_demo.py` |
> | `claude/dataset-generator-v2.md` (notebook) | `scripts/dataset_generator.py` |

---

## The one-line framing

> "Chapter 5 already documented four reproducibility gaps and scheduled them
> for Sprint 2. Your brief asked for them this week, so I pulled them forward
> and closed all four, plus the two things the repository had nothing for at
> all — automated tests and workflow automation."

That framing matters. Every finding below was **self-identified and written
into the report before this sprint**, not discovered by the supervisor. The
work is closing a known list, not patching a surprise.

---

## 1. Documentation updates

**Status: proposal content already converted; two statements now need updating
because Sprint 1 made them false.**

The revised report is structured as project documentation, not a proposal —
Chapters 4 and 5 describe a built system, and Table 3.3 marks "Prototype
planning (proposal, scope, backlog)" as completed in May–June.

Three edits are now outstanding, all caused by this sprint's work:

| Location | Current text | Should become |
|---|---|---|
| Ch. 5, reproducibility gaps | "Three gaps ... are scheduled for Sprint 2" and "[Confirm that credentials were rotated and record the date]" | Gaps 2 and 3 closed in Sprint 1; gap 1 closes when `000_base_schema.sql` is committed. Credentials rotated **24 September 2026**. |
| Table 5.2 | `[pip freeze]` in every version cell | Actual versions from `requirements.lock.txt` |
| Table 3.1 | v1 generator config (12 routes, 3 days, 162 flights, 2,000 passengers) | v2 config — see `claude/dataset-generator-v2.md` in the project |

---

## 2. Development environment

**Show:** `README.md` → Setup section, then `requirements.txt` and `.env.example`.

| Before | After |
|---|---|
| No `requirements.txt`; versions unrecoverable from the code | `requirements.txt` (9 direct dependencies) + `requirements.lock.txt` |
| No virtual environment; packages installed globally | `make setup` / `.\tasks.ps1 setup` creates `.venv` |
| `.env.example` carried a **real** 64-character session secret | Placeholder only |
| `.env.example` named `JWT_SECRET`; `auth.py` reads `SESSION_SECRET` | Corrected — see below |
| `.env.example` pointed at pooler port 6543 | Port 5432 (6543 cannot run `COPY`) |

**The config bug worth mentioning.** `.env` defined `JWT_SECRET` and
`SESSION_TTL_MINUTES`; `auth.py` reads neither. It reads `SESSION_SECRET`,
which was never set, so on every start it fell back to a random per-process
secret and printed a warning — meaning every bearer token was invalidated on
restart. Found by diffing the `.env` keys against `grep -rn 'getenv('`.

---

## 3. Codebase organisation

**Show:** `README.md` → Repository layout, then `pyproject.toml`.

Added: `README.md`, `pyproject.toml` (ruff + pytest config in one place),
`tests/`, `scripts/check_secrets.py`, `scripts/export_schema.py`,
`Makefile` + `tasks.ps1`.

**Be honest about the one structural weakness.** This is the `ICS-4th-year`
repository — it also holds Distributed Systems, Embedded Systems, Machine
Learning, Multimedia and IoT coursework, plus PDFs and an MP3. The CI workflow
is path-filtered to compensate, but the project does not have a repository of
its own.

Recommended, and offer it as the first Sprint 2 task:

```bash
git subtree split -P "Project Kestrel" -b kestrel-only
# then push kestrel-only to a new, private Bill-Ritchie88/project-kestrel
```

This preserves the commit history for the project's files, which Section 3.3
relies on as "evidence of completed work".

---

## 4. Version control

**Show:** `git log --oneline -6`, then `git show 0a0ca6b --stat`.

**The finding.** Both `.gitignore` files were saved as **UTF-16LE with CRLF**.
Git cannot parse that encoding, so every rule in them was inert. Consequences:

- `Project Kestrel/project/.env`, containing a live Supabase password, a
  Google API key and a session secret, was committed in `209cc94`, removed in
  `73f16cc`, and **re-committed in `2b8c4b4`** — it was in `HEAD` at the start
  of this sprint.
- Compiled bytecode (`__pycache__/*.pyc`) was tracked.
- There was no repository-root `.gitignore` at all.

**The fix, in order:** credentials rotated first (Supabase password, Google API
key, `SESSION_SECRET` — 24 September 2026), then `.gitignore` rewritten as
UTF-8/LF, then `.env` and the bytecode untracked, then a guard added so it
cannot recur (see item 6).

Demonstrate the fix is real:

```bash
file .gitignore                                    # ASCII text, not UTF-16
git check-ignore -v "Project Kestrel/project/.env" # now matched by a rule
```

Also worth conceding: commit messages such as *"Free me"* and *"progress
upload"* are not adequate. The five Sprint 1 commits are written in
conventional-commit form and each explains why, not just what.

---

## 5. Data and database preparation

**Show:** `python database.py`, then the notebook.

| Item | State |
|---|---|
| Synthetic dataset generator v2 | 30 routes, 7 days → ~1,020 flights, 171,528 seats, 141,637 bookings, 75,466 passengers |
| Reproducibility | `--seed 42`; `--dry-run` inspects the shape without writing |
| Reset between runs | `sql/Reset_demo_state.sql`, no hardcoded identifiers, keeps the audit log |
| Migration 0 | **Outstanding** — run `python scripts/export_schema.py` |
| Policy corpus (FR-02) | Not started; Sprint 2 |

**The dead-seed fix.** `database.py` called the stored procedure with a PNR
`KQX89A` and a flight UUID from an early seed. Neither survives a regenerated
dataset, so the script reported a failure caused by its own stale constants.
It now discovers a disrupted PNR and a viable alternative at runtime, calls the
procedure twice to prove the idempotency guard refuses the second call, and
rolls the transaction back so the demo state is untouched.

---

## 6. Automation

**Show:** `.github/workflows/ci.yml`, then run the secret scan live.

| Layer | What it does |
|---|---|
| `.pre-commit-config.yaml` | ruff, line endings, large files, private keys, project secret scan — at commit time |
| `.github/workflows/ci.yml` | Secret scan → lint → tests, on every push and PR touching the project |
| `scripts/check_secrets.py` | Fails if a `.env` is tracked, a `.gitignore` is UTF-16, or a tracked file holds a credential |

The UTF-16 check is a **regression test for the actual incident**: the exact
condition that leaked credentials twice now fails the build. It was verified
against planted fixtures — a leaked connection string, a Google API key, a
tracked `.env` and a UTF-16 `.gitignore` — and caught all four.

**Tests.** 17 assertions on the session token scheme (signature tampering,
six malformed token shapes, expiry either side of the boundary, throttling
including PNR normalisation and window expiry), boundary tests on the request
models, and one integration test per defect that migration 003 corrected.
Integration tests skip themselves without `DATABASE_URL`, so CI runs the suite
with no credentials.

---

## Before the meeting — run these

```bash
cd "Project Kestrel/project"

python -m venv .venv && .venv\Scripts\activate
pip install -r requirements.txt -r requirements-dev.txt

copy .env.example .env        # fill in the three rotated values

ruff check . --fix            # expect import-order fixes on existing files
pytest -v                     # unit suite must be green
python scripts/check_secrets.py
python scripts/export_schema.py   # writes sql/000_base_schema.sql
python database.py                # end-to-end proof
make lock                         # requirements.lock.txt -> Table 5.2

pre-commit install
git add sql/000_base_schema.sql requirements.lock.txt && git commit
git push -u origin sprint-1/dev-environment
```

Then open a pull request into `main`. A green CI check on a PR is the single
most persuasive artefact for items 3, 4 and 6 — it shows the automation
working, not just configured.

---

## Open items — say these before he finds them

1. **No repository of its own.** The project shares `ICS-4th-year` with eight
   other units. Fix proposed in item 3.
2. **The leaked credentials remain in git history.** They are rotated and
   dead. Purging history would rewrite every commit hash; not worth it on a
   solo repository, but it should be stated rather than glossed over.
3. **Cabin class is not enforced in seat assignment** (Fix 5). A disrupted
   economy passenger can be handed a business seat. Logged, scheduled for
   Sprint 2; the dataset now makes it observable because cabin and loyalty
   tier correlate.
4. **Login throttling is per-process and in-memory.** It will not hold across
   multiple workers.
5. **Test coverage is auth, validation and the stored procedure only.**
   `main.py`'s endpoints and `agent.py`'s tool loop have no tests yet.
6. **Sprints have not been fortnightly.** Twenty-one commits between April and
   September, clustered. Worth acknowledging directly and proposing a cadence.

---

## Proposed Sprint 2 backlog

1. Split Project Kestrel into its own repository, history preserved.
2. Commit `000_base_schema.sql` and verify a rebuild from nothing.
3. Fix 5 — enforce cabin class in `reaccommodate_passenger_atomic`.
4. FR-02 — policy corpus ingestion and pgvector retrieval.
5. FR-04 — deterministic entitlement rules layer.
6. Endpoint tests for `main.py` via FastAPI's `TestClient`.
7. Move the backlog into GitHub Issues, as Section 3.3 already commits to.
