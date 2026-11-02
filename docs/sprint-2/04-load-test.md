# Load test: concurrent rebooking (NFR-01, NFR-03)

Run 30 October 2026, 08:44–09:13 UTC, by `scripts/evaluation/load_test.py`. One row per run in
[04-load-test-runs.csv](04-load-test-runs.csv). Measures what Chapter 3 promises in Table 3.2: allocation
integrity under contention (NFR-03) and the response time of `POST /api/reaccommodate` (NFR-01, p95 ≤ 1.0 s).

## Set-up

| | |
|---|---|
| Machine | HP 245 14 inch G9 Notebook PC, Windows 11 Home, 7.5 GB RAM, Python 3.13, asyncpg 0.31, httpx 0.28 |
| Network | Mobile hotspot from Nairobi (campus Wi-Fi blocks port 5432) |
| Database | Supabase Postgres, eu-central-1 (Frankfurt), via the Supavisor **session** pooler (`pool_size` 15); `max_connections` 60 |
| Harness pool | **10** asyncpg connections for the integrity runs (15 was refused, see Limitations); 2 for the API runs (fixture set-up only) |
| REST tier | `.\tasks.ps1 start`, one uvicorn process, its own pool of 4–10 connections (`api/db.py`), unchanged |

## Method

Every run builds its own **synthetic fixture** in one transaction, and deletes it again in a `finally` block.
No existing flight, passenger or booking is read for the test or changed by it.

- Flights `LT9000` (CANCELLED, `cancelled_at` set) and `LT9001` (SCHEDULED), both NBO → LTX, a route no real
  flight uses, departing in 30 and 31 days.
- `LT9000`: N ECONOMY seats, one held by each booking. `LT9001`: exactly **S = N / 2** AVAILABLE ECONOMY seats
  and nothing else, so S < N.
- N passengers "Load Test", `loadtest+<run>-<i>@example.invalid`; N DISRUPTED bookings `9L0000`… on `LT9000`.
  Every real PNR starts with a letter, so a PNR that starts with a digit cannot collide with one.
- Cleanup, children first: `audit_logs`, `vouchers`, `handoff_cases`, `chat_messages` for `9L%` → `pnr_bookings` →
  `passenger_accounts` → `passengers` → `flights` (seats cascade). Afterwards a query counts the fixture rows
  in every table and fails the run if any remain. The same cleanup also runs at start-up, for leftovers from a
  crashed run. After the last run every count was 0.

**Integrity runs.** N ∈ {50, 100, 200}, 10 runs each, a fresh fixture each run. All N calls of
`reaccommodate_passenger_atomic(pnr, LT9001, 'LOADTEST')` are started at once with `asyncio.gather`. Each call
runs in its own committed transaction. **All N requests are in flight at once, but the database sees at most 10
of them at a time** (the pool size). This is not N simultaneous database sessions: the other calls queue for a
connection. The latency below is the procedure call alone, measured after a connection is acquired.

**API runs.** 10 runs of N = 50, S = 25. Bearer tokens are minted in-process with `kestrel.api.auth.issue_token`
using the REST tier's `SESSION_SECRET`, so the login throttle is not involved. All 50
`POST /api/reaccommodate {"target_flight_id": …}` requests go out at once over `httpx.AsyncClient` to
`http://127.0.0.1:8000`. The latency is client wall time per request, with the `Server-Timing: app` header
recorded beside it.

**Checks per run**, by SQL on the fixture:
1. no seat on the target flight is held by more than one booking;
2. successful allocations = min(N, S) = S;
3. the other N − S calls are the procedure's "no seat" refusal;
4. BOOKED seats on the target flight = bookings holding a seat there (seat conservation);
5. `audit_logs` rows for the fixture PNRs = N. Only the procedure's two actions count:
   `AUTOMATED_REACCOMMODATION` and `REACCOMMODATION_REJECTED`. Through the API, each success also writes an
   `ENTITLEMENTS_ISSUED` row, reported separately;
6. deadlocks = 0: the change in `pg_stat_database.deadlocks` across the run (readable every run), plus any
   `DeadlockDetectedError`.

## Results: integrity (NFR-03)

Latency is the procedure call in ms, across all calls of the 10 runs.

| N | S | runs passed | successes per run | refusals per run | max bookings per seat | conservation | audit rows per run | deadlocks | p50 | p95 | max |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 50 | 25 | **10 / 10** | 25 | 25 "no seat" | 1 | 25 = 25, all runs | 50 | 0 | 614 | 1070 | 1552 |
| 100 | 50 | **9 / 10** | 50 | 50 (49 "no seat" + 1 dropped connection in run 3) | 1 | 50 = 50, all runs | 100 (99 in run 3) | 0 | 442 | 732 | 1017 |
| 200 | 100 | **10 / 10** | 100 | 100 "no seat" | 1 | 100 = 100, all runs | 200 | 0 | 462 | 820 | 1757 |

Every refusal that reached the database was `No economy seats remaining on the target flight.`

**N = 100, run 3.** One of the 100 calls failed with `ConnectionDoesNotExistError`: the hotspot dropped the
connection before the call reached the database or committed. Checks 3 and 5 therefore failed: 49 "no seat"
refusals instead of 50, and 99 audit rows instead of 100. The database is still consistent with exactly the 99
calls that completed: 50 allocations, no seat held twice, 50 BOOKED seats = 50 bookings holding them, no
deadlock. The lost call left no partial state behind. The run is counted as a fail, not rerun.

## Results: API latency (NFR-01)

50 concurrent `POST /api/reaccommodate`, S = 25, times in ms.

| run | statuses | p50 | p95 | max | app p95 (Server-Timing) | checks 1, 2, 4, 5 |
|---|---|---|---|---|---|---|
| 1 | 200 × 25, 409 × 25 | 8814 | 10386 | 10913 | 10288 | pass |
| 2 | 200 × 25, 409 × 25 | 7642 | 9607 | 9725 | 9535 | pass |
| 3 | 200 × 25, 409 × 25 | 7531 | 9922 | 10197 | 9846 | pass |
| 4 | 200 × 25, 409 × 25 | 7858 | 9842 | 9864 | 9781 | pass |
| 5 | 200 × 25, 409 × 25 | 7867 | 9719 | 9933 | 9646 | pass |
| 6 | 200 × 25, 409 × 25 | 7491 | 11273 | 11456 | 11196 | pass |
| 7 | 200 × 25, 409 × 25 | 7922 | 9988 | 10147 | 9890 | pass |
| 8 | 200 × 25, 409 × 25 | 7236 | 9844 | 9955 | 9762 | pass |
| 9 | 200 × 25, 409 × 25 | 7562 | 9558 | 9648 | 9477 | pass |
| 10 | 200 × 25, 409 × 25 | 7641 | 10230 | 10351 | 10160 | pass |
| **all 500** | 200 × 250, 409 × 250 | **7783** | **10098** | **11456** | 10014 | pass |

The 25 refusals in every run were **409 Conflict** with the procedure's message as `detail`. Every run had
0 duplicate seats, 25 BOOKED = 25 held, and 50 procedure audit rows (75 with the 25 `ENTITLEMENTS_ISSUED`
rows). No vouchers are issued for the fixture: NBO → LTX is outside the entitlement rules' airport data.

**Likely cause.** The time is spent inside the REST tier, not on the network between client and server: app
time (Server-Timing) is within about 100 ms of wall time. The 50 requests share the REST tier's pool of at most
10 connections, so most of each request is spent waiting for a connection. Each success also holds its
connection for about eight round trips to Frankfurt: the procedure, the entitlements transaction (begin, load,
void, audit, select, commit) and the booking reload. At a few hundred ms per round trip, 25 successes and 25
refusals over 10 connections give a p50 of 7–8 s. Pool sizes, timeouts and code were not changed for the test.

## Pass / fail

| Criterion | Target | Result | |
|---|---|---|---|
| No seat held by more than one booking (NFR-03) | 0 in every run | 0 in all 40 runs (30 integrity, 10 API) | **Pass** |
| Successful allocations = min(N, S) = S (NFR-03) | every run | every run, all N | **Pass** |
| No deadlock (NFR-03) | 0 | 0 in all 40 runs (`pg_stat_database` readable) | **Pass** |
| Refused calls = N − S, all "no seat" | every run | 39 of 40 runs; N = 100 run 3 lost one call to a dropped connection | **Fail (1 run, network)** |
| Seat conservation | every run | every run | **Pass** |
| Audit completeness: one row per call | N per run | 39 of 40 runs; 99 / 100 in N = 100 run 3, the lost call never reached the database | **Fail (1 run, network)** |
| API p95 (NFR-01) | ≤ 1.0 s | **10.1 s** (p50 7.8 s) | **Fail** |

## Limitations

- **Concurrency at the database is bounded by the pool, not by N.** The integrity runs put at most 10 calls on
  the database at a time. The other N − 10 wait for a connection, so the contention is 10-way however large N
  is. A pool of 15 was refused (`EMAXCONNSESSION … pool_size: 15`) because the session pooler's 15 slots are
  shared with the REST tier's pool and with other clients of the project. Two slots were held by a client
  outside this test. The integrity runs were therefore made with the services stopped.
- **Network.** Every query pays the round trip from Nairobi over a mobile hotspot to Frankfurt. The hotspot
  dropped the connection three times during the session:
  - in N = 100 run 3, recorded above;
  - once that ended an earlier attempt at N = 100 run 4 (`WinError 64`), after which N = 100 and N = 200 were
    rerun in full;
  - once in an earlier API attempt, where one request stalled for 199 s and ended as a 500. The REST tier's
    traceback was not captured.

  Latency figures from this set-up describe this workstation and network, not a deployed service near its
  database.
- **The N = 50 integrity runs come from a separate session** (08:44–08:51 UTC) from the N = 100 and N = 200 runs
  (08:53–09:08 UTC). Their latency is higher (p95 1070 ms against 732 and 820 ms), consistent with a busier hotspot.
- **One aircraft cabin.** The fixture uses ECONOMY only, and no seat is LOCKED. Contention between cabins and
  the hold/lock path were not exercised.
- **The API test exercises one endpoint.** It sends no agent traffic and no login requests, and has no
  think-time between requests: it is the worst case of 50 passengers pressing "rebook" in the same instant.
