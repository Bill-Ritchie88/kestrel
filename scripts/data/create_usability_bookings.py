"""
Project Kestrel - bookings for the usability test (Sprint III, FR-08).

Creates one cancelled flight with six disrupted economy bookings, one per
participant (P1-P6), and prints only each booking reference and surname for
the participant sheets (docs/sprint-3/usability/03-participant-sheet.md).

    python scripts/data/create_usability_bookings.py             # create, or refresh
    python scripts/data/create_usability_bookings.py --dry-run   # do it all, then roll back
    python scripts/data/create_usability_bookings.py --cleanup   # remove everything it made

What it creates, every row recognisable by a fixed marker:
  * flight KQ0901, CANCELLED (TECHNICAL), departing at least 24 hours after the
    run, on a route with at least three later scheduled flights that still
    have free economy seats, so the same-route rule (migration 011) leaves the
    participants real flights to choose from. The generator writes flight
    numbers as KQ<integer>, so a leading zero can never belong to its data;
  * that flight's full seat map (generate_dataset.seat_map), six seats BOOKED;
  * six passengers with clearly fake names and the exact e-mail addresses
    usability+1@example.com .. usability+6@example.com;
  * six DISRUPTED bookings, one per passenger.

Vouchers are not created here: the REST tier issues them when a passenger is
rebooked (POST /api/reaccommodate), and works the entitlements out live before
that, exactly as for every other booking (reset_demo_state.sql deletes them
too).

Re-running refreshes: everything above is removed and made again in one
transaction, keeping each participant's booking reference, so a filled-in
participant sheet stays valid while rebookings, vouchers, hand-off cases and
assistant history start again from nothing. --cleanup removes the same rows
and frees any seat a participant was rebooked into. audit_logs is left alone,
as reset_demo.py does: it is the evidence of what happened in the sessions.

It never touches flight KQ606, the demo passengers (Kristina Edwards, Charles
Mueller) or their routes: those routes are never chosen, so participants
cannot take seats the demo needs. Rows are only ever selected by the fixed
flight number and the exact e-mail addresses, never by a pattern.

reset_demo.py (also run by make test-all, smoke and agent when the demo is
stale) resets every booking in the database, these six included: run this
script again after any reset.
"""

import argparse
import asyncio
import math
import os
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

import asyncpg

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_dataset import (  # noqa: E402  - also loads .env
    AIRCRAFT,
    BLOCK_HOURS,
    DEFAULT_BLOCK,
    make_pnr,
    seat_map,
)

FLIGHT_NUMBER = "KQ0901"
DISRUPTION_REASON = "TECHNICAL"  # within the airline's control: care plus goodwill points
LEAD = timedelta(hours=25)  # still more than 24 h away an hour after the run
MIN_LATER_FLIGHTS = 3
PARTICIPANTS = [
    # (first name, surname), clearly not real people
    ("Ada", "Sample"),
    ("Ben", "Example"),
    ("Cleo", "Testcase"),
    ("Dev", "Mockup"),
    ("Eli", "Dummy"),
    ("Fay", "Trialist"),
]
EMAILS = [f"usability+{i}@example.com" for i in range(1, len(PARTICIPANTS) + 1)]
PHONE = "+0000000000"
PROTECTED_FLIGHT = "KQ606"
PROTECTED_PASSENGERS = ["kristina edwards", "charles mueller"]


# ---------------------------------------------------------------------------
# Planning: pure, unit-tested without a database (tests/unit/test_usability.py)
# ---------------------------------------------------------------------------


def plan_departure(now: datetime) -> datetime:
    """LEAD after now, rounded up to the next five minutes."""
    t = now.astimezone(UTC) + LEAD
    minutes = math.ceil((t.minute * 60 + t.second + t.microsecond / 1e6) / 300) * 5
    return t.replace(minute=0, second=0, microsecond=0) + timedelta(minutes=minutes)


def choose_route(candidates: list[dict], protected: set[tuple[str, str]]) -> dict | None:
    """The route with the most later flights, preferring departures from
    Nairobi (the network's hub, one time zone). Each candidate is
    {origin, destination, aircraft, later_flights, free_economy}, counted over
    the scheduled flights leaving after the planned departure."""
    eligible = [
        c
        for c in candidates
        if (c["origin"], c["destination"]) not in protected
        and c["aircraft"] in AIRCRAFT
        and c["later_flights"] >= MIN_LATER_FLIGHTS
        and c["free_economy"] >= len(PARTICIPANTS)
    ]
    return max(
        eligible,
        key=lambda c: (c["origin"] == "NBO", c["later_flights"], c["free_economy"],
                       c["origin"], c["destination"]),
        default=None,
    )  # fmt: skip


def block_time(destination: str, aircraft: str) -> timedelta:
    return timedelta(hours=BLOCK_HOURS.get(destination, DEFAULT_BLOCK[aircraft]))


def participant_seats(aircraft: str) -> list[str]:
    """One economy seat per participant: the first economy seats of the map."""
    economy = [n for n, cabin in seat_map(aircraft) if cabin == "ECONOMY"]
    return economy[: len(PARTICIPANTS)]


# ---------------------------------------------------------------------------
# SQL. Our rows: flight_number = FLIGHT_NUMBER, email = ANY(EMAILS).
# ---------------------------------------------------------------------------

SQL_KEPT_PNRS = """
    SELECT p.email, b.pnr_code FROM pnr_bookings b
    JOIN passengers p ON p.passenger_id = b.passenger_id
    WHERE p.email = ANY($1::text[])
"""

# Refuse rather than delete if anyone else is on our flight, or one of ours
# is somehow on the protected flight.
SQL_GUARD = """
    WITH ours AS (SELECT passenger_id FROM passengers WHERE email = ANY($1::text[]))
    SELECT
      (SELECT count(*) FROM pnr_bookings b
         JOIN flights f ON f.flight_id IN (b.original_flight_id, b.reaccommodated_flight_id)
         WHERE f.flight_number = $2
           AND b.passenger_id NOT IN (SELECT passenger_id FROM ours)) AS strangers,
      (SELECT count(*) FROM pnr_bookings b
         JOIN flights f ON f.flight_id IN (b.original_flight_id, b.reaccommodated_flight_id)
         WHERE f.flight_number = $3
           AND b.passenger_id IN (SELECT passenger_id FROM ours))     AS on_protected
"""

# Every statement selects by the exact e-mail addresses ($1) or the flight
# number, never by a pattern.
SQL_RELEASE_SEATS = """
    UPDATE seats SET status = 'AVAILABLE', row_version = row_version + 1
    WHERE status <> 'AVAILABLE' AND seat_id IN (
        SELECT b.assigned_seat_id FROM pnr_bookings b
        JOIN passengers p ON p.passenger_id = b.passenger_id
        WHERE p.email = ANY($1::text[]))
"""
SQL_DELETE_BY_PNR = """
    DELETE FROM {table} WHERE pnr_code IN (
        SELECT b.pnr_code FROM pnr_bookings b
        JOIN passengers p ON p.passenger_id = b.passenger_id
        WHERE p.email = ANY($1::text[]))
"""
SQL_DELETE_BY_PASSENGER = """
    DELETE FROM {table} WHERE passenger_id IN (
        SELECT passenger_id FROM passengers WHERE email = ANY($1::text[]))
"""


def cleanup_statements() -> list[tuple[str, tuple]]:
    """(sql, args) removing every row this script made, children first."""
    return [
        # A participant rebooked onto a real flight holds a seat there.
        (SQL_RELEASE_SEATS, (EMAILS,)),
        *((SQL_DELETE_BY_PNR.format(table=t), (EMAILS,))
          for t in ("vouchers", "handoff_cases", "chat_messages")),
        *((SQL_DELETE_BY_PASSENGER.format(table=t), (EMAILS,))
          for t in ("pnr_bookings", "passenger_accounts")),
        ("DELETE FROM passengers WHERE email = ANY($1::text[])", (EMAILS,)),
        # Seats cascade with the flight.
        ("DELETE FROM flights WHERE flight_number = $1", (FLIGHT_NUMBER,)),
    ]  # fmt: skip


SQL_PROTECTED_ROUTES = """
    SELECT DISTINCT f.origin, f.destination FROM flights f
    WHERE f.flight_number = $1
       OR f.flight_id IN (
           SELECT unnest(ARRAY[b.original_flight_id, b.reaccommodated_flight_id])
           FROM pnr_bookings b JOIN passengers p ON p.passenger_id = b.passenger_id
           WHERE lower(p.first_name || ' ' || p.last_name) = ANY($2::text[]))
"""

SQL_CANDIDATE_ROUTES = """
    SELECT f.origin, f.destination, f.aircraft_type AS aircraft,
           count(DISTINCT f.flight_id) AS later_flights,
           count(s.seat_id)            AS free_economy
    FROM flights f
    JOIN seats s ON s.flight_id = f.flight_id
                AND s.status = 'AVAILABLE' AND s.cabin_class = 'ECONOMY'
    WHERE f.status = 'SCHEDULED' AND f.departure_time > $1
    GROUP BY f.origin, f.destination, f.aircraft_type
"""

SQL_INSERT_FLIGHT = """
    INSERT INTO flights (flight_number, origin, destination, departure_time, arrival_time,
                         status, aircraft_type, disruption_reason)
    VALUES ($1, $2, $3, $4, $5, 'CANCELLED', $6, $7)
    RETURNING flight_id
"""

SQL_INSERT_SEATS = """
    INSERT INTO seats (flight_id, seat_number, cabin_class, status)
    SELECT $1::uuid, t.n, t.c,
           (CASE WHEN t.n = ANY($4::text[]) THEN 'BOOKED' ELSE 'AVAILABLE' END)::seat_status
    FROM unnest($2::text[], $3::text[]) AS t(n, c)
"""

SQL_INSERT_PASSENGERS = """
    INSERT INTO passengers (first_name, last_name, email, phone_number)
    SELECT t.f, t.l, t.e, $4::text FROM unnest($1::text[], $2::text[], $3::text[]) AS t(f, l, e)
"""

SQL_INSERT_BOOKINGS = """
    INSERT INTO pnr_bookings (pnr_code, passenger_id, original_flight_id,
                              assigned_seat_id, booking_status)
    SELECT t.pnr, p.passenger_id, $1::uuid, s.seat_id, 'DISRUPTED'
    FROM unnest($2::text[], $3::text[], $4::text[]) AS t(pnr, email, seat)
    JOIN passengers p ON p.email = t.email
    JOIN seats s ON s.flight_id = $1::uuid AND s.seat_number = t.seat
    RETURNING pnr_code
"""


# ---------------------------------------------------------------------------
# Database steps
# ---------------------------------------------------------------------------


async def guard(conn: asyncpg.Connection) -> None:
    row = await conn.fetchrow(SQL_GUARD, EMAILS, FLIGHT_NUMBER, PROTECTED_FLIGHT)
    if row["strangers"]:
        raise RuntimeError(
            f"{row['strangers']} booking(s) of other passengers are on {FLIGHT_NUMBER}; "
            "refusing to touch it."
        )
    if row["on_protected"]:
        raise RuntimeError(f"A usability booking is on {PROTECTED_FLIGHT}; refusing to touch it.")


async def cleanup(conn: asyncpg.Connection) -> None:
    await guard(conn)
    for sql, args in cleanup_statements():
        await conn.execute(sql, *args)


async def fresh_pnrs(conn: asyncpg.Connection, kept: dict[str, str]) -> list[str]:
    """Each participant's previous reference, or a new one no booking uses."""
    taken = set(kept.values())
    pnrs = []
    for email in EMAILS:
        code = kept.get(email)
        while code is None or (
            email not in kept
            and await conn.fetchval("SELECT 1 FROM pnr_bookings WHERE pnr_code = $1", code)
        ):
            code = make_pnr(taken)
        pnrs.append(code)
    return pnrs


async def create(conn: asyncpg.Connection) -> tuple[list[str], dict, datetime]:
    kept = {r["email"]: r["pnr_code"] for r in await conn.fetch(SQL_KEPT_PNRS, EMAILS)}
    await cleanup(conn)

    departure = plan_departure(datetime.now(UTC))
    protected = {
        (r["origin"], r["destination"])
        for r in await conn.fetch(SQL_PROTECTED_ROUTES, PROTECTED_FLIGHT, PROTECTED_PASSENGERS)
    }
    candidates = [dict(r) for r in await conn.fetch(SQL_CANDIDATE_ROUTES, departure)]
    route = choose_route(candidates, protected)
    if route is None:
        raise RuntimeError(
            f"No route has {MIN_LATER_FLIGHTS} scheduled flights with free economy seats after "
            f"{departure:%d %b %H:%M} UTC. The schedule has run out: reset it "
            "(.\\tasks.ps1 reset), then run this script again."
        )

    aircraft = route["aircraft"]
    flight_id = await conn.fetchval(
        SQL_INSERT_FLIGHT, FLIGHT_NUMBER, route["origin"], route["destination"], departure,
        departure + block_time(route["destination"], aircraft), aircraft, DISRUPTION_REASON,
    )  # fmt: skip
    seats = seat_map(aircraft)
    mine = participant_seats(aircraft)
    await conn.execute(
        SQL_INSERT_SEATS, flight_id, [n for n, _ in seats], [c for _, c in seats], mine
    )
    await conn.execute(
        SQL_INSERT_PASSENGERS,
        [f for f, _ in PARTICIPANTS], [s for _, s in PARTICIPANTS], EMAILS, PHONE,
    )  # fmt: skip
    pnrs = await fresh_pnrs(conn, kept)
    rows = await conn.fetch(SQL_INSERT_BOOKINGS, flight_id, pnrs, EMAILS, mine)
    if len(rows) != len(PARTICIPANTS):
        raise RuntimeError(f"Created {len(rows)} bookings, expected {len(PARTICIPANTS)}")
    return pnrs, route, departure


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
                pnrs, route, departure = await create(conn)
            if args.dry_run:
                raise DryRun
    except DryRun:
        if args.cleanup:
            print("[DRY RUN] Cleanup ran and was rolled back; nothing changed.")
        else:
            print(
                f"[DRY RUN] {FLIGHT_NUMBER} {route['origin']}-{route['destination']} "
                f"({route['aircraft']}) departing {departure:%d %b %H:%M} UTC, "
                f"{route['later_flights']} later flights, {len(pnrs)} bookings. "
                "Rolled back; nothing changed."
            )
        return 0
    except (asyncpg.PostgresError, OSError, RuntimeError) as exc:
        print(f"[ERROR] {type(exc).__name__}: {exc}")
        return 1
    finally:
        await conn.close()

    if args.cleanup:
        print("[OK] Usability flight, passengers and bookings removed.")
        return 0
    for i, (pnr, (_, surname)) in enumerate(zip(pnrs, PARTICIPANTS, strict=True), start=1):
        print(f"P{i}  {pnr}  {surname}")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Bookings for the Kestrel usability test.")
    parser.add_argument(
        "--cleanup", action="store_true", help="Remove everything this script created."
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="Run inside a transaction, then roll it back."
    )
    sys.exit(asyncio.run(main(parser.parse_args())))
