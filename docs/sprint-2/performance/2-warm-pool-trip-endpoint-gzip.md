# Kestrel latency - Phase 2 (warm pool, no reset round trip, /api/trip, gzip)

Measured 2026-10-18 14:15 E. Africa Standard Time with `scripts/evaluation/measure_latency.py` on Windows 11, Python 3.13.14.
REST tier http://127.0.0.1:8000, agent service http://127.0.0.1:8001; booking A27Z99 (DISRUPTED). REST calls x10, assistant questions x0 (15 s apart, for the model's per-minute quota), one after another over one keep-alive connection.

All times in milliseconds. *wall*: what the client waited. *app*: the REST tier's own time (Server-Timing). *first*: the first run, which pays any cold start. *first words*: when the reply text started (agent `first_token_ms`).

| Call | n | p50 | p90 | max | first | app p50 | first words p50 | errors |
|---|---|---|---|---|---|---|---|---|
| GET /api/me | 10 | 391 | 395 | 397 | 391 | 387 | - |  |
| GET /api/flights/alternatives | 10 | 406 | 453 | 6,830 | 406 | 399 | - |  |
| GET /api/entitlements | 10 | 787 | 889 | 1,679 | 789 | 783 | - |  |
| GET /api/handoff | 10 | 393 | 481 | 520 | 520 | 390 | - |  |
| GET /api/trip | 10 | 393 | 404 | 407 | 390 | 390 | - |  |
