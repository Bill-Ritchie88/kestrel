# Kestrel latency - Baseline (Phase 0)

Measured 2026-10-18 13:10 E. Africa Standard Time with `scripts/evaluation/measure_latency.py` on Windows 11, Python 3.13.14.
REST tier http://127.0.0.1:8000, agent service http://127.0.0.1:8001; booking A27Z99 (DISRUPTED). REST calls x10, assistant questions x3 (15 s apart, for the model's per-minute quota), one after another over one keep-alive connection.

All times in milliseconds. *wall*: what the client waited. *app*: the REST tier's own time (Server-Timing). *first*: the first run, which pays any cold start. *first words*: when the reply text started (agent `first_token_ms`).

| Call | n | p50 | p90 | max | first | app p50 | first words p50 | errors |
|---|---|---|---|---|---|---|---|---|
| GET /api/me | 10 | 632 | 748 | 812 | 621 | 628 | - |  |
| GET /api/flights/alternatives | 10 | 626 | 642 | 693 | 622 | 622 | - |  |
| GET /api/entitlements | 10 | 1,024 | 1,031 | 1,042 | 1,031 | 1,020 | - |  |
| GET /api/handoff | 10 | 701 | 772 | 816 | 663 | 697 | - |  |
| Assistant: "What are my options?" | 3 | 7,123 | 7,469 | 7,469 | 6,948 | - | 2,580 |  |
| Assistant: "What am I entitled to?" | 3 | 7,737 | 8,386 | 8,386 | 8,386 | - | 3,135 |  |
| Assistant: "Can I get a refund instead?" | 0 | - | - | - | - | - | - | 503 quota x3 |
