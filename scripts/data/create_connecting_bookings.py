"""
Project Kestrel - connecting-flight demo bookings (migration 015, supervisor
review of 20 Nov 2026: "what if the cancelled flight is a connection?").

Creates three synthetic passengers, each on a two-flight journey through
Nairobi (X -> NBO -> Y) on a route pair the schedule really flies, and breaks
each journey a different way:

  C1  leg 1 cancelled (TECHNICAL)            -> leg 2 "Missed connection"
  C2  leg 1 delayed 100 minutes              -> lands 20 minutes before leg 2
                                                leaves, under the 60-minute MCT
  C3  leg 2 cancelled (CREW)                 -> keep leg 1, new onward flight

The bookings are made CONFIRMED and the flights then cancelled or delayed, so
it is migration 015's trigger that marks them DISRUPTED (the script checks it
did). Prints only each booking reference and surname.

    python scripts/data/create_connecting_bookings.py             # create, or refresh
    python scripts/data/create_connecting_bookings.py --dry-run   # do it all, then roll back
    python scripts/data/create_connecting_bookings.py --cleanup   # remove everything it made
    python scripts/data/create_connecting_bookings.py --dry-run         --preview-migration db/migrations/015_connecting_flights.sql   # before 015 is applied

Every row is recognisable by a fixed marker: flights KQ0911-KQ0916 (the
generator never writes a leading zero), the exact e-mail addresses
connecting+1..3@example.com. It never touches flight KQ606, the demo
passengers, or the usability flight KQ0901 and its six bookings: their routes
are never chosen. Re-running keeps each passenger's booking reference.
Requires migration 015. reset_demo.py (.\tasks.ps1 reset) does not know the
onward columns: run this script again after any reset.
"""

import argparse
import asyncio
import os
import sys
from datetime import datetime, timedelta
from pathlib import Path

import asyncpg

sys.path.insert(0, str(Path(__file__).resolve().parent))
from create_usability_bookings import FLIGHT_NUMBER as USABILITY_FLIGHT  # noqa: E402
from create_usability_bookings import (  # noqa: E402  - also loads .env
    PROTECTED_FLIGHT,
    PROTECTED_PASSENGERS,
    SQL_CANDIDATE_ROUTES,
    SQL_INSERT_SEATS,
    SQL_PROTECTED_ROUTES,
    block_time,
    plan_departure,
)
from generate_dataset import AIRCRAFT, make_pnr, seat_map  # noqa: E402

from kestrel.api.journeys import LEG_CANDIDATES, SQL_JOURNEY_LEGS, build_journeys  # noqa: E402

HUB = "NBO"
CONNECTION = timedelta(hours=2)  # booked time at the hub; MCT is 60 minutes
DELAY = timedelta(minutes=100)  # C2: leaves 20 minutes at the hub
MIN_LATER_FLIGHTS = 2
# (first name, surname, scenario), clearly not real people
PASSENGERS = [
    ("Cara", "Connex", "LEG1_CANCELLED"),
    ("Dan", "Layover", "LEG1_DELAYED"),
    ("Eve", "Transfer", "LEG2_CANCELLED"),
]
EMAILS = [f"connecting+{i}@example.com" for i in range(1, len(PASSENGERS) + 1)]
FLIGHT_NUMBERS = [f"KQ{911 + i:04d}" for i in range(2 * len(PASSENGERS))]  # KQ0911..KQ0916
PHONE = "+0000000000"
SEAT = "20A"  # each passenger's economy seat on both their flights


# ---------------------------------------------------------------------------
# Planning: pure, unit-tested without a database (tests/unit/test_usability.py)
# ---------------------------------------------------------------------------


def choose_journey(candidates: list[dict], protected: set[tuple[str, str]]) -> tuple[dict, dict] | None:
    """The (X -> NBO, NBO -> Y) route pair with the most later flights on its
    thinner leg, X != Y, neither route protected. Candidates as
    create_usability_bookings.SQL_CANDIDATE_ROUTES returns them."""

    def ok(c):
        return ((c["origin"], c["destination"]) not in protected and c["aircraft"] in AIRCRAFT
                and c["later_flights"] >= MIN_LATER_FLIGHTS and c["free_economy"] >= len(PASSENGERS))  # fmt: skip

    firsts = [c for c in candidates if c["destination"] == HUB and c["origin"] != HUB and ok(c)]
    onwards = [c for c in candidates if c["origin"] == HUB and c["destination"] != HUB and ok(c)]
    pairs = [(a, b) for a in firsts for b in onwards if a["origin"] != b["destination"]]
    return max(
        pairs,
        key=lambda ab: (min(ab[0]["later_flights"], ab[1]["later_flights"]),
                        ab[0]["origin"], ab[1]["destination"]),
        default=None,
    )  # fmt: skip


def plan_flights(first: dict, onward: dict, departure: datetime) -> list[dict]:
    """Each passenger's own two flights, as booked (before the disruption)."""
    flights = []
    for i, _ in enumerate(PASSENGERS):
        dep1 = departure + timedelta(minutes=10 * i)
        arr1 = dep1 + block_time(HUB, first["aircraft"])
        dep2 = arr1 + CONNECTION
        flights.append({"number": FLIGHT_NUMBERS[2 * i], "origin": first["origin"], "destination": HUB,
                        "aircraft": first["aircraft"], "departure": dep1, "arrival": arr1})  # fmt: skip
        flights.append({"number": FLIGHT_NUMBERS[2 * i + 1], "origin": HUB,
                        "destination": onward["destination"], "aircraft": onward["aircraft"],
                        "departure": dep2, "arrival": dep2 + block_time(onward["destination"], onward["aircraft"])})  # fmt: skip
    return flights


def disruption(scenario: str, first_number: str, onward_number: str) -> tuple[str, tuple]:
    """The UPDATE that breaks one journey (migration 015's trigger does the rest)."""
    if scenario == "LEG1_CANCELLED":
        return ("UPDATE flights SET status = 'CANCELLED', disruption_reason = 'TECHNICAL' WHERE flight_number = $1",
                (first_number,))  # fmt: skip
    if scenario == "LEG1_DELAYED":
        return ("UPDATE flights SET status = 'DELAYED', disruption_reason = 'OPERATIONAL', "
                "departure_time = departure_time + $2::interval, arrival_time = arrival_time + $2::interval "
                "WHERE flight_number = $1", (first_number, DELAY))  # fmt: skip
    if scenario == "LEG2_CANCELLED":
        return ("UPDATE flights SET status = 'CANCELLED', disruption_reason = 'CREW' WHERE flight_number = $1",
                (onward_number,))  # fmt: skip
    raise ValueError(scenario)


# ---------------------------------------------------------------------------
# SQL. Our rows: flight_number = ANY(FLIGHT_NUMBERS), email = ANY(EMAILS).
# ---------------------------------------------------------------------------

SQL_HAS_015 = "SELECT to_regprocedure('reaccommodate_journey_atomic(varchar, uuid, uuid, varchar, uuid, uuid)') IS NOT NULL"

SQL_KEPT_PNRS = """
    SELECT p.email, b.pnr_code FROM pnr_bookings b
    JOIN passengers p ON p.passenger_id = b.passenger_id
    WHERE p.email = ANY($1::text[])
"""

SQL_STRANGERS = """
    SELECT count(*) FROM pnr_bookings b
    JOIN flights f ON f.flight_id IN (b.original_flight_id, b.reaccommodated_flight_id,
                                      b.onward_flight_id, b.reaccommodated_onward_flight_id)
    WHERE f.flight_number = ANY($2::text[])
      AND b.passenger_id NOT IN (SELECT passenger_id FROM passengers WHERE email = ANY($1::text[]))
"""

SQL_OURS = "SELECT b.pnr_code FROM pnr_bookings b JOIN passengers p USING (passenger_id) WHERE p.email = ANY($1::text[])"


def cleanup_statements() -> list[tuple[str, tuple]]:
    """(sql, args) removing every row this script made, children first."""
    # Built from constants only; every value is bound, so S608 does not apply.
    ours = f"pnr_code IN ({SQL_OURS})"
    return [
        # Seats a passenger was rebooked into, on real flights.
        ("""UPDATE seats SET status = 'AVAILABLE', row_version = row_version + 1
            WHERE status <> 'AVAILABLE' AND seat_id IN (
                SELECT unnest(ARRAY[b.assigned_seat_id, b.onward_seat_id]) FROM pnr_bookings b
                JOIN passengers p USING (passenger_id) WHERE p.email = ANY($1::text[]))""", (EMAILS,)),
        *((f"DELETE FROM {t} WHERE {ours}", (EMAILS,)) for t in ("vouchers", "handoff_cases", "chat_messages", "compensation_claims")),  # noqa: S608
        (f"DELETE FROM pnr_bookings WHERE {ours}", (EMAILS,)),  # noqa: S608
        ("DELETE FROM passenger_accounts WHERE passenger_id IN "
         "(SELECT passenger_id FROM passengers WHERE email = ANY($1::text[]))", (EMAILS,)),
        ("DELETE FROM passengers WHERE email = ANY($1::text[])", (EMAILS,)),
        ("DELETE FROM flights WHERE flight_number = ANY($1::text[])", (FLIGHT_NUMBERS,)),  # seats cascade
    ]  # fmt: skip


SQL_INSERT_FLIGHT = """
    INSERT INTO flights (flight_number, origin, destination, departure_time, arrival_time, status, aircraft_type)
    VALUES ($1, $2, $3, $4, $5, 'SCHEDULED', $6) RETURNING flight_id
"""

SQL_INSERT_BOOKING = """
    INSERT INTO pnr_bookings (pnr_code, passenger_id, original_flight_id, assigned_seat_id,
                              onward_flight_id, onward_seat_id, booking_status)
    SELECT $1, p.passenger_id, $3::uuid,
           (SELECT seat_id FROM seats WHERE flight_id = $3::uuid AND seat_number = $5),
           $4::uuid,
           (SELECT seat_id FROM seats WHERE flight_id = $4::uuid AND seat_number = $5),
           'CONFIRMED'
    FROM passengers p WHERE p.email = $2
"""


# ---------------------------------------------------------------------------
# Database steps
# ---------------------------------------------------------------------------


async def cleanup(conn: asyncpg.Connection) -> None:
    strangers = await conn.fetchval(SQL_STRANGERS, EMAILS, FLIGHT_NUMBERS)
    if strangers:
        raise RuntimeError(f"{strangers} other booking(s) use {FLIGHT_NUMBERS[0]}..; refusing to touch them.")
    for sql, args in cleanup_statements():
        await conn.execute(sql, *args)


async def create(conn: asyncpg.Connection) -> tuple[list[str], tuple[dict, dict], datetime]:
    if not await conn.fetchval(SQL_HAS_015):
        raise RuntimeError("Migration 015 is not applied: apply db/migrations/015_connecting_flights.sql first.")
    kept = {r["email"]: r["pnr_code"] for r in await conn.fetch(SQL_KEPT_PNRS, EMAILS)}
    await cleanup(conn)

    departure = plan_departure(datetime.now().astimezone())
    protected = {
        (r["origin"], r["destination"])
        for flight in (PROTECTED_FLIGHT, USABILITY_FLIGHT)
        for r in await conn.fetch(SQL_PROTECTED_ROUTES, flight, PROTECTED_PASSENGERS)
    }
    candidates = [dict(r) for r in await conn.fetch(SQL_CANDIDATE_ROUTES, departure)]
    journey = choose_journey(candidates, protected)
    if journey is None:
        raise RuntimeError("No X-NBO-Y route pair has later scheduled flights with free economy seats.")

    ids = {}
    for f in plan_flights(*journey, departure):
        ids[f["number"]] = await conn.fetchval(
            SQL_INSERT_FLIGHT, f["number"], f["origin"], f["destination"], f["departure"], f["arrival"],
            f["aircraft"],
        )  # fmt: skip
        seats = seat_map(f["aircraft"])
        await conn.execute(SQL_INSERT_SEATS, ids[f["number"]], [n for n, _ in seats], [c for _, c in seats], [SEAT])

    taken = set(kept.values())
    pnrs = []
    for i, ((first, last, scenario), email) in enumerate(zip(PASSENGERS, EMAILS, strict=True)):
        await conn.execute(
            "INSERT INTO passengers (first_name, last_name, email, phone_number) VALUES ($1, $2, $3, $4)",
            first, last, email, PHONE,
        )  # fmt: skip
        pnr = kept.get(email)
        while pnr is None or (email not in kept and await conn.fetchval(
                "SELECT 1 FROM pnr_bookings WHERE pnr_code = $1", pnr)):  # fmt: skip
            pnr = make_pnr(taken)
        first_no, onward_no = FLIGHT_NUMBERS[2 * i], FLIGHT_NUMBERS[2 * i + 1]
        await conn.execute(SQL_INSERT_BOOKING, pnr, email, ids[first_no], ids[onward_no], SEAT)
        sql, args = disruption(scenario, first_no, onward_no)
        await conn.execute(sql, *args)
        status = await conn.fetchval("SELECT booking_status::text FROM pnr_bookings WHERE pnr_code = $1", pnr)
        if status != "DISRUPTED":
            raise RuntimeError(f"{scenario}: the 015 trigger left {pnr} {status}, expected DISRUPTED.")
        # The passenger must have somewhere to go, as the REST tier will see it.
        if not build_journeys(await conn.fetch(SQL_JOURNEY_LEGS, pnr, LEG_CANDIDATES), 5):
            raise RuntimeError(f"{scenario}: {pnr} has no journey options on this route pair.")
        pnrs.append(pnr)
    return pnrs, journey, departure


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
            if args.preview_migration:
                # Inside this transaction, which --dry-run always rolls back.
                await conn.execute(Path(args.preview_migration).read_text(encoding="utf-8"))
            if args.cleanup:
                await cleanup(conn)
            else:
                pnrs, (first, onward), departure = await create(conn)
            if args.dry_run:
                raise DryRun
    except DryRun:
        if args.cleanup:
            print("[DRY RUN] Cleanup ran and was rolled back; nothing changed.")
        else:
            print(f"[DRY RUN] {first['origin']}-{HUB}-{onward['destination']} departing "
                  f"{departure:%d %b %H:%M %Z}, {len(pnrs)} bookings, all DISRUPTED by the trigger and "
                  "each with journey options. "
                  "Rolled back; nothing changed.")  # fmt: skip
        return 0
    except (asyncpg.PostgresError, OSError, RuntimeError) as exc:
        print(f"[ERROR] {type(exc).__name__}: {exc}")
        return 1
    finally:
        await conn.close()

    if args.cleanup:
        print("[OK] Connecting-flight demo flights, passengers and bookings removed.")
        return 0
    print(f"Journey {first['origin']}-{HUB}-{onward['destination']}")
    for i, (pnr, (_, surname, scenario)) in enumerate(zip(pnrs, PASSENGERS, strict=True), start=1):
        print(f"C{i}  {pnr}  {surname}  ({scenario})")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Connecting-flight demo bookings for Kestrel.")
    parser.add_argument("--cleanup", action="store_true", help="Remove everything this script created.")
    parser.add_argument("--dry-run", action="store_true", help="Run inside a transaction, then roll it back.")
    parser.add_argument("--preview-migration", metavar="PATH",
                        help="With --dry-run: run this migration first, inside the rolled-back transaction.")
    parsed = parser.parse_args()
    if parsed.preview_migration and not parsed.dry_run:
        parser.error("--preview-migration needs --dry-run")
    sys.exit(asyncio.run(main(parsed)))
