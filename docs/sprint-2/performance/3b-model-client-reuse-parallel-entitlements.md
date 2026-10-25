# Kestrel latency - Phase 3, after reusing the model client and parallel entitlements

Measured 2026-10-18 15:24 E. Africa Standard Time with `scripts/evaluation/measure_latency.py` on Windows 11, Python 3.13.14.
REST tier http://127.0.0.1:8000, agent service http://127.0.0.1:8001; booking A27Z99 (DISRUPTED). REST calls x3, assistant questions x0 (20 s apart, for the model's per-minute quota), one after another over one keep-alive connection.

Assistant model: `gemini-3.8-flash`.

All times in milliseconds. *wall*: what the client waited (for a streamed reply, until `done`). *app*: the REST tier's own time (Server-Timing). *first*: the first run, which pays any cold start. *first words*: streamed - when the first `delta` reached the client; not streamed - when the reply text would start (agent `first_token_ms`). *calls*: model calls per turn.

| Call | n | p50 | p90 | max | first | app p50 | first words p50 / p90 | calls | errors |
|---|---|---|---|---|---|---|---|---|---|
| GET /api/me | 3 | 411 | 424 | 424 | 404 | 407 | - | - |  |
| GET /api/flights/alternatives | 3 | 414 | 484 | 484 | 484 | 411 | - | - |  |
| GET /api/entitlements | 3 | 410 | 434 | 434 | 410 | 406 | - | - |  |
| GET /api/handoff | 3 | 416 | 489 | 489 | 489 | 413 | - | - |  |
| GET /api/trip | 3 | 399 | 410 | 410 | 392 | 396 | - | - |  |
| Streamed: "What are my options?" | 1 | 6,640 | 6,640 | 6,640 | 6,640 | - | 6,335 / 6,335 | 1 |  |
| Streamed: "What am I entitled to?" | 1 | 3,744 | 3,744 | 3,744 | 3,744 | - | 3,712 / 3,712 | 1 |  |
| Streamed: "Can I get a refund instead?" | 1 | 14,499 | 14,499 | 14,499 | 14,499 | - | 14,254 / 14,254 | 2 |  |
| Quick reply: "Find me another flight" (alternatives) | 10 | 421 | 444 | 526 | 435 | - | 419 / 441 | 0 |  |
| Quick reply: "What am I entitled to?" (entitlements) | 10 | 425 | 1,118 | 1,753 | 412 | - | 419 / 1,113 | 0 |  |
