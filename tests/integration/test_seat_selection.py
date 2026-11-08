"""
Integration tests for seat selection in reaccommodate_passenger_atomic
(migration 013, FR-16).

No existing flight, passenger or booking is read or changed: every test
builds its own synthetic flights, seats, passengers and bookings, recognisable
by prefix (PNRs starting with a digit, which real PNRs never do; flight
numbers SM9/SC9 on routes to SMX/SCX, which no real flight flies).

  * The procedure tests run on one connection inside a transaction that is
    always rolled back. With KESTREL_PREVIEW_MIGRATION=<path to 013> they
    first run that migration inside the same transaction, so the SQL can be
    proved before it is applied.
  * The concurrency tests need several connections, so their fixture is
    committed and deleted again in a finally block, even after a failure.
"""

import asyncio
import os
from pathlib import Path

import asyncpg
import pytest

pytestmark = pytest.mark.integration

CALL4 = "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3, $4)"
CALL3 = "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3)"
SEAT_TAKEN = "That seat was just taken. Please pick another."
SQL_HAS_SEAT_PARAMETER = """
    SELECT EXISTS (SELECT 1 FROM pg_proc
                   WHERE proname = 'reaccommodate_passenger_atomic'
                     AND 'p_seat_id' = ANY (proargnames))
"""


async def make_fixture(conn, pnr_prefix: str, flight_prefix: str, destination: str, n: int) -> dict:
    """A cancelled flight with n DISRUPTED bookings (economy seats 10A..), a
    target flight on the same route with economy 5A-5F (5D already BOOKED)
    and business 1A, and another flight on the route with economy 5A."""
    flights = {}
    for key, number, status, days in (
        ("original", "000", "CANCELLED", 30),
        ("target", "001", "SCHEDULED", 31),
        ("other", "002", "SCHEDULED", 32),
    ):
        flights[key] = await conn.fetchval(
            """INSERT INTO flights (flight_number, origin, destination, departure_time, arrival_time,
                                    status, aircraft_type)
               VALUES ($1, 'NBO', $2, now() + make_interval(days => $3),
                       now() + make_interval(days => $3, hours => 2), $4::flight_status, '738')
               RETURNING flight_id""",
            flight_prefix + number, destination, days, status,
        )  # fmt: skip
    await conn.execute(
        """INSERT INTO seats (flight_id, seat_number, cabin_class, status)
           SELECT $1, (g / 6 + 10)::text || substr('ABCDEF', g % 6 + 1, 1), 'ECONOMY', 'BOOKED'
           FROM generate_series(0, $2 - 1) g""",
        flights["original"], n,
    )  # fmt: skip
    seats = {}
    for flight, number, cabin, status in (
        *((flights["target"], f"5{x}", "ECONOMY", "AVAILABLE") for x in "ABCEF"),
        (flights["target"], "5D", "ECONOMY", "BOOKED"),
        (flights["target"], "1A", "BUSINESS", "AVAILABLE"),
        (flights["other"], "5A", "ECONOMY", "AVAILABLE"),
    ):
        key = number if flight == flights["target"] else f"other-{number}"
        seats[key] = await conn.fetchval(
            """INSERT INTO seats (flight_id, seat_number, cabin_class, status)
               VALUES ($1, $2, $3, $4::seat_status) RETURNING seat_id""",
            flight, number, cabin, status,
        )  # fmt: skip
    rows = await conn.fetch(
        """WITH p AS (
               INSERT INTO passengers (first_name, last_name, email, phone_number)
               SELECT 'Seat', 'Test', 'seatmap+' || $1 || '-' || g || '@example.invalid', '+0000000000'
               FROM generate_series(0, $3 - 1) g
               RETURNING passenger_id, email
           )
           INSERT INTO pnr_bookings (pnr_code, passenger_id, original_flight_id, assigned_seat_id,
                                     booking_status)
           SELECT $1 || lpad(g::text, 4, '0'), p.passenger_id, $2, st.seat_id, 'DISRUPTED'
           FROM generate_series(0, $3 - 1) g
           JOIN p ON p.email = 'seatmap+' || $1 || '-' || g || '@example.invalid'
           JOIN seats st ON st.flight_id = $2
                        AND st.seat_number = (g / 6 + 10)::text || substr('ABCDEF', g % 6 + 1, 1)
           RETURNING pnr_code, assigned_seat_id""",
        pnr_prefix, flights["original"], n,
    )  # fmt: skip
    assert len(rows) == n
    rows = sorted(rows, key=lambda r: r["pnr_code"])
    return {**flights, "seats": seats, "pnrs": [r["pnr_code"] for r in rows],
            "old_seats": [r["assigned_seat_id"] for r in rows]}  # fmt: skip


async def last_reason(conn, pnr):
    return await conn.fetchval(
        """SELECT details->>'reason' FROM audit_logs
           WHERE pnr_code = $1 ORDER BY timestamp DESC LIMIT 1""",
        pnr,
    )


async def booking_state(conn, pnr):
    return await conn.fetchrow(
        "SELECT booking_status, reaccommodated_flight_id, assigned_seat_id FROM pnr_bookings WHERE pnr_code = $1",
        pnr,
    )


# ---------------------------------------------------------------------------
# One connection, rolled back.
# ---------------------------------------------------------------------------


@pytest.fixture
async def conn():
    connection = await asyncpg.connect(os.environ["DATABASE_URL"], statement_cache_size=0)
    transaction = connection.transaction()
    await transaction.start()
    try:
        preview = os.getenv("KESTREL_PREVIEW_MIGRATION")
        if preview:
            # One multi-statement execute: inside this transaction, rolled back below.
            await connection.execute(Path(preview).read_text(encoding="utf-8"))
        if not await connection.fetchval(SQL_HAS_SEAT_PARAMETER):
            pytest.skip("reaccommodate_passenger_atomic has no p_seat_id: apply migration 013")
        yield connection
    finally:
        await transaction.rollback()
        await connection.close()


@pytest.fixture
async def fx(conn):
    return await make_fixture(conn, "8S", "SM9", "SMX", 1)


async def test_a_chosen_free_seat_is_assigned(conn, fx):
    pnr, seat = fx["pnrs"][0], fx["seats"]["5C"]
    row = await conn.fetchrow(CALL4, pnr, fx["target"], "PYTEST", seat)
    assert row["success"] is True
    assert row["assigned_seat_number"] == "5C"
    after = await booking_state(conn, pnr)
    assert after["assigned_seat_id"] == seat
    assert after["reaccommodated_flight_id"] == fx["target"]
    assert after["booking_status"] == "REACCOMMODATED"
    assert await conn.fetchval("SELECT status::text FROM seats WHERE seat_id = $1", seat) == "BOOKED"
    old = await conn.fetchval("SELECT status::text FROM seats WHERE seat_id = $1", fx["old_seats"][0])
    assert old == "AVAILABLE"
    chosen = await conn.fetchval(
        """SELECT details->>'seat_chosen' FROM audit_logs
           WHERE pnr_code = $1 AND action = 'AUTOMATED_REACCOMMODATION'""",
        pnr,
    )
    assert chosen == "true"


@pytest.mark.parametrize(
    ("seat_key", "reason"),
    [
        ("5D", "SEAT_TAKEN"),  # already BOOKED
        ("1A", "SEAT_WRONG_CABIN"),  # business, for an economy passenger
        ("other-5A", "SEAT_NOT_ON_FLIGHT"),  # same route, another flight
    ],
)
async def test_a_seat_that_cannot_be_given_is_refused_and_only_audited(conn, fx, seat_key, reason):
    pnr, seat = fx["pnrs"][0], fx["seats"][seat_key]
    before = await booking_state(conn, pnr)
    seats_before = await conn.fetch(
        "SELECT seat_id, status FROM seats WHERE flight_id = ANY($1) ORDER BY seat_id",
        [fx["original"], fx["target"], fx["other"]],
    )
    row = await conn.fetchrow(CALL4, pnr, fx["target"], "PYTEST", seat)
    assert row["success"] is False
    assert row["assigned_seat_number"] is None
    assert await last_reason(conn, pnr) == reason
    if reason == "SEAT_TAKEN":
        assert row["message"] == SEAT_TAKEN
    assert await booking_state(conn, pnr) == before
    seats_after = await conn.fetch(
        "SELECT seat_id, status FROM seats WHERE flight_id = ANY($1) ORDER BY seat_id",
        [fx["original"], fx["target"], fx["other"]],
    )
    assert seats_after == seats_before  # nothing written but the audit row


async def test_an_unknown_seat_id_is_refused(conn, fx):
    row = await conn.fetchrow(
        CALL4, fx["pnrs"][0], fx["target"], "PYTEST", "00000000-0000-0000-0000-000000000000"
    )
    assert row["success"] is False
    assert await last_reason(conn, fx["pnrs"][0]) == "SEAT_NOT_ON_FLIGHT"


@pytest.mark.parametrize("call", [CALL3, CALL4], ids=["three-arguments", "seat-null"])
async def test_without_a_seat_the_first_free_seat_in_the_cabin_is_assigned(conn, fx, call):
    """The 011 behaviour, which the assistant's tool and the deployed API rely on."""
    args = (fx["pnrs"][0], fx["target"], "PYTEST") + ((None,) if call == CALL4 else ())
    row = await conn.fetchrow(call, *args)
    assert row["success"] is True
    assert row["assigned_seat_number"] == "5A"  # first free economy seat, never business 1A


async def test_route_rules_still_come_before_the_seat(conn, fx):
    """A cancelled target flight is refused as before, whatever seat is named."""
    row = await conn.fetchrow(CALL4, fx["pnrs"][0], fx["original"], "PYTEST", fx["seats"]["5A"])
    assert row["success"] is False
    assert await last_reason(conn, fx["pnrs"][0]) == "ALREADY_ON_TARGET_FLIGHT"


# ---------------------------------------------------------------------------
# Several connections: a committed fixture, always deleted again.
# ---------------------------------------------------------------------------

C_PNR, C_FLIGHT, C_DEST = "8C", "SC9", "SCX"


async def cleanup(conn) -> None:
    async with conn.transaction():
        await conn.execute("DELETE FROM audit_logs WHERE pnr_code LIKE $1", C_PNR + "%")
        await conn.execute("DELETE FROM pnr_bookings WHERE pnr_code LIKE $1", C_PNR + "%")
        await conn.execute(
            "DELETE FROM passengers WHERE email LIKE $1", f"seatmap+{C_PNR}-%@example.invalid"
        )
        # Seats cascade with their flight.
        await conn.execute(
            "DELETE FROM flights WHERE flight_number LIKE $1 AND destination = $2", C_FLIGHT + "%", C_DEST
        )
    left = await conn.fetchval(
        """SELECT (SELECT count(*) FROM pnr_bookings WHERE pnr_code LIKE $1)
                + (SELECT count(*) FROM audit_logs WHERE pnr_code LIKE $1)
                + (SELECT count(*) FROM flights WHERE flight_number LIKE $2 AND destination = $3)""",
        C_PNR + "%", C_FLIGHT + "%", C_DEST,
    )  # fmt: skip
    assert left == 0, "seat-selection fixture rows left behind"


@pytest.fixture
async def pool():
    pool = await asyncpg.create_pool(
        os.environ["DATABASE_URL"], min_size=2, max_size=10, statement_cache_size=0
    )
    async with pool.acquire() as c:
        if not await c.fetchval(SQL_HAS_SEAT_PARAMETER):
            await pool.close()
            pytest.skip("reaccommodate_passenger_atomic has no p_seat_id: apply migration 013")
        await cleanup(c)  # a crashed earlier run
    try:
        yield pool
    finally:
        async with pool.acquire() as c:
            await cleanup(c)
        await pool.close()


@pytest.mark.parametrize("n", [2, 10])
async def test_n_passengers_choosing_the_same_seat_at_once_one_gets_it(pool, n):
    """NFR-03: exactly one success, every other call SEAT_TAKEN, no seat held twice."""
    async with pool.acquire() as c, c.transaction():
        fx = await make_fixture(c, C_PNR, C_FLIGHT, C_DEST, n)
    seat = fx["seats"]["5B"]

    async def choose(pnr):
        async with pool.acquire() as c:
            return await c.fetchrow(CALL4, pnr, fx["target"], "PYTEST", seat)

    results = await asyncio.gather(*(choose(p) for p in fx["pnrs"]))
    assert sum(r["success"] for r in results) == 1
    assert [r["message"] for r in results if not r["success"]] == [SEAT_TAKEN] * (n - 1)

    async with pool.acquire() as c:
        holders = await c.fetchval("SELECT count(*) FROM pnr_bookings WHERE assigned_seat_id = $1", seat)
        duplicates = await c.fetchval(
            """SELECT count(*) FROM (SELECT assigned_seat_id FROM pnr_bookings
                                     WHERE pnr_code LIKE $1 AND assigned_seat_id IS NOT NULL
                                     GROUP BY 1 HAVING count(*) > 1) d""",
            C_PNR + "%",
        )
        status = await c.fetchval("SELECT status::text FROM seats WHERE seat_id = $1", seat)
        audits = await c.fetchval("SELECT count(*) FROM audit_logs WHERE pnr_code LIKE $1", C_PNR + "%")
        unmoved = await c.fetchval(
            "SELECT count(*) FROM pnr_bookings WHERE pnr_code LIKE $1 AND booking_status = 'DISRUPTED'",
            C_PNR + "%",
        )
    assert (holders, duplicates, status) == (1, 0, "BOOKED")
    assert audits == n  # one row per call
    assert unmoved == n - 1


async def test_a_seat_locked_by_another_rebooking_is_refused_at_once(pool):
    """NOWAIT: while another transaction holds the seat's row lock the call
    answers SEAT_TAKEN immediately instead of waiting for it."""
    async with pool.acquire() as c, c.transaction():
        fx = await make_fixture(c, C_PNR, C_FLIGHT, C_DEST, 1)
    seat = fx["seats"]["5C"]
    async with pool.acquire() as holder, pool.acquire() as caller:
        lock = holder.transaction()
        await lock.start()
        try:
            await holder.execute("SELECT 1 FROM seats WHERE seat_id = $1 FOR UPDATE", seat)
            row = await asyncio.wait_for(
                caller.fetchrow(CALL4, fx["pnrs"][0], fx["target"], "PYTEST", seat), timeout=10
            )
        finally:
            await lock.rollback()
        assert row["success"] is False and row["message"] == SEAT_TAKEN
        assert await last_reason(caller, fx["pnrs"][0]) == "SEAT_TAKEN"
        assert (await booking_state(caller, fx["pnrs"][0]))["booking_status"] == "DISRUPTED"
