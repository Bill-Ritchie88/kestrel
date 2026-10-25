"""
Integration tests for the Sprint 2 tables (migrations 005 and 006): vouchers,
hand-off cases and the policy store. Live database, always rolled back.
"""

import os

import asyncpg
import pytest

from kestrel.api.booking import issue_entitlements
from kestrel.handoff import SQL_RESOLVE, open_case

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
async def rebooked(conn):
    """A disrupted passenger moved onto an alternative in their own cabin."""
    row = await conn.fetchrow("""
        SELECT b.pnr_code, alt.flight_id AS target
        FROM pnr_bookings b
        JOIN flights o   ON o.flight_id = b.original_flight_id
        JOIN flights alt ON alt.origin = o.origin AND alt.destination = o.destination
        LEFT JOIN seats cur ON cur.seat_id = b.assigned_seat_id
        WHERE b.booking_status = 'DISRUPTED'
          AND alt.status = 'SCHEDULED' AND alt.departure_time > now()
          AND EXISTS (SELECT 1 FROM seats s WHERE s.flight_id = alt.flight_id
                        AND s.status = 'AVAILABLE'
                        AND s.cabin_class = COALESCE(cur.cabin_class, 'ECONOMY'))
        ORDER BY alt.departure_time LIMIT 1
    """)
    if row is None:
        pytest.skip("Demo data is stale. Run: python scripts/data/reset_demo.py")
    result = await conn.fetchrow(
        "SELECT * FROM reaccommodate_passenger_atomic($1, $2, 'PYTEST')", row["pnr_code"], row["target"]
    )
    assert result["success"] is True
    return row["pnr_code"]


async def test_entitlements_are_written_once_per_type(conn, rebooked):
    first = await issue_entitlements(conn, rebooked, "PYTEST")
    second = await issue_entitlements(conn, rebooked, "PYTEST")
    types_ = [v["entitlement_type"] for v in second["vouchers"]]
    assert len(types_) == len(set(types_)), "one voucher per entitlement type"
    assert {v["voucher_code"] for v in first["vouchers"]} == {
        v["voucher_code"] for v in second["vouchers"]
    }, "re-issuing must update vouchers, not create new codes"
    audited = await conn.fetchval(
        "SELECT count(*) FROM audit_logs WHERE pnr_code = $1 AND action = 'ENTITLEMENTS_ISSUED'",
        rebooked,
    )
    assert audited >= 2


async def test_handoff_case_round_trip(conn, rebooked):
    case = await open_case(
        conn, pnr_code=rebooked, trigger="PASSENGER_REQUEST", actor="PYTEST", summary="Wants a call"
    )
    again = await open_case(
        conn, pnr_code=rebooked, trigger="PASSENGER_REQUEST", actor="PYTEST", summary="Still waiting"
    )
    assert again["case_id"] == case["case_id"] and again["created"] is False
    resolved = await conn.fetchrow(SQL_RESOLVE, case["case_id"], "STAFF:pytest", "Called back")
    assert resolved["status"] == "RESOLVED"
    assert await conn.fetchrow(SQL_RESOLVE, case["case_id"], "STAFF:pytest", "again") is None


async def test_policy_store_returns_clauses_in_similarity_order(conn):
    count = await conn.fetchval("SELECT count(*) FROM policy_chunks")
    if not count:
        pytest.skip("Policy corpus not ingested. Run: python scripts/data/ingest_policies.py")
    probe = await conn.fetchval("SELECT embedding::text FROM policy_chunks LIMIT 1")
    rows = await conn.fetch("SELECT * FROM match_policy_chunks($1, 3)", probe)
    sims = [r["similarity"] for r in rows]
    assert sims == sorted(sims, reverse=True)
    assert sims[0] == pytest.approx(1.0, abs=1e-5)  # a clause matches itself
