"""
Concurrent rebooking load test (NFR-01, NFR-03).

Every run builds its own synthetic fixture, fires N rebooking requests at a
flight with S = N / 2 free seats, checks the outcome and deletes the fixture
again, in a finally block, even after an error. No existing flight, passenger
or booking is read for the test or changed by it.

The fixture, all recognisable by prefix:
  * flights LT9000 (CANCELLED) and LT9001 (SCHEDULED), NBO -> LTX, a route no
    real flight uses, departing a month from now;
  * N ECONOMY seats on LT9000, one per booking, and S AVAILABLE ECONOMY seats
    on LT9001 (nothing else a passenger could be given);
  * N passengers "Load Test", loadtest+<run>-<i>@example.invalid;
  * N DISRUPTED bookings 9L0000.. on LT9000. Real PNRs always start with a
    letter, so a digit first cannot collide.

Two modes:
  integrity  N in --sizes, --runs each: all N calls of
             reaccommodate_passenger_atomic at once through an asyncpg pool of
             --pool connections, each call its own committed transaction.
             All N are in flight at once; the database sees at most --pool of
             them at a time.
  api        --runs runs of each N in --api-sizes (default 50): all N
             POST /api/reaccommodate at once against the REST tier at
             --api-base. Against the local tier, tokens are minted in-process
             by issue_token (same SESSION_SECRET, no login throttle). Against
             any other base (e.g. the Render deployment, whose secret is not
             ours) each fixture passenger signs in once through
             POST /api/auth/session before the timed section; a correct
             sign-in clears its own throttle count, so nothing is weakened.
             A deployment that sleeps is polled on /health until online.
             A run with a 5xx or a request without a response stops the mode.

Checks per run (Table 3.2):
  1. no seat on the target flight is held by more than one booking;
  2. successful allocations = min(N, S) = S;
  3. the other N - S calls are the procedure's "no seat" refusal;
  4. BOOKED seats on the target flight = bookings holding a seat there;
  5. one audit_logs row per call (the procedure's own two actions);
  6. no deadlock (pg_stat_database.deadlocks, and no DeadlockDetectedError).
API runs also need overall p95 <= 1.0 s (NFR-01).

    python scripts/evaluation/load_test.py --mode all --csv docs/sprint-2/04-load-test-runs.csv

The API mode needs the services: .\\tasks.ps1 start. Against Render:

    python scripts/evaluation/load_test.py --mode api --api-base https://kestrel-myd3.onrender.com \\
        --target render --api-sizes 50 --runs 10 --csv run.csv
"""

import argparse
import asyncio
import csv
import math
import os
import sys
import time
from collections import Counter
from dataclasses import dataclass, field

import asyncpg
import httpx

from kestrel import config  # noqa: F401  - loads .env (SESSION_SECRET before auth reads it)
from kestrel.api.auth import issue_token

PNR_PREFIX = "9L"
FLIGHT_PREFIX = "LT9"
ROUTE = ("NBO", "LTX")
EMAIL_PREFIX = "loadtest+"
EMAIL_DOMAIN = "@example.invalid"
ACTOR = "LOADTEST"
NO_SEAT = "No economy seats remaining on the target flight."
PROCEDURE_ACTIONS = ("AUTOMATED_REACCOMMODATION", "REACCOMMODATION_REJECTED")
API_URL = "http://127.0.0.1:8000"
API_N = 50
HEALTH_WAIT_S = 150  # a sleeping Render free instance takes about a minute to wake
P95_LIMIT_S = 1.0

SQL_CALL = "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3)"
SQL_DEADLOCKS = "SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()"
# LIKE patterns that select the fixture's rows and nothing else.
PNR_LIKE = PNR_PREFIX + "%"
EMAIL_LIKE = EMAIL_PREFIX + "%" + EMAIL_DOMAIN
FLIGHT_LIKE = FLIGHT_PREFIX + "%"


def percentile(values: list[float], p: float) -> float:
    """Nearest-rank percentile: p95 of 50 values is the 48th smallest."""
    ordered = sorted(values)
    return ordered[max(0, math.ceil(p / 100 * len(ordered)) - 1)]


def cleanup_statements() -> list[tuple[str, tuple]]:
    """(sql, args) deleting every fixture row, children first. Only the
    prefixes select rows, so a leftover from a crashed run goes the same way."""
    return [
        ("DELETE FROM audit_logs WHERE pnr_code LIKE $1", (PNR_LIKE,)),
        ("DELETE FROM vouchers WHERE pnr_code LIKE $1", (PNR_LIKE,)),
        ("DELETE FROM handoff_cases WHERE pnr_code LIKE $1", (PNR_LIKE,)),
        ("DELETE FROM chat_messages WHERE pnr_code LIKE $1", (PNR_LIKE,)),
        ("DELETE FROM pnr_bookings WHERE pnr_code LIKE $1", (PNR_LIKE,)),
        (
            "DELETE FROM passenger_accounts WHERE passenger_id IN "
            "(SELECT passenger_id FROM passengers WHERE email LIKE $1)",
            (EMAIL_LIKE,),
        ),
        ("DELETE FROM passengers WHERE email LIKE $1", (EMAIL_LIKE,)),
        # Seats cascade with their flight.
        (
            "DELETE FROM flights WHERE flight_number LIKE $1 AND destination = $2",
            (FLIGHT_LIKE, ROUTE[1]),
        ),
    ]


# One row: how many fixture rows remain in each table.
SQL_LEFTOVERS = """
    SELECT
      (SELECT count(*) FROM audit_logs    WHERE pnr_code LIKE $1) AS audit_logs,
      (SELECT count(*) FROM vouchers      WHERE pnr_code LIKE $1) AS vouchers,
      (SELECT count(*) FROM handoff_cases WHERE pnr_code LIKE $1) AS handoff_cases,
      (SELECT count(*) FROM chat_messages WHERE pnr_code LIKE $1) AS chat_messages,
      (SELECT count(*) FROM pnr_bookings  WHERE pnr_code LIKE $1) AS pnr_bookings,
      (SELECT count(*) FROM passengers    WHERE email LIKE $2)    AS passengers,
      (SELECT count(*) FROM flights WHERE flight_number LIKE $3 AND destination = $4) AS flights,
      (SELECT count(*) FROM seats s JOIN flights f USING (flight_id)
         WHERE f.flight_number LIKE $3 AND f.destination = $4)    AS seats
"""
LEFTOVER_ARGS = (PNR_LIKE, EMAIL_LIKE, FLIGHT_LIKE, ROUTE[1])


async def cleanup(pool: asyncpg.Pool) -> None:
    async with pool.acquire() as conn, conn.transaction():
        for sql, args in cleanup_statements():
            await conn.execute(sql, *args)
    async with pool.acquire() as conn:
        left = dict(await conn.fetchrow(SQL_LEFTOVERS, *LEFTOVER_ARGS))
    if any(left.values()):
        raise RuntimeError(f"Fixture rows left after cleanup: {left}")


@dataclass
class Fixture:
    original: str
    target: str
    bookings: list[tuple[str, str]]  # (pnr_code, passenger_id)


async def create_fixture(pool: asyncpg.Pool, tag: str, n: int, s: int) -> Fixture:
    async with pool.acquire() as conn, conn.transaction():
        original = await conn.fetchval(
            """INSERT INTO flights (flight_number, origin, destination, departure_time, arrival_time,
                                    status, aircraft_type, disruption_reason, cancelled_at)
               VALUES ($1, $2, $3, now() + interval '30 days', now() + interval '30 days 2 hours',
                       'CANCELLED', '738', 'TECHNICAL', now())
               RETURNING flight_id""",
            f"{FLIGHT_PREFIX}000", *ROUTE,
        )  # fmt: skip
        target = await conn.fetchval(
            """INSERT INTO flights (flight_number, origin, destination, departure_time, arrival_time,
                                    status, aircraft_type)
               VALUES ($1, $2, $3, now() + interval '31 days', now() + interval '31 days 2 hours',
                       'SCHEDULED', '738')
               RETURNING flight_id""",
            f"{FLIGHT_PREFIX}001", *ROUTE,
        )  # fmt: skip
        # Seat i is 1A..1F, 2A..: rows of six; the bookings join on the same numbers.
        for flight, count, status in ((original, n, "BOOKED"), (target, s, "AVAILABLE")):
            await conn.execute(
                """INSERT INTO seats (flight_id, seat_number, cabin_class, status)
                    SELECT $1, (g / 6 + 1)::text || substr('ABCDEF', g % 6 + 1, 1), 'ECONOMY', $3::seat_status
                    FROM generate_series(0, $2 - 1) g""",
                flight, count, status,
            )  # fmt: skip
        await conn.execute(
            """INSERT INTO passengers (first_name, last_name, email, phone_number)
               SELECT 'Load', 'Test', $1 || $2 || '-' || g || $3, '+0000000000'
               FROM generate_series(0, $4 - 1) g""",
            EMAIL_PREFIX, tag, EMAIL_DOMAIN, n,
        )  # fmt: skip
        rows = await conn.fetch(
            """INSERT INTO pnr_bookings (pnr_code, passenger_id, original_flight_id,
                                          assigned_seat_id, booking_status)
                SELECT $1 || lpad(g::text, 4, '0'), p.passenger_id, $2, st.seat_id, 'DISRUPTED'
                FROM generate_series(0, $3 - 1) g
                JOIN passengers p ON p.email = $4 || $5 || '-' || g || $6
                JOIN seats st ON st.flight_id = $2 AND st.seat_number = (g / 6 + 1)::text || substr('ABCDEF', g % 6 + 1, 1)
                RETURNING pnr_code, passenger_id""",
            PNR_PREFIX, original, n, EMAIL_PREFIX, tag, EMAIL_DOMAIN,
        )  # fmt: skip
    if len(rows) != n:
        raise RuntimeError(f"Fixture has {len(rows)} bookings, expected {n}")
    return Fixture(
        str(original), str(target), sorted((r["pnr_code"], str(r["passenger_id"])) for r in rows)
    )


SQL_FACTS = """
    SELECT
      (SELECT count(*) FROM (SELECT b.assigned_seat_id FROM pnr_bookings b
                             JOIN seats st ON st.seat_id = b.assigned_seat_id
                             WHERE st.flight_id = $1
                             GROUP BY 1 HAVING count(*) > 1) d)             AS duplicate_seats,
      (SELECT coalesce(max(c), 0) FROM (SELECT count(*) c FROM pnr_bookings b
                             JOIN seats st ON st.seat_id = b.assigned_seat_id
                             WHERE st.flight_id = $1 GROUP BY b.assigned_seat_id) m) AS max_holders,
      (SELECT count(*) FROM pnr_bookings
         WHERE reaccommodated_flight_id = $1 AND booking_status = 'REACCOMMODATED') AS rebooked,
      (SELECT count(*) FROM seats WHERE flight_id = $1 AND status = 'BOOKED')       AS booked_seats,
      (SELECT count(*) FROM pnr_bookings b JOIN seats st ON st.seat_id = b.assigned_seat_id
         WHERE st.flight_id = $1)                                                   AS seats_held,
      (SELECT count(*) FROM audit_logs WHERE pnr_code LIKE $3
         AND action = ANY($2::text[]))                                              AS audit_rows,
      (SELECT count(*) FROM audit_logs WHERE pnr_code LIKE $3)                      AS audit_all
"""


@dataclass
class Call:
    ok: bool
    message: str  # the procedure's message, or the exception's class
    latency: float
    status: int | None = None  # HTTP status, API mode only
    app_ms: float | None = None  # Server-Timing app;dur
    deadlock: bool = False


@dataclass
class Run:
    mode: str
    n: int
    s: int
    run: int
    pool: int
    calls: list[Call] = field(default_factory=list)
    facts: dict = field(default_factory=dict)
    deadlocks: int | None = None  # None: pg_stat_database not readable
    checks: dict = field(default_factory=dict)
    target: str = "local"  # the CSV's target column: where the REST tier ran


def evaluate_run(calls: list[Call], n: int, s: int, facts: dict, deadlocks: int | None) -> dict:
    """Post-conditions of one run, from the calls' results and the database facts."""
    expected = min(n, s)
    successes = sum(c.ok for c in calls)
    refused = [c for c in calls if not c.ok]
    deadlock_count = (deadlocks or 0) + sum(c.deadlock for c in calls)
    return {
        "all_calls_returned": len(calls) == n,
        "no_duplicate_seats": facts["duplicate_seats"] == 0,
        "successes_eq_s": successes == expected and facts["rebooked"] == expected,
        "refusals_are_no_seat": len(refused) == n - expected
        and all(c.message == NO_SEAT for c in refused),
        "seats_conserved": facts["booked_seats"] == facts["seats_held"],
        "audit_one_per_call": facts["audit_rows"] == n,
        "no_deadlock": deadlock_count == 0,
    }


async def read_deadlocks(pool: asyncpg.Pool) -> int | None:
    try:
        async with pool.acquire() as conn:
            return await conn.fetchval(SQL_DEADLOCKS)
    except asyncpg.PostgresError:
        return None


async def call_procedure(pool: asyncpg.Pool, pnr: str, target: str) -> Call:
    try:
        async with pool.acquire() as conn:
            t0 = time.perf_counter()
            row = await conn.fetchrow(SQL_CALL, pnr, target, ACTOR)
            return Call(row["success"], row["message"], time.perf_counter() - t0)
    except asyncpg.DeadlockDetectedError as exc:
        return Call(False, type(exc).__name__, math.nan, deadlock=True)
    except (asyncpg.PostgresError, asyncpg.InterfaceError, OSError, TimeoutError) as exc:
        return Call(False, type(exc).__name__, math.nan)


async def call_api(client: httpx.AsyncClient, token: str, target: str) -> Call:
    t0 = time.perf_counter()
    try:
        r = await client.post(
            "/api/reaccommodate",
            json={"target_flight_id": target},
            headers={"Authorization": f"Bearer {token}"},
        )
    except httpx.HTTPError as exc:
        return Call(False, type(exc).__name__, math.nan)
    elapsed = time.perf_counter() - t0
    timing = r.headers.get("server-timing", "")
    app_ms = float(timing.split("dur=")[1]) if "dur=" in timing else None
    body = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
    message = body.get("message") if r.status_code == 200 else body.get("detail", r.text[:80])
    return Call(r.status_code == 200, str(message), elapsed, r.status_code, app_ms)


# Server-Timing of each sign-in: one indexed query, so the fastest is about one
# REST tier -> database round trip plus a pool acquire.
sign_in_app_ms: list[float] = []


async def sign_in(client: httpx.AsyncClient, bookings: list[tuple[str, str]]) -> list[str]:
    """One token per fixture booking from the deployed sign-in endpoint, all at
    once, so the client also holds one warm connection per later request and
    no TLS handshake falls inside the timed section. Not timed."""

    async def one(pnr: str) -> str:
        r = await client.post("/api/auth/session", json={"pnr_code": pnr, "last_name": "Test"})
        if r.status_code != 200:
            raise RuntimeError(f"Sign-in for a fixture booking returned {r.status_code}")
        timing = r.headers.get("server-timing", "")
        if "dur=" in timing:
            sign_in_app_ms.append(float(timing.split("dur=")[1]))
        return r.json()["access_token"]

    return list(await asyncio.gather(*(one(p) for p, _ in bookings)))


async def wait_online(client: httpx.AsyncClient, deadline_s: float) -> dict:
    """Poll /health with back-off until the database is connected or the
    deadline passes (0: one attempt). Returns the last answer."""
    start, delay, health = time.monotonic(), 5.0, {}
    while True:
        try:
            r = await client.get("/health")
            health = r.json() if r.status_code == 200 else {"status": r.status_code}
        except (httpx.HTTPError, ValueError) as exc:
            health = {"error": type(exc).__name__}
        if health.get("database") == "connected" or time.monotonic() - start + delay > deadline_s:
            return health
        print(f"[INFO] waiting for {client.base_url}: {health}")
        await asyncio.sleep(delay)
        delay = min(delay * 2, 30.0)


def server_failure(calls: list[Call]) -> bool:
    """A 5xx or a request without a response: stop, do not hammer a free tier."""
    return any(c.status is None or c.status >= 500 for c in calls)


async def one_run(
    pool: asyncpg.Pool, run: Run, client: httpx.AsyncClient | None, remote: bool = False
) -> Run:
    tag = f"{run.mode[0]}{run.n}r{run.run}"
    try:
        fixture = await create_fixture(pool, tag, run.n, run.s)
        before = await read_deadlocks(pool)
        if client is None:
            run.calls = list(
                await asyncio.gather(
                    *(call_procedure(pool, p, fixture.target) for p, _ in fixture.bookings)
                )
            )
        else:
            tokens = (
                await sign_in(client, fixture.bookings)
                if remote
                else [
                    issue_token(
                        pnr_code=p, passenger_id=pid, last_name="Test", rewards_tier="BLUE"
                    )[0]
                    for p, pid in fixture.bookings
                ]
            )
            run.calls = list(
                await asyncio.gather(*(call_api(client, t, fixture.target) for t in tokens))
            )
        await asyncio.sleep(1.0)  # pg_stat_database is flushed about once a second
        after = await read_deadlocks(pool)
        run.deadlocks = after - before if before is not None and after is not None else None
        async with pool.acquire() as conn:
            run.facts = dict(
                await conn.fetchrow(SQL_FACTS, fixture.target, list(PROCEDURE_ACTIONS), PNR_LIKE)
            )
        run.checks = evaluate_run(run.calls, run.n, run.s, run.facts, run.deadlocks)
    finally:
        await cleanup(pool)
    return run


def latencies(calls: list[Call]) -> list[float]:
    return [c.latency for c in calls if not math.isnan(c.latency)]


def ms(values: list[float], p: float | None = None) -> str:
    if not values:
        return ""
    v = max(values) if p is None else percentile(values, p)
    return f"{v * 1000:.0f}"


def row_for(run: Run) -> dict:
    lat = latencies(run.calls)
    refused = Counter(c.message for c in run.calls if not c.ok)
    app = [c.app_ms / 1000 for c in run.calls if c.app_ms is not None]
    return {
        "target": run.target,
        "mode": run.mode,
        "n": run.n,
        "s": run.s,
        "run": run.run,
        "pool": run.pool,
        "successes": sum(c.ok for c in run.calls),
        "refusals": sum(not c.ok for c in run.calls),
        "refusal_messages": "; ".join(f"{k} x{v}" for k, v in refused.items()),
        "statuses": "; ".join(
            f"{k} x{v}" for k, v in sorted(Counter(c.status for c in run.calls).items(), key=str)
        )
        if run.mode == "api"
        else "",
        "max_holders_per_seat": run.facts.get("max_holders", ""),
        "duplicate_seats": run.facts.get("duplicate_seats", ""),
        "booked_seats": run.facts.get("booked_seats", ""),
        "seats_held": run.facts.get("seats_held", ""),
        "audit_rows": run.facts.get("audit_rows", ""),
        "audit_rows_all_actions": run.facts.get("audit_all", ""),
        "deadlocks": "not available" if run.deadlocks is None else run.deadlocks,
        "p50_ms": ms(lat, 50),
        "p95_ms": ms(lat, 95),
        "max_ms": ms(lat),
        "app_p50_ms": ms(app, 50),
        "app_p95_ms": ms(app, 95),
        "passed": all(run.checks.values()),
        "failed_checks": " ".join(k for k, v in run.checks.items() if not v),
    }


def summarise(label: str, runs: list[Run], p95_limit: float | None = None) -> bool:
    lat = [x for r in runs for x in latencies(r.calls)]
    passed = all(all(r.checks.values()) for r in runs)
    print(
        f"[RESULT] {label}: {len(runs)} runs, checks {'all passed' if passed else 'FAILED'}; "
        f"latency p50={ms(lat, 50)} ms p95={ms(lat, 95)} ms max={ms(lat)} ms"
    )
    if p95_limit is not None:
        p95_ok = bool(lat) and percentile(lat, 95) <= p95_limit
        app = [c.app_ms for r in runs for c in r.calls if c.app_ms is not None]
        if app:
            print(
                f"[RESULT] {label}: Server-Timing app p50={percentile(app, 50):.0f} ms p95={percentile(app, 95):.0f} ms"
            )
        print(f"[RESULT] {label}: p95 <= {p95_limit:.1f} s: {'PASS' if p95_ok else 'FAIL'}")
        passed = passed and p95_ok
    return passed


def csv_writer(path: str | None):
    """Append each run's row as soon as it is known, so a crash keeps the runs so far."""
    header_written = False

    def save(row: dict) -> None:
        nonlocal header_written
        if not path:
            return
        with open(path, "a" if header_written else "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=list(row))
            if not header_written:
                writer.writeheader()
                header_written = True
            writer.writerow(row)

    return save


async def open_pool(size: int) -> asyncpg.Pool:
    # Every connection opened up front: the session pooler refuses clients
    # beyond its pool_size (15, shared with the REST tier), and a refusal
    # mid-run would also leave the finally block's cleanup without one.
    return await asyncpg.create_pool(
        os.environ["DATABASE_URL"], min_size=size, max_size=size, statement_cache_size=0
    )


async def main(args) -> int:
    rows, passed = [], True
    save = csv_writer(args.csv)
    if args.mode in ("integrity", "all"):
        pool = await open_pool(args.pool)
        try:
            await cleanup(pool)  # leftovers of an earlier crashed run
            for n in args.sizes:
                runs = []
                for k in range(1, args.runs + 1):
                    run = await one_run(pool, Run("integrity", n, n // 2, k, args.pool), None)
                    row = row_for(run)
                    rows.append(row)
                    save(row)
                    runs.append(run)
                    print(f"[RUN] integrity N={n} #{k}: {row['successes']} ok, {row['refusals']} refused, "
                          f"p95={row['p95_ms']} ms, {'pass' if row['passed'] else 'FAIL ' + row['failed_checks']}")  # fmt: skip
                passed &= summarise(f"integrity N={n}", runs)
        finally:
            await pool.close()
    if args.mode in ("api", "all"):
        remote = args.api_base.rstrip("/") != API_URL
        if not remote and not os.getenv("SESSION_SECRET"):
            print("[ERROR] SESSION_SECRET is not set: the REST tier would refuse every token.")
            return 1
        pool = await open_pool(2)  # the REST tier's own pool shares the pooler's limit
        # Keep the sign-in connections open into the timed burst (httpx's default is 5 s).
        limits = httpx.Limits(max_connections=200, keepalive_expiry=120)
        stopped = False
        try:
            await cleanup(pool)
            async with httpx.AsyncClient(
                base_url=args.api_base, timeout=60, limits=limits
            ) as client:
                health = await wait_online(client, HEALTH_WAIT_S if remote else 0)
                if health.get("database") != "connected":
                    print(f"[ERROR] REST tier not ready: {health}. Local: .\\tasks.ps1 start")
                    return 1
                for n in args.api_sizes:
                    runs = []
                    for k in range(1, args.runs + 1):
                        sign_in_app_ms.clear()
                        run = Run("api", n, n // 2, k, 0, target=args.target)
                        run = await one_run(pool, run, client, remote)
                        row = row_for(run)
                        rows.append(row)
                        save(row)
                        runs.append(run)
                        sign_ins = (
                            f", sign-in app min={min(sign_in_app_ms):.0f} ms"
                            if sign_in_app_ms
                            else ""
                        )
                        print(f"[RUN] api N={n} #{k}: {row['statuses']}, p50={row['p50_ms']} p95={row['p95_ms']} "
                              f"max={row['max_ms']} ms, app p95={row['app_p95_ms']} ms{sign_ins}, "
                              f"{'pass' if row['passed'] else 'FAIL ' + row['failed_checks']}")  # fmt: skip
                        if server_failure(run.calls):
                            print("[ERROR] 5xx or no response: stopping (fixture cleaned up).")
                            stopped = True
                            break
                    passed &= summarise(f"api N={n}", runs, P95_LIMIT_S)
                    if stopped:
                        passed = False
                        break
        finally:
            await pool.close()
    if args.csv and rows:
        print(f"[INFO] {len(rows)} runs written to {args.csv}")
    print("[PASS]" if passed else "[FAIL]")
    return 0 if passed else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Concurrent rebooking load test, self-cleaning fixture."
    )
    parser.add_argument("--mode", choices=["integrity", "api", "all"], default="all")
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument(
        "--sizes", type=lambda v: [int(x) for x in v.split(",")], default=[50, 100, 200]
    )
    parser.add_argument(
        "--pool", type=int, default=10, help="asyncpg pool size for the integrity runs"
    )
    parser.add_argument("--csv", help="write one row per run to this file")
    parser.add_argument("--api-base", default=API_URL, help="REST tier for the API runs")
    parser.add_argument(
        "--api-sizes", type=lambda v: [int(x) for x in v.split(",")], default=[API_N]
    )
    parser.add_argument("--target", default="local", help="label for the CSV's target column")
    sys.exit(asyncio.run(main(parser.parse_args())))
