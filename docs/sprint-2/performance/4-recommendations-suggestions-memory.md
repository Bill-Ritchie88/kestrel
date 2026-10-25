# Kestrel latency - Phase 4 (why this flight, suggestions, memory)

Measured 2026-10-18 15:50 E. Africa Standard Time with `scripts/evaluation/measure_latency.py` on Windows 11, Python 3.13.14.
REST tier http://127.0.0.1:8000, agent service http://127.0.0.1:8001; booking A27Z99 (DISRUPTED). REST calls x10, assistant questions x0 (15 s apart, for the model's per-minute quota), one after another over one keep-alive connection.

Assistant model: `gemini-3.8-flash`.

All times in milliseconds. *wall*: what the client waited (for a streamed reply, until `done`). *app*: the REST tier's own time (Server-Timing). *first*: the first run, which pays any cold start. *first words*: streamed - when the first `delta` reached the client; not streamed - when the reply text would start (agent `first_token_ms`). *calls*: model calls per turn.

| Call | n | p50 | p90 | max | first | app p50 | first words p50 / p90 | calls | errors |
|---|---|---|---|---|---|---|---|---|---|
| GET /api/me | 10 | 422 | 721 | 1,949 | 413 | 418 | - | - |  |
| GET /api/flights/alternatives | 10 | 429 | 1,126 | 2,248 | 2,248 | 411 | - | - |  |
| GET /api/entitlements | 10 | 418 | 1,225 | 1,273 | 419 | 414 | - | - |  |
| GET /api/handoff | 10 | 434 | 1,132 | 1,360 | 422 | 429 | - | - |  |
| GET /api/trip | 10 | 427 | 1,844 | 2,823 | 444 | 423 | - | - |  |
| Quick reply: "Find me another flight" (alternatives) | 10 | 408 | 1,409 | 1,874 | 1,409 | - | 405 / 1,405 | 0 |  |
| Quick reply: "What am I entitled to?" (entitlements) | 10 | 412 | 458 | 2,124 | 402 | - | 410 / 456 | 0 |  |
