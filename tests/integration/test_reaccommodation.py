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
        LEFT JOIN seats cur ON cur.seat_id = b.assigned_seat_id
        WHERE b.booking_status = 'DISRUPTED'
          AND alt.status = 'SCHEDULED' AND alt.departure_time > now()
          AND EXISTS (SELECT 1 FROM seats s
                      WHERE s.flight_id = alt.flight_id AND s.status = 'AVAILABLE'
                        AND s.cabin_class = COALESCE(cur.cabin_class, 'ECONOMY'))
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


# ---------------------------------------------------------------------------
# Migration 004 (Sprint 2): cabin class, eligibility and audit completeness.
# ---------------------------------------------------------------------------


async def test_cabin_class_is_preserved(conn, disrupted):
    """Fix 5: the Sprint 1 end-to-end run put an economy passenger in 1A."""
    booking, target = disrupted
    cabin_before = await conn.fetchval(
        "SELECT COALESCE(cabin_class::text, 'ECONOMY') FROM seats WHERE seat_id = $1",
        booking["assigned_seat_id"],
    ) or "ECONOMY"
    row = await conn.fetchrow(
        "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3)",
        booking["pnr_code"], target, "PYTEST",
    )  # fmt: skip
    assert row["success"] is True
    cabin_after = await conn.fetchval(
        """SELECT s.cabin_class::text FROM pnr_bookings b
           JOIN seats s ON s.seat_id = b.assigned_seat_id WHERE b.pnr_code = $1""",
        booking["pnr_code"],
    )
    assert cabin_after == cabin_before


async def test_confirmed_booking_cannot_be_moved_for_free(conn, disrupted):
    _, target = disrupted
    pnr = await conn.fetchval(
        "SELECT pnr_code FROM pnr_bookings WHERE booking_status = 'CONFIRMED' LIMIT 1"
    )
    if pnr is None:
        pytest.skip("No confirmed booking in the dataset.")
    row = await conn.fetchrow(
        "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3)", pnr, target, "PYTEST"
    )
    assert row["success"] is False
    reason = await conn.fetchval(
        """SELECT details->>'reason' FROM audit_logs
           WHERE pnr_code = $1 ORDER BY timestamp DESC LIMIT 1""",
        pnr,
    )
    assert reason == "BOOKING_NOT_DISRUPTED"


async def test_cancelled_target_rejection_is_audited(conn, disrupted):
    """003 returned early without an audit row for a cancelled target."""
    booking, _ = disrupted
    # On the booking's own route: since migration 011 a cancelled flight on
    # another route is refused as DIFFERENT_ROUTE before its status is read.
    cancelled = await conn.fetchval(
        """SELECT flight_id FROM flights
           WHERE status = 'CANCELLED' AND origin = $1 AND destination = $2
           ORDER BY departure_time DESC LIMIT 1""",
        booking["origin"], booking["destination"],
    )  # fmt: skip
    await conn.fetchrow(
        "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3)",
        booking["pnr_code"], cancelled, "PYTEST",
    )  # fmt: skip
    reason = await conn.fetchval(
        """SELECT details->>'reason' FROM audit_logs
           WHERE pnr_code = $1 ORDER BY timestamp DESC LIMIT 1""",
        booking["pnr_code"],
    )
    assert reason in ("FLIGHT_NOT_SCHEDULED", "ALREADY_ON_TARGET_FLIGHT")


# ---------------------------------------------------------------------------
# Migration 011: the target flight must be on the booking's route.
# ---------------------------------------------------------------------------


async def test_flight_on_another_route_is_refused_and_audited(conn, disrupted):
    """Issue #2: a flight id from another route (visible in /api/me and the
    alternatives list) used to be accepted; only the AI prompt stood in the way."""
    booking, _ = disrupted
    other = await conn.fetchrow(
        """SELECT flight_id, origin, destination FROM flights
           WHERE status = 'SCHEDULED' AND departure_time > now()
             AND (origin, destination) <> ($1, $2)
             AND EXISTS (SELECT 1 FROM seats s WHERE s.flight_id = flights.flight_id
                         AND s.status = 'AVAILABLE')
           LIMIT 1""",
        booking["origin"], booking["destination"],
    )  # fmt: skip
    if other is None:
        pytest.skip("No scheduled flight on another route.")
    before = await conn.fetchrow(
        "SELECT booking_status, reaccommodated_flight_id, assigned_seat_id FROM pnr_bookings WHERE pnr_code = $1",
        booking["pnr_code"],
    )
    row = await conn.fetchrow(
        "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3)",
        booking["pnr_code"], other["flight_id"], "PYTEST",
    )  # fmt: skip
    assert row["success"] is False
    assert row["message"].startswith(f"Target flight flies {other['origin']} to {other['destination']}")
    reason = await conn.fetchval(
        """SELECT details->>'reason' FROM audit_logs
           WHERE pnr_code = $1 ORDER BY timestamp DESC LIMIT 1""",
        booking["pnr_code"],
    )
    assert reason == "DIFFERENT_ROUTE"
    after = await conn.fetchrow(
        "SELECT booking_status, reaccommodated_flight_id, assigned_seat_id FROM pnr_bookings WHERE pnr_code = $1",
        booking["pnr_code"],
    )
    assert after == before  # nothing moved


def test_the_api_recognises_the_procedures_route_message():
    """The message the API maps to X-Refusal-Reason: DIFFERENT_ROUTE is the
    one migration 011 writes."""
    from pathlib import Path

    from kestrel.api.main import refusal_reason

    sql = (Path(__file__).parents[2] / "db/migrations/011_rebooking_same_route.sql").read_text()
    assert "'Target flight flies %s to %s;" in sql
    assert refusal_reason("Target flight flies NBO to LHR; this booking ...") == "DIFFERENT_ROUTE"
