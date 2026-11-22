"""
Unit tests for migration 016's rules and endpoints, with no database:
delay entitlements (B3.4), the refund option and a refunded booking (B3.2),
the stranded passenger's hotel and automatic hand-off (B3.1), a second
disruption (B3.3), and the compensation claim workflow (B2).
"""

from datetime import timedelta

import pytest
from fastapi.testclient import TestClient

from kestrel.api import auth, db, main
from kestrel.api.auth import issue_token
from kestrel.api.booking import context_from_booking, delay_minutes, refundable
from kestrel.entitlements import evaluate
from tests.conftest import FakeConn, FakePool
from tests.unit.test_endpoints import NOW, booking_row
from tests.unit.test_entitlements import ctx, types

# -- B3.4 delays (AMS-NBO: EU261, over 3,500 km, so care from 4 hours) ------------


def delayed(hours, arrival_hours=None, **kw):
    """ctx() as a DELAYED flight: the booking stays CONFIRMED and keeps its seat."""
    c = ctx(delay_h=hours, booking_status="CONFIRMED", flight_status="DELAYED", **kw)
    if arrival_hours is not None:
        from dataclasses import replace

        c = replace(c, new_arrival=c.scheduled_arrival + timedelta(hours=arrival_hours))
    return c


def test_a_short_delay_gives_no_care_and_never_a_free_rebooking():
    d = evaluate(delayed(1))
    assert types(d) == {}
    assert any("not offered for a delay" in n for n in d.notes)
    assert any("4-hour threshold" in n for n in d.notes)


def test_care_from_the_distance_threshold_and_compensation_from_three_hours_late():
    t = types(evaluate(delayed(4.5)))
    assert set(t) == {"MEAL", "CASH_COMPENSATION"}
    assert t["MEAL"].basis.startswith("EU261 Art. 6(1)(c), Art. 9(1)(a)")
    assert (t["CASH_COMPENSATION"].amount, t["CASH_COMPENSATION"].currency) == (600, "EUR")
    assert "Sturgeon" in t["CASH_COMPENSATION"].basis
    assert "REROUTING" not in t


def test_long_haul_between_three_and_four_hours_late_is_halved():
    t = types(evaluate(delayed(3.5)))
    assert "MEAL" not in t  # below the 4-hour care threshold for this distance
    assert t["CASH_COMPENSATION"].amount == 300


def test_a_long_overnight_delay_gives_a_hotel_and_the_refund_option():
    t = types(evaluate(delayed(6)))  # 23:55 to 05:55 the next day
    assert {"MEAL", "HOTEL", "TRANSPORT", "REFUND", "CASH_COMPENSATION"} <= set(t)
    assert t["REFUND"].basis == "EU261 Art. 6(1)(c)(iii), Art. 8(1)(a)"
    assert t["REFUND"].status == "INFO"


def test_outside_the_regulation_the_project_threshold_applies_and_no_cash():
    d = evaluate(delayed(2, origin="NBO", destination="MBA"))
    assert set(types(d)) == {"MEAL"}
    assert any("Art. 3(1)" in n for n in d.notes)


def test_extraordinary_delays_give_care_but_no_cash():
    t = types(evaluate(delayed(5, reason="WEATHER")))
    assert "CASH_COMPENSATION" not in t and {"MEAL", "REFUND"} <= set(t)


def test_a_delay_whose_length_is_unknown_says_so():
    d = evaluate(ctx(booking_status="CONFIRMED", flight_status="DELAYED"))
    assert types(d) == {} and any("not recorded" in n for n in d.notes)


# -- B3.2 the refund option, and a refunded booking ----------------------------------


def test_a_disrupted_booking_may_take_a_refund_until_rebooked():
    assert types(evaluate(ctx()))["REFUND"].basis == "EU261 Art. 5(1)(a), Art. 8(1)(a)"
    assert "REFUND" not in types(evaluate(ctx(delay_h=20)))


def test_a_refunded_cancellation_keeps_compensation_but_no_care():
    t = types(evaluate(ctx(booking_status="CANCELLED", flight_status="CANCELLED")))
    assert set(t) == {"CASH_COMPENSATION", "ASANTE_POINTS"}
    assert t["CASH_COMPENSATION"].amount == 600


def test_a_cancelled_booking_on_a_flight_that_flew_is_not_affected():
    assert types(evaluate(ctx(booking_status="CANCELLED", flight_status="SCHEDULED"))) == {}


# -- B3.1 no seats left: a hotel for a stranded passenger ------------------------------


def test_no_alternatives_close_to_departure_gives_one_hotel_night():
    t = types(evaluate(ctx(no_alternatives=True)))
    assert (t["HOTEL"].quantity, "TRANSPORT" in t) == (1, True)
    assert "no other flight has a seat" in t["HOTEL"].explanation


def test_no_alternatives_days_ahead_gives_no_hotel_yet():
    far = ctx(no_alternatives=True, now=ctx().scheduled_departure - timedelta(days=3))
    assert "HOTEL" not in types(evaluate(far))


# -- booking rows: delay, refund button, second disruption -------------------------------


def delayed_row(hours, **kw):
    dep = NOW + timedelta(hours=10)
    return booking_row(
        booking_status="CONFIRMED", original_status="DELAYED",
        original_departure=dep + timedelta(hours=hours), original_arrival=dep + timedelta(hours=8 + hours),
        original_scheduled_departure=dep, original_scheduled_arrival=dep + timedelta(hours=8), **kw,
    )  # fmt: skip


def test_a_delayed_row_is_measured_against_its_schedule():
    row = delayed_row(6)
    assert delay_minutes(row) == 360
    c = context_from_booking(row)
    assert (c.flight_status, c.new_departure - c.scheduled_departure) == ("DELAYED", timedelta(hours=6))
    assert "MEAL" in types(evaluate(c))


@pytest.mark.parametrize(
    ("row", "expected"),
    [
        (booking_row(), True),  # disrupted
        (booking_row(booking_status="REACCOMMODATED", current_flight_id="f", current_departure=NOW), False),
        (delayed_row(4), False),
        (delayed_row(5), True),
        (booking_row(booking_status="CONFIRMED", original_status="SCHEDULED"), False),
        (booking_row(original_status="SCHEDULED", original_departure=NOW - timedelta(hours=1)), False),  # left
    ],
)
def test_the_refund_button_follows_the_procedure_rule(row, expected):
    assert refundable(row) is expected


def test_a_second_disruption_no_longer_counts_the_cancelled_new_flight():
    row = booking_row(
        booking_status="DISRUPTED", current_flight_id="f-new",
        current_departure=NOW + timedelta(hours=30), current_arrival=NOW + timedelta(hours=38),
    )  # fmt: skip
    c = context_from_booking(row)
    assert c.new_departure is None
    assert "REROUTING" in types(evaluate(c))


# -- endpoints ----------------------------------------------------------------------------

CLAIM_ROW = {
    "claim_id": 7, "pnr_code": "S958PC", "kind": "COMPENSATION", "status": "CLAIMED", "amount": 600,
    "currency": "EUR", "rule_id": "R4_COMPENSATION", "basis": "EU261 Art. 5(1)(c), Art. 7(1)",
    "claimed_by": "PASSENGER:S958PC", "decided_by": None, "reason": None, "paid_by": None,
    "payout_reference": None, "created_at": NOW, "decided_at": None, "paid_at": None,
}  # fmt: skip

REBOOKED = booking_row(
    booking_status="REACCOMMODATED", current_flight_id="f-alt", current_flight_number="KQ117",
    current_departure=NOW + timedelta(hours=27), current_arrival=NOW + timedelta(hours=35),
)  # fmt: skip


@pytest.fixture
def conn():
    return FakeConn({"COALESCE(s.cabin_class::text": booking_row()})


@pytest.fixture
def client(conn, monkeypatch):
    monkeypatch.setattr(main, "STAFF_API_KEY", "staff-secret")
    main.app.dependency_overrides[db.get_pool] = lambda: FakePool(conn)
    auth._failed_attempts.clear()
    yield TestClient(main.app)
    main.app.dependency_overrides.clear()


@pytest.fixture
def token():
    t, _ = issue_token(pnr_code="S958PC", passenger_id="p-1", last_name="Whitehead", rewards_tier="GOLD")
    return {"Authorization": f"Bearer {t}"}


STAFF = {"X-Staff-Key": "staff-secret"}


def test_a_claim_takes_its_amount_and_rule_from_the_rules(client, conn, token):
    conn.routes["COALESCE(s.cabin_class::text"] = REBOOKED
    conn.routes["INSERT INTO compensation_claims"] = lambda *a: {**CLAIM_ROW, "amount": a[1]}
    r = client.post("/api/compensation/claim", headers=token)
    assert r.status_code == 201
    [args] = conn.called("INSERT INTO compensation_claims")
    assert args == ("S958PC", 600.0, "EUR", "R4_COMPENSATION", "EU261 Art. 5(1)(c), Art. 7(1)", "PASSENGER:S958PC")
    assert (r.json()["status"], r.json()["amount"]) == ("CLAIMED", 600.0)


@pytest.mark.parametrize(
    ("row", "insert", "reason"),
    [
        (booking_row(), CLAIM_ROW, "CHOOSE_FLIGHT_FIRST"),  # the amount depends on the new flight
        ({**REBOOKED, "disruption_reason": "WEATHER"}, CLAIM_ROW, "NO_COMPENSATION"),  # R4 gives nothing
        (REBOOKED, None, "ALREADY_CLAIMED"),
    ],
)
def test_a_claim_is_refused_when_the_rules_give_nothing_or_it_exists(client, conn, token, row, insert, reason):
    conn.routes["COALESCE(s.cabin_class::text"] = row
    conn.routes["INSERT INTO compensation_claims"] = insert
    r = client.post("/api/compensation/claim", headers=token)
    assert (r.status_code, r.headers.get("X-Refusal-Reason")) == (409, reason)
    if reason == "NO_COMPENSATION":
        assert "extraordinary" in r.json()["detail"]
        assert not conn.called("INSERT INTO compensation_claims")


def test_cancel_for_refund_passes_the_rules_basis_and_maps_refusals(client, conn, token):
    conn.routes["cancel_booking_for_refund"] = {"success": False, "reason": "ALREADY_REBOOKED", "message": "Rebooked."}
    r = client.post("/api/booking/cancel", headers=token)
    assert (r.status_code, r.headers["X-Refusal-Reason"], r.json()["detail"]) == (409, "ALREADY_REBOOKED", "Rebooked.")
    [args] = conn.called("cancel_booking_for_refund")
    assert args == ("S958PC", "PASSENGER:S958PC", "EU261 Art. 5(1)(a), Art. 8(1)(a)")


def test_cancel_for_refund_returns_the_refund_claim(client, conn, token):
    conn.routes["cancel_booking_for_refund"] = {"success": True, "reason": None, "message": "Cancelled.", "claim_id": 9}
    conn.routes["FROM compensation_claims WHERE pnr_code"] = [{**CLAIM_ROW, "claim_id": 9, "kind": "REFUND"}]
    r = client.post("/api/booking/cancel", headers=token)
    assert r.status_code == 200
    assert (r.json()["claim_id"], r.json()["claims"][0]["kind"]) == (9, "REFUND")


def test_staff_claim_endpoints_need_the_staff_key_not_a_passenger_token(client, token):
    for method, path, body in (
        ("get", "/api/staff/claims", None),
        ("post", "/api/staff/claims/7/approve", {"by": "Asha"}),
        ("post", "/api/staff/claims/7/pay", {"by": "Asha", "payout_reference": "P-1"}),
    ):
        r = client.request(method.upper(), path, json=body, headers=token)
        assert r.status_code == 401, path  # a passenger cannot approve their own claim


def test_staff_approve_reject_and_pay(client, conn):
    conn.routes["SET status = 'APPROVED'"] = lambda cid, by: {**CLAIM_ROW, "status": "APPROVED", "decided_by": by}
    conn.routes["SET status = 'REJECTED'"] = lambda cid, by, why: {**CLAIM_ROW, "status": "REJECTED", "reason": why}
    conn.routes["SET status = 'PAID'"] = lambda cid, by, ref: {**CLAIM_ROW, "status": "PAID", "payout_reference": ref}
    r = client.post("/api/staff/claims/7/approve", json={"by": "Asha"}, headers=STAFF)
    assert (r.status_code, r.json()["decided_by"]) == (200, "STAFF:Asha")
    r = client.post("/api/staff/claims/7/reject", json={"by": "Asha", "reason": "Weather"}, headers=STAFF)
    assert r.json()["reason"] == "Weather"
    r = client.post("/api/staff/claims/7/pay", json={"by": "Asha", "payout_reference": "BANK-1"}, headers=STAFF)
    assert r.json()["payout_reference"] == "BANK-1"


def test_staff_reject_needs_a_reason_and_pay_a_reference(client):
    assert client.post("/api/staff/claims/7/reject", json={"by": "Asha"}, headers=STAFF).status_code == 422
    assert client.post("/api/staff/claims/7/pay", json={"by": "Asha"}, headers=STAFF).status_code == 422


@pytest.mark.parametrize(("current", "code"), [("PAID", 409), ("REJECTED", 409), (None, 404)])
def test_a_stale_or_unknown_claim_changes_nothing(client, conn, current, code):
    conn.routes["SELECT status FROM compensation_claims"] = current
    r = client.post("/api/staff/claims/7/approve", json={"by": "Asha"}, headers=STAFF)
    assert r.status_code == code
    if code == 409:
        assert r.headers["X-Refusal-Reason"] == "INVALID_TRANSITION"
        assert current.lower() in r.json()["detail"]


def test_the_staff_list_filters_by_status(client, conn):
    conn.routes["FROM compensation_claims c"] = [{**CLAIM_ROW, "first_name": "J", "last_name": "W", "booking_status": "X"}]
    r = client.get("/api/staff/claims?status=CLAIMED", headers=STAFF)
    assert r.json()["claims"][0]["passenger"] == {"first_name": "J", "last_name": "W"}
    assert conn.called("FROM compensation_claims c")[0] == ("CLAIMED", 200)


# -- B3.1 the trip opens a case once when no flight has a seat ------------------------------

CASE_ROW = {
    "case_id": 3, "pnr_code": "S958PC", "trigger": "NO_ALTERNATIVES", "booking_status": "DISRUPTED",
    "question": None, "top_similarity": None, "similarity_scores": None, "summary": "No seat.",
    "status": "OPEN", "created_at": NOW, "resolved_at": None, "resolved_by": None, "resolution_note": None,
}  # fmt: skip


def test_no_seats_left_opens_a_case_and_grants_the_hotel(client, conn, token):
    conn.routes["INSERT INTO handoff_cases"] = CASE_ROW
    body = client.get("/api/trip", headers=token).json()
    assert body["alternatives"] == []
    assert [c["trigger"] for c in body["cases"]] == ["NO_ALTERNATIVES"]
    [audit] = conn.called("INSERT INTO audit_logs (pnr_code, actor, action, details)\n    VALUES ($1, $2, $3")
    assert audit[1:3] == ("SYSTEM", "HANDOFF_OPENED")
    assert conn.called("INSERT INTO vouchers"), "the hotel voucher is issued now"
    kinds = {e["entitlement_type"] for e in body["entitlements"]["decision"]["entitlements"]}
    assert {"HOTEL", "TRANSPORT"} <= kinds


def test_an_open_case_is_not_opened_again(client, conn, token):
    conn.routes["handoff_cases WHERE pnr_code = $1 ORDER BY"] = [CASE_ROW]
    body = client.get("/api/trip", headers=token).json()
    assert not conn.called("INSERT INTO handoff_cases")
    assert "HOTEL" in {e["entitlement_type"] for e in body["entitlements"]["decision"]["entitlements"]}


def test_a_trip_with_seats_left_opens_no_case(client, conn, token):
    from tests.unit.test_endpoints import ALTERNATIVE

    conn.routes["WITH bk AS"] = [ALTERNATIVE]
    client.get("/api/trip", headers=token)
    assert not conn.called("INSERT INTO handoff_cases")


def test_the_trip_carries_the_claims(client, conn, token):
    conn.routes["FROM compensation_claims WHERE pnr_code"] = [CLAIM_ROW]
    assert client.get("/api/trip", headers=token).json()["claims"][0]["status"] == "CLAIMED"


