"""Voucher codes and issuing (issue #16), with the shared fake connection."""

import re

import asyncpg

from kestrel.api import booking
from tests.conftest import FakeConn
from tests.unit.test_endpoints import booking_row


def test_codes_have_four_letters():
    for kind in ("MEAL", "HOTEL", "TRANSPORT", "ASANTE_POINTS", "CASH_COMPENSATION"):
        assert re.fullmatch(r"KQ-[A-Z]{2}-\d{4}-[A-HJ-NP-Z]{4}", booking.voucher_code(kind))


async def test_a_clashing_code_is_retried_with_fresh_codes():
    """A clash rolls the transaction back; the passenger must still get
    their vouchers rather than `entitlements: null`."""
    upserts = []

    def upsert(code, *_):
        upserts.append(code)
        if len(upserts) == 1:
            raise asyncpg.UniqueViolationError("duplicate key value violates vouchers_voucher_code_key")
        return "INSERT 0 1"

    conn = FakeConn({
        "COALESCE(s.cabin_class::text": booking_row(),
        "INSERT INTO vouchers": upsert,
        "FROM vouchers WHERE pnr_code": [],
    })
    issued = await booking.issue_entitlements(conn, "S958PC", "PASSENGER:S958PC")
    assert issued is not None
    assert len(upserts) > 1 and len(set(upserts)) == len(upserts)  # new codes on the retry


async def test_a_code_that_keeps_clashing_is_an_error_after_three_tries():
    def clash(*_):
        raise asyncpg.UniqueViolationError("duplicate")

    conn = FakeConn({"COALESCE(s.cabin_class::text": booking_row(), "INSERT INTO vouchers": clash})
    try:
        await booking.issue_entitlements(conn, "S958PC", "PASSENGER:S958PC")
    except asyncpg.UniqueViolationError:
        pass
    else:
        raise AssertionError("expected UniqueViolationError")
    assert len(conn.called("INSERT INTO vouchers")) == booking.ISSUE_ATTEMPTS
