"""
Project Kestrel - AI Agent Tier.

The agent holds no database credentials and cannot write to the database. It
can only call the REST tier, and only while carrying a session token that the
passenger obtained by authenticating. This is the boundary that keeps a
nondeterministic language model from mutating transactional state directly.

Sprint 2 adds three tools (policy search, entitlements, hand-off), passes the
conversation history into the model, and returns structured events alongside
the reply so the Flutter client can render flight, citation and voucher cards
from the same data the model saw. The model is created lazily and can be
injected, so the tool loop is unit-tested with a scripted model
(tests/unit/test_agent_loop.py).
"""

from __future__ import annotations

import argparse
import json
import os
import time
from contextvars import ContextVar
from dataclasses import dataclass, field

import httpx
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage, ToolMessage
from langchain_core.tools import tool

from kestrel import config  # noqa: F401  - loads .env before anything reads it

FASTAPI_BASE_URL = os.getenv("FASTAPI_BASE_URL", "http://127.0.0.1:8000")
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-flash-latest")
# Gemini 3 models reason before answering; at the default depth each step of a
# tool loop took several seconds. Routing a disrupted passenger needs little
# reasoning - the rules live in code - so "low" is the default. Set
# GEMINI_THINKING_LEVEL to minimal/low/medium/high, or to "" for the model's
# own default.
GEMINI_THINKING_LEVEL = os.getenv("GEMINI_THINKING_LEVEL", "low") or None
MAX_TOOL_ITERATIONS = 5
MAX_HISTORY_TURNS = 10

http_client = httpx.Client(timeout=10.0)

# The session token lives in a context variable rather than a tool argument.
# If it were an argument, the language model would be able to invent one.
_session_token: ContextVar[str | None] = ContextVar("session_token", default=None)
# Structured results of the tool calls made during the current turn.
_events: ContextVar[list | None] = ContextVar("events", default=None)


def _auth_headers() -> dict[str, str]:
    token = _session_token.get()
    if not token:
        raise RuntimeError("No authenticated session. Call authenticate() first.")
    return {"Authorization": f"Bearer {token}"}


def _emit(kind: str, data: dict) -> None:
    events = _events.get()
    if events is not None:
        events.append({"type": kind, "data": data})


def _detail(response: httpx.Response) -> str:
    try:
        return str(response.json().get("detail", response.text))
    except ValueError:
        return response.text[:300]


def authenticate(pnr_code: str, last_name: str) -> dict:
    """
    Exchange PNR + surname for a session token and bind it to this context.

    Called by the application before the agent runs, never by the agent itself:
    credentials must not pass through the model.
    """
    response = http_client.post(
        f"{FASTAPI_BASE_URL}/api/auth/session",
        json={"pnr_code": pnr_code, "last_name": last_name},
    )
    if response.status_code != 200:
        raise PermissionError(_detail(response))

    data = response.json()
    _session_token.set(data["access_token"])
    return data["passenger"]


def bind_token(token: str) -> None:
    """Used by the agent service, which receives the token from the client."""
    _session_token.set(token)


def _open_handoff(trigger: str, summary: str, question: str | None = None) -> dict | None:
    """Deterministic hand-off raised by the loop itself (not chosen by the model)."""
    try:
        response = http_client.post(
            f"{FASTAPI_BASE_URL}/api/handoff",
            json={"trigger": trigger, "summary": summary[:2000], "question": question},
            headers=_auth_headers(),
        )
        if response.status_code in (200, 201):
            case = response.json()
            _emit("handoff", case)
            return case
    except (httpx.HTTPError, RuntimeError):
        pass
    return None


# ---------------------------------------------------------------------------
# Tools. Each returns compact JSON for the model and emits the same data as an
# event for the client.
# ---------------------------------------------------------------------------


@tool
def find_alternative_flights_tool() -> str:
    """
    Lists the recovery flights available to the authenticated passenger on the
    same route and in the same cabin, earliest arrival first, with flight IDs,
    departure and arrival times and seats left. Call this FIRST whenever a
    passenger asks to be rebooked. Takes no arguments.
    """
    try:
        response = http_client.get(
            f"{FASTAPI_BASE_URL}/api/flights/alternatives", headers=_auth_headers()
        )
        if response.status_code != 200:
            return json.dumps({"status": "FAILED", "detail": _detail(response)})
        data = response.json()
        _emit("alternatives", data)
        if data["count"] == 0:
            case = _open_handoff(
                "NO_ALTERNATIVES",
                "No alternative flight with a free seat in the passenger's cabin.",
            )
            return json.dumps(
                {
                    "status": "NO_OPTIONS",
                    "detail": "No alternative flights with seats in this cabin. "
                    "A hand-off case has been opened.",
                    "case_id": case["case_id"] if case else None,
                }
            )
        # Only what the model needs to choose and to tell the passenger, in
        # local airport time. Fewer tokens is a faster step.
        compact = [
            {
                "flight_id": f["flight_id"],
                "flight_number": f["flight_number"],
                "departs_local": f.get("departure_local"),
                "arrives_local": f.get("arrival_local"),
                "cabin": f["cabin_class"],
                "seats_left": f["available_seats"],
            }
            for f in data["alternatives"]
        ]
        return json.dumps({"status": "OK", "alternatives": compact})
    except (httpx.HTTPError, RuntimeError) as exc:
        return json.dumps({"status": "ERROR", "detail": f"Could not reach the backend: {exc}"})


@tool
def reaccommodate_passenger_tool(target_flight_id: str) -> str:
    """
    Rebooks the authenticated passenger onto a specific recovery flight and
    assigns a seat in their cabin. The target_flight_id MUST be copied from a
    previous find_alternative_flights_tool result. Never guess or invent one.
    """
    try:
        response = http_client.post(
            f"{FASTAPI_BASE_URL}/api/reaccommodate",
            json={"target_flight_id": target_flight_id},
            headers=_auth_headers(),
        )
        data = response.json()
        if response.status_code == 200:
            _emit("rebooked", data)
            booking = data.get("booking") or {}
            current = booking.get("current_flight") or {}
            issued = data.get("entitlements") or {}
            # The vouchers issued with the rebooking are returned here, so the
            # model can tell the passenger without a further get_entitlements
            # round trip (one model call fewer per rebooking).
            return json.dumps(
                {
                    "status": "SUCCESS",
                    "seat": data["assigned_seat"],
                    "cabin": booking.get("cabin_class"),
                    "flight_number": current.get("flight_number"),
                    "departs_local": current.get("departure_local"),
                    "arrives_local": current.get("arrival_local"),
                    "vouchers": [
                        {
                            k: v[k]
                            for k in ("entitlement_type", "quantity", "amount", "currency",
                                      "points", "status", "voucher_code")
                            if v.get(k) is not None
                        }
                        for v in issued.get("vouchers") or []
                        if v["status"] in ("ISSUED", "ELIGIBLE")
                    ],
                    "not_applicable": (issued.get("decision") or {}).get("notes", []),
                }
            )
        _emit("error", {"action": "reaccommodate", "detail": _detail(response)})
        return json.dumps({"status": "FAILED", "detail": _detail(response)})
    except (httpx.HTTPError, RuntimeError, ValueError) as exc:
        return json.dumps({"status": "ERROR", "detail": f"Could not reach the backend: {exc}"})


@tool
def search_policy_tool(question: str) -> str:
    """
    Searches Kenya Airways' Conditions of Carriage, EU Regulation 261/2004 and
    the Montreal Convention for clauses relevant to the passenger's question
    about their rights, refunds, compensation, care or baggage. Returns the
    best clauses with similarity scores, or OUT_OF_SCOPE when nothing in the
    policies answers the question (a member of staff is then notified).
    """
    try:
        response = http_client.get(
            f"{FASTAPI_BASE_URL}/api/policy/search",
            params={"q": question[:500]},
            headers=_auth_headers(),
        )
        if response.status_code != 200:
            return json.dumps({"status": "FAILED", "detail": _detail(response)})
        data = response.json()
        _emit("policy", data)
        if not data["in_scope"]:
            return json.dumps(
                {
                    "status": "OUT_OF_SCOPE",
                    "detail": "No policy clause answers this question. A member of staff "
                    "has been notified and will follow up.",
                    "case_id": (data.get("case") or {}).get("case_id"),
                }
            )
        return json.dumps(
            {
                "status": "OK",
                "clauses": [
                    {"ref": h["clause_ref"], "similarity": h["similarity"], "text": h["content"]}
                    for h in data["hits"]
                ],
            }
        )
    except (httpx.HTTPError, RuntimeError) as exc:
        return json.dumps({"status": "ERROR", "detail": f"Could not reach the backend: {exc}"})


@tool
def get_entitlements_tool() -> str:
    """
    Returns exactly what the authenticated passenger is entitled to (meal and
    hotel vouchers, transfers, cash compensation, Asante Rewards points) as
    decided by Kenya Airways' deterministic rules, with the reason for anything
    that does not apply. Use this for any question about what the passenger
    gets; never state an amount this tool did not return.
    """
    try:
        response = http_client.get(
            f"{FASTAPI_BASE_URL}/api/entitlements", headers=_auth_headers()
        )
        if response.status_code != 200:
            return json.dumps({"status": "FAILED", "detail": _detail(response)})
        data = response.json()
        _emit("entitlements", data)
        return json.dumps({"status": "OK", **data["decision"], "vouchers": data["vouchers"]})
    except (httpx.HTTPError, RuntimeError) as exc:
        return json.dumps({"status": "ERROR", "detail": f"Could not reach the backend: {exc}"})


@tool
def escalate_to_human_tool(summary: str) -> str:
    """
    Hands the conversation to a Kenya Airways desk agent. Use only when the
    passenger explicitly asks for a person, or when you cannot help with the
    tools you have. Give a one or two sentence summary of the case.
    """
    case = _open_handoff("PASSENGER_REQUEST", summary)
    if case is None:
        return json.dumps({"status": "FAILED", "detail": "Could not open a hand-off case."})
    return json.dumps({"status": "OK", "case_id": case["case_id"]})


tools = [
    find_alternative_flights_tool,
    reaccommodate_passenger_tool,
    search_policy_tool,
    get_entitlements_tool,
    escalate_to_human_tool,
]
tools_by_name = {t.name: t for t in tools}

SYSTEM_PROMPT = (
    "You are Kestrel, Kenya Airways' disruption recovery assistant. The passenger is "
    "already authenticated; never ask for or accept a PNR, surname or flight ID from them.\n"
    "Rules:\n"
    "1. To rebook, call find_alternative_flights_tool first, then "
    "reaccommodate_passenger_tool with a flight_id copied verbatim from its result. Never "
    "invent a flight ID. If the passenger has not chosen a flight, describe the options "
    "(flight number, departure, arrival, seats left) and ask which one they want, unless "
    "they asked for the next available flight.\n"
    "2. For questions about rights, refunds, compensation, care or rules, call "
    "search_policy_tool and answer ONLY from the clauses it returns, citing each clause "
    "reference you rely on in square brackets, e.g. [EU261 Art. 9]. If it returns "
    "OUT_OF_SCOPE, do not answer from your own knowledge: say a member of staff has been "
    "notified and will follow up.\n"
    "3. For what this passenger receives, call get_entitlements_tool and report only the "
    "items and amounts it returns, including why anything does not apply. A successful "
    "rebooking already returns the vouchers issued with it: report those and do not call "
    "get_entitlements_tool again.\n"
    "4. If the passenger asks for a person, call escalate_to_human_tool.\n"
    "Quote times from the *_local fields: they are local time at that airport, with the "
    "offset shown. Be brief, warm and concrete."
)


def get_llm():
    """Created on first use so importing this module needs no API key."""
    from langchain_google_genai import ChatGoogleGenerativeAI

    api_key = os.getenv("GOOGLE_API_KEY") or os.getenv("GEMINI_API_KEY")
    if not api_key:
        raise ValueError("Missing GOOGLE_API_KEY in .env file.")
    options = {"thinking_level": GEMINI_THINKING_LEVEL} if GEMINI_THINKING_LEVEL else {}
    llm = ChatGoogleGenerativeAI(model=GEMINI_MODEL, temperature=0, api_key=api_key, **options)
    return llm.bind_tools(tools)


@dataclass
class AgentResult:
    reply: str
    events: list = field(default_factory=list)
    tool_calls: list = field(default_factory=list)
    steps: int = 0
    stopped_at_limit: bool = False
    # Wall-clock milliseconds, for NFR-01 (a full agent turn within 15 s).
    model_ms: list = field(default_factory=list)
    tool_ms: list = field(default_factory=list)
    total_ms: int = 0

    def timing(self) -> dict:
        return {
            "total_ms": self.total_ms,
            "model_ms": self.model_ms,
            "tool_ms": self.tool_ms,
            "model_calls": len(self.model_ms),
        }

    def to_dict(self) -> dict:
        return {
            "reply": self.reply,
            "events": self.events,
            "tool_calls": self.tool_calls,
            "steps": self.steps,
            "stopped_at_limit": self.stopped_at_limit,
            "model": GEMINI_MODEL,
            "thinking_level": GEMINI_THINKING_LEVEL,
            "timing": self.timing(),
        }


def _history_messages(history: list[dict] | None) -> list:
    messages = []
    for turn in (history or [])[-MAX_HISTORY_TURNS * 2 :]:
        content = str(turn.get("content", ""))[:4000]
        if turn.get("role") == "user":
            messages.append(HumanMessage(content=content))
        elif turn.get("role") == "assistant":
            messages.append(AIMessage(content=content))
    return messages


def run_agent(user_query: str, history: list[dict] | None = None, llm=None) -> AgentResult:
    """
    Bounded tool-calling loop. The model either answers in text, which ends the
    turn, or requests tool calls whose results are added to the conversation.
    At MAX_TOOL_ITERATIONS the loop stops and opens a STEP_LIMIT hand-off case.
    """
    model = llm or get_llm()
    events: list = []
    token = _events.set(events)
    result = AgentResult(reply="", events=events)
    started = time.perf_counter()
    try:
        messages: list = [
            SystemMessage(content=SYSTEM_PROMPT),
            *_history_messages(history),
            HumanMessage(content=user_query),
        ]

        for step in range(1, MAX_TOOL_ITERATIONS + 1):
            t0 = time.perf_counter()
            ai_msg: AIMessage = model.invoke(messages)
            result.model_ms.append(round((time.perf_counter() - t0) * 1000))
            messages.append(ai_msg)
            result.steps = step

            if not ai_msg.tool_calls:
                result.reply = _extract_text(ai_msg)
                return result

            for tool_call in ai_msg.tool_calls:
                selected = tools_by_name.get(tool_call["name"])
                if selected is None:
                    output = json.dumps(
                        {"status": "ERROR", "detail": f"Unknown tool '{tool_call['name']}'."}
                    )
                else:
                    t0 = time.perf_counter()
                    output = selected.invoke(tool_call["args"])
                    result.tool_ms.append(round((time.perf_counter() - t0) * 1000))
                result.tool_calls.append(
                    {"name": tool_call["name"], "args": tool_call["args"], "result": output}
                )
                print(f"\n[TOOL CALL] {tool_call['name']} args={tool_call['args']}")
                print(f"[TOOL RESULT] {output}\n")
                messages.append(ToolMessage(content=str(output), tool_call_id=tool_call["id"]))

        result.stopped_at_limit = True
        case = _open_handoff(
            "STEP_LIMIT",
            f"Agent reached its {MAX_TOOL_ITERATIONS}-step limit. Last request: {user_query[:300]}",
            question=user_query,
        )
        result.reply = (
            "I couldn't finish this automatically, so I've passed your case to a Kenya Airways "
            "agent"
            + (f" (case #{case['case_id']})" if case else "")
            + ". They'll follow up with you shortly."
        )
        return result
    finally:
        result.total_ms = round((time.perf_counter() - started) * 1000)
        _events.reset(token)


def _extract_text(msg: AIMessage) -> str:
    if isinstance(msg.content, list):
        return "".join(
            block.get("text", "") if isinstance(block, dict) else str(block)
            for block in msg.content
        )
    return str(msg.content)


DEFAULT_PROMPT = "My flight was cancelled. Please get me on the next available flight."


def main(argv: list[str] | None = None) -> None:
    # The passenger is supplied by the caller rather than hardcoded: a fixed PNR
    # vanishes the moment the dataset is regenerated or reset. The agent has no
    # database access to look one up itself, by design - scripts/agent_demo.py
    # finds a disrupted passenger and calls main() with it.
    parser = argparse.ArgumentParser(description="Run the Kestrel agent for one passenger.")
    parser.add_argument("--pnr", required=True, help="Booking reference, e.g. IZNXXV")
    parser.add_argument("--last-name", required=True, help="Passenger surname on the booking")
    parser.add_argument("--prompt", default=DEFAULT_PROMPT, help="What the passenger asks")
    args = parser.parse_args(argv)

    print("\n--- Project Kestrel AI Agent Online ---")

    passenger = authenticate(pnr_code=args.pnr, last_name=args.last_name)
    print(f"Authenticated: {passenger['last_name']} ({passenger['rewards_tier']})")
    print(f"User Request: {args.prompt}")

    print("--- Final Agent Response ---")
    result = run_agent(args.prompt)
    print(result.reply)
    t = result.timing()
    print(
        f"\n[TIMING] total {t['total_ms']} ms | model calls {t['model_calls']} "
        f"{t['model_ms']} ms | tools {t['tool_ms']} ms | thinking_level={GEMINI_THINKING_LEVEL}"
    )


if __name__ == "__main__":
    main()
