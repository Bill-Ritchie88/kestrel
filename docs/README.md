# Documentation

Organised by sprint. Design notes and future work apply across sprints. Database migrations are listed in
[`db/README.md`](../db/README.md).

Requirements: FR-01 sign-in · FR-02 policy corpus · FR-03 alternative flights · FR-04 entitlements ·
FR-05 hand-off and scope guard · FR-06 booking-reference authentication · FR-07 atomic rebooking with audit ·
FR-08 passenger interface · FR-09 staff queue · FR-16 seat selection · FR-17 confirmation before the assistant rebooks · NFR-01/02 response time and concurrency · NFR-03 data
integrity · NFR-04 retrieval accuracy · DR-09 provenance of each assistant answer.

| Document | What it is | Sprint | Requirement |
|---|---|---|---|
| [handover.md](handover.md) | Handover: live addresses, demo data, architecture and REST endpoints, running and deploying, measured results, known limitations | 3 | All |
| [diagrams/README.md](diagrams/README.md) | Architecture, deployment, entity-relationship and rebooking sequence diagrams (Mermaid source, PNG, SVG) with figure captions | 3 | All |
| [sprint-1/sprint-1-review.md](sprint-1/sprint-1-review.md) | Sprint 1 review: data preparation and development environment | 1 | FR-02, FR-04, NFR-03 |
| [sprint-2/01-standalone-repository-and-dataset-v2.md](sprint-2/01-standalone-repository-and-dataset-v2.md) | The move to a standalone repository, fixes and dataset v2 (1 October 2026) | 2 | NFR-03 |
| [sprint-2/02-test-log.md](sprint-2/02-test-log.md) | Every Sprint 2 test actually run: expected result, outcome, correction | 2 | FR-02 to FR-05, NFR-01, NFR-02 |
| [sprint-2/performance/0-baseline.md](sprint-2/performance/0-baseline.md) | Latency baseline before any performance work (Phase 0) | 2 | NFR-01, NFR-02 |
| [sprint-2/performance/2-warm-pool-trip-endpoint-gzip.md](sprint-2/performance/2-warm-pool-trip-endpoint-gzip.md) | Phase 2: warm connection pool, one `/api/trip` call, gzip | 2 | NFR-01, NFR-02 |
| [sprint-2/performance/3a-streaming-and-quick-replies.md](sprint-2/performance/3a-streaming-and-quick-replies.md) | Phase 3: streamed replies, quick replies, faster policy search | 2 | NFR-01, NFR-02 |
| [sprint-2/performance/3b-model-client-reuse-parallel-entitlements.md](sprint-2/performance/3b-model-client-reuse-parallel-entitlements.md) | Phase 3, after reusing the model client and computing entitlements in parallel | 2 | NFR-01, NFR-02 |
| [sprint-2/performance/4-recommendations-suggestions-memory.md](sprint-2/performance/4-recommendations-suggestions-memory.md) | Phase 4: "Why this flight?", suggestions and conversation memory | 2 | NFR-01, NFR-02 |
| [sprint-2/ai-code-review/review-tools-evaluation.md](sprint-2/ai-code-review/review-tools-evaluation.md) | Evaluation of the AI code-review tools run on Kestrel (18 October 2026) | 2 | NFR-03 |
| [sprint-2/ai-code-review/issues-found-and-fixed.md](sprint-2/ai-code-review/issues-found-and-fixed.md) | The issues those reviews found and how each was fixed | 2 | FR-01, FR-03, FR-04, FR-05, NFR-03 |
| [sprint-2/03-retrieval-evaluation.md](sprint-2/03-retrieval-evaluation.md) | Retrieval evaluation and tau calibration on the labelled question set, with [per-question scores](sprint-2/03-retrieval-evaluation-scores.csv) | 2 | NFR-04, FR-05 |
| [sprint-2/04-load-test.md](sprint-2/04-load-test.md) | Load test: concurrent rebooking integrity at N = 50, 100, 200 and API latency at 50 concurrent requests, rerun against Render at 10, 25 and 50 (November 2026), self-cleaning fixture, with [one row per run](sprint-2/04-load-test-runs.csv) | 2 | NFR-01, NFR-03 |
| [sprint-2/05-ai-use-log.md](sprint-2/05-ai-use-log.md) | AI-use log: tools used, one AI suggestion examined in full (account linking) and the other suggestions checked | 2 | FR-01, FR-05, NFR-03, NFR-04 |
| [sprint-2/sprint-2-review.md](sprint-2/sprint-2-review.md) | Sprint 2 review: backlog planned vs delivered, the four review items, results (retrieval, load test, response time), changes of scope, open items | 2 | All |
| [traceability.md](traceability.md) | Every requirement mapped to code, test, result and evidence | 3 | All |
| [sprint-3/00-status.md](sprint-3/00-status.md) | Sprint III status: remaining build work checked against the code, gaps and owner actions | 3 | All |
| [sprint-3/01-usability-test-plan.md](sprint-3/01-usability-test-plan.md) | Usability test plan for Kestrel Web: participants, consent, five tasks, SUS questionnaire, notes sheet, analysis | 3 | FR-08 |
| [sprint-3/usability/02-session-script.md](sprint-3/usability/02-session-script.md) | Usability test kit: [test-day checklist](sprint-3/usability/00-test-day-checklist.md), facilitator script (five tasks, success criteria, time limits), [participant sheets](sprint-3/usability/03-participant-sheet.md), [SUS questionnaire](sprint-3/usability/04-sus-questionnaire.md), results sheets ([tasks](sprint-3/usability/05-results-template-tasks.csv), [SUS](sprint-3/usability/05-results-template-sus.csv)) scored by `scripts/evaluation/score_usability.py`, [findings template](sprint-3/usability/06-findings-template.md); bookings from `scripts/data/create_usability_bookings.py` | 3 | FR-08 |
| [sprint-3/02-seat-selection.md](sprint-3/02-seat-selection.md) | Seat selection: seat map, migration 013, NOWAIT for a chosen seat vs SKIP LOCKED for auto-assign, 409 `SEAT_TAKEN` | 3 | FR-16, FR-07, NFR-03 |
| [sprint-3/03-sign-in-retest.md](sprint-3/03-sign-in-retest.md) | Google and email sign-in retest: configuration checked read-only, the linking rule, and a manual checklist for phone and laptop | 3 | FR-01, FR-06 |
| [sprint-3/04-account-deletion.md](sprint-3/04-account-deletion.md) | Account unlink and data deletion: what is deleted (link, chat history, Supabase sign-in), what is kept and why (bookings, audit logs), the manual Supabase step without a service-role key | 3 | DR-01, FR-01, NFR-03 |
| [design/assistant-intelligence-features.md](design/assistant-intelligence-features.md) | Design of the assistant's recommendations, explanations, suggestions and frustration hand-off | 2 | FR-03, FR-05, FR-08 |
| [design/database-connection-pool.md](design/database-connection-pool.md) | How the REST tier's database connection pool is sized and kept warm | 2 | NFR-01, NFR-02 |
| [future-work/ml-disruption-prediction.md](future-work/ml-disruption-prediction.md) | Proposal: a supervised model that predicts flight disruption (pending approval) | Future | — |
