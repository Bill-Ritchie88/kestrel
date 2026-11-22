"""
Integration tests for connecting journeys (migration 015):
reaccommodate_journey_atomic and the broken-connection trigger.

No existing flight, passenger or booking is read or changed: every test builds
its own synthetic rows, recognisable by prefix (PNRs starting with a digit,
which real PNRs never do; flight numbers CN9.. between the made-up airports
CXA and CXB and NBO).

  * Most tests run on one connection inside a transaction that is always
    rolled back. With KESTREL_PREVIEW_MIGRATION=db/migrations/015_connecting_flights.sql
    the migration runs first inside it, so 015 is proved before it is applied.
  * The lock tests need a second connection, so their flights and seats are
    committed and deleted again in a finally block. The NOWAIT test runs with
    the preview (only the seats are shared); the two-passenger race needs 015
    applied and skips until then.
"""

import asyncio
import json
import os
from pathlib import Path

import asyncpg
import pytest

from kestrel.api.journeys import LEG_CANDIDATES, MIN_CONNECTION, SQL_JOURNEY_LEGS, build_journeys

pytestmark = pytest.mark.integration

CALL = "SELECT * FROM reaccommodate_journey_atomic($1, $2, $3, $4, $5, $6)"
SQL_HAS_JOURNEY = "SELECT to_regprocedure('reaccommodate_journey_atomic(varchar, uuid, uuid, varchar, uuid, uuid)') IS NOT NULL"
ORIGIN, FINAL = "CXA", "CXB"


async def make_flights(conn, prefix: str, first_status: str = "CANCELLED") -> dict:
    """Day 30: the booked journey f1 (CXA-NBO 00:00-02:00) and f2 (NBO-CXB
    03:30-05:30). Day 31: a1 (CXA-NBO 00:00-02:00), b_short (NBO-CXB
    02:30, inside the 60-minute connection), b2 (NBO-CXB 04:00-06:00).
    Economy seats: 10A on f1 and f2 (the passenger's), 5A/5B on the rest, 5B
    on b2 already BOOKED. Business 1A on b2."""
    spec = {
        "f1": (ORIGIN, "NBO", 30, 0, 2, first_status),
        "f2": ("NBO", FINAL, 30, 3.5, 5.5, "SCHEDULED"),
        "a1": (ORIGIN, "NBO", 31, 0, 2, "SCHEDULED"),
        "b_short": ("NBO", FINAL, 31, 2.5, 4.5, "SCHEDULED"),
        "b2": ("NBO", FINAL, 31, 4, 6, "SCHEDULED"),
    }
    ids = {}
    for i, (key, (o, d, day, dep, arr, st)) in enumerate(spec.items()):
        ids[key] = await conn.fetchval(
            """INSERT INTO flights (flight_number, origin, destination, departure_time, arrival_time,
                                    status, aircraft_type, disruption_reason)
               VALUES ($1, $2, $3,
                       date_trunc('day', now()) + make_interval(days => $4) + make_interval(mins => $5),
                       date_trunc('day', now()) + make_interval(days => $4) + make_interval(mins => $6),
                       $7::flight_status, '738', CASE WHEN $7 = 'CANCELLED' THEN 'TECHNICAL' END)
               RETURNING flight_id""",
            f"{prefix}{i}", o, d, day, int(dep * 60), int(arr * 60), st,
        )  # fmt: skip
    seats = {}
    for key, number, cabin, status in (
        ("f1", "10A", "ECONOMY", "BOOKED"),
        ("f2", "10A", "ECONOMY", "BOOKED"),
        *((k, n, "ECONOMY", "AVAILABLE") for k in ("a1", "b_short", "b2") for n in ("5A",)),
        ("a1", "5B", "ECONOMY", "AVAILABLE"),
        ("b2", "5B", "ECONOMY", "BOOKED"),
        ("b2", "1A", "BUSINESS", "AVAILABLE"),
    ):
        seats[f"{key}-{number}"] = await conn.fetchval(
            "INSERT INTO seats (flight_id, seat_number, cabin_class, status) VALUES ($1, $2, $3, $4::seat_status) "
            "RETURNING seat_id",
            ids[key], number, cabin, status,
        )  # fmt: skip
    return {**ids, "seats": seats}


async def make_booking(conn, fx: dict, pnr: str, status: str = "DISRUPTED", seat_suffix: str = "10A") -> str:
    pid = await conn.fetchval(
        """INSERT INTO passengers (first_name, last_name, email, phone_number)
           VALUES ('Conn', 'Test', 'connect+' || $1 || '@example.invalid', '+0000000000')
           RETURNING passenger_id""",
        pnr,
    )
    await conn.execute(
        """INSERT INTO pnr_bookings (pnr_code, passenger_id, original_flight_id, assigned_seat_id,
                                     onward_flight_id, onward_seat_id, booking_status)
           VALUES ($1, $2, $3, $4, $5, $6, $7::pnr_status)""",
        pnr, pid, fx["f1"], fx["seats"][f"f1-{seat_suffix}"], fx["f2"], fx["seats"][f"f2-{seat_suffix}"], status,
    )  # fmt: skip
    return pnr


async def state(conn, pnr):
    return await conn.fetchrow(
        """SELECT booking_status::text AS status, reaccommodated_flight_id, reaccommodated_onward_flight_id,
                  assigned_seat_id, onward_seat_id FROM pnr_bookings WHERE pnr_code = $1""",
        pnr,
    )


async def seat_status(conn, seat_id):
    return await conn.fetchval("SELECT status::text FROM seats WHERE seat_id = $1", seat_id)


async def last_audit(conn, pnr):
    return await conn.fetchrow(
        "SELECT action, details FROM audit_logs WHERE pnr_code = $1 ORDER BY timestamp DESC LIMIT 1", pnr
    )


async def preview(connection) -> None:
    path = os.getenv("KESTREL_PREVIEW_MIGRATION")
    if path:
        await connection.execute(Path(path).read_text(encoding="utf-8"))
    if not await connection.fetchval(SQL_HAS_JOURNEY):
        pytest.skip("reaccommodate_journey_atomic does not exist: apply or preview migration 015")


# ---------------------------------------------------------------------------
# One connection, rolled back.
# ---------------------------------------------------------------------------


@pytest.fixture
async def conn():
    connection = await asyncpg.connect(os.environ["DATABASE_URL"], statement_cache_size=0)
    transaction = connection.transaction()
    await transaction.start()
    try:
        await preview(connection)
        yield connection
    finally:
        await transaction.rollback()
        await connection.close()


@pytest.fixture
async def fx(conn):
    flights = await make_flights(conn, "CN9")
    return {**flights, "pnr": await make_booking(conn, flights, "7J0001")}


async def test_the_sql_and_python_connection_times_agree(conn):
    assert await conn.fetchval("SELECT kestrel_min_connection()") == MIN_CONNECTION
    assert await conn.fetchval("SELECT kestrel_connection_hub()") == "NBO"


async def test_the_journey_options_query_offers_only_journeys_that_connect(conn, fx):
    rows = await conn.fetch(SQL_JOURNEY_LEGS, fx["pnr"], LEG_CANDIDATES)
    options = [(o["flight_id"], o["onward"]["flight_id"]) for o in build_journeys(rows, 5)]
    # a1 lands 02:00: b_short (02:30) is too tight, b2 (04:00) connects; the
    # cancelled f1 is no option, and the kept f2 leaves before a1 lands.
    assert options == [(str(fx["a1"]), str(fx["b2"]))]


async def test_both_legs_are_rebooked_together(conn, fx):
    row = await conn.fetchrow(CALL, fx["pnr"], fx["a1"], fx["b2"], "PYTEST", None, None)
    assert (row["success"], row["assigned_seat_number"], row["onward_seat_number"]) == (True, "5A", "5A")
    after = await state(conn, fx["pnr"])
    assert after["status"] == "REACCOMMODATED"
    assert (after["reaccommodated_flight_id"], after["reaccommodated_onward_flight_id"]) == (fx["a1"], fx["b2"])
    assert (after["assigned_seat_id"], after["onward_seat_id"]) == (fx["seats"]["a1-5A"], fx["seats"]["b2-5A"])
    for seat, expected in (("a1-5A", "BOOKED"), ("b2-5A", "BOOKED"), ("f1-10A", "AVAILABLE"), ("f2-10A", "AVAILABLE")):
        assert await seat_status(conn, fx["seats"][seat]) == expected, seat
    legs = await conn.fetch(
        """SELECT details->>'leg' AS leg FROM audit_logs
           WHERE pnr_code = $1 AND action = 'AUTOMATED_REACCOMMODATION' ORDER BY 1""",
        fx["pnr"],
    )
    assert [r["leg"] for r in legs] == ["1", "2"]  # one audit row per leg


async def test_chosen_seats_on_both_legs(conn, fx):
    row = await conn.fetchrow(
        CALL, fx["pnr"], fx["a1"], fx["b2"], "PYTEST", fx["seats"]["a1-5B"], fx["seats"]["b2-5A"]
    )
    assert (row["success"], row["assigned_seat_number"], row["onward_seat_number"]) == (True, "5B", "5A")


async def assert_nothing_changed(conn, fx, before, reason):
    assert await state(conn, fx["pnr"]) == before
    for seat, expected in (("a1-5A", "AVAILABLE"), ("a1-5B", "AVAILABLE"), ("f1-10A", "BOOKED"), ("f2-10A", "BOOKED")):
        assert await seat_status(conn, fx["seats"][seat]) == expected, seat
    audit = await last_audit(conn, fx["pnr"])
    assert audit["action"] == "REACCOMMODATION_REJECTED"
    assert json_reason(audit) == reason


@pytest.mark.parametrize(
    ("onward_seat", "reason", "message"),
    [
        ("b2-5B", "SEAT_TAKEN", "That seat was just taken on your onward flight. Please pick another."),
        ("b2-1A", "SEAT_WRONG_CABIN", None),
        ("a1-5A", "SEAT_NOT_ON_FLIGHT", None),
    ],
)
async def test_a_refused_onward_seat_leaves_the_first_leg_untouched(conn, fx, onward_seat, reason, message):
    """All or nothing: leg 1's seat would have been free, but nothing is written."""
    before = await state(conn, fx["pnr"])
    row = await conn.fetchrow(
        CALL, fx["pnr"], fx["a1"], fx["b2"], "PYTEST", fx["seats"]["a1-5A"], fx["seats"][onward_seat]
    )
    assert row["success"] is False and row["assigned_seat_number"] is None
    if message:
        assert row["message"] == message
    await assert_nothing_changed(conn, fx, before, reason)


@pytest.mark.parametrize(
    ("first", "onward", "reason"),
    [
        ("a1", "b_short", "CONNECTION_TOO_SHORT"),
        ("b2", "a1", "DIFFERENT_ROUTE"),
        ("f1", "b2", "FLIGHT_NOT_SCHEDULED"),  # the cancelled leg itself
        ("f1", "f2", "ALREADY_ON_TARGET_FLIGHT"),
    ],
)
async def test_journey_rules_are_refused_and_audited(conn, fx, first, onward, reason):
    before = await state(conn, fx["pnr"])
    row = await conn.fetchrow(CALL, fx["pnr"], fx[first], fx[onward], "PYTEST", None, None)
    assert row["success"] is False
    await assert_nothing_changed(conn, fx, before, reason)


async def test_a_single_flight_booking_is_refused(conn, fx):
    await conn.execute("UPDATE pnr_bookings SET onward_flight_id = NULL WHERE pnr_code = $1", fx["pnr"])
    row = await conn.fetchrow(CALL, fx["pnr"], fx["a1"], fx["b2"], "PYTEST", None, None)
    assert row["success"] is False
    assert json_reason(await last_audit(conn, fx["pnr"])) == "NOT_A_CONNECTION"


def json_reason(audit) -> str:
    return json.loads(audit["details"])["reason"]


async def test_a_good_first_leg_is_kept_with_its_seat(conn):
    """Leg 2 cancelled: keep leg 1 and its seat, move only the onward flight."""
    flights = await make_flights(conn, "CN9", first_status="SCHEDULED")
    await conn.execute("UPDATE flights SET status = 'CANCELLED' WHERE flight_id = $1", flights["f2"])
    pnr = await make_booking(conn, flights, "7J0002")
    row = await conn.fetchrow(CALL, pnr, flights["f1"], flights["b2"], "PYTEST", None, None)
    assert (row["success"], row["assigned_seat_number"], row["onward_seat_number"]) == (True, "10A", "5A")
    after = await state(conn, pnr)
    assert after["assigned_seat_id"] == flights["seats"]["f1-10A"]
    assert await seat_status(conn, flights["seats"]["f1-10A"]) == "BOOKED"
    assert await seat_status(conn, flights["seats"]["f2-10A"]) == "AVAILABLE"


# -- The broken-connection trigger ------------------------------------------


@pytest.fixture
async def confirmed(conn):
    flights = await make_flights(conn, "CN9", first_status="SCHEDULED")
    return {**flights, "pnr": await make_booking(conn, flights, "7J0003", status="CONFIRMED")}


CANCEL = "UPDATE flights SET status = 'CANCELLED' WHERE flight_id = $1"
DELAY = ("UPDATE flights SET status = 'DELAYED', departure_time = departure_time + make_interval(mins => {m}), "
         "arrival_time = arrival_time + make_interval(mins => {m}) WHERE flight_id = $1")


@pytest.mark.parametrize(
    ("leg", "update", "disrupted"),
    [
        ("f1", CANCEL, True),
        ("f2", CANCEL, True),
        # Leg 1 lands 02:00, leg 2 leaves 03:30: 31 minutes late leaves 59 at the hub.
        ("f1", DELAY.format(m=31), True),
        ("f1", DELAY.format(m=30), False),
    ],
    ids=["leg-1-cancelled", "leg-2-cancelled", "leg-1-delayed-past-mct", "leg-1-delayed-within-mct"],
)
async def test_a_broken_connection_disrupts_the_booking(conn, confirmed, leg, update, disrupted):
    await conn.execute(update, confirmed[leg])
    assert (await state(conn, confirmed["pnr"]))["status"] == ("DISRUPTED" if disrupted else "CONFIRMED")


async def test_a_single_flight_booking_is_left_to_the_existing_process(conn, confirmed):
    await conn.execute("UPDATE pnr_bookings SET onward_flight_id = NULL WHERE pnr_code = $1", confirmed["pnr"])
    await conn.execute("UPDATE flights SET status = 'CANCELLED' WHERE flight_id = $1", confirmed["f1"])
    assert (await state(conn, confirmed["pnr"]))["status"] == "CONFIRMED"


# ---------------------------------------------------------------------------
# Several connections: committed flights and seats, always deleted again.
# ---------------------------------------------------------------------------

L_PREFIX, L_PNR = "CL9", "7L"


async def cleanup(c) -> None:
    async with c.transaction():
        has_onward = await c.fetchval(
            "SELECT 1 FROM information_schema.columns WHERE table_name = 'pnr_bookings' AND column_name = 'onward_flight_id'"
        )
        await c.execute("DELETE FROM audit_logs WHERE pnr_code LIKE $1", L_PNR + "%")
        if has_onward:
            await c.execute("DELETE FROM pnr_bookings WHERE pnr_code LIKE $1", L_PNR + "%")
        await c.execute("DELETE FROM passengers WHERE email LIKE $1", f"connect+{L_PNR}%@example.invalid")
        await c.execute(
            "DELETE FROM flights WHERE flight_number LIKE $1 AND (origin = $2 OR destination = $3)",
            L_PREFIX + "%", ORIGIN, FINAL,
        )  # fmt: skip


@pytest.fixture
async def pool():
    pool = await asyncpg.create_pool(os.environ["DATABASE_URL"], min_size=2, max_size=6, statement_cache_size=0)
    async with pool.acquire() as c:
        await cleanup(c)
    try:
        yield pool
    finally:
        async with pool.acquire() as c:
            await cleanup(c)
        await pool.close()


async def test_an_onward_seat_locked_by_another_rebooking_is_refused_at_once(pool):
    """NOWAIT on leg 2: while another transaction holds the onward seat the call
    answers SEAT_TAKEN at once, and leg 1 is not taken either. Runs with the
    preview: only the committed seats are shared between the connections."""
    async with pool.acquire() as c, c.transaction():
        flights = await make_flights(c, L_PREFIX)
    seat = flights["seats"]["b2-5A"]
    async with pool.acquire() as holder, pool.acquire() as caller:
        lock = holder.transaction()
        work = caller.transaction()
        await lock.start()
        await work.start()
        try:
            await preview(caller)
            pnr = await make_booking(caller, flights, L_PNR + "0001")
            await holder.execute("SELECT 1 FROM seats WHERE seat_id = $1 FOR UPDATE", seat)
            row = await asyncio.wait_for(
                caller.fetchrow(CALL, pnr, flights["a1"], flights["b2"], "PYTEST", None, seat), timeout=10
            )
            assert row["success"] is False
            assert row["message"] == "That seat was just taken on your onward flight. Please pick another."
            assert await seat_status(caller, flights["seats"]["a1-5A"]) == "AVAILABLE"
            assert (await state(caller, pnr))["status"] == "DISRUPTED"
        finally:
            await work.rollback()
            await lock.rollback()


async def test_two_passengers_racing_for_one_onward_seat_exactly_one_wins(pool):
    """NFR-03 for journeys: needs 015 applied (the bookings must be committed)."""
    async with pool.acquire() as c:
        if not await c.fetchval(SQL_HAS_JOURNEY):
            pytest.skip("migration 015 is not applied; the NOWAIT test above covers the lock until then")
        async with c.transaction():
            flights = await make_flights(c, L_PREFIX)
            # A second passenger's seats on the booked journey.
            for key in ("f1", "f2"):
                flights["seats"][f"{key}-10B"] = await c.fetchval(
                    "INSERT INTO seats (flight_id, seat_number, cabin_class, status) "
                    "VALUES ($1, '10B', 'ECONOMY', 'BOOKED') RETURNING seat_id",
                    flights[key],
                )
            pnrs = [await make_booking(c, flights, L_PNR + "0001"),
                    await make_booking(c, flights, L_PNR + "0002", seat_suffix="10B")]  # fmt: skip
    seat = flights["seats"]["b2-5A"]

    async def choose(pnr):
        async with pool.acquire() as c:
            return await c.fetchrow(CALL, pnr, flights["a1"], flights["b2"], "PYTEST", None, seat)

    results = await asyncio.gather(*(choose(p) for p in pnrs))
    assert sorted(r["success"] for r in results) == [False, True]
    async with pool.acquire() as c:
        holders = await c.fetchval("SELECT count(*) FROM pnr_bookings WHERE onward_seat_id = $1", seat)
        loser = next(p for p, r in zip(pnrs, results, strict=True) if not r["success"])
        assert holders == 1
        assert (await state(c, loser))["status"] == "DISRUPTED"
        # The loser took nothing on leg 1 either: only the winner's seat is booked there.
        assert await c.fetchval(
            "SELECT count(*) FROM seats WHERE flight_id = $1 AND status = 'BOOKED'", flights["a1"]
        ) == 1
