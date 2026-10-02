"""
Integration tests for reaccommodate_passenger_atomic.

Marked `integration`: skipped automatically when DATABASE_URL is unset, which
is what lets the same suite run in CI with no credentials.

Every test runs inside a transaction that is rolled back, so the suite can be
run against the demonstration database without disturbing it.

These cover the defects migration 003 corrected. Each one failed against the
baseline procedure in db/migrations/001_baseline_reaccommodate_passenger_atomic.sql.
"""

import os

import asyncpg
import pytest

pytestmark = pytest.mark.integration


@pytest.fixture
async def conn():
    connection = await asyncpg.connect(os.environ["DATABASE_URL"], statement_cache_size=0)
    transaction = connection.transaction()
    await transaction.start()
    try:
        yield connection
    finally:
        await transaction.rollback()
        await connection.close()


@pytest.fixture
async def disrupted(conn):
    """A disrupted booking plus an alternative flight that has free seats."""
    # Booking and alternative are chosen together: picking any disrupted
    # booking first can land on a route with no capacity left.
    booking = await conn.fetchrow("""
        SELECT b.pnr_code, b.assigned_seat_id, o.origin, o.destination,
               alt.flight_id AS target
        FROM pnr_bookings b
        JOIN flights o   ON o.flight_id = b.original_flight_id
        JOIN flights alt ON alt.origin = o.origin AND alt.destination = o.destination
        WHERE b.booking_status = 'DISRUPTED'
          AND alt.status = 'SCHEDULED' AND alt.departure_time > now()
          AND EXISTS (SELECT 1 FROM seats s
                      WHERE s.flight_id = alt.flight_id AND s.status = 'AVAILABLE')
        ORDER BY alt.departure_time
        LIMIT 1
    """)
    if booking is None:
        pytest.skip(
            "No disrupted passenger with an alternative flight; the demo data is "
            "stale. Run: python scripts/reset_demo.py"
        )
    target = booking["target"]

    return booking, target


async def test_reaccommodation_assigns_a_seat(conn, disrupted):
    booking, target = disrupted
    row = await conn.fetchrow(
        "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3)",
        booking["pnr_code"],
        target,
        "PYTEST",
    )
    assert row["success"] is True
    assert row["assigned_seat_number"]


async def test_repeat_call_is_refused(conn, disrupted):
    """Defect 3 in the baseline: a second call issued a second seat."""
    booking, target = disrupted
    await conn.fetchrow(
        "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3)",
        booking["pnr_code"],
        target,
        "PYTEST",
    )
    second = await conn.fetchrow(
        "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3)",
        booking["pnr_code"],
        target,
        "PYTEST",
    )
    assert second["success"] is False


async def test_previous_seat_is_released(conn, disrupted):
    """Defect 1 in the baseline: the old seat leaked, destroying capacity."""
    booking, target = disrupted
    old_seat = booking["assigned_seat_id"]
    if old_seat is None:
        pytest.skip("Booking held no seat, so there is nothing to release.")

    await conn.fetchrow(
        "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3)",
        booking["pnr_code"],
        target,
        "PYTEST",
    )
    status = await conn.fetchval("SELECT status::text FROM seats WHERE seat_id = $1", old_seat)
    assert status == "AVAILABLE"


async def test_unknown_pnr_is_rejected_and_audited(conn, disrupted):
    """Defect 4 in the baseline: failed attempts wrote no audit row."""
    _, target = disrupted
    before = await conn.fetchval("SELECT count(*) FROM audit_logs")

    row = await conn.fetchrow(
        "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3)",
        "ZZZZZZ",
        target,
        "PYTEST",
    )
    assert row["success"] is False

    after = await conn.fetchval("SELECT count(*) FROM audit_logs")
    assert after > before, "a rejected attempt must still be audited"


async def test_cancelled_target_flight_is_rejected(conn, disrupted):
    """Defect 2 in the baseline: the target flight was never validated."""
    booking, _ = disrupted
    cancelled = await conn.fetchval(
        "SELECT flight_id FROM flights WHERE status = 'CANCELLED' LIMIT 1"
    )
    if cancelled is None:
        pytest.skip("No cancelled flight in the dataset.")

    row = await conn.fetchrow(
        "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3)",
        booking["pnr_code"],
        cancelled,
        "PYTEST",
    )
    assert row["success"] is False


async def test_no_seat_is_held_by_two_bookings(conn):
    """NFR-03. A dataset-level invariant, not a procedure call."""
    duplicates = await conn.fetchval("""
        SELECT count(*) FROM (
            SELECT assigned_seat_id FROM pnr_bookings
            WHERE assigned_seat_id IS NOT NULL
            GROUP BY assigned_seat_id HAVING count(*) > 1
        ) d
    """)
    assert duplicates == 0
