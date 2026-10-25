"""
Phase 3 of the performance plan: streamed replies, the booking briefing,
quick replies without the model, and speculative policy search.

A scripted model streams its replies in pieces (or asks for a tool) and the
REST tier is an httpx MockTransport, as in test_agent_loop.py; the agent
service is driven through FastAPI's TestClient.
"""

import json
import re

import httpx
import pytest
from fastapi.testclient import TestClient
from langchain_core.messages import AIMessageChunk, SystemMessage

from kestrel import agent, agent_service

TOKEN = "header.signature-not-real"
AUTH = {"Authorization": f"Bearer {TOKEN}"}

FLIGHT = {
    "flight_id": "real-flight-id",
    "flight_number": "KQ116",
    "origin": "NBO",
    "destination": "AMS",
    "departure_time": "2026-10-15T19:45:00+00:00",
    "arrival_time": "2026-10-16T04:10:00+00:00",
    "departure_local": "2026-10-15T22:45+03:00",
    "arrival_local": "2026-10-16T06:10+02:00",
    "cabin_class": "ECONOMY",
    "available_seats": 12,
}

TRIP = {
    "pnr_code": "S958PC",
    "booking": {
        "pnr_code": "S958PC",
        "booking_status": "DISRUPTED",
        "passenger": {"first_name": "Joseph", "last_name": "Whitehead", "rewards_tier": "GOLD"},
        "original_flight": {"flight_number": "KQ116", "origin": "NBO", "destination": "AMS",
                            "departure_local": "2026-10-14T22:45+03:00", "status": "CANCELLED",
                            "disruption_reason": "TECHNICAL"},
        "current_flight": None,
        "cabin_class": "ECONOMY",
    },
    "alternatives": [FLIGHT],
    "entitlements": {
        "decision": {
            "regulation": None,
            "entitlements": [{"entitlement_type": "MEAL", "label": "Meal voucher", "status": "ISSUED",
                              "rule_id": "R2_MEAL", "quantity": 1, "amount": 2500.0, "currency": "KES"}],
            "notes": ["Hotel accommodation is decided once you are rebooked."],
        },
        "vouchers": [],
    },
    "cases": [],
    "suggestions": [],
}  # fmt: skip


class RestTier:
    """The REST tier, mocked; records every request."""

    def __init__(self, policy_in_scope=True):
        self.policy_in_scope = policy_in_scope
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        assert request.headers["Authorization"] == f"Bearer {TOKEN}"
        path = request.url.path
        if path == "/api/trip":
            return httpx.Response(200, json=TRIP)
        if path == "/api/flights/alternatives":
            return httpx.Response(200, json={"pnr_code": "S958PC", "count": 1, "alternatives": [FLIGHT]})
        if path == "/api/reaccommodate":
            return httpx.Response(200, json={
                "success": True, "assigned_seat": "24A", "message": "ok",
                "booking": {"cabin_class": "ECONOMY", "current_flight": {"flight_number": "KQ116"}},
                "entitlements": {"vouchers": [], "decision": {"notes": []}},
            })  # fmt: skip
        if path == "/api/policy/search":
            return httpx.Response(200, json={
                "question": request.url.params["q"], "in_scope": self.policy_in_scope, "tau": 0.6,
                "top_similarity": 0.8,
                "hits": [{"clause_ref": "EU261 Art. 8", "similarity": 0.8, "content": "refund"}],
                "case": None if self.policy_in_scope else {"case_id": 3},
            })  # fmt: skip
        if path == "/api/entitlements":
            return httpx.Response(200, json={"pnr_code": "S958PC", **TRIP["entitlements"]})
        if path == "/api/handoff":
            body = json.loads(request.content)
            return httpx.Response(201, json={"case_id": 11, "trigger": body["trigger"]})
        return httpx.Response(404, json={"detail": "not found"})

    def paths(self):
        return [r.url.path for r in self.requests]


class StreamingLLM:
    """Streams each scripted text reply in word-sized pieces, or asks for a
    tool. Counts its calls; refuses invoke(), which a streamed turn must not
    use."""

    def __init__(self, script):
        self.script = list(script)
        self.calls = 0
        self.seen = []

    def stream(self, messages):
        self.calls += 1
        self.seen.append(list(messages))
        item = self.script.pop(0)
        if isinstance(item, Exception):
            raise item
        if isinstance(item, str):
            for piece in re.findall(r"\S+\s*", item):
                yield AIMessageChunk(content=piece)
            return
        name, args = item
        yield AIMessageChunk(
            content="",
            tool_call_chunks=[{"name": name, "args": json.dumps(args), "id": f"c{self.calls}", "index": 0}],
        )

    def invoke(self, messages):
        self.calls += 1
        self.seen.append(list(messages))
        raise AssertionError("expected a streamed call")


def _no_model():
    raise AssertionError("a quick reply must not call the model")


@pytest.fixture
def rest(monkeypatch, tmp_path):
    tier = RestTier()
    monkeypatch.setattr(agent, "http_client", httpx.Client(transport=httpx.MockTransport(tier)))
    monkeypatch.setattr(agent_service, "LOG_DIR", tmp_path)
    return tier


def _use(monkeypatch, llm):
    monkeypatch.setattr(agent, "get_llm", lambda: llm)
    return llm


def _sse(text: str) -> list[tuple[str, dict]]:
    events = []
    for block in text.strip().split("\n\n"):
        kind = re.search(r"^event: (.+)$", block, re.M).group(1)
        data = json.loads(re.search(r"^data: (.+)$", block, re.M).group(1))
        events.append((kind, data))
    return events


client = TestClient(agent_service.app)


def _stream(message, **extra):
    r = client.post("/api/chat/stream", json={"message": message, **extra}, headers=AUTH)
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/event-stream")
    assert r.headers["cache-control"] == "no-cache"
    assert r.headers["x-accel-buffering"] == "no"
    return _sse(r.text)


# -- streamed replies ------------------------------------------------------------


def test_stream_sends_status_then_event_then_deltas_then_done(rest, monkeypatch):
    _use(monkeypatch, StreamingLLM([
        ("find_alternative_flights_tool", {}),
        "KQ116 leaves at 22:45 and has 12 seats left.",
    ]))  # fmt: skip
    events = _stream("Find me a flight please")
    kinds = [k for k, _ in events]
    assert kinds[0] == "status" and events[0][1]["text"].startswith("Checking flights")
    assert kinds[1] == "event" and events[1][1]["type"] == "alternatives"
    assert set(kinds[2:-1]) == {"delta"} and len(kinds[2:-1]) > 1
    assert kinds[-1] == "done"


def test_deltas_join_to_the_final_reply(rest, monkeypatch):
    _use(monkeypatch, StreamingLLM([("get_entitlements_tool", {}), "You get one meal voucher of KES 2,500."]))
    events = _stream("Tell me about the meal")
    deltas = "".join(d["text"] for k, d in events if k == "delta")
    done = events[-1][1]
    assert deltas == done["reply"] == "You get one meal voucher of KES 2,500."
    t = done["timing"]
    assert 0 <= t["first_token_ms"] <= t["total_ms"]
    assert t["model_calls"] == 2
    assert done["suggestions"]  # next steps come with the reply


def test_quota_error_arrives_as_an_error_event(rest, monkeypatch):
    _use(monkeypatch, StreamingLLM([RuntimeError("429 RESOURCE_EXHAUSTED: quota exceeded")]))
    events = _stream("Hello")
    assert events[-1][0] == "error"
    assert events[-1][1]["status"] == 503
    assert "usage limit" in events[-1][1]["detail"]


def test_expired_session_is_401_before_the_stream_starts(monkeypatch):
    rest = httpx.MockTransport(lambda r: httpx.Response(401, json={"detail": "Token has expired."}))
    monkeypatch.setattr(agent, "http_client", httpx.Client(transport=rest))
    r = client.post("/api/chat/stream", json={"message": "hi"}, headers=AUTH)
    assert r.status_code == 401
    assert client.post("/api/chat/stream", json={"message": "hi"}).status_code == 401


# -- the booking briefing (CONTEXT) -------------------------------------------------


def test_options_are_answered_from_context_in_one_model_call(rest, monkeypatch):
    llm = _use(monkeypatch, StreamingLLM(["Your best option is KQ116 at 22:45, with 12 seats left."]))
    events = _stream("What are my options?")
    assert llm.calls == 1
    context = [m.content for m in llm.seen[0] if isinstance(m, SystemMessage)][1]
    assert context.startswith("CONTEXT")
    assert "flight_id=real-flight-id" in context
    # No tool ran, yet the flight cards come with the reply (from the same trip).
    assert [d["type"] for k, d in events if k == "event"] == ["alternatives"]
    assert "/api/flights/alternatives" not in rest.paths()


def test_rebooking_still_goes_through_the_tool_and_refreshes_the_briefing(rest, monkeypatch):
    _use(monkeypatch, StreamingLLM([
        ("reaccommodate_passenger_tool", {"target_flight_id": "real-flight-id"}),
        "Done: you're on KQ116, seat 24A.",
    ]))  # fmt: skip
    events = _stream("Book me on KQ116 please")
    assert "/api/reaccommodate" in rest.paths()
    assert "rebooked" in [d["type"] for k, d in events if k == "event"]
    # The trip has changed: the next turn fetches it again.
    client.post("/api/chat", json={"message": "x", "intent": "entitlements"}, headers=AUTH)
    assert rest.paths().count("/api/trip") == 2


def test_the_briefing_is_fetched_on_every_turn(rest, monkeypatch):
    """Issue #5: never cached, so a rebooking on the Confirm page is seen by
    the very next turn."""
    monkeypatch.setattr(agent, "get_llm", _no_model)
    for _ in range(3):
        r = client.post("/api/chat", json={"message": "x", "intent": "entitlements"}, headers=AUTH)
        assert r.status_code == 200
    assert rest.paths().count("/api/trip") == 3
    assert "/api/me" not in rest.paths()


def test_briefing_text_names_the_flights_with_their_ids_and_the_entitlements():
    text = agent.briefing_text(TRIP)
    assert "Joseph, GOLD tier" in text
    assert "KQ116 flight_id=real-flight-id departs Thu 15 Oct 22:45" in text
    assert "12 seats left" in text
    assert "Meal voucher 1 x KES 2,500 (ISSUED; R2_MEAL)" in text
    assert "Not applicable: Hotel accommodation is decided once you are rebooked." in text


# -- quick replies: no model -----------------------------------------------------------


@pytest.mark.parametrize(
    ("intent", "event", "words"),
    [
        ("alternatives", "alternatives", "KQ116 on Thu 15 Oct at 22:45 arrives first"),
        ("entitlements", "entitlements", "meal voucher (1 x KES 2,500)"),
        ("person", "handoff", "case #11"),
    ],
)
def test_a_quick_reply_runs_its_tool_with_no_model_call(rest, monkeypatch, intent, event, words):
    monkeypatch.setattr(agent, "get_llm", _no_model)
    events = _stream("Find me another flight", intent=intent)
    done = events[-1][1]
    assert words in done["reply"]
    assert done["timing"]["model_calls"] == 0
    assert [d["type"] for k, d in events if k == "event"] == [event]
    assert "".join(d["text"] for k, d in events if k == "delta") == done["reply"]


def test_typed_text_cannot_claim_an_unknown_intent(rest):
    r = client.post("/api/chat", json={"message": "x", "intent": "rebook"}, headers=AUTH)
    assert r.status_code == 422


# -- speculative policy search ------------------------------------------------------------


def _policy_calls(rest):
    return [r for r in rest.requests if r.url.path == "/api/policy/search"]


def test_speculative_policy_search_is_reused(rest, monkeypatch):
    _use(monkeypatch, StreamingLLM([
        ("search_policy_tool", {"question": "Can I get a refund instead?"}),
        "Yes, you can choose a refund [EU261 Art. 8].",
    ]))  # fmt: skip
    events = _stream("Can I get a refund instead?")
    calls = _policy_calls(rest)
    assert len(calls) == 1  # started with the first model call, used by the tool
    assert calls[0].url.params["handoff"] == "false"
    assert [d["type"] for k, d in events if k == "event"] == ["policy"]


def test_a_different_question_gets_its_own_search(rest, monkeypatch):
    _use(monkeypatch, StreamingLLM([
        ("search_policy_tool", {"question": "baggage allowance for animals in the cabin"}),
        "Pets may travel [KQ CoC Art. 8].",
    ]))  # fmt: skip
    _stream("Can I get a refund instead?")
    calls = _policy_calls(rest)
    assert len(calls) == 2
    # The speculative search runs in its own thread, so either may arrive first.
    assert {c.url.params["q"] for c in calls} == {
        "Can I get a refund instead?", "baggage allowance for animals in the cabin"}


def test_an_out_of_scope_speculation_is_not_reused_so_the_case_is_opened(rest, monkeypatch):
    rest.policy_in_scope = False
    _use(monkeypatch, StreamingLLM([
        ("search_policy_tool", {"question": "Can I get a refund instead?"}),
        "A member of staff will follow up.",
    ]))  # fmt: skip
    _stream("Can I get a refund instead?")
    calls = _policy_calls(rest)
    assert [c.url.params.get("handoff") for c in calls] == ["false", None]


def test_token_set_similarity():
    assert agent.token_set_similarity("Can I get a refund?", "can i get a REFUND") == 1.0
    assert agent.token_set_similarity("refund please", "hotel tonight") == 0.0
    assert agent.looks_like_rights_question("Am I owed compensation?")
    assert not agent.looks_like_rights_question("Hello")
