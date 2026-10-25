"""Frustration -> an earlier hand-off (Phase 4): the pure detector, and the
agent service's use of it (no model call for the hand-off)."""

import json

import httpx
import pytest
from fastapi.testclient import TestClient

from kestrel import agent, agent_service, frustration


def _user(text):
    return {"role": "user", "content": text}


def _assistant(text):
    return {"role": "assistant", "content": text}


# -- the detector ---------------------------------------------------------------


def test_a_calm_question_has_no_signal():
    assert frustration.signals("Can I get a refund instead?") == []
    assert frustration.assess("What are my options?").action == "none"


def test_the_same_question_again_is_a_signal():
    history = [_user("Can I get a refund instead?"), _assistant("Here is the policy...")]
    assert frustration.signals("can I get a REFUND instead", history) == ["asked the same question again"]


def test_only_the_last_two_questions_count_as_a_repeat():
    history = [_user("Can I get a refund?"), _user("Where is my hotel?"), _user("And meals?")]
    assert frustration.signals("Can I get a refund?", history) == []


def test_strong_negative_words_are_a_signal():
    assert frustration.signals("This is useless, a total waste of time") == ["used strong negative words"]


def test_shouting_is_a_signal():
    assert frustration.signals("WHERE IS MY FLIGHT") == ["wrote in capitals or with '!!!'"]
    assert frustration.signals("Where is my flight!!!") == ["wrote in capitals or with '!!!'"]
    assert frustration.signals("KQ886 NBO") == []  # short codes are not shouting


def test_first_signal_acknowledges_second_hands_over():
    first = frustration.assess("This is useless")
    assert first.action == "acknowledge"
    history = [_user("This is useless"), _assistant("I'm sorry...")]
    second = frustration.assess("WHY IS NOBODY HELPING ME", history)
    assert second.action == "handoff"
    assert "a second time in this conversation" in second.reasons


def test_saying_yes_to_the_offer_hands_over():
    history = [_user("This is useless"), _assistant(f"{frustration.ACKNOWLEDGE} ... {frustration.OFFER}")]
    assert frustration.assess("Yes please", history).action == "handoff"
    # "yes" to anything else is just "yes".
    assert frustration.assess("Yes please", [_assistant("Shall I book KQ116?")]).action == "none"


def test_choosing_a_flight_after_the_offer_is_not_a_handoff():
    """Issue #4: a reply that starts with yes/ok/please but names a flight
    accepts the flight, not the person."""
    offer_history = [_user("This is useless"), _assistant(f"{frustration.ACKNOWLEDGE} ... {frustration.OFFER}")]
    for message in ("yes the first one", "ok KQ116 please", "please book the first flight",
                    "Yes, KQ116 please", "ok the first one"):
        assert frustration.assess(message, offer_history).action != "handoff", message
    for message in ("yes", "Yes please", "ok, connect me", "yes please, thanks", "talk to a person please"):
        assert frustration.assess(message, offer_history).action == "handoff", message


def test_the_summary_says_why():
    a = frustration.Assessment("handoff", ["used strong negative words"])
    assert a.summary("This is useless").startswith("Passenger frustrated (used strong negative words)")


# -- in the agent service ---------------------------------------------------------

TOKEN = "header.signature-not-real"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
TRIP = {"pnr_code": "S958PC", "booking": {"booking_status": "DISRUPTED"}, "alternatives": [],
        "entitlements": {}, "cases": []}  # fmt: skip


class Rest:
    def __init__(self):
        self.requests = []

    def __call__(self, request):
        self.requests.append(request)
        path = request.url.path
        if path == "/api/trip":
            return httpx.Response(200, json=TRIP)
        if path == "/api/handoff":
            body = json.loads(request.content)
            return httpx.Response(201, json={"case_id": 21, "trigger": body["trigger"], "summary": body["summary"]})
        if path == "/api/chat/history":
            return httpx.Response(201, json={})
        return httpx.Response(404, json={"detail": "not found"})

    def handoffs(self):
        return [json.loads(r.content) for r in self.requests if r.url.path == "/api/handoff"]


class OneLineLLM:
    def __init__(self):
        self.calls = 0

    def invoke(self, messages):
        from langchain_core.messages import AIMessage

        self.calls += 1
        return AIMessage(content="Here is what I can do.")


@pytest.fixture
def rest(monkeypatch, tmp_path):
    tier = Rest()
    monkeypatch.setattr(agent, "http_client", httpx.Client(transport=httpx.MockTransport(tier)))
    monkeypatch.setattr(agent_service, "LOG_DIR", tmp_path)
    return tier


client = TestClient(agent_service.app)


def test_first_signal_says_sorry_answers_and_offers_a_person(rest, monkeypatch):
    llm = OneLineLLM()
    monkeypatch.setattr(agent, "get_llm", lambda: llm)
    body = client.post("/api/chat", json={"message": "This is useless"}, headers=AUTH).json()
    assert body["reply"].startswith(frustration.ACKNOWLEDGE)
    assert "Here is what I can do." in body["reply"]
    assert body["reply"].endswith(frustration.OFFER)
    assert body["suggestions"][0] == {"label": "Talk to a person", "intent": "person"}
    assert rest.handoffs() == []


def test_second_signal_opens_a_frustration_case_without_the_model(rest, monkeypatch):
    llm = OneLineLLM()
    monkeypatch.setattr(agent, "get_llm", lambda: llm)
    history = [_user("This is useless"), _assistant("Sorry...")]
    body = client.post(
        "/api/chat", json={"message": "STILL NOTHING WORKS", "history": history}, headers=AUTH
    ).json()
    assert llm.calls == 0
    [case] = rest.handoffs()
    assert case["trigger"] == "FRUSTRATION"
    assert "Passenger frustrated" in case["summary"]
    assert "case #21" in body["reply"]
    assert body["events"][0]["type"] == "handoff"


def test_accepting_the_offer_opens_the_case(rest, monkeypatch):
    monkeypatch.setattr(agent, "get_llm", lambda: OneLineLLM())
    history = [_user("This is useless"), _assistant(f"Sorry. {frustration.OFFER}")]
    client.post("/api/chat", json={"message": "yes", "history": history}, headers=AUTH)
    assert [c["trigger"] for c in rest.handoffs()] == ["FRUSTRATION"]


def test_a_repeated_quick_reply_is_not_frustration(rest, monkeypatch):
    monkeypatch.setattr(agent, "get_llm", lambda: OneLineLLM())
    rest_alt = {"pnr_code": "S958PC", "count": 0, "alternatives": []}
    original = rest.__call__

    def with_alternatives(request):
        if request.url.path == "/api/flights/alternatives":
            return httpx.Response(200, json=rest_alt)
        return original(request)

    monkeypatch.setattr(agent, "http_client", httpx.Client(transport=httpx.MockTransport(with_alternatives)))
    history = [_user("What am I entitled to?"), _assistant("...")]
    body = client.post(
        "/api/chat",
        json={"message": "What am I entitled to?", "intent": "entitlements", "history": history},
        headers=AUTH,
    ).json()
    assert not body["reply"].startswith(frustration.ACKNOWLEDGE)


def test_streamed_acknowledgement_still_joins_to_the_reply(rest, monkeypatch):
    from langchain_core.messages import AIMessageChunk

    class Streaming:
        def stream(self, messages):
            yield AIMessageChunk(content="Here is ")
            yield AIMessageChunk(content="what I can do.")

    monkeypatch.setattr(agent, "get_llm", lambda: Streaming())
    r = client.post("/api/chat/stream", json={"message": "This is useless"}, headers=AUTH)
    blocks = [b for b in r.text.strip().split("\n\n")]
    deltas = "".join(json.loads(b.split("data: ", 1)[1])["text"] for b in blocks if b.startswith("event: delta"))
    done = json.loads(blocks[-1].split("data: ", 1)[1])
    assert deltas == done["reply"]
    assert done["reply"].startswith(frustration.ACKNOWLEDGE)


def test_both_turns_are_saved_after_the_reply(rest, monkeypatch):
    monkeypatch.setattr(agent, "get_llm", lambda: OneLineLLM())
    client.post("/api/chat", json={"message": "Hello there"}, headers=AUTH)
    saved = [json.loads(r.content) for r in rest.requests if r.url.path == "/api/chat/history"]
    assert saved == [
        {"role": "user", "content": "Hello there"},
        {"role": "assistant", "content": "Here is what I can do."},
    ]
    assert all(r.headers["Authorization"] == f"Bearer {TOKEN}" for r in rest.requests)
    # Issue #12: only the assistant's turn carries the service's key.
    keys = [r.headers.get("X-Agent-Key") for r in rest.requests if r.url.path == "/api/chat/history"]
    assert keys == [None, agent_service.AGENT_HISTORY_KEY]


# -- review of 18 Oct ---------------------------------------------------------------


def test_repeating_a_short_reply_is_not_a_repeat():
    """Issue #7: "yes" twice is an answer twice, not the same question again."""
    history = [_user("yes"), _assistant("Book KQ101?")]
    assert frustration.signals("yes", history) == []
    assert frustration.signals("ok", [_user("ok"), _assistant("Done.")]) == []


def test_three_chip_taps_are_not_an_earlier_signal():
    """Issue #8: the refund chip is offered again after it is answered, and
    every tap is saved as a user message; the next mild complaint must get
    the apology first, not a case."""
    history = [
        _user("Show my flight options"), _assistant("Here are 3 flights..."),
        _user("Can I get a refund instead?"), _assistant("Under Art. 8 ..."),
        _user("Can I get a refund instead?"), _assistant("Under Art. 8 ..."),
    ]
    assert frustration.earlier_signal(history) is False
    assert frustration.assess("This is ridiculous", history).action == "acknowledge"
    # The chip tapped again is not "asked the same question again" either.
    assert frustration.signals("Can I get a refund instead?", history) == []


def test_a_typed_repeat_still_counts():
    history = [_user("Why has nobody answered my question about hotels?"), _assistant("...")]
    assert frustration.signals("why has nobody answered my question about hotels", history) == [
        "asked the same question again"
    ]


def test_a_second_signal_with_a_case_already_open_reminds_instead_of_a_new_case(rest, monkeypatch):
    """Issue #9: no duplicate FRUSTRATION case, and the passenger is told a
    person already has it."""
    llm = OneLineLLM()
    monkeypatch.setattr(agent, "get_llm", lambda: llm)
    monkeypatch.setitem(TRIP, "cases", [{"case_id": 21, "status": "OPEN", "trigger": "FRUSTRATION"}])
    history = [_user("This is useless"), _assistant("Sorry...")]
    body = client.post(
        "/api/chat", json={"message": "STILL NOTHING WORKS", "history": history}, headers=AUTH
    ).json()
    assert rest.handoffs() == []
    assert llm.calls == 0
    assert "case #21 is already with the Kenya Airways disruption desk" in body["reply"]
    assert "your last question" in body["reply"]


def test_hand_off_replies_say_only_what_staff_can_see():
    """Issue #14: the staff queue shows the booking, a summary and the last
    question - not the conversation."""
    reply = agent._person_reply({"status": "OK", "case_id": 5})
    assert "your booking and your last question" in reply
    assert "discussed" not in reply and "conversation" not in reply
