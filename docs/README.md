# Documentation

Organised by sprint. Design notes and future work apply across sprints. Database migrations are listed in
[`db/README.md`](../db/README.md).

Requirements: FR-01 sign-in · FR-02 policy corpus · FR-03 alternative flights · FR-04 entitlements ·
FR-05 hand-off and scope guard · FR-06 booking-reference authentication · FR-07 atomic rebooking with audit ·
FR-08 passenger interface · FR-09 staff queue · NFR-01/02 response time and concurrency · NFR-03 data
integrity · NFR-04 retrieval accuracy.

| Document | What it is | Sprint | Requirement |
|---|---|---|---|
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
| [design/assistant-intelligence-features.md](design/assistant-intelligence-features.md) | Design of the assistant's recommendations, explanations, suggestions and frustration hand-off | 2 | FR-03, FR-05, FR-08 |
| [design/database-connection-pool.md](design/database-connection-pool.md) | How the REST tier's database connection pool is sized and kept warm | 2 | NFR-01, NFR-02 |
| [future-work/ml-disruption-prediction.md](future-work/ml-disruption-prediction.md) | Proposal: a supervised model that predicts flight disruption (pending approval) | Future | — |
