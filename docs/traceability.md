# Traceability record

Each requirement mapped to the code that implements it, the test or evaluation that checks it,
the result and where the evidence is. Results are from runs on 25 October 2026 unless a test-log
ID says otherwise: `pytest` 288 passed (unit and integration against Supabase, rolled back),
`flutter analyze` clean, `flutter test` 74 passed.

Requirement IDs are the ones in Chapter 3 and [`docs/README.md`](README.md). The Sprint III
playbook calls retrieval calibration "FR-05"; in this project that work is **NFR-04**, and FR-05 is
the hand-off and scope guard.

| Requirement | Implemented component | Test / evaluation | Result | Evidence |
|---|---|---|---|---|
| FR-01 Sign-in (Google, emailed code) | `src/kestrel/api/accounts.py`, `POST /api/auth/account`, Supabase Auth; sign-in screen in `kestrel_client/` | `tests/unit/test_accounts.py` (22): links only on a matching verified email, unverified email 401, booking of another account 409, Supabase down 503, throttling | Pass | `pytest` run; [issues found and fixed](sprint-2/ai-code-review/issues-found-and-fixed.md) |
| FR-02 Policy corpus and retrieval | `src/kestrel/policy/`, migration 005 (pgvector), `scripts/data/ingest_policies.py`; 120 clauses (KQ Conditions of Carriage 36, EU261 24, Montreal Convention 60) | `tests/unit/test_policy.py` (21); integration `test_policy_store_returns_clauses_in_similarity_order`; PC-01 to PC-06 | Pass. KCAA rules are **not** in the corpus | [Test log §2](sprint-2/02-test-log.md) |
| FR-03 Alternative flights | `GET /api/flights/alternatives`, `find_alternative_flights_tool`, `src/kestrel/api/explain.py` | `test_alternatives_are_same_cabin_and_limit_is_clamped`; `tests/unit/test_explain.py` (8) | Pass | `pytest` run |
| FR-04 Entitlements (rules layer, separate from retrieval) | `src/kestrel/entitlements.py`; vouchers in `src/kestrel/api/booking.py` | `tests/unit/test_entitlements.py` (27, per disruption type: weather, 14-day notice, distance bands, tier); `tests/unit/test_vouchers.py` (3); E2E-01 | Pass | [Test log §6](sprint-2/02-test-log.md) |
| FR-05 Hand-off and scope guard | `src/kestrel/handoff.py`, `frustration.py`, the tau check in `policy/retriever.py` | `test_out_of_scope_question_opens_a_handoff_case`, `test_no_alternatives_opens_a_handoff_case`, `test_scope_guard_threshold_is_inclusive`, `tests/unit/test_frustration.py` (20) | Pass | `pytest` run |
| FR-06 Booking-reference authentication | `src/kestrel/api/auth.py`: HMAC-SHA256 signed bearer token with an expiry (JWT-like, not RFC 7519 JWT); login throttling | `tests/unit/test_auth.py` (14) incl. `test_expired_token_is_rejected`; `test_booking_endpoints_reject_missing_or_forged_tokens`; `test_sixth_failed_login_is_throttled_429` | Pass | `pytest` run |
| FR-07 Atomic re-accommodation with audit | `reaccommodate_passenger_atomic` (migrations 001, 003, 004 Fix 5, 011 same route); `POST /api/reaccommodate` | `tests/integration/test_reaccommodation.py` (11): seat assigned, repeat refused, old seat released, unknown PNR audited, cabin kept, confirmed booking refused, other route refused; DB-01 to DB-10; LT-01 (12 concurrent, 1 free seat) | Pass. LT-01: 1 success, 11 refused, 0 duplicate seats, p95 430 ms | [Test log §1, §4](sprint-2/02-test-log.md); `audit_logs` rows |
| Auth and ownership | PNR and audit actor taken from the token, never the request body (`auth.py` `audit_actor`) | `test_reaccommodate_body_cannot_name_another_pnr`, `test_me_returns_the_sessions_own_booking`, `test_chat_history_is_the_tokens_own_booking_oldest_first`, `test_booking_linked_to_another_account_is_409`, `test_expired_session_is_401_before_the_model_runs` | Pass | `pytest` run |
| FR-08 Passenger interface | `kestrel_client/` (Kestrel Web) | `flutter test` (74): phone and laptop layouts, 48 dp targets, 4.5:1 contrast; CL-01, CL-02 | Pass. Not yet tested with representative users or on a real phone | [Test log §5](sprint-2/02-test-log.md) |
| FR-09 Staff queue | `GET /api/staff/cases`, `POST /api/staff/cases/{id}/resolve`, staff desk | `test_staff_queue_requires_the_staff_key`, `test_staff_queue_disabled_without_configuration`, `test_the_staff_queue_is_newest_first` | Pass | `pytest` run |
| NFR-01/02 Response time and concurrency | `measure_latency.py`, `load_test.py`, connection pool, streaming | PF series, LT-01 | Measured on the workstation only, not on the deployed service | [Performance reports](sprint-2/performance/) |
| NFR-03 Data integrity | Migrations 000 to 012, row-level security, `scripts/ci/check_secrets.py` | DB-13 to DB-15; IT-02 (every SQL statement prepares against the live schema) | Pass | [Test log §1, §5](sprint-2/02-test-log.md) |
| NFR-04 Retrieval accuracy and tau calibration | `data/eval/policy_questions.csv` (88 hand-labelled: 44 calibration, 44 held-out test); `gemini-embedding-001`, 768 dimensions | `scripts/evaluation/evaluate_retrieval.py`: Recall@3 and a tau sweep scored by F0.5 | Recall@3 (test) **0.967**. Calibrated tau **0.66**: test precision 0.906, recall 0.967, F0.5 0.918, false hand-off rate 0.033 (at the old 0.75: recall 0.233) | [Retrieval evaluation](sprint-2/03-retrieval-evaluation.md), [per-question scores](sprint-2/03-retrieval-evaluation-scores.csv) |
| Unmet: account deletion | Only unlinking exists (`DELETE /api/auth/account/link`) | — | **Not met.** Google Play needs in-app and web deletion before release | — |
| Unmet: deployed release | `deploy/` (Dockerfile, Cloud Run steps) | — | **Not met yet.** No live HTTPS service, so nothing is tested in the deployed configuration | — |
