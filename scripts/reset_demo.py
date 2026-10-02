"""
Project Kestrel - demo data reset.

The synthetic schedule covers a fixed window (the generator's --days) anchored
to the moment it was generated or last reset. Once that window has passed every
flight is in the past, no disrupted passenger has anywhere to go, and the smoke
test, the integration tests and the agent demo all fail for reasons that have
nothing to do with the code. Rebooking passengers during a demo uses the
disruption up in the same way.

db/seeds/reset_demo_state.sql re-anchors the schedule to now() and recreates
the disruption. This script runs it - unconditionally, or with --if-stale only
when the demo can no longer work - so nobody has to remember to.

    python scripts/reset_demo.py              # always reset
    python scripts/reset_demo.py --if-stale   # reset only if the demo is unusable

audit_logs is preserved either way. smoke_test.py and agent_demo.py import
ensure_fresh() from here and call it themselves.
"""

import argparse
import asyncio
import os
import sys
from pathlib import Path

import asyncpg
from dotenv import load_dotenv

PROJECT_ROOT = Path(__file__).resolve().parent.parent
RESET_SQL = PROJECT_ROOT / "db" / "seeds" / "reset_demo_state.sql"
load_dotenv(dotenv_path=PROJECT_ROOT / ".env")

# One disrupted passenger together with the earliest alternative on the same
# route that still has a free seat. Choosing the booking and the flight in one
# query matters: picking any disrupted booking first and then looking for a
# flight can land on a route that has no capacity left. The six-hour lead time
# stops a flight from departing in the middle of a demonstration.
FIND_DEMO_CASE = """
    SELECT b.pnr_code, p.last_name, o.origin, o.destination,
           alt.flight_id, alt.flight_number, alt.departure_time
    FROM pnr_bookings b
    JOIN passengers p ON p.passenger_id = b.passenger_id
    JOIN flights    o ON o.flight_id    = b.original_flight_id
    JOIN flights  alt ON alt.origin = o.origin AND alt.destination = o.destination
    WHERE b.booking_status = 'DISRUPTED'
      AND alt.status = 'SCHEDULED'
      AND alt.departure_time > now() + interval '6 hours'
      AND EXISTS (SELECT 1 FROM seats s
                  WHERE s.flight_id = alt.flight_id AND s.status = 'AVAILABLE')
    ORDER BY alt.departure_time, b.pnr_code
    LIMIT 1
"""


async def find_demo_case(conn: asyncpg.Connection) -> asyncpg.Record | None:
    return await conn.fetchrow(FIND_DEMO_CASE)


async def reset(conn: asyncpg.Connection) -> None:
    # No arguments, so asyncpg sends the file as one simple-protocol query and
    # its own BEGIN/COMMIT apply. The trailing verification SELECT is discarded.
    await conn.execute(RESET_SQL.read_text(encoding="utf-8"))


async def ensure_fresh(conn: asyncpg.Connection, force: bool = False) -> asyncpg.Record:
    """Reset if forced or if no usable demo case exists; return a usable case."""
    case = None if force else await find_demo_case(conn)
    if case is None:
        print("[INFO] Resetting demo data: re-anchoring the schedule to now...")
        await reset(conn)
        case = await find_demo_case(conn)
        if case is None:
            raise RuntimeError(
                "Even after a reset no disrupted passenger has an alternative "
                "flight with a free seat. Regenerate the dataset with more --days "
                "(scripts/dataset_generator.py)."
            )
        print("[OK]   Demo data reset.")
    return case


async def main(args: argparse.Namespace) -> int:
    url = os.getenv("DATABASE_URL")
    if not url:
        print("[ERROR] DATABASE_URL is not set. Copy .env.example to .env first.")
        return 1

    conn = await asyncpg.connect(url, statement_cache_size=0)
    try:
        if args.if_stale and await find_demo_case(conn) is not None:
            print("[OK]   Demo data is current; no reset needed.")
        case = await ensure_fresh(conn, force=not args.if_stale)
        disrupted = await conn.fetchval(
            "SELECT count(*) FROM pnr_bookings WHERE booking_status = 'DISRUPTED'"
        )
        last = await conn.fetchval("SELECT max(departure_time) FROM flights")
    except (asyncpg.PostgresError, OSError, RuntimeError) as exc:
        print(f"[ERROR] {type(exc).__name__}: {exc}")
        return 1
    finally:
        await conn.close()

    print(f"[OK]   {disrupted} disrupted passengers; schedule runs until {last:%d %b %H:%M} UTC")
    print(
        f"[DEMO] PNR {case['pnr_code']} / surname {case['last_name']} "
        f"({case['origin']}-{case['destination']}) -> {case['flight_number']} "
        f"departing {case['departure_time']:%d %b %H:%M} UTC"
    )
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Reset the Project Kestrel demo data.")
    parser.add_argument(
        "--if-stale",
        action="store_true",
        help="Only reset when no disrupted passenger has a usable alternative flight.",
    )
    sys.exit(asyncio.run(main(parser.parse_args())))
