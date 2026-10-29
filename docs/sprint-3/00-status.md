# Sprint III status

Checked against the code, the tests and `.env` (names only) on 25 October 2026. Each item in the
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
| Flutter clients on the live backend | Done (no sample data except the labelled "Example" table on Home) | `kestrel_client/`; 74 widget tests |
| Credentials rotated; `.env` ignored and absent from history | `.env` is ignored and absent from every ref, including the stash. Rotation (2026-09-24, per README) is *owner* to confirm | `git log --all -- .env` returns nothing; `scripts/ci/check_secrets.py` in CI |

## 2. Gaps against the plan found in the code

| Gap | Plan section | Effect | Needs |
|---|---|---|---|
| No account deletion: only unlinking a booking | §7.6, §8.6 | Blocks a Google Play release | A decision on what is deleted and what audit data is kept, then an endpoint and a web page |
| The agent may rebook without a separate confirmation when asked for "the next available flight" (system prompt rule 2) | §8.5 | The app's Confirm screen asks first; the chat does not | Supervisor decision; changing it alters the agreed behaviour (E2E-02) |
| `GEMINI_MODEL` defaults to the alias `gemini-flash-latest` in code. `.env` pins a named model | §6.3 | A deploy without the variable would run an unpinned model | Set the variable in Cloud Run (`deploy/README.md`) or change the default |
| No system-prompt version and no model IDs in the agent turn log | §5, §6.3 | Provenance for each answer is incomplete | A version constant logged with each turn |
| No rate limit on `POST /api/chat` and `/api/chat/stream` (sign-in is throttled) | §6.3 | Free Gemini quota can be used up by one client | A per-token limit |
| No test for a prompt-injection request ("upgrade me to business") or a destination change | §8.7 | The procedure already refuses both (cabin from the current seat, `DIFFERENT_ROUTE`), but the demo cases are not recorded | Two E2E runs in the test log |
| No live HTTPS release; CI does not build or deploy; no Workload Identity Federation | §6.2 | Definition of Done item 3 not met | *Owner*: GCP project, budget alert, then a deploy job |
| No release tag | §10 | Handover not reproducible from a tag | Tag after the final release (`v1.0-sprint3`) |

## 3. Owner actions

- Agree the remaining tasks, acceptance criteria and the same-route scope with the supervisor.
- Set `POLICY_TAU=0.66` in `.env` and in the deployed configuration, then restart the API.
- GCP: project, region `europe-west3`, MFA, budget alert, Secret Manager, then deploy (`deploy/README.md`).
- Usability sessions with representative users; record task success, problems and fixes.
- Report: Chapters 5 and 6, the Chapter 3/4 corrections, references in APA 7.
