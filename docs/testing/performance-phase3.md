# Kestrel latency - Phase 3 (streaming, CONTEXT, quick replies, faster policy search)

Measured 2026-10-18 15:20 E. Africa Standard Time with `scripts/measure_latency.py` on Windows 11, Python 3.13.14.
REST tier http://127.0.0.1:8000, agent service http://127.0.0.1:8001; booking A27Z99 (DISRUPTED). REST calls x3, assistant questions x1 (20 s apart, for the model's per-minute quota), one after another over one keep-alive connection.

Assistant model: `gemini-3.8-flash`.

All times in milliseconds. *wall*: what the client waited (for a streamed reply, until `done`). *app*: the REST tier's own time (Server-Timing). *first*: the first run, which pays any cold start. *first words*: streamed - when the first `delta` reached the client; not streamed - when the reply text would start (agent `first_token_ms`). *calls*: model calls per turn.

| Call | n | p50 | p90 | max | first | app p50 | first words p50 / p90 | calls | errors |
|---|---|---|---|---|---|---|---|---|---|
| GET /api/me | 3 | 416 | 418 | 418 | 408 | 413 | - | - |  |
| GET /api/flights/alternatives | 3 | 429 | 461 | 461 | 461 | 426 | - | - |  |
| GET /api/entitlements | 3 | 824 | 928 | 928 | 798 | 821 | - | - |  |
| GET /api/handoff | 3 | 399 | 515 | 515 | 515 | 396 | - | - |  |
| GET /api/trip | 3 | 427 | 436 | 436 | 399 | 424 | - | - |  |
| Assistant: "What are my options?" | 1 | 8,351 | 8,351 | 8,351 | 8,351 | - | 0 / 0 | 1 |  |
| Assistant: "What am I entitled to?" | 1 | 8,307 | 8,307 | 8,307 | 8,307 | - | 0 / 0 | 1 |  |
| Assistant: "Can I get a refund instead?" | 1 | 26,594 | 26,594 | 26,594 | 26,594 | - | 22,953 / 22,953 | 2 |  |
| Streamed: "What are my options?" | 2 | 5,636 | 5,788 | 5,788 | 5,484 | - | 5,377 / 5,392 | 1 |  |
| Streamed: "What am I entitled to?" | 2 | 5,496 | 5,978 | 5,978 | 5,978 | - | 5,074 / 5,931 | 1 |  |
| Streamed: "Can I get a refund instead?" | 2 | 9,746 | 9,806 | 9,806 | 9,806 | - | 9,498 / 9,556 | 2 |  |
| Quick reply: "Find me another flight" (alternatives) | 10 | 464 | 571 | 816 | 424 | - | 462 / 569 | 0 |  |
| Quick reply: "What am I entitled to?" (entitlements) | 10 | 829 | 858 | 893 | 843 | - | 827 / 855 | 0 |  |
