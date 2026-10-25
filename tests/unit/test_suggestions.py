"""Suggested next steps (performance plan, Phases 2 and 4)."""

from kestrel.suggestions import CLIENT_INTENTS, SERVER_INTENTS, suggestions


def _labels(items):
    return [s["label"] for s in items]


def test_disrupted_passenger_is_offered_options_entitlements_and_the_refund_question():
    items = suggestions({"booking_status": "DISRUPTED"})
    assert [s.get("intent") for s in items] == ["alternatives", "entitlements", None]
    assert items[2]["message"] == "Can I get a refund instead?"


def test_rebooked_passenger_is_offered_vouchers_calendar_and_a_person():
    items = suggestions({"booking_status": "REACCOMMODATED"})
    assert [s["intent"] for s in items] == ["entitlements", "calendar", "person"]


def test_an_open_case_comes_first_and_replaces_talk_to_a_person():
    items = suggestions(
        {"booking_status": "REACCOMMODATED"}, [{"status": "OPEN"}, {"status": "RESOLVED"}]
    )
    assert items[0] == {"label": "Check my case", "intent": "case"}
    assert "person" not in [s.get("intent") for s in items]


def test_every_suggestion_is_a_known_intent_or_a_message():
    for status in ("DISRUPTED", "REACCOMMODATED", "CONFIRMED"):
        for case in ([], [{"status": "OPEN"}]):
            for s in suggestions({"booking_status": status}, case):
                assert s["label"]
                assert ("intent" in s) != ("message" in s)
                assert s.get("intent") in SERVER_INTENTS | CLIENT_INTENTS | {None}
            assert len(suggestions({"booking_status": status}, case)) <= 3


# -- after a turn (Phase 4) -------------------------------------------------------

from kestrel.suggestions import after_turn  # noqa: E402

TRIP = {"booking": {"booking_status": "DISRUPTED"}, "cases": []}


def test_after_showing_the_flights_they_are_not_offered_again():
    items = after_turn(TRIP, [{"type": "alternatives", "data": {}}])
    assert "alternatives" not in [s.get("intent") for s in items]
    assert len(items) == 3


def test_after_a_rebooking_the_next_steps_are_for_a_rebooked_passenger():
    items = after_turn(TRIP, [{"type": "rebooked", "data": {}}])
    assert [s.get("intent") for s in items][:2] == ["entitlements", "calendar"]


def test_after_a_hand_off_the_case_comes_first_and_no_second_person():
    items = after_turn(TRIP, [{"type": "handoff", "data": {"case_id": 3}}])
    assert items[0]["intent"] == "case"
    assert "person" not in [s.get("intent") for s in items]


def test_an_out_of_scope_policy_answer_counts_as_a_case():
    items = after_turn(TRIP, [{"type": "policy", "data": {"case": {"case_id": 4}}}])
    assert items[0]["intent"] == "case"


def test_a_policy_answer_counts_as_shown():
    """Issue #8: the refund question just answered is not offered again."""
    items = after_turn(TRIP, [{"type": "policy", "data": {"in_scope": True}}])
    assert "Can I get a refund instead?" not in [s.get("message") for s in items]
    assert len(items) == 3


def test_every_chip_label_is_a_quick_reply_label():
    from kestrel.suggestions import QUICK_REPLY_LABELS, suggestions

    for status in ("DISRUPTED", "REACCOMMODATED", "CONFIRMED"):
        for s in suggestions({"booking_status": status}, [{"status": "OPEN"}]) + suggestions(
            {"booking_status": status}
        ):
            assert s["label"] in QUICK_REPLY_LABELS
