"""
Project Kestrel - synthetic dataset generator.

Populates flights, seats, passengers and pnr_bookings with a plausible Kenya
Airways network, then cancels one or more flights to create the disruption the
re-accommodation engine has to recover from.

Passenger and booking records are synthetic by necessity: real Passenger Name
Records are commercially confidential and are not released for research, which
is the same constraint that motivated Mottini et al. (2018) to generate PNRs
adversarially at Amadeus. Route topology follows Kenya Airways' published
network out of Nairobi.

All timestamps are computed relative to now(), so the dataset can never go
stale the way a fixed-timestamp seed does.

Usage:
    python scripts/dataset_generator.py --passengers 2000 --days 3 --cancel 2
    python scripts/dataset_generator.py --truncate --passengers 5000 --seed 42

Requires: pip install asyncpg faker python-dotenv
"""

import argparse
import asyncio
import os
import random
import string
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import asyncpg
from dotenv import load_dotenv
from faker import Faker

load_dotenv(dotenv_path=Path(__file__).resolve().parent.parent / ".env")
DATABASE_URL = os.getenv("postgresql://postgres.PROJECT_REF:REDACTED@aws-0-eu-central-1.pooler.supabase.com:5432/postgres?sslmode=require")

# ---------------------------------------------------------------------------
# Network definition.
#
# Each route carries a frequency: the number of departures per day. High
# frequency matters for this project specifically - a route flown four times a
# day gives the agent somewhere to re-accommodate passengers to, whereas a
# thrice-weekly long-haul route does not. The recovery problem is only
# interesting where alternatives exist.
# ---------------------------------------------------------------------------

ROUTES = [
    # (origin, destination, aircraft, daily frequency)
    ("NBO", "MBA", "E190", 6),
    ("NBO", "KIS", "E190", 4),
    ("NBO", "EDL", "E190", 2),
    ("NBO", "JNB", "738", 3),
    ("NBO", "LOS", "738", 2),
    ("NBO", "ACC", "738", 2),
    ("NBO", "DXB", "738", 2),
    ("NBO", "LHR", "788", 2),
    ("NBO", "CDG", "788", 1),
    ("NBO", "AMS", "788", 1),
    ("NBO", "BOM", "738", 1),
    ("NBO", "BKK", "788", 1),
]

# Seat maps. rows_business / rows_economy with the letter layout per cabin.
AIRCRAFT = {
    "E190": {"J_rows": (1, 3), "J_letters": "AC DF", "Y_rows": (4, 24), "Y_letters": "AC DF"},
    "738":  {"J_rows": (1, 4), "J_letters": "AC DF", "Y_rows": (5, 32), "Y_letters": "ABC DEF"},
    "788":  {"J_rows": (1, 8), "J_letters": "AC DG HK", "Y_rows": (20, 45), "Y_letters": "ABC DEFG HJK"},
}

# Asante Rewards distribution. Loyalty programmes are steeply pyramidal; a flat
# distribution would make tier-based prioritisation look far more impactful
# than it is.
TIERS = ["BLUE", "SILVER", "GOLD", "PLATINUM"]
TIER_WEIGHTS = [0.74, 0.18, 0.06, 0.02]

LOAD_FACTOR = 0.82  # IATA reports global passenger load factors in the low 80s.

fake = Faker()


def seat_numbers(aircraft: str) -> list[tuple[str, str]]:
    """Return [(seat_number, cabin_class), ...] for one aircraft."""
    cfg = AIRCRAFT[aircraft]
    seats: list[tuple[str, str]] = []
    for row in range(cfg["J_rows"][0], cfg["J_rows"][1] + 1):
        for letter in cfg["J_letters"].replace(" ", ""):
            seats.append((f"{row}{letter}", "BUSINESS"))
    for row in range(cfg["Y_rows"][0], cfg["Y_rows"][1] + 1):
        for letter in cfg["Y_letters"].replace(" ", ""):
            seats.append((f"{row}{letter}", "ECONOMY"))
    return seats


def make_pnr(existing: set[str]) -> str:
    """Six-character alphanumeric record locator, as used by real GDS systems."""
    alphabet = string.ascii_uppercase + string.digits
    while True:
        code = "".join(random.choices(alphabet, k=6))
        if code not in existing:
            existing.add(code)
            return code


def build_flights(days: int) -> list[dict]:
    """One row per departure across the requested number of days."""
    flights = []
    base = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    seq = 100

    for origin, dest, aircraft, freq in ROUTES:
        block_hours = {"E190": 1, "738": 4, "788": 8}[aircraft]
        for day in range(days):
            for n in range(freq):
                # Spread departures across the operating day rather than
                # clustering them, so "next available flight" varies.
                hour_offset = 6 + int(n * (14 / max(freq, 1)))
                dep = base + timedelta(days=day, hours=hour_offset)
                if dep <= datetime.now(timezone.utc):
                    dep += timedelta(days=1)

                seq += 1
                flights.append({
                    "flight_id": uuid.uuid4(),
                    "flight_number": f"KQ{seq}",
                    "origin": origin,
                    "destination": dest,
                    "departure_time": dep,
                    "arrival_time": dep + timedelta(hours=block_hours),
                    "status": "SCHEDULED",
                    "aircraft_type": aircraft,
                })
                # Return leg, so passengers are not all outbound from NBO.
                seq += 1
                ret = dep + timedelta(hours=block_hours + 2)
                flights.append({
                    "flight_id": uuid.uuid4(),
                    "flight_number": f"KQ{seq}",
                    "origin": dest,
                    "destination": origin,
                    "departure_time": ret,
                    "arrival_time": ret + timedelta(hours=block_hours),
                    "status": "SCHEDULED",
                    "aircraft_type": aircraft,
                })
    return flights


async def main(args: argparse.Namespace) -> None:
    if args.seed is not None:
        random.seed(args.seed)
        Faker.seed(args.seed)

    conn = await asyncpg.connect(DATABASE_URL, statement_cache_size=0)

    try:
        if args.truncate:
            # Order matters: children before parents.
            await conn.execute("""
                TRUNCATE vouchers, audit_logs, pnr_bookings, seats, flights, passengers
                RESTART IDENTITY CASCADE;
            """)
            print("[INFO] Existing data cleared.")

        # ------------------------------------------------------------------
        # Flights
        # ------------------------------------------------------------------
        flights = build_flights(args.days)
        await conn.executemany(
            """INSERT INTO flights (flight_id, flight_number, origin, destination,
                                    departure_time, arrival_time, status, aircraft_type)
               VALUES ($1,$2,$3,$4,$5,$6,$7::flight_status,$8)""",
            [(f["flight_id"], f["flight_number"], f["origin"], f["destination"],
              f["departure_time"], f["arrival_time"], f["status"], f["aircraft_type"])
             for f in flights],
        )
        print(f"[INFO] {len(flights)} flights inserted.")

        # ------------------------------------------------------------------
        # Seats
        # ------------------------------------------------------------------
        seat_rows = []
        seats_by_flight: dict[uuid.UUID, list[uuid.UUID]] = {}
        for f in flights:
            ids = []
            for number, cabin in seat_numbers(f["aircraft_type"]):
                sid = uuid.uuid4()
                ids.append(sid)
                seat_rows.append((sid, f["flight_id"], number, cabin, "AVAILABLE", 1))
            seats_by_flight[f["flight_id"]] = ids

        await conn.executemany(
            """INSERT INTO seats (seat_id, flight_id, seat_number, cabin_class, status, row_version)
               VALUES ($1,$2,$3,$4,$5::seat_status,$6)""",
            seat_rows,
        )
        print(f"[INFO] {len(seat_rows)} seats inserted.")

        # ------------------------------------------------------------------
        # Passengers
        # ------------------------------------------------------------------
        passengers = []
        for _ in range(args.passengers):
            first, last = fake.first_name(), fake.last_name()
            passengers.append((
                uuid.uuid4(), first, last,
                f"{first.lower()}.{last.lower()}{random.randint(1, 999)}@example.com",
                f"+2547{random.randint(10000000, 99999999)}",
                random.choices(TIERS, weights=TIER_WEIGHTS, k=1)[0],
                datetime.now(timezone.utc),
            ))

        await conn.executemany(
            """INSERT INTO passengers (passenger_id, first_name, last_name, email,
                                       phone_number, asante_rewards_tier, created_at)
               VALUES ($1,$2,$3,$4,$5,$6,$7)""",
            passengers,
        )
        print(f"[INFO] {len(passengers)} passengers inserted.")

        # ------------------------------------------------------------------
        # Bookings. Seats are consumed from each flight's pool up to the load
        # factor, so no seat is double-allocated at generation time.
        # ------------------------------------------------------------------
        pool: list[tuple[uuid.UUID, uuid.UUID]] = []
        for fid, sids in seats_by_flight.items():
            take = int(len(sids) * LOAD_FACTOR)
            for sid in random.sample(sids, take):
                pool.append((fid, sid))
        random.shuffle(pool)

        used_pnrs: set[str] = set()
        bookings, booked_seat_ids = [], []
        for i, (passenger_id, *_rest) in enumerate(passengers):
            if i >= len(pool):
                break
            flight_id, seat_id = pool[i]
            bookings.append((
                make_pnr(used_pnrs), passenger_id, flight_id, None, seat_id,
                "CONFIRMED", datetime.now(timezone.utc),
            ))
            booked_seat_ids.append(seat_id)

        await conn.executemany(
            """INSERT INTO pnr_bookings (pnr_code, passenger_id, original_flight_id,
                                         reaccommodated_flight_id, assigned_seat_id,
                                         booking_status, updated_at)
               VALUES ($1,$2,$3,$4,$5,$6::pnr_status,$7)""",
            bookings,
        )
        await conn.execute(
            "UPDATE seats SET status='BOOKED', row_version=row_version+1 WHERE seat_id = ANY($1::uuid[])",
            booked_seat_ids,
        )
        print(f"[INFO] {len(bookings)} bookings inserted.")

        # ------------------------------------------------------------------
        # Disruption. Cancel the busiest routes so there is genuine contention
        # for the remaining seats - that contention is what the pessimistic
        # locking in reaccommodate_passenger_atomic exists to handle.
        # ------------------------------------------------------------------
        cancelled = await conn.fetch(
            """UPDATE flights SET status='CANCELLED'
               WHERE flight_id IN (
                   SELECT f.flight_id FROM flights f
                   JOIN pnr_bookings b ON b.original_flight_id = f.flight_id
                   WHERE f.status='SCHEDULED' AND f.departure_time > now()
                   GROUP BY f.flight_id
                   ORDER BY count(b.pnr_code) DESC
                   LIMIT $1
               )
               RETURNING flight_number, origin, destination, departure_time""",
            args.cancel,
        )
        disrupted = await conn.fetchval(
            """UPDATE pnr_bookings b SET booking_status='DISRUPTED', updated_at=now()
               FROM flights f
               WHERE f.flight_id = b.original_flight_id AND f.status='CANCELLED'
               RETURNING (SELECT count(*) FROM pnr_bookings WHERE booking_status='DISRUPTED')"""
        )

        print("\n--- Disruption created ---")
        for c in cancelled:
            print(f"  {c['flight_number']}  {c['origin']}-{c['destination']}  "
                  f"{c['departure_time']:%Y-%m-%d %H:%M}")
        print(f"  {disrupted} passengers now require re-accommodation.\n")

        # A known PNR for manual testing.
        demo = await conn.fetchrow(
            """SELECT b.pnr_code, p.last_name, f.flight_number, f.origin, f.destination
               FROM pnr_bookings b
               JOIN passengers p ON p.passenger_id = b.passenger_id
               JOIN flights f ON f.flight_id = b.original_flight_id
               WHERE b.booking_status='DISRUPTED' LIMIT 1"""
        )
        if demo:
            print(f"[DEMO] PNR {demo['pnr_code']} / surname {demo['last_name']} "
                  f"was on {demo['flight_number']} ({demo['origin']}-{demo['destination']})")

    finally:
        await conn.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate Project Kestrel test data.")
    parser.add_argument("--passengers", type=int, default=2000)
    parser.add_argument("--days", type=int, default=3, help="Days of schedule to build.")
    parser.add_argument("--cancel", type=int, default=2, help="Flights to cancel.")
    parser.add_argument("--seed", type=int, default=None, help="Fix the RNG for reproducibility.")
    parser.add_argument("--truncate", action="store_true", help="Clear existing data first.")
    asyncio.run(main(parser.parse_args()))