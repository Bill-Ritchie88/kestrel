"""Why this flight (Phase 4): reasons and badges, a pure function."""

from datetime import UTC, datetime, timedelta

from kestrel.api.explain import ALMOST_FULL_SEATS, explain_alternatives

# 10:00 Nairobi time (UTC+3) on 15 Oct, NBO-AMS, cancelled for a technical
# reason (within the airline's control).
ORIGINAL = datetime(2026, 10, 15, 7, 0, tzinfo=UTC)


def _booking(**over):
    row = {
        "pnr_code": "S958PC",
        "booking_status": "DISRUPTED",
        "asante_rewards_tier": "GOLD",
        "origin": "NBO",
        "destination": "AMS",
        "original_departure": ORIGINAL,
        "original_arrival": ORIGINAL + timedelta(hours=9),
        "disruption_reason": "TECHNICAL",
        "current_departure": None,
        "current_arrival": None,
    }
    row.update(over)
    return row


def _alt(number, dep_hours, seats, flight_id=None):
    dep = ORIGINAL + timedelta(hours=dep_hours)
    return {
        "flight_id": flight_id or f"f-{number}-{dep_hours}",
        "flight_number": number,
        "origin": "NBO",
        "destination": "AMS",
        "available_seats": seats,
        "cabin_class": "ECONOMY",
        "_departure": dep,
        "_arrival": dep + timedelta(hours=9),
    }


def _by_id(out):
    return {a["flight_id"]: a for a in out}


def test_badges_follow_the_order_seats_and_the_rules():
    out = _by_id(explain_alternatives(
        [_alt("KQ116", 5, 3, "same-day"), _alt("KQ116", 24, 40, "next-day"), _alt("KQ118", 30, 12, "later")],
        _booking(),
    ))  # fmt: skip
    assert out["same-day"]["badges"] == ["EARLIEST_ARRIVAL", "SAME_DAY", "ALMOST_FULL"]
    assert out["next-day"]["badges"] == ["NEXT_DAY_HOTEL", "MOST_SEATS"]
    assert out["later"]["badges"] == ["NEXT_DAY_HOTEL"]
    assert out["same-day"]["wait_hours"] == 5.0
    assert out["next-day"]["wait_hours"] == 24.0


def test_reasons_are_plain_sentences_with_local_times():
    [first] = explain_alternatives([_alt("KQ116", 5, 3)], _booking())
    assert first["reasons"][0] == "Gets you to Amsterdam first: arrives Thu 15 Oct at 23:00."
    assert "Leaves the same day as your original flight, 5 hours later." in first["reasons"]
    assert "Only 3 seats left in your cabin: choose soon if you want it." in first["reasons"]
    assert 3 <= ALMOST_FULL_SEATS


def test_a_next_day_flight_includes_what_the_rules_give_with_it():
    [nxt] = explain_alternatives([_alt("KQ116", 24, 40)], _booking())
    kinds = {e["entitlement_type"] for e in nxt["includes"]}
    assert {"MEAL", "HOTEL", "TRANSPORT", "ASANTE_POINTS"} <= kinds
    assert any("hotel night" in r for r in nxt["reasons"])


def test_a_short_wait_after_midnight_gets_no_hotel_badge():
    # 23:00 local on the 15th -> 00:30 local on the 16th: a later day, but
    # the rules want a 6-hour wait for a hotel.
    booking = _booking(original_departure=datetime(2026, 10, 15, 20, 0, tzinfo=UTC))
    alt = _alt("KQ116", 0, 20)
    alt["_departure"] = datetime(2026, 10, 15, 21, 30, tzinfo=UTC)
    [out] = explain_alternatives([alt], booking)
    assert "NEXT_DAY_HOTEL" not in out["badges"]
    assert "SAME_DAY" not in out["badges"]


def test_no_most_seats_badge_on_a_tie_or_for_a_single_flight():
    tie = explain_alternatives([_alt("A", 5, 10), _alt("B", 6, 10)], _booking())
    assert all("MOST_SEATS" not in a["badges"] for a in tie)
    [single] = explain_alternatives([_alt("A", 5, 40)], _booking())
    assert "MOST_SEATS" not in single["badges"]


def test_private_fields_are_dropped_and_nothing_is_decided_here():
    out = explain_alternatives([_alt("KQ116", 5, 3)], _booking())
    assert not any(k.startswith("_") for k in out[0])
    assert explain_alternatives([], _booking()) == []


def test_an_earlier_flight_says_before_not_minus():
    """Issue #25: "-12 hours after your original flight"."""
    # Two days before the original's local date: not the same day, no hotel.
    [early] = explain_alternatives([_alt("KQ114", -48, 30)], _booking())
    text = " ".join(early["reasons"])
    assert "48 hours before your original flight" in text
    assert "-48" not in text


def test_city_names_and_the_date_format_have_one_copy_each():
    """Issues #34 and #38."""
    from kestrel import agent
    from kestrel.airports import CITIES, city
    from kestrel.api import explain
    from kestrel.entitlements import when_text

    assert explain._city is city and city("MBA") == "Mombasa" and city("XYZ") == "XYZ"
    assert agent._when is when_text
    assert when_text("2026-10-19T05:26+03:00") == "Mon 19 Oct at 05:26"
    assert len(CITIES) >= 29
