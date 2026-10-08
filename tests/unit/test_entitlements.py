"""
Unit tests for the deterministic entitlement engine (FR-04).

Each test pins one rule to the clause it implements, so a change to a rule
that breaks the Regulation fails here before it reaches a passenger.
"""

from datetime import datetime, timedelta, timezone

import pytest

from kestrel.entitlements import (
    PROJECT_POLICY,
    DisruptionContext,
    applicable_regulation,
    distance_band,
    evaluate,
    great_circle_km,
)

EAT = timezone(timedelta(hours=3))
DEP = datetime(2026, 10, 14, 23, 55, tzinfo=EAT)  # late-evening long-haul bank
ARR = DEP + timedelta(hours=8, minutes=30)


def ctx(origin="AMS", destination="NBO", reason="TECHNICAL", delay_h=None, **kw):
    new_dep = DEP + timedelta(hours=delay_h) if delay_h is not None else None
    new_arr = new_dep + (ARR - DEP) if new_dep else None
    defaults = {
        "pnr_code": "S958PC",
        "rewards_tier": "GOLD",
        "booking_status": "REACCOMMODATED" if new_dep else "DISRUPTED",
        "origin": origin,
        "destination": destination,
        "scheduled_departure": DEP,
        "scheduled_arrival": ARR,
        "disruption_reason": reason,
        "new_departure": new_dep,
        "new_arrival": new_arr,
        "now": DEP - timedelta(hours=3),
    }
    defaults.update(kw)
    return DisruptionContext(**defaults)


def types(decision):
    return {e.entitlement_type: e for e in decision.entitlements}


# -- reference data --------------------------------------------------------


def test_distance_bands_follow_article_7():
    assert distance_band(1500) == 0
    assert distance_band(1501) == 1
    assert distance_band(3500) == 1
    assert distance_band(3501) == 2


def test_long_haul_routes_are_in_the_top_band():
    assert distance_band(great_circle_km("NBO", "AMS")) == 2
    assert distance_band(great_circle_km("NBO", "MBA")) == 0


@pytest.mark.parametrize(
    ("origin", "expected"),
    [("AMS", "EU261"), ("CDG", "EU261"), ("LHR", "UK261"), ("NBO", None), ("JFK", None)],
)
def test_scope_is_departures_from_eu_or_uk_only(origin, expected):
    """Art. 3(1): Kenya Airways is not a Community carrier, so inbound EU
    flights are out of scope; only departures from the EU/UK are covered."""
    assert applicable_regulation(origin) == expected


# -- eligibility ------------------------------------------------------------


def test_confirmed_booking_gets_nothing():
    d = evaluate(ctx(booking_status="CONFIRMED"))
    assert d.entitlements == []
    assert "not affected" in d.notes[0]


def test_rerouting_is_always_offered_for_a_disrupted_booking():
    assert types(evaluate(ctx(origin="NBO", destination="AMS")))["REROUTING"].status == "INFO"


# -- care: meals, hotel, transport -------------------------------------------


def test_eu_departure_gets_meal_before_rebooking():
    """Art. 5(1)(b): care is owed on cancellation regardless of the wait."""
    meal = types(evaluate(ctx()))["MEAL"]
    assert meal.quantity == 1
    assert meal.currency == "EUR"
    assert "Art. 9(1)(a)" in meal.basis


def test_meals_scale_with_waiting_time_and_are_capped():
    assert types(evaluate(ctx(delay_h=7)))["MEAL"].quantity == 2  # 7 h -> 2 started 6-h blocks
    assert types(evaluate(ctx(delay_h=40)))["MEAL"].quantity == PROJECT_POLICY["max_meals"]


def test_meal_currency_follows_departure_region():
    assert types(evaluate(ctx(origin="NBO", destination="AMS", delay_h=5)))["MEAL"].currency == "KES"
    assert types(evaluate(ctx(origin="LHR", destination="NBO", delay_h=5)))["MEAL"].currency == "GBP"


def test_short_wait_outside_regulation_gets_no_meal():
    d = evaluate(ctx(origin="NBO", destination="MBA", delay_h=1))
    assert "MEAL" not in types(d)
    assert any("threshold" in n for n in d.notes)


def test_next_day_departure_gets_hotel_and_transfer():
    """Art. 5(1)(b) with Art. 9(1)(b),(c)."""
    t = types(evaluate(ctx(delay_h=23)))
    assert t["HOTEL"].quantity == 1
    assert t["TRANSPORT"].quantity == 1
    assert "Art. 9(1)(b)" in t["HOTEL"].basis


def test_slip_just_past_midnight_gets_no_hotel():
    """23:55 moved to 01:00 is a later calendar day but no overnight stay."""
    d = evaluate(ctx(delay_h=1.1))
    assert "HOTEL" not in types(d)


def test_hotel_waits_until_rebooked():
    d = evaluate(ctx())
    assert "HOTEL" not in types(d)
    assert any("once you are rebooked" in n for n in d.notes)


# -- cash compensation (Art. 7) ----------------------------------------------


def test_long_haul_controllable_cancellation_pays_600_eur():
    comp = types(evaluate(ctx(delay_h=23)))["CASH_COMPENSATION"]
    assert comp.amount == 600.0
    assert comp.currency == "EUR"
    assert comp.status == "ELIGIBLE"


def test_uk_departure_pays_in_pounds():
    comp = types(evaluate(ctx(origin="LHR", delay_h=23)))["CASH_COMPENSATION"]
    assert (comp.amount, comp.currency) == (520.0, "GBP")


def test_weather_is_extraordinary_so_no_compensation():
    """Art. 5(3)."""
    d = evaluate(ctx(reason="WEATHER", delay_h=23))
    assert "CASH_COMPENSATION" not in types(d)
    assert any("Art. 5(3)" in n for n in d.notes)


def test_unknown_reason_is_left_to_staff():
    d = evaluate(ctx(reason=None, delay_h=23))
    assert "CASH_COMPENSATION" not in types(d)
    assert any("member of staff" in n for n in d.notes)


def test_no_compensation_outside_the_regulation():
    d = evaluate(ctx(origin="NBO", destination="AMS", delay_h=23))
    assert "CASH_COMPENSATION" not in types(d)
    assert any("Art. 3(1)" in n for n in d.notes)


def test_fourteen_days_notice_removes_compensation():
    """Art. 5(1)(c)(i)."""
    d = evaluate(ctx(delay_h=23, notified_at=DEP - timedelta(days=15)))
    assert "CASH_COMPENSATION" not in types(d)


def test_close_rerouting_with_short_notice_removes_compensation():
    """Art. 5(1)(c)(iii): under 7 days' notice, new flight leaves <=1 h early
    and arrives <2 h late."""
    d = evaluate(ctx(delay_h=1.5))
    assert "CASH_COMPENSATION" not in types(d)


def test_arrival_within_four_hours_halves_long_haul_compensation():
    """Art. 7(2)(c). Notified 3 days out and arriving 3 h late: not exempt under
    Art. 5(1)(c)(iii) (needs <2 h), but within 4 h, so EUR 600 is halved."""
    early = ctx(
        delay_h=3,
        notified_at=DEP - timedelta(days=3),
    )
    comp = types(evaluate(early))["CASH_COMPENSATION"]
    assert comp.amount == 300.0
    assert "Art. 7(2)" in comp.basis


# -- goodwill points (project policy) ----------------------------------------


@pytest.mark.parametrize(("tier", "points"), [("BLUE", 1000), ("GOLD", 3000), ("PLATINUM", 5000)])
def test_goodwill_points_scale_with_tier(tier, points):
    assert types(evaluate(ctx(rewards_tier=tier)))["ASANTE_POINTS"].points == points


def test_no_goodwill_points_for_extraordinary_causes():
    assert "ASANTE_POINTS" not in types(evaluate(ctx(reason="ATC")))


def test_project_assumptions_are_labelled_as_such():
    """Values Kenya Airways does not publish must say so in their basis."""
    t = types(evaluate(ctx(delay_h=23)))
    assert "assumption" in t["ASANTE_POINTS"].basis
    assert "assumption" in t["MEAL"].basis


def test_evaluation_is_deterministic():
    c = ctx(delay_h=23)
    assert evaluate(c).to_dict() == evaluate(c).to_dict()


def test_local_time_uses_the_airports_zone():
    """First end-to-end run: a 13:21 UTC Nairobi departure was reported as
    13:21; the passenger's clock says 16:21."""
    from kestrel.entitlements import local_iso

    utc = datetime(2026, 10, 11, 13, 21, tzinfo=timezone.utc)
    assert local_iso(utc, "NBO") == "2026-10-11T16:21+03:00"
    assert local_iso(utc, "AMS") == "2026-10-11T15:21+02:00"  # CEST
    assert local_iso(None, "NBO") is None
