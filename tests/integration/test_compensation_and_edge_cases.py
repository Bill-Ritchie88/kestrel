"""
Integration tests for migration 016: the claim states and their guard, the
audit trail, scheduled times kept on a delay, cancel-for-refund, and a second
disruption (the rebooked flight is cancelled too).

Every test runs on one connection inside a transaction that is always rolled
back, on synthetic rows only (PNRs starting with a digit, flights CM9.. between
the made-up airports CXA and CXB). With
KESTREL_PREVIEW_MIGRATION="db/migrations/015_connecting_flights.sql;db/migrations/016_compensation_and_edge_cases.sql"
(os.pathsep between them) both migrations run first inside it; without them,
and before 016 is applied, the tests skip.
"""

import os
from pathlib import Path

import asyncpg
import pytest

from kestrel.api.claims import (
    SQL_APPROVE,
    SQL_CANCEL_FOR_REFUND,
    SQL_INSERT_CLAIM,
    SQL_PAY,
    SQL_REJECT,
)

pytestmark = pytest.mark.integration

REBOOK = "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3, $4)"


@pytest.fixture
async def conn():
    if not os.getenv("DATABASE_URL"):
        pytest.skip("DATABASE_URL is not set")
    connection = await asyncpg.connect(os.environ["DATABASE_URL"], statement_cache_size=0)
    transaction = connection.transaction()
    await transaction.start()
    try:
        preview = os.getenv("KESTREL_PREVIEW_MIGRATION")
        if preview:
            await connection.execute("\n".join(Path(p).read_text(encoding="utf-8") for p in preview.split(os.pathsep)))
        if not await connection.fetchval("SELECT to_regclass('public.compensation_claims')"):
            pytest.skip("compensation_claims does not exist: apply or preview migrations 015 and 016")
        yield connection
    finally:
        await transaction.rollback()
        await connection.close()


@pytest.fixture
async def fx(conn):
    """f1, the booked flight (CXA-CXB in two days), and two later flights a1,
    a2 on the route. Seat 10A on f1 is the passenger's; 5A free on a1 and a2.
    Booking 7M0001, CONFIRMED."""
    ids = {}
    for key, hours in (("f1", 48), ("a1", 52), ("a2", 56)):
        ids[key] = await conn.fetchval(
            """INSERT INTO flights (flight_number, origin, destination, departure_time, arrival_time,
                                    status, aircraft_type, disruption_reason)
               VALUES ($1, 'CXA', 'CXB', now() + make_interval(hours => $2), now() + make_interval(hours => $2 + 2),
                       'SCHEDULED', '738', 'TECHNICAL') RETURNING flight_id""",
            f"CM9{key}", hours,
        )  # fmt: skip
    seats = {}
    for key, number, st in (("f1", "10A", "BOOKED"), ("a1", "5A", "AVAILABLE"), ("a2", "5A", "AVAILABLE")):
        seats[key] = await conn.fetchval(
            "INSERT INTO seats (flight_id, seat_number, cabin_class, status) "
            "VALUES ($1, $2, 'ECONOMY', $3::seat_status) RETURNING seat_id",
            ids[key], number, st,
        )  # fmt: skip
    pid = await conn.fetchval(
        """INSERT INTO passengers (first_name, last_name, email, phone_number)
           VALUES ('Claim', 'Test', 'claim+7m0001@example.invalid', '+0000000000') RETURNING passenger_id"""
    )
    await conn.execute(
        """INSERT INTO pnr_bookings (pnr_code, passenger_id, original_flight_id, assigned_seat_id, booking_status)
           VALUES ('7M0001', $1, $2, $3, 'CONFIRMED')""",
        pid, ids["f1"], seats["f1"],
    )  # fmt: skip
    return {**ids, "seats": seats, "pnr": "7M0001"}


async def claim(conn, pnr: str) -> int:
    row = await conn.fetchrow(SQL_INSERT_CLAIM, pnr, 300, "EUR", "R4_COMPENSATION", "EU261 Art. 7(1)", f"PASSENGER:{pnr}")
    return row["claim_id"]


async def audit(conn, pnr: str) -> list[tuple[str, str]]:
    rows = await conn.fetch("SELECT actor, action FROM audit_logs WHERE pnr_code = $1 ORDER BY log_id", pnr)
    return [(r["actor"], r["action"]) for r in rows]


async def actions(conn, pnr: str) -> set[str]:
    # audit_logs.timestamp is the transaction's time here, so compare as a set.
    return {a for _, a in await audit(conn, pnr)}


async def booking(conn, pnr: str):
    return await conn.fetchrow(
        "SELECT booking_status::text AS status, reaccommodated_flight_id, assigned_seat_id "
        "FROM pnr_bookings WHERE pnr_code = $1",
        pnr,
    )


async def refused(conn, sql: str, *args) -> str:
    """Runs sql in a savepoint and returns the error class name it raised."""
    try:
        async with conn.transaction():
            await conn.execute(sql, *args)
    except asyncpg.PostgresError as exc:
        return type(exc).__name__
    return "no error"


# -- B2: the claim states ---------------------------------------------------------


async def test_claimed_approved_paid_each_audited_with_its_actor(conn, fx):
    cid = await claim(conn, fx["pnr"])
    approved = await conn.fetchrow(SQL_APPROVE, cid, "STAFF:Asha")
    paid = await conn.fetchrow(SQL_PAY, cid, "STAFF:Ben", "BANK-0001")
    assert (approved["status"], paid["status"], paid["payout_reference"]) == ("APPROVED", "PAID", "BANK-0001")
    trail = await audit(conn, fx["pnr"])
    assert {("PASSENGER:7M0001", "COMPENSATION_CLAIMED"), ("STAFF:Asha", "CLAIM_APPROVED"),
            ("STAFF:Ben", "CLAIM_PAID")} <= set(trail)  # fmt: skip


async def test_a_rejection_needs_a_reason_and_is_audited(conn, fx):
    cid = await claim(conn, fx["pnr"])
    assert await refused(conn, SQL_REJECT, cid, "STAFF:Asha", " ") == "CheckViolationError"
    row = await conn.fetchrow(SQL_REJECT, cid, "STAFF:Asha", "Weather: extraordinary circumstances")
    assert (row["status"], row["reason"]) == ("REJECTED", "Weather: extraordinary circumstances")
    assert "CLAIM_REJECTED" in await actions(conn, fx["pnr"])


@pytest.mark.parametrize(
    ("setup", "to"),
    [
        ([], "PAID"),  # skipping APPROVED
        (["APPROVED"], "CLAIMED"),  # backwards
        (["APPROVED"], "REJECTED"),
        (["REJECTED"], "APPROVED"),
        (["APPROVED", "PAID"], "APPROVED"),
    ],
)
async def test_states_cannot_be_skipped_or_reversed(conn, fx, setup, to):
    cid = await claim(conn, fx["pnr"])
    for state in setup:
        await conn.execute(
            "UPDATE compensation_claims SET status = $2, decided_by = 'STAFF:A', reason = 'r', paid_by = 'STAFF:A', "
            "payout_reference = 'P-1' WHERE claim_id = $1",
            cid, state,
        )  # fmt: skip
    sql = (
        "UPDATE compensation_claims SET status = $2, decided_by = 'STAFF:A', reason = 'r', paid_by = 'STAFF:A', "
        "payout_reference = 'P-1' WHERE claim_id = $1"
    )
    assert await refused(conn, sql, cid, to) == "CheckViolationError"


async def test_the_rest_tier_updates_name_the_state_they_expect(conn, fx):
    cid = await claim(conn, fx["pnr"])
    assert await conn.fetchrow(SQL_PAY, cid, "STAFF:Asha", "BANK-1") is None  # not approved yet
    await conn.fetchrow(SQL_APPROVE, cid, "STAFF:Asha")
    assert await conn.fetchrow(SQL_APPROVE, cid, "STAFF:Asha") is None  # a second click
    assert await conn.fetchrow(SQL_REJECT, cid, "STAFF:Asha", "late") is None


async def test_a_claim_starts_claimed_and_only_staff_decide(conn, fx):
    insert = (
        "INSERT INTO compensation_claims (pnr_code, kind, status, rule_id, basis, claimed_by) "
        "VALUES ($1, 'COMPENSATION', 'APPROVED', 'R4', 'b', 'PASSENGER:x')"
    )
    assert await refused(conn, insert, fx["pnr"]) == "CheckViolationError"
    cid = await claim(conn, fx["pnr"])
    assert await refused(conn, SQL_APPROVE, cid, "PASSENGER:7M0001") == "CheckViolationError"
    amount = "UPDATE compensation_claims SET amount = 600 WHERE claim_id = $1"
    assert await refused(conn, amount, cid) == "CheckViolationError"


async def test_one_compensation_claim_per_booking(conn, fx):
    await claim(conn, fx["pnr"])
    again = await conn.fetchrow(SQL_INSERT_CLAIM, fx["pnr"], 300, "EUR", "R4", "b", "PASSENGER:7M0001")
    assert again is None


# -- B3.4: a delay keeps the scheduled times ----------------------------------------


async def test_a_delay_keeps_the_times_before_it(conn, fx):
    before = await conn.fetchrow("SELECT departure_time, arrival_time FROM flights WHERE flight_id = $1", fx["f1"])
    move = (
        "UPDATE flights SET status = 'DELAYED', departure_time = departure_time + interval '3 hours', "
        "arrival_time = arrival_time + interval '3 hours' WHERE flight_id = $1"
    )
    await conn.execute(move, fx["f1"])
    await conn.execute(move, fx["f1"])  # delayed again: still measured from the first schedule
    row = await conn.fetchrow(
        "SELECT departure_time - scheduled_departure_time AS late, scheduled_departure_time, scheduled_arrival_time, "
        "(SELECT booking_status::text FROM pnr_bookings WHERE pnr_code = $2) AS booking FROM flights WHERE flight_id = $1",
        fx["f1"], fx["pnr"],
    )  # fmt: skip
    assert (row["scheduled_departure_time"], row["scheduled_arrival_time"]) == tuple(before)
    assert row["late"].total_seconds() == 6 * 3600
    assert row["booking"] == "CONFIRMED"  # a delay is not a disruption: no free rebooking


# -- B3.2: cancel and request a refund ------------------------------------------------


async def delay(conn, flight, hours):
    await conn.execute(
        "UPDATE flights SET status = 'DELAYED', departure_time = departure_time + make_interval(hours => $2) "
        "WHERE flight_id = $1",
        flight, hours,
    )  # fmt: skip


async def test_refund_is_refused_for_an_on_time_or_short_delay(conn, fx):
    row = await conn.fetchrow(SQL_CANCEL_FOR_REFUND, fx["pnr"], "PASSENGER:7M0001", "basis")
    assert (row["success"], row["reason"]) == (False, "NOT_ELIGIBLE")
    await delay(conn, fx["f1"], 4)
    row = await conn.fetchrow(SQL_CANCEL_FOR_REFUND, fx["pnr"], "PASSENGER:7M0001", "basis")
    assert (row["success"], row["reason"]) == (False, "NOT_ELIGIBLE")
    assert (await booking(conn, fx["pnr"]))["status"] == "CONFIRMED"
    assert "REFUND_REJECTED" in await actions(conn, fx["pnr"])


async def test_refund_after_a_five_hour_delay_cancels_frees_the_seat_and_opens_a_claim(conn, fx):
    await delay(conn, fx["f1"], 5)
    row = await conn.fetchrow(SQL_CANCEL_FOR_REFUND, fx["pnr"], "PASSENGER:7M0001", "EU261 Art. 8(1)(a)")
    assert row["success"] is True
    assert (await booking(conn, fx["pnr"]))["status"] == "CANCELLED"
    assert await conn.fetchval("SELECT status::text FROM seats WHERE seat_id = $1", fx["seats"]["f1"]) == "AVAILABLE"
    refund = await conn.fetchrow("SELECT * FROM compensation_claims WHERE claim_id = $1", row["claim_id"])
    assert (refund["kind"], refund["status"], refund["basis"]) == ("REFUND", "CLAIMED", "EU261 Art. 8(1)(a)")
    assert {"BOOKING_CANCELLED", "REFUND_CLAIMED"} <= await actions(conn, fx["pnr"])
    again = await conn.fetchrow(SQL_CANCEL_FOR_REFUND, fx["pnr"], "PASSENGER:7M0001", "b")
    assert (again["success"], again["reason"]) == (False, "ALREADY_CANCELLED")
    # Staff process the refund like any claim.
    assert (await conn.fetchrow(SQL_APPROVE, row["claim_id"], "STAFF:Asha"))["status"] == "APPROVED"


async def test_refund_for_a_cancelled_flight_and_refusals_once_rebooked_or_departed(conn, fx):
    await conn.execute("UPDATE flights SET status = 'CANCELLED' WHERE flight_id = $1", fx["f1"])
    await conn.execute("UPDATE pnr_bookings SET booking_status = 'DISRUPTED' WHERE pnr_code = $1", fx["pnr"])
    rebooked = await conn.fetchrow(REBOOK, fx["pnr"], fx["a1"], "PYTEST", None)
    assert rebooked["success"] is True
    row = await conn.fetchrow(SQL_CANCEL_FOR_REFUND, fx["pnr"], "PASSENGER:7M0001", "b")
    assert (row["success"], row["reason"]) == (False, "ALREADY_REBOOKED")

    # A disrupted booking on a flight that has already left (a missed connection, say).
    await conn.execute(
        "UPDATE pnr_bookings SET booking_status = 'DISRUPTED', reaccommodated_flight_id = NULL WHERE pnr_code = $1",
        fx["pnr"],
    )
    await conn.execute(
        "UPDATE flights SET status = 'SCHEDULED', departure_time = now() - interval '1 hour' WHERE flight_id = $1",
        fx["f1"],
    )
    row = await conn.fetchrow(SQL_CANCEL_FOR_REFUND, fx["pnr"], "PASSENGER:7M0001", "b")
    assert (row["success"], row["reason"]) == (False, "FLIGHT_DEPARTED")

    await conn.execute("UPDATE flights SET status = 'CANCELLED' WHERE flight_id = $1", fx["f1"])
    row = await conn.fetchrow(SQL_CANCEL_FOR_REFUND, fx["pnr"], "PASSENGER:7M0001", "b")
    assert row["success"] is True  # a cancelled flight never leaves


# -- B3.3: a second disruption ----------------------------------------------------------


async def test_a_rebooked_flight_cancelled_too_disrupts_again_and_the_passenger_can_rebook(conn, fx):
    await conn.execute("UPDATE flights SET status = 'CANCELLED' WHERE flight_id = $1", fx["f1"])
    await conn.execute("UPDATE pnr_bookings SET booking_status = 'DISRUPTED' WHERE pnr_code = $1", fx["pnr"])
    assert (await conn.fetchrow(REBOOK, fx["pnr"], fx["a1"], "PYTEST", None))["success"] is True
    assert (await booking(conn, fx["pnr"]))["status"] == "REACCOMMODATED"

    await conn.execute("UPDATE flights SET status = 'CANCELLED' WHERE flight_id = $1", fx["a1"])
    assert (await booking(conn, fx["pnr"]))["status"] == "DISRUPTED"
    assert ("SYSTEM", "BOOKING_DISRUPTED_AGAIN") in await audit(conn, fx["pnr"])

    second = await conn.fetchrow(REBOOK, fx["pnr"], fx["a2"], "PYTEST", None)
    assert second["success"] is True
    after = await booking(conn, fx["pnr"])
    assert (after["status"], after["reaccommodated_flight_id"], after["assigned_seat_id"]) == (
        "REACCOMMODATED", fx["a2"], fx["seats"]["a2"],
    )  # fmt: skip
    # The seat on the cancelled flight went back.
    assert await conn.fetchval("SELECT status::text FROM seats WHERE seat_id = $1", fx["seats"]["a1"]) == "AVAILABLE"


async def test_a_delay_of_the_rebooked_flight_does_not_disrupt_again(conn, fx):
    await conn.execute("UPDATE flights SET status = 'CANCELLED' WHERE flight_id = $1", fx["f1"])
    await conn.execute("UPDATE pnr_bookings SET booking_status = 'DISRUPTED' WHERE pnr_code = $1", fx["pnr"])
    await conn.fetchrow(REBOOK, fx["pnr"], fx["a1"], "PYTEST", None)
    await delay(conn, fx["a1"], 2)
    assert (await booking(conn, fx["pnr"]))["status"] == "REACCOMMODATED"
