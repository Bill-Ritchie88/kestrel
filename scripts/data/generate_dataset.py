"""
Project Kestrel - synthetic dataset generator (v2).

Populates flights, seats, passengers and pnr_bookings with a plausible Kenya
Airways network, then cancels the busiest future flights to create the
disruption the re-accommodation engine has to recover from.

Passenger and booking records are synthetic by necessity: real Passenger Name
Records are commercially confidential and are not released for research, which
is the same constraint that motivated Mottini et al. (2018) to generate PNRs
adversarially at Amadeus. Route topology follows Kenya Airways' published
network out of Nairobi.

                    v1                       v2 (default)
    Routes          12                       30
    Schedule        3 days                   7 days
    Departures      162                      ~1,020
    Seats           ~27,200                  ~171,500
    Bookings        ~2,000                   ~141,600
    Passengers      2,000 (1 booking each)   ~75,500 (repeat travellers)
    Load factor     flat 0.82                Beta draw, mean 0.82, per flight

What v2 changes:

1. Repeat travellers. Trip counts are drawn per loyalty tier (PLATINUM flies
   ~7x per week, BLUE ~1.4x), which is what makes tier-based prioritisation
   testable. v1 allowed one booking per passenger.
2. Load-factor spread. A per-flight Beta draw produces flights at 0.98 (real
   contention for the pessimistic lock) alongside flights at 0.65, so the "no
   seats remaining" path is exercised. A flat 0.82 never exercised it.
3. Cabin-coherent allocation. Business cabins fill from the top of the loyalty
   pyramid, so an ECONOMY passenger handed a BUSINESS seat is an observable
   defect - the dataset side of the logged Fix 5.
4. COPY instead of executemany: 171,000 seats in seconds rather than ~20
   minutes. Falls back to batched INSERT if the pooler refuses COPY.
5. Schema preflight. Verifies every column and enum label before writing
   anything, instead of failing halfway and leaving a half-populated database.
6. Nairobi-anchored schedule. Departure times are local Nairobi time and a
   service number belongs to one calendar day, so KQ604 cannot appear twice on
   a Tuesday.

Days sets everything else; passengers and bookings are derived from the seats
the schedule produces:

    --days   flights   seats     bookings   passengers   approx. DB size
    3        484       81,700    66,500     35,500       ~70 MB
    7        1,020     171,500   141,600    75,500       ~150 MB
    14       1,958     328,700   272,100    145,000      ~290 MB

Supabase's free tier allows 500 MB, so 14 days is the practical ceiling.

Usage:
    python scripts/data/generate_dataset.py --dry-run                 # plan only, no DB
    python scripts/data/generate_dataset.py --truncate --days 7 --seed 42

--truncate deletes every row in pnr_bookings, seats, flights, passengers and,
if they exist, vouchers and audit_logs. Between test runs do not regenerate:
run scripts/data/reset_demo.py, which keeps the audit log.
"""

import argparse
import asyncio
import os
import random
import sys
import uuid
from collections import defaultdict
from datetime import UTC, datetime, timedelta, timezone
from pathlib import Path

import asyncpg
from dotenv import load_dotenv
from faker import Faker

ENV_PATH = Path(__file__).resolve().parents[2] / ".env"
load_dotenv(dotenv_path=ENV_PATH)

# ---------------------------------------------------------------------------
# Network definition.
#
# Frequency is departures per day in one direction; the return leg is generated
# automatically, so a frequency of 8 produces 16 departures a day. Frequency is
# what matters for this project: a route flown eight times a day gives the agent
# somewhere to re-accommodate passengers to; a thrice-weekly long-haul route
# does not.
# ---------------------------------------------------------------------------

ROUTES = [
    # (origin, dest, aircraft, daily frequency, base flight number)
    # -- Domestic ----------------------------------------------------------
    ("NBO", "MBA", "E190", 8, 600),
    ("NBO", "KIS", "E190", 6, 630),
    ("NBO", "EDL", "E190", 3, 650),
    ("NBO", "MYD", "E190", 2, 660),
    ("NBO", "UKA", "E190", 1, 670),
    # -- Regional, East Africa --------------------------------------------
    ("NBO", "EBB", "738", 4, 410),
    ("NBO", "DAR", "738", 4, 420),
    ("NBO", "ZNZ", "738", 2, 430),
    ("NBO", "KGL", "738", 3, 440),
    ("NBO", "BJM", "738", 1, 450),
    ("NBO", "ADD", "738", 3, 460),
    ("NBO", "MGQ", "738", 2, 470),
    ("NBO", "JUB", "738", 2, 480),
    # -- Regional, Southern and Central Africa ----------------------------
    ("NBO", "HRE", "738", 2, 700),
    ("NBO", "LUN", "738", 2, 710),
    ("NBO", "LLW", "738", 1, 720),
    ("NBO", "JNB", "738", 3, 760),
    ("NBO", "FIH", "738", 1, 780),
    # -- Regional, West Africa --------------------------------------------
    ("NBO", "LOS", "738", 3, 530),
    ("NBO", "ACC", "738", 2, 540),
    ("NBO", "ABV", "738", 1, 550),
    # -- Medium and long haul ---------------------------------------------
    ("NBO", "DXB", "738", 2, 310),
    ("NBO", "BOM", "738", 1, 320),
    ("NBO", "LHR", "788", 2, 100),
    ("NBO", "CDG", "788", 1, 112),
    ("NBO", "AMS", "788", 1, 116),
    ("NBO", "BKK", "788", 1, 886),
    ("NBO", "JFK", "788", 1, 3),
    # -- Non-hub services, so not every itinerary starts at NBO ------------
    ("MBA", "ZNZ", "E190", 1, 690),
    ("MBA", "DXB", "738", 1, 340),
]

# Block time in hours, keyed by destination. Anything not listed falls back to a
# per-aircraft default. Real block times matter because the agent compares
# departure times when ranking alternatives.
BLOCK_HOURS = {
    "MBA": 1.0, "KIS": 1.0, "EDL": 1.25, "MYD": 1.0, "UKA": 1.0,
    "EBB": 1.25, "DAR": 1.5, "ZNZ": 1.5, "KGL": 1.5, "BJM": 1.75,
    "ADD": 2.0, "MGQ": 1.75, "JUB": 2.0,
    "HRE": 3.0, "LUN": 3.5, "LLW": 3.0, "JNB": 4.0, "FIH": 3.5,
    "LOS": 5.25, "ACC": 5.75, "ABV": 5.0,
    "DXB": 5.0, "BOM": 6.0,
    "LHR": 8.75, "CDG": 8.5, "AMS": 8.5, "BKK": 9.0, "JFK": 15.0,
}  # fmt: skip
DEFAULT_BLOCK = {"E190": 1.0, "738": 4.0, "788": 8.5}

# Minimum ground time before the aircraft operates the return leg.
TURNAROUND_HOURS = {"E190": 0.75, "738": 1.25, "788": 2.5}

# Departure window per aircraft, as (earliest hour, latest hour) local. Short
# haul runs all day; long haul departs NBO in the late evening, which is how the
# real network is banked.
DEPARTURE_WINDOW = {"E190": (5.5, 20.5), "738": (6.0, 22.5), "788": (8.0, 23.5)}

# Seat maps. Totals: E190 96, 738 184, 788 308 - unchanged from v1, so Table
# 3.1 of the write-up still describes the seat maps correctly.
AIRCRAFT = {
    "E190": {"J_rows": (1, 3), "J_letters": "AC DF", "Y_rows": (4, 24), "Y_letters": "AC DF"},
    "738": {"J_rows": (1, 4), "J_letters": "AC DF", "Y_rows": (5, 32), "Y_letters": "ABC DEF"},
    "788": {
        "J_rows": (1, 8),
        "J_letters": "AC DG HK",
        "Y_rows": (20, 45),
        "Y_letters": "ABC DEFG HJK",
    },
}

# Asante Rewards distribution. Loyalty programmes are steeply pyramidal; a flat
# distribution would make tier-based prioritisation look far more impactful
# than it is.
TIERS = ["BLUE", "SILVER", "GOLD", "PLATINUM"]
TIER_WEIGHTS = [0.74, 0.18, 0.06, 0.02]

# Mean trips per passenger across the schedule window, by tier.
TIER_TRIP_MEAN = {"BLUE": 1.35, "SILVER": 2.6, "GOLD": 4.5, "PLATINUM": 7.0}

# Relative likelihood of holding a business-cabin seat, by tier. Business
# cabins are small, so this only has to bias the draw, not dominate it.
TIER_BUSINESS_WEIGHT = {"BLUE": 1.0, "SILVER": 3.0, "GOLD": 9.0, "PLATINUM": 20.0}

# Day-of-week demand multiplier applied to the load factor, Monday first.
# Friday and Sunday are the peaks on this network.
DOW_DEMAND = [1.00, 0.95, 0.96, 1.02, 1.08, 0.93, 1.06]

# Record locators omit I, O, 0 and 1: real GDS locators do, because they are
# read aloud and written down.
PNR_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

REQUIRED_COLUMNS = {
    "flights": [
        "flight_id", "flight_number", "origin", "destination",
        "departure_time", "arrival_time", "status", "aircraft_type",
    ],
    "seats": ["seat_id", "flight_id", "seat_number", "cabin_class", "status", "row_version"],
    "passengers": [
        "passenger_id", "first_name", "last_name", "email",
        "phone_number", "asante_rewards_tier", "created_at",
    ],
    "pnr_bookings": [
        "pnr_code", "passenger_id", "original_flight_id", "reaccommodated_flight_id",
        "assigned_seat_id", "booking_status", "updated_at",
    ],
}  # fmt: skip

REQUIRED_ENUM_LABELS = {
    "flight_status": ["SCHEDULED", "CANCELLED"],
    "seat_status": ["AVAILABLE", "BOOKED"],
    "pnr_status": ["CONFIRMED", "DISRUPTED"],
}

EAT = timezone(timedelta(hours=3))  # Africa/Nairobi, no DST.


# ---------------------------------------------------------------------------
# Planning stage. Nothing here touches the database, which is what makes the
# shape of the dataset inspectable (--dry-run) before a single row is written.
# ---------------------------------------------------------------------------


def seat_map(aircraft: str) -> list[tuple[str, str]]:
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


SEAT_MAP_CACHE = {a: seat_map(a) for a in AIRCRAFT}


def make_pnr(existing: set[str]) -> str:
    """Six-character record locator, first character always a letter."""
    letters = PNR_ALPHABET[:24]
    while True:
        code = random.choice(letters) + "".join(random.choices(PNR_ALPHABET, k=5))
        if code not in existing:
            existing.add(code)
            return code


def _departure_times(freq: int, aircraft: str) -> list[float]:
    """Spread `freq` departures across the operating day for this aircraft."""
    lo, hi = DEPARTURE_WINDOW[aircraft]
    if freq == 1:
        return [lo + (hi - lo) * 0.55]
    step = (hi - lo) / (freq - 1)
    return [lo + i * step for i in range(freq)]


def build_flights(days: int, repeat_numbers: bool) -> list[dict]:
    """One row per departure across the requested number of days.

    Departures are anchored to midnight in Nairobi local time, not to the
    moment the script runs, so an 06:00 departure is 06:00 in Nairobi and a
    service number belongs to exactly one calendar day. v1 anchored to now(),
    which smeared each schedule day across two calendar dates.

    Today is generated as a partial day: departures already past are dropped,
    so a run at 14:00 still produces flights a few hours out. days + 1 days are
    built to compensate, giving roughly `days` full days of schedule.
    """
    flights: list[dict] = []
    now = datetime.now(UTC)
    day0 = now.astimezone(EAT).replace(hour=0, minute=0, second=0, microsecond=0)
    unique_seq = 1000

    for origin, dest, aircraft, freq, base_no in ROUTES:
        block = timedelta(hours=BLOCK_HOURS.get(dest, DEFAULT_BLOCK[aircraft]))
        turn = timedelta(hours=TURNAROUND_HOURS[aircraft])
        hours = _departure_times(freq, aircraft)

        for day in range(days + 1):
            for idx, hour in enumerate(hours):
                # +/- 10 minutes of jitter, rounded to 5, so departure times do
                # not look machine-generated in the seat-map screens.
                jitter = timedelta(minutes=5 * random.randint(-2, 2))
                dep = day0 + timedelta(days=day, hours=hour) + jitter
                dep = dep.replace(second=0, microsecond=0)
                if dep <= now + timedelta(minutes=45):
                    continue  # already departed, or inside check-in closure

                if repeat_numbers:
                    out_no, ret_no = base_no + 2 * idx, base_no + 2 * idx + 1
                else:
                    unique_seq += 2
                    out_no, ret_no = unique_seq, unique_seq + 1

                arr = dep + block
                flights.append({
                    "flight_id": uuid.uuid4(),
                    "flight_number": f"KQ{out_no}",
                    "origin": origin,
                    "destination": dest,
                    "departure_time": dep,
                    "arrival_time": arr,
                    "status": "SCHEDULED",
                    "aircraft_type": aircraft,
                    "dow": dep.weekday(),
                })  # fmt: skip

                ret_dep = arr + turn
                flights.append({
                    "flight_id": uuid.uuid4(),
                    "flight_number": f"KQ{ret_no}",
                    "origin": dest,
                    "destination": origin,
                    "departure_time": ret_dep,
                    "arrival_time": ret_dep + block,
                    "status": "SCHEDULED",
                    "aircraft_type": aircraft,
                    "dow": ret_dep.weekday(),
                })  # fmt: skip

    flights.sort(key=lambda f: f["departure_time"])
    return flights


def build_seats(flights: list[dict]) -> tuple[list[tuple], dict]:
    """Materialise every seat on every flight.

    Returns the rows to insert plus an index of
    flight_id -> {"BUSINESS": [seat_id, ...], "ECONOMY": [...]}.
    """
    rows: list[tuple] = []
    index: dict[uuid.UUID, dict[str, list[uuid.UUID]]] = {}

    for f in flights:
        by_cabin: dict[str, list[uuid.UUID]] = {"BUSINESS": [], "ECONOMY": []}
        for number, cabin in SEAT_MAP_CACHE[f["aircraft_type"]]:
            sid = uuid.uuid4()
            by_cabin[cabin].append(sid)
            rows.append((sid, f["flight_id"], number, cabin, "AVAILABLE", 1))
        index[f["flight_id"]] = by_cabin

    return rows, index


def plan_occupancy(
    flights: list[dict], seat_index: dict, lf_mean: float, lf_spread: float
) -> list[tuple]:
    """Decide which seats are sold, flight by flight.

    A per-flight Beta draw rather than one global load factor. The point is
    spread: some flights come out at 0.98 and are effectively closed, some at
    0.6 and can absorb a disrupted cabin. Uniform 0.82 gave every flight the
    same spare capacity, so no re-accommodation attempt could ever fail for
    lack of seats and the failure path went untested.

    Returns [(flight_id, seat_id, cabin_class), ...] in flight order.
    """
    # Convert mean/spread into Beta(a, b).
    m = min(max(lf_mean, 0.05), 0.97)
    var = max(lf_spread, 0.001) ** 2
    var = min(var, m * (1 - m) * 0.9)
    common = m * (1 - m) / var - 1
    alpha, beta = m * common, (1 - m) * common

    sold: list[tuple] = []
    for f in flights:
        lf = random.betavariate(alpha, beta) * DOW_DEMAND[f["dow"] % 7]
        lf = min(lf, 1.0)
        # Business cabins run fuller than economy on this network.
        lf_j = min(lf * 1.06, 1.0)

        cabins = seat_index[f["flight_id"]]
        for cabin, factor in (("BUSINESS", lf_j), ("ECONOMY", lf)):
            pool = cabins[cabin]
            take = int(round(len(pool) * factor))
            for sid in random.sample(pool, take):
                sold.append((f["flight_id"], sid, cabin))
    return sold


def build_passengers(n: int, fake: Faker) -> list[tuple]:
    """Passenger rows. E-mail uses the reserved example.com domain and carries
    a sequence number so the column stays unique at 75,000 rows."""
    now = datetime.now(UTC)
    rows = []
    for i in range(n):
        first, last = fake.first_name(), fake.last_name()
        local = f"{first}.{last}".lower().replace(" ", "").replace("'", "")
        rows.append((
            uuid.uuid4(),
            first,
            last,
            f"{local}{i}@example.com",
            f"+2547{random.randint(10000000, 99999999)}",
            random.choices(TIERS, weights=TIER_WEIGHTS, k=1)[0],
            now,
        ))  # fmt: skip
    return rows


def estimate_passenger_count(seats_to_sell: int) -> int:
    """How many passengers are needed to absorb this many bookings, given the
    tier mix and the per-tier trip means."""
    avg_trips = sum(w * TIER_TRIP_MEAN[t] for t, w in zip(TIERS, TIER_WEIGHTS, strict=True))
    return max(1, int(seats_to_sell / avg_trips) + 1)


def assign_bookings(sold: list[tuple], passengers: list[tuple]) -> tuple[list[tuple], int]:
    """Match sold seats to passengers.

    Two constraints, both of which v1 could not express because it allowed one
    booking per passenger:

      * business seats are drawn preferentially from the top of the loyalty
        pyramid, so cabin and tier correlate the way they do in reality. That
        correlation is what makes the logged Fix 5 - the procedure handing an
        economy passenger a business seat - visible in test data;

      * the same passenger is never booked twice on the same flight.

    Returns (booking rows, number of seats left unsold because no eligible
    passenger remained).
    """
    now = datetime.now(UTC)

    # Trip budget per passenger, Poisson-ish around the tier mean.
    tier_of = {i: p[5] for i, p in enumerate(passengers)}
    budget: list[int] = []
    for i in range(len(passengers)):
        mean = TIER_TRIP_MEAN[tier_of[i]]
        budget.append(max(1, int(random.gauss(mean, mean * 0.45) + 0.5)))

    # Two draw pools. The business pool is the same passengers, weighted so
    # higher tiers are sampled far more often.
    econ_pool: list[int] = []
    for i, b in enumerate(budget):
        econ_pool.extend([i] * b)
    random.shuffle(econ_pool)

    biz_pool: list[int] = []
    for i, b in enumerate(budget):
        w = TIER_BUSINESS_WEIGHT[tier_of[i]]
        biz_pool.extend([i] * max(1, int(b * w / 4)))
    random.shuffle(biz_pool)

    econ_cur = biz_cur = 0
    used: dict[uuid.UUID, set[int]] = defaultdict(set)
    remaining = dict(enumerate(budget))

    used_pnrs: set[str] = set()
    bookings: list[tuple] = []
    unsold = 0

    for flight_id, seat_id, cabin in sold:
        pool, cursor = (biz_pool, biz_cur) if cabin == "BUSINESS" else (econ_pool, econ_cur)
        chosen = None

        # Walk the pool until a passenger turns up who has trips left and is
        # not already on this flight. Bounded so a nearly exhausted pool cannot
        # make this quadratic.
        for _ in range(64):
            if cursor >= len(pool):
                break
            cand = pool[cursor]
            cursor += 1
            if remaining.get(cand, 0) <= 0:
                continue
            if cand in used[flight_id]:
                continue
            chosen = cand
            break

        if cabin == "BUSINESS":
            biz_cur = cursor
        else:
            econ_cur = cursor

        if chosen is None:
            unsold += 1
            continue

        remaining[chosen] -= 1
        used[flight_id].add(chosen)
        bookings.append((
            make_pnr(used_pnrs),
            passengers[chosen][0],  # passenger_id
            flight_id,  # original_flight_id
            None,  # reaccommodated_flight_id
            seat_id,  # assigned_seat_id
            "CONFIRMED",
            now,
        ))  # fmt: skip

    return bookings, unsold


def plan(args: argparse.Namespace) -> dict:
    """Everything that does not need a database. Returns the row sets."""
    if args.seed is not None:
        random.seed(args.seed)
        Faker.seed(args.seed)
    fake = Faker()

    flights = build_flights(args.days, repeat_numbers=not args.unique_flight_numbers)
    print(f"[PLAN] {len(flights):,} departures over {args.days} days across {len(ROUTES)} routes.")

    seat_rows, seat_index = build_seats(flights)
    print(f"[PLAN] {len(seat_rows):,} seats.")

    sold = plan_occupancy(flights, seat_index, args.load_factor, args.load_spread)
    print(
        f"[PLAN] {len(sold):,} seats to sell "
        f"(target load {args.load_factor:.2f} +/- {args.load_spread:.2f})."
    )

    n_pax = args.passengers or estimate_passenger_count(len(sold))
    passenger_rows = build_passengers(n_pax, fake)
    print(f"[PLAN] {len(passenger_rows):,} passengers.")

    bookings, unsold = assign_bookings(sold, passenger_rows)
    print(
        f"[PLAN] {len(bookings):,} bookings "
        f"({unsold:,} seats left unsold for want of an eligible passenger)."
    )

    return {
        "flight_rows": [
            (
                f["flight_id"],
                f["flight_number"],
                f["origin"],
                f["destination"],
                f["departure_time"],
                f["arrival_time"],
                f["status"],
                f["aircraft_type"],
            )
            for f in flights
        ],  # fmt: skip
        "seat_rows": seat_rows,
        "passenger_rows": passenger_rows,
        "booking_rows": bookings,
        "booked_seat_ids": [b[4] for b in bookings],
    }


# ---------------------------------------------------------------------------
# Database stage.
# ---------------------------------------------------------------------------


async def preflight(conn: asyncpg.Connection) -> dict:
    """Verify the deployed schema before writing a single row.

    v1 assumed column names and enum labels. When the ERD and the deployed
    schema diverged, the load failed part-way through and left the database in
    a half-populated state. Checking first costs four queries.
    """
    problems: list[str] = []

    for table, cols in REQUIRED_COLUMNS.items():
        found = {
            r["column_name"]
            for r in await conn.fetch(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_schema='public' AND table_name=$1",
                table,
            )
        }
        if not found:
            problems.append(f"table public.{table} does not exist")
            continue
        missing = [c for c in cols if c not in found]
        if missing:
            problems.append(f"{table} is missing column(s): {', '.join(missing)}")

    for enum_name, labels in REQUIRED_ENUM_LABELS.items():
        found = await _enum_labels(conn, enum_name)
        if not found:
            problems.append(f"enum type {enum_name} does not exist")
            continue
        missing = [lbl for lbl in labels if lbl not in found]
        if missing:
            problems.append(f"enum {enum_name} is missing label(s): {', '.join(missing)}")

    if problems:
        raise RuntimeError(
            "Schema preflight failed - nothing was written:\n  - "
            + "\n  - ".join(problems)
            + "\n\nApply the base schema and the migrations in db/migrations/ first."
        )

    # Does flights.flight_number carry a unique constraint? If it does not, the
    # same service can keep its number every day, which is what the UI shows.
    unique_fn = await conn.fetchval("""
        SELECT EXISTS (
            SELECT 1
            FROM pg_index i
            JOIN pg_class c     ON c.oid = i.indrelid
            JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(i.indkey)
            WHERE c.relname = 'flights'
              AND i.indisunique
              AND i.indnatts = 1          -- unique on the column by itself
              AND a.attname = 'flight_number'
        )
    """)

    labels = {name: await _enum_labels(conn, name) for name in ("flight_status", "pnr_status")}
    return {"unique_flight_number": bool(unique_fn), "labels": labels}


async def _enum_labels(conn: asyncpg.Connection, enum_name: str) -> set[str]:
    rows = await conn.fetch(
        "SELECT e.enumlabel FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid "
        "WHERE t.typname = $1",
        enum_name,
    )
    return {r["enumlabel"] for r in rows}


async def bulk_insert(
    conn: asyncpg.Connection, table: str, columns: list[str], rows: list[tuple], batch: int = 10000
) -> None:
    """COPY the rows in, falling back to batched executemany if the pooler
    refuses COPY. 157,000 seats through executemany is roughly twenty minutes;
    through COPY it is seconds."""
    if not rows:
        return
    try:
        # Inside a transaction so a mid-stream COPY failure rolls back rather
        # than leaving a partial load that the fallback would then duplicate.
        async with conn.transaction():
            await conn.copy_records_to_table(table, records=rows, columns=columns)
        print(f"[INFO] {len(rows):>7,} rows -> {table} (COPY)")
        return
    except Exception as exc:  # noqa: BLE001 - any COPY failure is recoverable
        print(
            f"[WARN] COPY into {table} unavailable ({type(exc).__name__}); "
            "falling back to batched INSERT."
        )

    # table and columns come from REQUIRED_COLUMNS above, never from input.
    placeholders = ",".join(f"${i + 1}" for i in range(len(columns)))
    sql = f"INSERT INTO {table} ({','.join(columns)}) VALUES ({placeholders})"  # noqa: S608
    for start in range(0, len(rows), batch):
        await conn.executemany(sql, rows[start : start + batch])
        print(f"[INFO] {min(start + batch, len(rows)):>7,}/{len(rows):,} -> {table}", end="\r")
    print(f"[INFO] {len(rows):>7,} rows -> {table} (INSERT)          ")


async def apply_disruption(conn: asyncpg.Connection, cancel: int, delay: int, labels: dict) -> None:
    """Cancel the busiest future flights, optionally delay a few more.

    Cancelling by booking volume rather than by a hardcoded flight number
    guarantees genuine contention for the remaining seats, which is the
    condition the pessimistic locking in reaccommodate_passenger_atomic exists
    to handle - and it means this script and db/seeds/reset_demo_state.sql agree.
    """
    cancelled = await conn.fetch(
        """
        UPDATE flights SET status='CANCELLED'
        WHERE flight_id IN (
            SELECT f.flight_id FROM flights f
            JOIN pnr_bookings b ON b.original_flight_id = f.flight_id
            WHERE f.status='SCHEDULED' AND f.departure_time > now()
            GROUP BY f.flight_id
            ORDER BY count(b.pnr_code) DESC
            LIMIT $1
        )
        RETURNING flight_id, flight_number, origin, destination, departure_time
    """,
        cancel,
    )

    # The UPDATE and the count must be separate statements: a subquery in
    # RETURNING sees the snapshot taken before the UPDATE.
    await conn.execute("""
        UPDATE pnr_bookings b SET booking_status='DISRUPTED', updated_at=now()
        FROM flights f
        WHERE f.flight_id = b.original_flight_id AND f.status='CANCELLED'
    """)

    # A DELAYED population is only created if the deployed enum has the label.
    # Never assume an enum value that preflight did not see.
    if delay and "DELAYED" in labels.get("flight_status", set()):
        await conn.execute(
            """
            UPDATE flights
            SET status='DELAYED',
                departure_time = departure_time + (interval '1 hour' * (1 + random()*4)),
                arrival_time   = arrival_time   + (interval '1 hour' * (1 + random()*4))
            WHERE flight_id IN (
                SELECT flight_id FROM flights
                WHERE status='SCHEDULED' AND departure_time > now()
                ORDER BY random() LIMIT $1
            )
        """,
            delay,
        )
        print(f"[INFO] {delay} flights marked DELAYED.")
    elif delay:
        print("[INFO] flight_status has no DELAYED label; skipping delays.")

    print("\n--- Disruption created ---")
    for c in cancelled:
        alts = await conn.fetchval(
            """
            SELECT count(*) FROM flights alt
            WHERE alt.origin=$1 AND alt.destination=$2
              AND alt.status='SCHEDULED' AND alt.departure_time > now()
        """,
            c["origin"],
            c["destination"],
        )
        print(
            f"  {c['flight_number']:<8} {c['origin']}-{c['destination']}  "
            f"{c['departure_time']:%a %d %b %H:%M}  ({alts} alternatives on route)"
        )


async def report(conn: asyncpg.Connection) -> None:
    """Verification. If any of these numbers look wrong, the dataset is wrong,
    and every downstream test result is meaningless."""
    counts = await conn.fetchrow("""
        SELECT (SELECT count(*) FROM flights)      AS flights,
               (SELECT count(*) FROM seats)        AS seats,
               (SELECT count(*) FROM passengers)   AS passengers,
               (SELECT count(*) FROM pnr_bookings) AS bookings,
               (SELECT count(*) FROM seats WHERE status='BOOKED')        AS booked_seats,
               (SELECT count(*) FROM pnr_bookings
                 WHERE booking_status='DISRUPTED')                       AS disrupted,
               (SELECT count(*) FROM flights WHERE status='CANCELLED')   AS cancelled
    """)
    print("\n--- Dataset ---")
    for k, v in counts.items():
        print(f"  {k:<14} {v:>9,}")

    lf = await conn.fetchval("""
        SELECT round(avg(lf)::numeric, 3) FROM (
            SELECT (count(*) FILTER (WHERE status='BOOKED'))::float / count(*) AS lf
            FROM seats GROUP BY flight_id
        ) x
    """)
    print(f"  {'avg load':<14} {lf}")

    # Integrity: no seat may be held by two bookings, and no booking may hold a
    # seat that belongs to a different flight. NFR-03 depends on both.
    dup = await conn.fetchval("""
        SELECT count(*) FROM (
            SELECT assigned_seat_id FROM pnr_bookings
            WHERE assigned_seat_id IS NOT NULL
            GROUP BY assigned_seat_id HAVING count(*) > 1
        ) d
    """)
    mismatch = await conn.fetchval("""
        SELECT count(*) FROM pnr_bookings b
        JOIN seats s ON s.seat_id = b.assigned_seat_id
        WHERE s.flight_id <> b.original_flight_id
    """)
    multi = await conn.fetchval("""
        SELECT count(*) FROM (
            SELECT passenger_id FROM pnr_bookings
            GROUP BY passenger_id HAVING count(*) > 1
        ) m
    """)
    print(f"\n  double-booked seats        {dup}   (must be 0)")
    print(f"  seat/flight mismatches     {mismatch}   (must be 0)")
    print(f"  passengers with >1 booking {multi:,}")

    demo = await conn.fetchrow("""
        SELECT b.pnr_code, p.last_name, p.asante_rewards_tier,
               f.flight_number, f.origin, f.destination, s.cabin_class
        FROM pnr_bookings b
        JOIN passengers p ON p.passenger_id = b.passenger_id
        JOIN flights    f ON f.flight_id    = b.original_flight_id
        LEFT JOIN seats s ON s.seat_id      = b.assigned_seat_id
        WHERE b.booking_status='DISRUPTED'
        ORDER BY p.asante_rewards_tier
        LIMIT 1
    """)
    if demo:
        print(
            f"\n[DEMO] PNR {demo['pnr_code']} / surname {demo['last_name']} "
            f"({demo['asante_rewards_tier']}, {demo['cabin_class']}) was on "
            f"{demo['flight_number']} {demo['origin']}-{demo['destination']}"
        )


async def run(args: argparse.Namespace) -> None:
    database_url = args.database_url or os.getenv("DATABASE_URL")
    if not database_url:
        # Without this guard asyncpg falls back to its defaults and tries to
        # authenticate as the operating system user, producing a password
        # failure that points at the wrong problem entirely.
        sys.exit(
            f"DATABASE_URL is not set.\n"
            f"  Looked for an .env file at: {ENV_PATH}\n"
            f"  Exists: {ENV_PATH.exists()}\n\n"
            f"On Windows, check the file is really named '.env' and not '.env.txt' -\n"
            f"Explorer hides known extensions. Run: Get-ChildItem -Force .env*"
        )

    conn = await asyncpg.connect(database_url, statement_cache_size=0)
    try:
        meta = await preflight(conn)
        print("[INFO] Schema preflight passed.")
        if meta["unique_flight_number"] and not args.unique_flight_numbers:
            print("[INFO] flights.flight_number is UNIQUE; using per-departure numbering.")
            args.unique_flight_numbers = True

        data = plan(args)

        if args.truncate:
            tables = ["pnr_bookings", "seats", "flights", "passengers"]
            for extra in ("vouchers", "audit_logs"):
                exists = await conn.fetchval(
                    "SELECT to_regclass($1::text) IS NOT NULL", f"public.{extra}"
                )
                if exists:
                    tables.insert(0, extra)
            # Table names are the fixed list above, never input.
            await conn.execute(f"TRUNCATE {', '.join(tables)} RESTART IDENTITY CASCADE;")
            print(f"[INFO] Cleared: {', '.join(tables)}.")

        await bulk_insert(conn, "flights", REQUIRED_COLUMNS["flights"], data["flight_rows"])
        await bulk_insert(conn, "seats", REQUIRED_COLUMNS["seats"], data["seat_rows"])
        await bulk_insert(
            conn, "passengers", REQUIRED_COLUMNS["passengers"], data["passenger_rows"]
        )
        await bulk_insert(
            conn, "pnr_bookings", REQUIRED_COLUMNS["pnr_bookings"], data["booking_rows"]
        )

        # Mark the sold seats, one statement per batch rather than one per
        # seat; 130,000 individual UPDATEs over a pooled connection is the
        # slowest possible way to do this.
        ids = data["booked_seat_ids"]
        for start in range(0, len(ids), 20000):
            await conn.execute(
                "UPDATE seats SET status='BOOKED', row_version=row_version+1 "
                "WHERE seat_id = ANY($1::uuid[])",
                ids[start : start + 20000],
            )
        print(f"[INFO] {len(ids):,} seats marked BOOKED.")

        await apply_disruption(conn, args.cancel, args.delay, meta["labels"])
        await report(conn)
    finally:
        await conn.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate Project Kestrel test data (v2).")
    parser.add_argument("--days", type=int, default=7, help="Days of schedule to build.")
    parser.add_argument(
        "--passengers",
        type=int,
        default=None,
        help="Passenger count. Default: derived from seats sold and tier trip means.",
    )
    parser.add_argument(
        "--load-factor", type=float, default=0.82, help="Mean seats sold per flight."
    )
    parser.add_argument(
        "--load-spread", type=float, default=0.09, help="Per-flight std deviation of load."
    )
    parser.add_argument("--cancel", type=int, default=3, help="Flights to cancel (busiest first).")
    parser.add_argument(
        "--delay", type=int, default=0, help="Flights to delay, if the enum has DELAYED."
    )
    parser.add_argument("--seed", type=int, default=None, help="Fix the RNG for reproducibility.")
    parser.add_argument("--truncate", action="store_true", help="Clear existing data first.")
    parser.add_argument(
        "--unique-flight-numbers",
        action="store_true",
        help="A distinct flight number per departure instead of per daily service.",
    )
    parser.add_argument("--database-url", default=None, help="Overrides DATABASE_URL from .env.")
    parser.add_argument(
        "--dry-run", action="store_true", help="Plan and print the shape; touch no database."
    )
    args = parser.parse_args()

    if args.dry_run:
        plan(args)
        return
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
