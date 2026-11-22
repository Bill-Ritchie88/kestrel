"""
Project Kestrel - a demo booking that qualifies for cash compensation
(migration 016, supervisor review of 20 Nov 2026: "compensation can be done
by the system").

EU261/UK261 cash applies only to departures from the EU or UK
(entitlements.applicable_regulation), and the generated schedule has no
bookings on those flights. This makes one synthetic passenger on one new
flight, KQ0921 London (LHR) -> Nairobi, a few hours before a real scheduled
LHR -> NBO flight with free economy seats (so the passenger has somewhere to
go), and cancels it for a cause within the airline's control (TECHNICAL).
The passenger rebooks, then claims; staff approve and pay in the Staff desk.

    python scripts/data/create_compensation_booking.py             # create, or refresh
    python scripts/data/create_compensation_booking.py --dry-run   # do it all, then roll back
    python scripts/data/create_compensation_booking.py --cleanup   # remove everything it made

Our rows: flight KQ0921 (the generator never writes a leading zero) and the
e-mail compensation+1@example.com. Re-running keeps the booking reference.
Prints only the booking reference and surname. Requires migration 016.
"""

import argparse
import asyncio
import os
import sys
from datetime import datetime, timedelta
from pathlib import Path

import asyncpg

sys.path.insert(0, str(Path(__file__).resolve().parent))
from create_usability_bookings import (  # noqa: E402  - also loads .env
    SQL_INSERT_SEATS,
    plan_departure,
)
from generate_dataset import AIRCRAFT, make_pnr, seat_map  # noqa: E402

FIRST, SURNAME = "Claire", "Claimant"  # clearly not a real person
EMAIL = "compensation+1@example.com"
FLIGHT_NUMBER = "KQ0921"
PHONE = "+0000000000"
SEAT = "20A"
ORIGIN, DESTINATION = "LHR", "NBO"
BEFORE_ALTERNATIVE = timedelta(hours=3)  # our flight leaves this long before the real one

SQL_HAS_016 = "SELECT to_regclass('public.compensation_claims') IS NOT NULL"

# The first real scheduled LHR -> NBO flight far enough ahead, with free economy.
SQL_ALTERNATIVE = """
    SELECT f.flight_id, f.departure_time, f.arrival_time, f.aircraft_type
    FROM flights f
    WHERE f.origin = $1 AND f.destination = $2 AND f.status = 'SCHEDULED'
      AND f.flight_number <> $3 AND f.departure_time >= $4
      AND EXISTS (SELECT 1 FROM seats s WHERE s.flight_id = f.flight_id
                  AND s.cabin_class = 'ECONOMY' AND s.status = 'AVAILABLE')
    ORDER BY f.departure_time
    LIMIT 1
"""

SQL_OURS = "SELECT b.pnr_code FROM pnr_bookings b JOIN passengers p USING (passenger_id) WHERE p.email = $1"


def cleanup_statements() -> list[tuple[str, tuple]]:
    """(sql, args) removing every row this script made, children first."""
    ours = f"pnr_code IN ({SQL_OURS})"
    return [
        # A seat the passenger was rebooked into, on a real flight.
        ("""UPDATE seats SET status = 'AVAILABLE', row_version = row_version + 1
            WHERE status <> 'AVAILABLE' AND seat_id IN (
                SELECT b.assigned_seat_id FROM pnr_bookings b
                JOIN passengers p USING (passenger_id) WHERE p.email = $1)""", (EMAIL,)),
        *((f"DELETE FROM {t} WHERE {ours}", (EMAIL,))  # noqa: S608 - constants only, values bound
          for t in ("vouchers", "handoff_cases", "chat_messages", "compensation_claims")),
        (f"DELETE FROM pnr_bookings WHERE {ours}", (EMAIL,)),  # noqa: S608
        ("DELETE FROM passenger_accounts WHERE passenger_id IN "
         "(SELECT passenger_id FROM passengers WHERE email = $1)", (EMAIL,)),
        ("DELETE FROM passengers WHERE email = $1", (EMAIL,)),
        ("DELETE FROM flights WHERE flight_number = $1", (FLIGHT_NUMBER,)),  # seats cascade
    ]  # fmt: skip


async def cleanup(conn: asyncpg.Connection) -> None:
    strangers = await conn.fetchval(
        """SELECT count(*) FROM pnr_bookings b JOIN flights f
           ON f.flight_id IN (b.original_flight_id, b.reaccommodated_flight_id)
           WHERE f.flight_number = $1 AND b.passenger_id NOT IN
                 (SELECT passenger_id FROM passengers WHERE email = $2)""",
        FLIGHT_NUMBER, EMAIL,
    )  # fmt: skip
    if strangers:
        raise RuntimeError(
            f"{strangers} other booking(s) use {FLIGHT_NUMBER}; refusing to touch them."
        )
    for sql, args in cleanup_statements():
        await conn.execute(sql, *args)


async def create(conn: asyncpg.Connection) -> tuple[str, datetime]:
    if not await conn.fetchval(SQL_HAS_016):
        raise RuntimeError(
            "Migration 016 is not applied: apply db/migrations/016_compensation_and_edge_cases.sql."
        )
    kept = await conn.fetchval(SQL_OURS, EMAIL)
    await cleanup(conn)

    earliest = plan_departure(datetime.now().astimezone()) + BEFORE_ALTERNATIVE
    alt = await conn.fetchrow(SQL_ALTERNATIVE, ORIGIN, DESTINATION, FLIGHT_NUMBER, earliest)
    if alt is None or alt["aircraft_type"] not in AIRCRAFT:
        raise RuntimeError(
            "No later scheduled LHR-NBO flight with free economy seats to rebook onto."
        )
    departure = alt["departure_time"] - BEFORE_ALTERNATIVE
    arrival = departure + (alt["arrival_time"] - alt["departure_time"])

    flight_id = await conn.fetchval(
        """INSERT INTO flights (flight_number, origin, destination, departure_time, arrival_time, status,
                                aircraft_type)
           VALUES ($1, $2, $3, $4, $5, 'SCHEDULED', $6) RETURNING flight_id""",
        FLIGHT_NUMBER, ORIGIN, DESTINATION, departure, arrival, alt["aircraft_type"],
    )  # fmt: skip
    seats = seat_map(alt["aircraft_type"])
    await conn.execute(
        SQL_INSERT_SEATS, flight_id, [n for n, _ in seats], [c for _, c in seats], [SEAT]
    )

    await conn.execute(
        "INSERT INTO passengers (first_name, last_name, email, phone_number) VALUES ($1, $2, $3, $4)",
        FIRST, SURNAME, EMAIL, PHONE,
    )  # fmt: skip
    pnr = kept
    while pnr is None or (
        pnr != kept and await conn.fetchval("SELECT 1 FROM pnr_bookings WHERE pnr_code = $1", pnr)
    ):
        pnr = make_pnr(set())
    await conn.execute(
        """INSERT INTO pnr_bookings (pnr_code, passenger_id, original_flight_id, assigned_seat_id, booking_status)
           SELECT $1, p.passenger_id, $2::uuid,
                  (SELECT seat_id FROM seats WHERE flight_id = $2::uuid AND seat_number = $3), 'DISRUPTED'
           FROM passengers p WHERE p.email = $4""",
        pnr, flight_id, SEAT, EMAIL,
    )  # fmt: skip
    # Within the airline's control, so Art. 5(3) gives no way out of compensation.
    await conn.execute(
        "UPDATE flights SET status = 'CANCELLED', disruption_reason = 'TECHNICAL' WHERE flight_id = $1",
        flight_id,
    )
    return pnr, departure


class DryRun(Exception):
    """Raised inside the transaction to roll it back."""


async def main(args: argparse.Namespace) -> int:
    url = os.getenv("DATABASE_URL")
    if not url:
        print("[ERROR] DATABASE_URL is not set. Copy .env.example to .env first.")
        return 1
    conn = await asyncpg.connect(url, statement_cache_size=0)
    try:
        async with conn.transaction():
            if args.cleanup:
                await cleanup(conn)
            else:
                pnr, departure = await create(conn)
            if args.dry_run:
                raise DryRun
    except DryRun:
        print("[DRY RUN] " + ("Cleanup ran" if args.cleanup else
              f"{FLIGHT_NUMBER} {ORIGIN}-{DESTINATION} {departure:%d %b %H:%M %Z}, cancelled (TECHNICAL), "
              "1 booking DISRUPTED") + ". Rolled back; nothing changed.")  # fmt: skip
        return 0
    except (asyncpg.PostgresError, OSError, RuntimeError) as exc:
        print(f"[ERROR] {type(exc).__name__}: {exc}")
        return 1
    finally:
        await conn.close()

    if args.cleanup:
        print("[OK] Compensation demo flight, passenger and booking removed.")
    else:
        print(
            f"{FLIGHT_NUMBER} {ORIGIN}-{DESTINATION} {departure:%d %b %H:%M %Z}, cancelled (TECHNICAL)"
        )
        print(f"K1  {pnr}  {SURNAME}")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="A Kestrel demo booking that qualifies for cash compensation."
    )
    parser.add_argument(
        "--cleanup", action="store_true", help="Remove everything this script created."
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="Run inside a transaction, then roll it back."
    )
    sys.exit(asyncio.run(main(parser.parse_args())))
