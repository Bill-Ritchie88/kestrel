"""
Agent tool-loop tests with a scripted model and a mocked REST tier
(Section 5.5.6: "the rebooking tool is never called with a flight ID that the
search tool did not return; the loop stops at five iterations").

No Gemini call and no HTTP leaves the process: the model is a list of
pre-written AIMessages and agent.http_client is replaced by an httpx client on
a MockTransport that plays the REST tier.
"""

import json

import httpx
import pytest
from langchain_core.messages import AIMessage

from kestrel import agent

TOKEN = "header.signature-not-real"

ALTERNATIVES = {
    "pnr_code": "S958PC",
    "count": 1,
    "alternatives": [
        {
            "flight_id": "real-flight-id",
            "flight_number": "KQ116",
            "departure_time": "2026-10-15T22:45:00+03:00",
            "arrival_time": "2026-10-16T06:10:00+02:00",
            "cabin_class": "ECONOMY",
            "available_seats": 12,
        }
    ],
}


class ScriptedLLM:
    """Returns the next scripted message; records what it was shown."""

    def __init__(self, script):
        self.script = list(script)
        self.seen = []

    def invoke(self, messages):
        self.seen.append(list(messages))
        return self.script.pop(0) if self.script else self.script_default()

    def script_default(self):
        return AIMessage(content="", tool_calls=[_call("get_entitlements_tool", {})])


_ids = iter(range(10_000))


def _call(name, args):
    return {"name": name, "args": args, "id": f"call-{next(_ids)}"}


class RestTier:
    """MockTransport handler that records every request."""

    def __init__(self, alternatives=ALTERNATIVES, policy_in_scope=True):
        self.alternatives = alternatives
        self.policy_in_scope = policy_in_scope
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        assert request.headers["Authorization"] == f"Bearer {TOKEN}"
        path = request.url.path
        if path == "/api/flights/alternatives":
            return httpx.Response(200, json=self.alternatives)
        if path == "/api/reaccommodate":
            fid = json.loads(request.content)["target_flight_id"]
            if fid != "real-flight-id":
                return httpx.Response(409, json={"detail": "Target flight does not exist."})
            return httpx.Response(200, json={
                "success": True, "assigned_seat": "24A", "message": "ok",
                "booking": {"current_flight": {"flight_number": "KQ116",
                                               "departure_time": "2026-10-15T22:45:00+03:00"}},
                "entitlements": {"vouchers": [{"entitlement_type": "MEAL", "status": "ISSUED"}]},
            })  # fmt: skip
        if path == "/api/policy/search":
            return httpx.Response(200, json={
                "in_scope": self.policy_in_scope, "tau": 0.75, "top_similarity": 0.8,
                "hits": [{"clause_ref": "EU261 Art. 9", "similarity": 0.8, "content": "meals"}],
                "case": None if self.policy_in_scope else {"case_id": 3},
            })  # fmt: skip
        if path == "/api/entitlements":
            return httpx.Response(200, json={"decision": {"entitlements": []}, "vouchers": []})
        if path == "/api/handoff":
            body = json.loads(request.content)
            return httpx.Response(201, json={"case_id": 11, "trigger": body["trigger"]})
        return httpx.Response(404, json={"detail": "not found"})

    def paths(self):
        return [r.url.path for r in self.requests]

    def handoff_triggers(self):
        return [json.loads(r.content)["trigger"] for r in self.requests if r.url.path == "/api/handoff"]


@pytest.fixture
def rest(monkeypatch):
    tier = RestTier()
    monkeypatch.setattr(agent, "http_client", httpx.Client(transport=httpx.MockTransport(tier)))
    agent.bind_token(TOKEN)
    return tier


def test_search_then_rebook_with_the_returned_flight_id(rest):
    llm = ScriptedLLM([
        AIMessage(content="", tool_calls=[_call("find_alternative_flights_tool", {})]),
        AIMessage(content="", tool_calls=[_call("reaccommodate_passenger_tool",
                                                {"target_flight_id": "real-flight-id"})]),
        AIMessage(content="You're on KQ116, seat 24A."),
    ])  # fmt: skip
    result = agent.run_agent("Rebook me on the next flight", llm=llm)
    assert result.reply == "You're on KQ116, seat 24A."
    assert rest.paths() == ["/api/flights/alternatives", "/api/reaccommodate"]
    assert [e["type"] for e in result.events] == ["alternatives", "rebooked"]
    assert result.steps == 3


def test_invented_flight_id_is_refused_by_the_rest_tier(rest):
    llm = ScriptedLLM([
        AIMessage(content="", tool_calls=[_call("reaccommodate_passenger_tool",
                                                {"target_flight_id": "made-up"})]),
        AIMessage(content="Sorry, that flight is not available."),
    ])  # fmt: skip
    result = agent.run_agent("Put me on any flight", llm=llm)
    tool_result = json.loads(result.tool_calls[0]["result"])
    assert tool_result["status"] == "FAILED"
    assert "does not exist" in tool_result["detail"]
    assert result.events[0]["type"] == "error"


def test_loop_stops_at_five_steps_and_hands_off(rest):
    llm = ScriptedLLM([])  # always asks for another tool call
    result = agent.run_agent("Keep checking my entitlements", llm=llm)
    assert result.stopped_at_limit is True
    assert result.steps == agent.MAX_TOOL_ITERATIONS
    assert rest.handoff_triggers() == ["STEP_LIMIT"]
    assert "case #11" in result.reply


def test_no_alternatives_opens_a_handoff_case(rest):
    rest.alternatives = {"pnr_code": "S958PC", "count": 0, "alternatives": []}
    llm = ScriptedLLM([
        AIMessage(content="", tool_calls=[_call("find_alternative_flights_tool", {})]),
        AIMessage(content="A colleague will contact you."),
    ])  # fmt: skip
    result = agent.run_agent("Rebook me", llm=llm)
    assert json.loads(result.tool_calls[0]["result"])["status"] == "NO_OPTIONS"
    assert rest.handoff_triggers() == ["NO_ALTERNATIVES"]


def test_out_of_scope_policy_question_is_not_answered_from_clauses(rest):
    rest.policy_in_scope = False
    llm = ScriptedLLM([
        AIMessage(content="", tool_calls=[_call("search_policy_tool", {"question": "pets?"})]),
        AIMessage(content="A member of staff will follow up."),
    ])  # fmt: skip
    result = agent.run_agent("Can I bring my dog?", llm=llm)
    out = json.loads(result.tool_calls[0]["result"])
    assert out["status"] == "OUT_OF_SCOPE"
    assert "clauses" not in out


def test_unknown_tool_is_reported_and_the_loop_continues(rest):
    llm = ScriptedLLM([
        AIMessage(content="", tool_calls=[_call("delete_booking_tool", {})]),
        AIMessage(content="I can't do that."),
    ])  # fmt: skip
    result = agent.run_agent("Delete my booking", llm=llm)
    assert "Unknown tool" in result.tool_calls[0]["result"]
    assert rest.requests == []


def test_session_token_never_reaches_the_model(rest):
    llm = ScriptedLLM([
        AIMessage(content="", tool_calls=[_call("find_alternative_flights_tool", {})]),
        AIMessage(content="Here are your options."),
    ])  # fmt: skip
    agent.run_agent("What are my options?", llm=llm)
    shown = " ".join(str(m.content) for batch in llm.seen for m in batch)
    assert TOKEN not in shown


def test_history_is_passed_to_the_model(rest):
    llm = ScriptedLLM([AIMessage(content="Yes, KQ116.")])
    agent.run_agent(
        "Which flight was that?",
        history=[{"role": "user", "content": "Rebook me"},
                 {"role": "assistant", "content": "Done: KQ116."}],
        llm=llm,
    )  # fmt: skip
    contents = [m.content for m in llm.seen[0]]
    assert contents[1:] == ["Rebook me", "Done: KQ116.", "Which flight was that?"]
