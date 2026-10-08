"""
Concurrent rebooking load test (NFR-01, NFR-02).

Takes N disrupted passengers from one cancelled flight and fires their
rebooking requests at the SAME alternative flight - the one with the fewest
free seats in their cabin - simultaneously, each on its
own database connection, so they genuinely contend for the same seats. Run it
with more passengers than free seats in their cabin to exercise the
"no seats remaining" path under contention.

Checks afterwards (the acceptance criteria in Section 5.5.6):
  * no seat is held by two bookings;
  * no booking holds more than one seat (by construction of pnr_bookings);
  * successes never exceed the free seats that existed before the run;
  * 95th-percentile latency of the procedure call.

Everything runs inside transactions that are rolled back, so the demo data
is unchanged. Each worker holds its transaction open until all have finished,
which is what makes the contention real.

    python scripts/load_test.py --passengers 12

Keep --passengers within the Supabase session pooler's connection limit (15 on
the free plan, minus the API's own pool).
"""

import argparse
import asyncio
import os
import statistics
import sys
import time

import asyncpg

from kestrel import config  # noqa: F401  - loads .env

# The alternative flight with the FEWEST free seats in the stranded
# passengers' cabin (but at least one), so a modest number of concurrent
# requests already exceeds capacity and the sold-out path runs under real
# contention.
PICK_TARGET = """
    WITH cand AS (
        SELECT o.flight_id AS cancelled, alt.flight_id AS alt_id, alt.flight_number,
               COALESCE(cur.cabin_class::text, 'ECONOMY') AS cabin,
               count(*) AS stranded
        FROM pnr_bookings b
        JOIN flights o   ON o.flight_id = b.original_flight_id
        JOIN flights alt ON alt.origin = o.origin AND alt.destination = o.destination
        LEFT JOIN seats cur ON cur.seat_id = b.assigned_seat_id
        WHERE b.booking_status = 'DISRUPTED' AND alt.status = 'SCHEDULED'
          AND alt.departure_time > now() + interval '1 hour'
        GROUP BY 1, 2, 3, 4
    )
    SELECT c.*,
           (SELECT count(*) FROM seats s WHERE s.flight_id = c.alt_id
              AND s.status = 'AVAILABLE' AND s.cabin_class::text = c.cabin) AS free_seats
    FROM cand c
    ORDER BY (SELECT count(*) FROM seats s WHERE s.flight_id = c.alt_id
                AND s.status = 'AVAILABLE' AND s.cabin_class::text = c.cabin) > 0 DESC,
             (SELECT count(*) FROM seats s WHERE s.flight_id = c.alt_id
                AND s.status = 'AVAILABLE' AND s.cabin_class::text = c.cabin) ASC
    LIMIT 1;
"""

PICK_PASSENGERS = """
    SELECT b.pnr_code
    FROM pnr_bookings b
    LEFT JOIN seats cur ON cur.seat_id = b.assigned_seat_id
    WHERE b.original_flight_id = $1 AND b.booking_status = 'DISRUPTED'
      AND COALESCE(cur.cabin_class::text, 'ECONOMY') = $2
    ORDER BY b.pnr_code
    LIMIT $3;
"""


async def worker(dsn, pnr, flight_id, start: asyncio.Event, done: asyncio.Barrier, out: list):
    conn = await asyncpg.connect(dsn, statement_cache_size=0)
    tx = conn.transaction()
    await tx.start()
    try:
        await start.wait()
        t0 = time.perf_counter()
        row = await conn.fetchrow(
            "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3)", pnr, flight_id, "LOADTEST"
        )
        elapsed = time.perf_counter() - t0
        seat = row["assigned_seat_number"] if row["success"] else None
        out.append((pnr, row["success"], seat, elapsed, row["message"]))
        await done.wait()  # hold locks until every worker has finished
    finally:
        await tx.rollback()
        await conn.close()


async def main(n: int) -> int:
    dsn = os.environ["DATABASE_URL"]
    conn = await asyncpg.connect(dsn, statement_cache_size=0)
    target = await conn.fetchrow(PICK_TARGET)
    rows = (
        await conn.fetch(PICK_PASSENGERS, target["cancelled"], target["cabin"], n) if target else []
    )
    await conn.close()
    if not rows:
        print("[ERROR] No disrupted passengers with an alternative. Run: python scripts/reset_demo.py")
        return 1
    flight_id, free = target["alt_id"], target["free_seats"]
    print(
        f"[INFO] {len(rows)} concurrent requests -> {target['flight_number']} ({flight_id}), "
        f"{free} free {target['cabin'].lower()} seats"
    )

    start, out = asyncio.Event(), []
    done = asyncio.Barrier(len(rows))
    tasks = [asyncio.create_task(worker(dsn, r["pnr_code"], flight_id, start, done, out)) for r in rows]
    await asyncio.sleep(1.0)  # let every connection open before the start signal
    start.set()
    await asyncio.gather(*tasks)

    ok = [o for o in out if o[1]]
    seats = [o[2] for o in ok]
    latencies = sorted(o[3] for o in out)
    p95 = latencies[max(0, int(round(0.95 * len(latencies))) - 1)]
    duplicate_seats = len(seats) - len(set(seats))

    print(f"[RESULT] requests={len(out)} succeeded={len(ok)} refused={len(out) - len(ok)}")
    print(f"[RESULT] duplicate seats among successes: {duplicate_seats} (must be 0)")
    print(f"[RESULT] successes <= free seats: {len(ok) <= free} ({len(ok)} <= {free})")
    print(f"[RESULT] latency p50={statistics.median(latencies) * 1000:.0f} ms "
          f"p95={p95 * 1000:.0f} ms max={latencies[-1] * 1000:.0f} ms (NFR-01: p95 < 2000 ms)")  # fmt: skip
    for reason, count in sorted(
        {m: sum(1 for o in out if not o[1] and o[4] == m) for m in {o[4] for o in out if not o[1]}}.items()
    ):
        print(f"[RESULT] refused: {count} x {reason}")
    passed = duplicate_seats == 0 and len(ok) <= free and p95 < 2.0
    print("[PASS]" if passed else "[FAIL]")
    return 0 if passed else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Concurrent rebooking load test.")
    parser.add_argument("--passengers", type=int, default=12)
    sys.exit(asyncio.run(main(parser.parse_args().passengers)))
