"""
Connecting journeys through NBO (migration 015), without a database:
missed-connection detection, journey options and their ranking, delay
measured at the final destination, and the REST endpoints for a journey.
"""

from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from kestrel.api import auth, db, main
from kestrel.api.auth import issue_token
from kestrel.api.booking import booking_to_dict, context_from_booking
from kestrel.api.journeys import MIN_CONNECTION, build_journeys, connection_broken, leg_statuses
from kestrel.entitlements import evaluate
from tests.conftest import FakeConn, FakePool

T0 = datetime(2026, 12, 1, 6, 0, tzinfo=UTC)
H = timedelta(hours=1)
FIRST_ID = "11111111-1111-4111-8111-111111111111"
ONWARD_ID = "22222222-2222-4222-8222-222222222222"


# -- Missed connection ------------------------------------------------------


@pytest.mark.parametrize(
    ("first", "arrival_late", "onward", "broken"),
    [
        ("SCHEDULED", timedelta(0), "SCHEDULED", False),
        ("CANCELLED", timedelta(0), "SCHEDULED", True),
        ("SCHEDULED", timedelta(0), "CANCELLED", True),
        # Lands 06:00, onward leaves 07:30: 90 minutes at the hub.
        ("DELAYED", timedelta(minutes=30), "SCHEDULED", False),  # exactly the MCT is enough
        ("DELAYED", timedelta(minutes=31), "SCHEDULED", True),
    ],
)
def test_a_connection_is_broken_by_a_cancelled_leg_or_too_little_time(first, arrival_late, onward, broken):
    assert MIN_CONNECTION == timedelta(minutes=60)
    assert connection_broken(first, T0 + arrival_late, onward, T0 + 1.5 * H) is broken


def test_each_leg_gets_the_status_my_trip_shows():
    assert leg_statuses("CANCELLED", T0, "SCHEDULED", T0 + 3 * H) == ("CANCELLED", "MISSED_CONNECTION")
    assert leg_statuses("DELAYED", T0 + 2.5 * H, "SCHEDULED", T0 + 3 * H) == ("DELAYED", "MISSED_CONNECTION")
    assert leg_statuses("SCHEDULED", T0, "CANCELLED", T0 + 3 * H) == ("SCHEDULED", "CANCELLED")
    assert leg_statuses("DELAYED", T0 + H, "SCHEDULED", T0 + 3 * H) == ("DELAYED", "SCHEDULED")


# -- Journey options --------------------------------------------------------


def leg(fid, leg_no, dep_h, arr_h, seats=10, kept=False, number=None):
    return {
        "flight_id": fid,
        "flight_number": number or f"KQ{fid}",
        "origin": "MBA" if leg_no == 1 else "NBO",
        "destination": "NBO" if leg_no == 1 else "EBB",
        "departure_time": T0 + dep_h * H,
        "arrival_time": T0 + arr_h * H,
        "aircraft_type": "738",
        "cabin_class": "ECONOMY",
        "leg": leg_no,
        "kept": kept,
        "available_seats": seats,
    }


def ids(options):
    return [(o["flight_id"], o["onward"]["flight_id"]) for o in options]


def test_options_reach_the_final_destination_earliest_first():
    rows = [
        leg("a1", 1, 0, 1),
        leg("a2", 1, 3, 4),
        leg("b1", 2, 1.5, 3),  # 30 minutes after a1 lands: too short
        leg("b2", 2, 2, 4),  # exactly 60 after a1
        leg("b3", 2, 6, 7),
    ]
    options = build_journeys(rows, 5)
    assert ids(options) == [("a1", "b2"), ("a2", "b3")]
    assert options[0]["final_destination"] == "EBB"
    assert options[0]["connection_minutes"] == 60
    assert options[0]["final_arrival_time"] == (T0 + 4 * H).isoformat()


def test_the_onward_flight_is_kept_when_a_new_first_leg_still_connects():
    rows = [leg("a1", 1, 0, 1), leg("cur2", 2, 5, 6, kept=True), leg("b2", 2, 2, 4)]
    # b2 arrives earlier, so both are offered; keeping the onward flight is one of them.
    assert ids(build_journeys(rows, 5)) == [("a1", "b2"), ("a1", "cur2")]
    rows = [leg("a1", 1, 0, 1), leg("cur2", 2, 5, 6, kept=True), leg("b9", 2, 8, 9)]
    assert ids(build_journeys(rows, 5)) == [("a1", "cur2")]  # a later new onward adds nothing


def test_a_good_first_leg_is_kept_and_the_current_journey_is_never_offered():
    rows = [leg("cur1", 1, 0, 1, kept=True), leg("cur2", 2, 1.5, 3, kept=True), leg("b2", 2, 4, 5)]
    options = build_journeys(rows, 5)
    assert ids(options) == [("cur1", "b2")]
    assert options[0]["kept"] is True and options[0]["onward"]["kept"] is False
    assert options[0]["available_seats"] == 10  # only the new leg's seats count


def test_a_full_new_leg_is_not_an_option():
    rows = [leg("a1", 1, 0, 1, seats=0), leg("a2", 1, 1, 2), leg("b2", 2, 3, 4, seats=0), leg("b3", 2, 5, 6)]
    assert ids(build_journeys(rows, 5)) == [("a2", "b3")]


def test_the_limit_applies_after_ranking():
    rows = [leg(f"a{i}", 1, i, i + 1) for i in range(5)] + [leg("b", 2, 10, 11), leg("bb", 2, 3, 4)]
    assert ids(build_journeys(rows, 2)) == [("a0", "bb"), ("a1", "bb")]


# -- The booking and its entitlements ---------------------------------------


def journey_row(**overrides):
    """CDG -> NBO (leg 1, cancelled) -> MBA. Leg 1 was to land 06:00, the
    onward flight leaves 14:00 and lands 15:00."""
    row = {
        "pnr_code": "7J0001",
        "booking_status": "DISRUPTED",
        "first_name": "Conn",
        "last_name": "Test",
        "asante_rewards_tier": "BLUE",
        "original_flight_id": "f1",
        "original_flight_number": "KQ113",
        "origin": "CDG",
        "destination": "NBO",
        "original_departure": T0 - 8 * H,
        "original_arrival": T0,
        "original_status": "CANCELLED",
        "disruption_reason": "TECHNICAL",
        "original_aircraft": "788",
        "cancelled_at": T0 - 30 * H,
        "current_flight_id": None,
        "current_flight_number": None,
        "current_departure": None,
        "current_arrival": None,
        "seat_number": "30A",
        "cabin_class": "ECONOMY",
        "onward_flight_id": "f2",
        "onward_flight_number": "KQ602",
        "onward_origin": "NBO",
        "onward_destination": "MBA",
        "onward_departure": T0 + 8 * H,
        "onward_arrival": T0 + 9 * H,
        "onward_status": "SCHEDULED",
        "onward_disruption_reason": None,
        "onward_aircraft": "E190",
        "onward_cancelled_at": None,
        "current_onward_flight_id": None,
        "current_onward_flight_number": None,
        "current_onward_departure": None,
        "current_onward_arrival": None,
        "onward_seat_number": "12C",
    }
    row.update(overrides)
    return row


def test_the_booking_shows_both_legs_and_the_missed_connection():
    body = booking_to_dict(journey_row())
    assert [(lg["flight_number"], lg["leg_status"]) for lg in body["legs"]] == [
        ("KQ113", "CANCELLED"),
        ("KQ602", "MISSED_CONNECTION"),
    ]
    assert body["final_destination"] == "MBA"
    assert body["onward_flight"]["origin"] == "NBO" and body["onward_seat_number"] == "12C"


def test_a_single_flight_booking_has_no_legs():
    row = {k: v for k, v in journey_row().items() if not k.startswith(("onward", "current_onward"))}
    body = booking_to_dict(row)
    assert body["legs"] == [] and body["onward_flight"] is None and body["final_destination"] == "NBO"


@pytest.mark.parametrize(("final_late_h", "cash"), [(0, None), (3, 300.0)])
def test_compensation_is_judged_on_the_journey_and_the_arrival_at_the_final_destination(final_late_h, cash):
    """Leg 1 lands 6.5 hours late at NBO either way; what counts is the
    arrival in Mombasa. On time there, with under 7 days' notice, Art.
    5(1)(c)(iii) exempts the airline; 3 hours late, Art. 7(2) halves the
    CDG-MBA (over 3,500 km) amount. Measured at NBO it would be EUR 600."""
    rebooked = journey_row(
        booking_status="REACCOMMODATED",
        current_flight_id="a1",
        current_departure=T0 - 1.5 * H,
        current_arrival=T0 + 6.5 * H,
        current_onward_flight_id="b2",
        current_onward_departure=T0 + (8 + final_late_h) * H,
        current_onward_arrival=T0 + (9 + final_late_h) * H,
    )
    ctx = context_from_booking(rebooked, now=T0 - 40 * H)
    assert (ctx.origin, ctx.destination, ctx.new_arrival) == ("CDG", "MBA", T0 + (9 + final_late_h) * H)
    decision = evaluate(ctx)
    assert decision.regulation == "EU261" and decision.distance_km > 3500
    amounts = [e.amount for e in decision.entitlements if e.entitlement_type == "CASH_COMPENSATION"]
    assert amounts == ([cash] if cash else [])


def test_when_only_the_onward_leg_is_cancelled_its_cause_counts():
    row = journey_row(original_status="SCHEDULED", disruption_reason=None, cancelled_at=None,
                      onward_status="CANCELLED", onward_disruption_reason="WEATHER")  # fmt: skip
    ctx = context_from_booking(row, now=T0 - 40 * H)
    assert ctx.disruption_reason == "WEATHER"


# -- Endpoints --------------------------------------------------------------

LEGS = [
    {**leg(FIRST_ID, 1, 0, 1), "flight_number": "KQ601"},
    {**leg(ONWARD_ID, 2, 2.5, 4), "flight_number": "KQ412"},
]


@pytest.fixture
def conn():
    row = journey_row(origin="MBA", onward_destination="EBB", original_departure=T0 - 2 * H,
                      original_arrival=T0 - H, onward_departure=T0 - 0.5 * H, onward_arrival=T0 + H)  # fmt: skip
    return FakeConn({
        "COALESCE(s.cabin_class::text": row,
        "SELECT onward_flight_id FROM pnr_bookings": {"onward_flight_id": "f2"},
        "AS kept,": LEGS,
    })  # fmt: skip


@pytest.fixture
def client(conn):
    main.app.dependency_overrides[db.get_pool] = lambda: FakePool(conn)
    auth._used_confirmations.clear()
    yield TestClient(main.app)
    main.app.dependency_overrides.clear()


@pytest.fixture
def token():
    t, _ = issue_token(pnr_code="7J0001", passenger_id="p-1", last_name="Test", rewards_tier="BLUE")
    return {"Authorization": f"Bearer {t}"}


def test_the_trip_offers_journeys_and_shows_the_legs(client, token):
    body = client.get("/api/trip", headers=token).json()
    assert [lg["leg_status"] for lg in body["booking"]["legs"]] == ["CANCELLED", "MISSED_CONNECTION"]
    (option,) = body["alternatives"]
    assert (option["flight_number"], option["onward"]["flight_number"]) == ("KQ601", "KQ412")
    assert option["final_destination"] == "EBB" and "EARLIEST_ARRIVAL" in option["badges"]
    assert not any(k.startswith("_") for k in option)
    assert any("90 minutes to connect" in r for r in option["reasons"])


def test_a_journey_proposal_binds_both_legs(client, conn, token):
    seat = "33333333-3333-4333-8333-333333333333"
    r = client.post("/api/reaccommodate/proposal", headers=token,
                    json={"target_flight_id": FIRST_ID, "onward_flight_id": ONWARD_ID, "onward_seat_id": seat})  # fmt: skip
    assert r.status_code == 200
    body = r.json()
    assert body["flight"]["onward"]["flight_id"] == ONWARD_ID and body["onward_seat_id"] == seat
    conn.routes["reaccommodate_journey_atomic"] = {
        "success": True, "assigned_seat_number": "5A", "onward_seat_number": "7C", "message": "ok"}  # fmt: skip
    base = {"target_flight_id": FIRST_ID, "onward_flight_id": ONWARD_ID,
            "confirmation_token": body["confirmation_token"]}  # fmt: skip
    agent = {**token, "X-Agent-Key": "x"}
    # The token is for this onward seat only.
    wrong = client.post("/api/reaccommodate", headers=agent, json=base)
    assert wrong.status_code == 403 and "seat choice" in wrong.json()["detail"]
    ok = client.post("/api/reaccommodate", headers=agent, json={**base, "onward_seat_id": seat})
    assert ok.status_code == 200
    assert (ok.json()["assigned_seat"], ok.json()["onward_seat"]) == ("5A", "7C")
    (call,) = conn.called("reaccommodate_journey_atomic")
    assert [str(a) for a in call[:3]] == ["7J0001", FIRST_ID, ONWARD_ID]


def test_a_journey_that_is_not_an_option_is_404(client, token):
    r = client.post("/api/reaccommodate/proposal", headers=token,
                    json={"target_flight_id": ONWARD_ID, "onward_flight_id": FIRST_ID})  # fmt: skip
    assert r.status_code == 404


def test_a_connecting_booking_never_moves_one_leg_alone(client, conn, token):
    r = client.post("/api/reaccommodate", headers=token, json={"target_flight_id": FIRST_ID})
    assert r.status_code == 409 and r.headers["X-Refusal-Reason"] == "JOURNEY_REQUIRED"
    assert not conn.called("reaccommodate_passenger_atomic")
    # Nor does the assistant get a one-leg proposal.
    assert client.post("/api/reaccommodate/proposal", headers=token,
                       json={"target_flight_id": FIRST_ID}).status_code == 404  # fmt: skip


def test_a_short_connection_refusal_is_named(client, conn, token):
    conn.routes["reaccommodate_journey_atomic"] = {
        "success": False, "assigned_seat_number": None, "onward_seat_number": None,
        "message": "Connection too short: the onward flight must leave at least 01:00:00 after the first one lands."}  # fmt: skip
    r = client.post("/api/reaccommodate", headers=token,
                    json={"target_flight_id": FIRST_ID, "onward_flight_id": ONWARD_ID})  # fmt: skip
    assert r.status_code == 409 and r.headers["X-Refusal-Reason"] == "CONNECTION_TOO_SHORT"
