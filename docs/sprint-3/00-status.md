# Sprint III status

Checked against the code, the tests and `.env` (names only) on 25 October 2026; updated on
10 November 2026 for seat selection and the load test against Render. Each item in the
Sprint III plan is marked **done** only where the repository shows it. Items marked *owner* need
the supervisor, an account, money or real participants, so code alone cannot close them.

## 1. Remaining build work

| Item | Status | Where it is checked |
|---|---|---|
| Fix 2: signed session tokens | Done. HMAC-SHA256 bearer token with expiry, not a standard JWT; the report should describe it that way | `src/kestrel/api/auth.py`; `tests/unit/test_auth.py` |
| Fix 3: audit actor from the token | Done | `PassengerSession.audit_actor` in `auth.py`; `test_reaccommodate_body_cannot_name_another_pnr` |
| Fix 4: flight discovery tool | Done | `find_alternative_flights_tool` in `agent.py`; `GET /api/flights/alternatives` |
| Fix 5: cabin class in the procedure | Done. No upgrade rule exists, so no economy-to-business move is possible | Migration 004; `test_cabin_class_is_preserved`; DB-01 to DB-03 |
| Policy retrieval (pgvector) | Done for the KQ Conditions of Carriage, EU261 and the Montreal Convention. **KCAA rules are not in the corpus** | Test log PC-01 to PC-06 |
| Entitlement rules, separate from retrieval | Done | `src/kestrel/entitlements.py` (no import from `policy/`); 27 rule tests |
| Labelled set and tau calibration | Done: run on 25 Oct, tau 0.66. **`POLICY_TAU` in `.env` is not yet 0.66** | [Retrieval evaluation](../sprint-2/03-retrieval-evaluation.md) |
| Flutter clients on the live backend | Done (no sample data except the labelled "Example" table on Home) | `kestrel_client/`; 80 widget tests |
| Seat selection (FR-16, UC4, mockup M10) | Done. The passenger picks a seat on a seat map or lets Kestrel choose; migration 013 locks a chosen seat `FOR UPDATE NOWAIT` (taken or locked: 409 `SEAT_TAKEN`) and keeps auto-assign on `SKIP LOCKED`. Live on Supabase since 9 November 2026 | [Seat selection](02-seat-selection.md); `tests/integration/test_seat_selection.py` (2 and 10 passengers choosing one seat: exactly one succeeds); seat-map widget tests |
| NFR-01 on the deployed REST tier | Measured on Render (Frankfurt), 10 runs each: p95 **0.40 s** at N = 10 and **0.70 s** at N = 25 (met); **1.27 s** at N = 50 (**not met** at the client; server time 0.73 s). 0 double seats in every run | [Rerun against Render](../sprint-2/04-load-test.md#rerun-against-render-november-2026) |
| Credentials rotated; `.env` ignored and absent from history | `.env` is ignored and absent from every ref, including the stash. Rotation (2026-09-24, per README) is *owner* to confirm | `git log --all -- .env` returns nothing; `scripts/ci/check_secrets.py` in CI |

## 2. Gaps against the plan found in the code

| Gap | Plan section | Effect | Needs |
|---|---|---|---|
| ~~No account deletion: only unlinking a booking~~ **Closed (11 Nov 2026)** | §7.6, §8.6 | Account menu: "Unlink this booking" and "Delete my account data", each confirmed first. Deletion removes the link, the chat history and (with a service-role key) the Supabase sign-in; bookings and audit kept (DR-01) | Done: [Account deletion](04-account-deletion.md); `tests/unit/test_accounts.py`; `widget_test.dart`. *Owner*: no `SUPABASE_SERVICE_ROLE_KEY`, so remove the Supabase user by hand, or set the key on Render |
| ~~The agent may rebook without a separate confirmation when asked for "the next available flight" (system prompt rule 2)~~ **Closed 11 November 2026 (FR-17)** | §8.5 | The assistant now only proposes: the chat shows a "Confirm rebooking" card, and the REST tier refuses a rebooking from the agent tier without the signed, single-use token that only the passenger's tap sends | `tests/unit/test_auth.py` `TestConfirmationToken`, the FR-17 tests in `tests/unit/test_endpoints.py` and `test_agent_loop.py`, `kestrel_client/test/rebook_proposal_test.dart`. E2E-02 must be rerun with the extra tap |
| `GEMINI_MODEL` defaults to the alias `gemini-flash-latest` in code. `.env` pins a named model | §6.3 | A deploy without the variable would run an unpinned model | Set the variable in Cloud Run (`deploy/README.md`) or change the default |
| ~~No system-prompt version and no model IDs in the agent turn log~~ **Closed 11 November 2026 (DR-09); migration 014 applied to live 11 November 2026** | §5, §6.3 | Each turn carries `prompt_version` (semver + prompt hash, e.g. `2.0.0+3fa9c2d1`) beside the model ID in `logs/agent-turns.jsonl`; each assistant turn is saved with it (`chat_messages.prompt_version`, migration 014); the staff desk shows it per case | `tests/unit/test_agent_loop.py`, `test_endpoints.py`, `test_frustration.py`, staff desk widget tests. *Owner*: apply 014 (preview first: `KESTREL_PREVIEW_MIGRATION=db/migrations/014_prompt_version.sql pytest tests/integration/test_sql_statements.py`) |
| ~~No rate limit on `POST /api/chat` and `/api/chat/stream`~~ **Closed (11 Nov 2026)** | §6.3 | Chat routes on both services: 20 a minute per token, burst 5; sign-in: 20 a minute per IP, burst 10; 429 with `Retry-After`, shown in Kestrel Web as "Please wait N seconds" (NFR-05) | Done: `src/kestrel/ratelimit.py`; `tests/unit/test_ratelimit.py`; `kestrel_client/test/rate_limit_test.dart`. In-memory per process: one instance per service ([deploy notes](../../deploy/README.md)) |
| ~~No test for a prompt-injection request ("upgrade me to business") or a destination change~~ **Closed (11 Nov 2026)** | §8.7 | TC-19: 11 injection attempts on a local stack (10 ran, all refused or safely redirected; one hit the Gemini quota) plus two direct REST checks of the FR-17 guard (403). TC-12: scope guard rerun at τ = 0.66, unchanged (test F0.5 0.918) | Done: [Security tests](05-security-tests.md). One wording fix for the next prompt version ("entitled to", not "issued") |
| No live HTTPS release; CI does not build or deploy; no Workload Identity Federation | §6.2 | Definition of Done item 3 not met | *Owner*: GCP project, budget alert, then a deploy job |
| ~~No release tag~~ **Closed (11 Nov 2026)** | §10 | Handover reproducible from the annotated tag `v1.0` | Done: `git checkout v1.0`; see [CHANGELOG](../../CHANGELOG.md) |

## 3. Owner actions

- Agree the remaining tasks, acceptance criteria and the same-route scope with the supervisor.
- Set `POLICY_TAU=0.66` in `.env` and in the deployed configuration, then restart the API.
- GCP: project, region `europe-west3`, MFA, budget alert, Secret Manager, then deploy (`deploy/README.md`).
- Usability sessions with representative users; record task success, problems and fixes.
- Report: Chapters 5 and 6, the Chapter 3/4 corrections, references in APA 7.
