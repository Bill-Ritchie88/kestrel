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
import re
import threading
import time
from collections.abc import Callable
from concurrent.futures import Future, ThreadPoolExecutor
from contextvars import ContextVar
from dataclasses import dataclass, field
from datetime import datetime

import httpx
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage, ToolMessage
from langchain_core.tools import tool

from kestrel import config  # noqa: F401  - loads .env before anything reads it
from kestrel.entitlements import when_text

FASTAPI_BASE_URL = os.getenv("FASTAPI_BASE_URL", "http://127.0.0.1:8000")
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-flash-latest")
# Gemini 3 models reason before answering; at the default depth each step of a
# tool loop took several seconds. Routing a disrupted passenger needs little
# reasoning - the rules live in code - so "low" is the default. Set
# GEMINI_THINKING_LEVEL to minimal/low/medium/high, or to "" for the model's
# own default.
GEMINI_THINKING_LEVEL = os.getenv("GEMINI_THINKING_LEVEL", "low") or None
# The Gemini client retries a failed call up to 6 times with growing waits by
# default. On a 429 (quota) that silently stretched one chat turn past the
# client's 45 s limit. Two attempts and a per-call timeout keep a turn bounded;
# a quota error then reaches the passenger as a clear message instead.
GEMINI_MAX_ATTEMPTS = int(os.getenv("GEMINI_MAX_ATTEMPTS", "2"))
GEMINI_TIMEOUT_S = float(os.getenv("GEMINI_TIMEOUT_S", "20"))
MAX_TOOL_ITERATIONS = 5
MAX_HISTORY_TURNS = 10

# 30 s: a rebooking under contention (row locks, then the vouchers) can take
# longer than the old 10 s, and a timed-out tool call told the model it had
# failed when it had not (issue #37). The client waits 45 s for a turn.
http_client = httpx.Client(timeout=30.0)

# The session token lives in a context variable rather than a tool argument.
# If it were an argument, the language model would be able to invent one.
_session_token: ContextVar[str | None] = ContextVar("session_token", default=None)
# Structured results of the tool calls made during the current turn.
_events: ContextVar[list | None] = ContextVar("events", default=None)
# A streamed turn (POST /api/chat/stream): told ("status" | "delta" | "event",
# data) as the turn runs.
_listener: ContextVar[Callable[[str, dict], None] | None] = ContextVar("listener", default=None)
# The passenger's trip (GET /api/trip), fetched by the agent service; it
# becomes the CONTEXT system message.
_briefing: ContextVar[dict | None] = ContextVar("briefing", default=None)
# A policy search started alongside the first model call: (question, future
# REST body, or None if it failed).
_speculative: ContextVar[tuple[str, Future] | None] = ContextVar("speculative", default=None)


def _auth_headers() -> dict[str, str]:
    token = _session_token.get()
    if not token:
        raise RuntimeError("No authenticated session. Call authenticate() first.")
    return {"Authorization": f"Bearer {token}"}


def _emit(kind: str, data: dict) -> None:
    events = _events.get()
    if events is not None:
        events.append({"type": kind, "data": data})
    listener = _listener.get()
    if listener is not None:
        listener("event", {"type": kind, "data": data})


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


def bind_listener(listener: Callable[[str, dict], None] | None) -> None:
    """A streamed turn: the agent service passes on what the turn reports."""
    _listener.set(listener)


def bind_briefing(trip: dict | None) -> None:
    """The passenger's trip, for the CONTEXT message (see briefing_text)."""
    _briefing.set(trip)
    _speculative.set(None)


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
        if response.headers.get("X-Refusal-Reason") == "DIFFERENT_ROUTE":
            # Migration 011: the flight is on another route. Nothing changed.
            return json.dumps({
                "status": "DIFFERENT_ROUTE",
                "detail": _detail(response) + " Nothing was changed. Offer only flights from "
                "CONTEXT or find_alternative_flights_tool.",
            })
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
        data = _reuse_speculative(question)
        if data is None:
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
    "A CONTEXT message holds the passenger's booking as the REST tier returned it at the "
    "start of this conversation: name, tier, booking status, original flight, the top "
    "alternative flights with their flight_id, and what the rules give them now.\n"
    "Rules:\n"
    "1. Questions about the options (which flights, when, seats left) may be answered from "
    "CONTEXT without a tool call. Call find_alternative_flights_tool when CONTEXT has no "
    "alternatives or the passenger asks for more or for an up-to-date list.\n"
    "2. To rebook you MUST call reaccommodate_passenger_tool with a flight_id copied verbatim "
    "from CONTEXT or from find_alternative_flights_tool. Never invent a flight ID. If the "
    "passenger has not chosen a flight, describe the options (flight number, departure, "
    "arrival, seats left) and ask which one they want, unless they asked for the next "
    "available flight.\n"
    "3. For questions about rights, refunds, compensation, care or rules you MUST call "
    "search_policy_tool and answer ONLY from the clauses it returns, citing each clause "
    "reference you rely on in square brackets, e.g. [EU261 Art. 9]. If it returns "
    "OUT_OF_SCOPE, do not answer from your own knowledge: say a member of staff has been "
    "notified and will follow up.\n"
    "4. What this passenger receives may be answered from the entitlements in CONTEXT, "
    "reporting only the items and amounts given there and why anything does not apply; call "
    "get_entitlements_tool if CONTEXT has none or the booking has changed since. A "
    "successful rebooking already returns the vouchers issued with it: report those and do "
    "not call get_entitlements_tool again.\n"
    "5. If the passenger asks for a person, call escalate_to_human_tool.\n"
    "Quote times from the *_local fields or as CONTEXT gives them: they are local time at "
    "that airport. Be brief, warm and concrete. Write plain text: no Markdown, no ** or "
    "other formatting marks."
)

# What the passenger sees while a tool runs (streamed replies).
TOOL_STATUS = {
    "find_alternative_flights_tool": "Checking flights\u2026",
    "reaccommodate_passenger_tool": "Rebooking you\u2026",
    "search_policy_tool": "Reading the conditions of carriage\u2026",
    "get_entitlements_tool": "Checking what you\u2019re entitled to\u2026",
    "escalate_to_human_tool": "Passing your case to a person\u2026",
}


# ---------------------------------------------------------------------------
# CONTEXT: the passenger's booking, written once per conversation
# ---------------------------------------------------------------------------

BRIEFING_ALTERNATIVES = 3


def _short(local_iso: str | None) -> str:
    """'2026-10-18T16:26+03:00' -> 'Sun 18 Oct 16:26' (local time, as given)."""
    if not local_iso:
        return "unknown"
    try:
        return datetime.fromisoformat(local_iso).strftime("%a %d %b %H:%M")
    except ValueError:
        return local_iso


def _entitlement_summary(entitlements: dict) -> list[str]:
    decision = entitlements.get("decision") or {}
    lines = []
    for e in decision.get("entitlements") or []:
        amount = ""
        if e.get("points"):
            amount = f" {e['points']:,} points"
        elif e.get("amount") is not None:
            amount = f" {e.get('quantity') or 1} x {e.get('currency') or ''} {e['amount']:,.0f}"
        elif (e.get("quantity") or 1) > 1:
            amount = f" x{e['quantity']}"
        lines.append(f"- {e.get('label')}{amount} ({e.get('status')}; {e.get('rule_id')})")
    for note in decision.get("notes") or []:
        lines.append(f"- Not applicable: {note}")
    vouchers = [v for v in entitlements.get("vouchers") or [] if v.get("status") in ("ISSUED", "ELIGIBLE")]
    if vouchers:
        lines.append("- Vouchers issued: " + ", ".join(
            f"{v.get('entitlement_type')} {v.get('voucher_code')}" for v in vouchers
        ))
    return lines


def briefing_text(trip: dict) -> str:
    """The compact CONTEXT message from GET /api/trip: who, which booking,
    the original flight, the top alternatives with their flight_id, and what
    the rules give now. Pure, so it is unit-tested."""
    booking = trip.get("booking") or {}
    passenger = booking.get("passenger") or {}
    original = booking.get("original_flight") or {}
    current = booking.get("current_flight") or {}
    lines = [
        "CONTEXT (from the passenger's booking; times are local to each airport)",
        f"Passenger: {passenger.get('first_name') or passenger.get('last_name') or 'unknown'}, "
        f"{passenger.get('rewards_tier') or 'BLUE'} tier. Booking {booking.get('pnr_code', '?')}: "
        f"{booking.get('booking_status', 'unknown')}, {booking.get('cabin_class', 'ECONOMY')} cabin.",
        f"Original flight: {original.get('flight_number', '?')} {original.get('origin', '?')}-"
        f"{original.get('destination', '?')}, departs {_short(original.get('departure_local'))}, "
        f"{original.get('status', '?')}"
        + (f" ({original['disruption_reason']})" if original.get("disruption_reason") else "")
        + ".",
    ]
    if current:
        lines.append(
            f"Now booked on: {current.get('flight_number')}, departs "
            f"{_short(current.get('departure_local'))}, arrives {_short(current.get('arrival_local'))}, "
            f"seat {booking.get('seat_number') or '?'}."
        )
    alternatives = (trip.get("alternatives") or [])[:BRIEFING_ALTERNATIVES]
    if alternatives:
        lines.append("Alternatives, earliest arrival first (flight_id for reaccommodate_passenger_tool):")
        for i, f in enumerate(alternatives, 1):
            lines.append(
                f"{i}. {f.get('flight_number')} flight_id={f.get('flight_id')} departs "
                f"{_short(f.get('departure_local'))} arrives {_short(f.get('arrival_local'))}, "
                f"{f.get('available_seats')} seats left"
                + (f"; {'; '.join(f['reasons'])}" if f.get("reasons") else "")
            )
    else:
        lines.append("Alternatives: none with a free seat in this cabin.")
    summary = _entitlement_summary(trip.get("entitlements") or {})
    if summary:
        lines.append("Entitlements now, from the rules engine:")
        lines.extend(summary)
    open_cases = [c for c in trip.get("cases") or [] if c.get("status") == "OPEN"]
    if open_cases:
        lines.append("Open hand-off cases: " + ", ".join(
            f"#{c.get('case_id')} ({c.get('trigger')})" for c in open_cases
        ))
    return "\n".join(lines)


def _context_messages() -> list:
    trip = _briefing.get()
    return [SystemMessage(content=briefing_text(trip))] if trip else []


# ---------------------------------------------------------------------------
# Speculative policy search
# ---------------------------------------------------------------------------

# Words that mark a question about rights or policy. When the passenger's
# message has one, the policy search starts at the same time as the first
# model call; the model usually asks for it a few seconds later.
# Whole words only (issue #21): "cancel" and "delay" are in nearly every
# message from a disrupted passenger, and "right"/"care" matched inside
# "alright" and "careful".
RIGHTS_WORDS = re.compile(
    r"\b(refunds?|compensat\w*|rights|entitle\w*|hotels?|meals?|eu261|care|reimburs\w*|"
    r"claims?|baggage|luggage|money back)\b"
)
# How long the policy tool waits for a speculative search before searching
# itself; the search normally takes about a second.
SPECULATION_WAIT_S = 5.0
SIMILAR = 0.8
_speculation = ThreadPoolExecutor(max_workers=4, thread_name_prefix="policy-speculation")
_WORD = re.compile(r"[a-z0-9]+")


def token_set_similarity(a: str, b: str) -> float:
    """Words shared over words used (Jaccard), ignoring case and punctuation."""
    sa, sb = set(_WORD.findall(a.lower())), set(_WORD.findall(b.lower()))
    if not sa or not sb:
        return 0.0
    return len(sa & sb) / len(sa | sb)


def looks_like_rights_question(text: str) -> bool:
    return bool(RIGHTS_WORDS.search(text.lower()))


def start_speculative_search(question: str) -> None:
    """Start GET /api/policy/search for the passenger's own words, without
    opening a hand-off case (the search the model makes does that, if it
    is out of scope)."""
    headers = _auth_headers()

    def fetch() -> dict | None:
        response = http_client.get(
            f"{FASTAPI_BASE_URL}/api/policy/search",
            params={"q": question[:500], "handoff": "false"},
            headers=headers,
        )
        return response.json() if response.status_code == 200 else None

    _speculative.set((question, _speculation.submit(fetch)))


def _reuse_speculative(question: str) -> dict | None:
    """The speculative result, if the model asked (nearly) the same question
    and it found clauses; otherwise None and the tool searches itself."""
    spec = _speculative.get()
    if spec is None:
        return None
    asked, future = spec
    if token_set_similarity(asked, question) < SIMILAR:
        return None
    try:
        data = future.result(timeout=SPECULATION_WAIT_S)
    except Exception:  # noqa: BLE001 - any failure: search the usual way
        return None
    if not isinstance(data, dict) or not data.get("in_scope"):
        return None
    _speculative.set(None)
    return data


_llm = None
_llm_lock = threading.Lock()


def get_llm():
    """Created on first use, so importing this module needs no API key, and
    then kept for the life of the process: its connections to the Gemini API
    stay open between turns instead of a new TLS connection (several round
    trips from Nairobi) for every turn. The first version built a new client
    per turn."""
    global _llm
    with _llm_lock:
        if _llm is None:
            from langchain_google_genai import ChatGoogleGenerativeAI

            api_key = os.getenv("GOOGLE_API_KEY") or os.getenv("GEMINI_API_KEY")
            if not api_key:
                raise ValueError("Missing GOOGLE_API_KEY in .env file.")
            options = {"thinking_level": GEMINI_THINKING_LEVEL} if GEMINI_THINKING_LEVEL else {}
            llm = ChatGoogleGenerativeAI(
                model=GEMINI_MODEL,
                temperature=0,
                api_key=api_key,
                max_retries=GEMINI_MAX_ATTEMPTS,
                timeout=GEMINI_TIMEOUT_S,
                **options,
            )
            _llm = llm.bind_tools(tools)
    return _llm


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
    # When the reply text would start reaching the passenger: the start of
    # the model call that wrote it (the last one), measured from the turn's
    # start.
    first_token_ms: int = 0

    def timing(self) -> dict:
        return {
            "first_token_ms": self.first_token_ms,
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

    In a streamed turn (bind_listener) the model's reply is passed on as it is
    written ("delta"), with a "status" line when a tool starts and each tool's
    structured result as an "event". The deltas, joined, are the reply.
    """
    model = llm or get_llm()
    events: list = []
    token = _events.set(events)
    result = AgentResult(reply="", events=events)
    listener = _listener.get()
    streaming = listener is not None and hasattr(model, "stream")
    streamed: list[str] = []
    started = time.perf_counter()

    def say(text: str) -> None:
        if not text:
            return
        if not streamed:
            result.first_token_ms = round((time.perf_counter() - started) * 1000)
        streamed.append(text)
        listener("delta", {"text": text})

    try:
        messages: list = [
            SystemMessage(content=SYSTEM_PROMPT),
            *_context_messages(),
            *_history_messages(history),
            HumanMessage(content=user_query),
        ]

        for step in range(1, MAX_TOOL_ITERATIONS + 1):
            t0 = time.perf_counter()
            if streaming:
                ai_msg = None
                wrote = False
                for chunk in model.stream(messages):
                    ai_msg = chunk if ai_msg is None else ai_msg + chunk
                    text = _extract_text(chunk)
                    if text:
                        if not wrote and streamed:
                            say("\n\n")  # text from an earlier step
                        wrote = True
                        say(text)
                if ai_msg is None:
                    ai_msg = AIMessage(content="")
            else:
                result.first_token_ms = round((t0 - started) * 1000)
                ai_msg = model.invoke(messages)
            result.model_ms.append(round((time.perf_counter() - t0) * 1000))
            messages.append(ai_msg)
            result.steps = step

            if not ai_msg.tool_calls:
                result.reply = "".join(streamed) if streaming else _extract_text(ai_msg)
                _context_cards(user_query, result.reply)
                return result

            for tool_call in ai_msg.tool_calls:
                selected = tools_by_name.get(tool_call["name"])
                if selected is None:
                    output = json.dumps(
                        {"status": "ERROR", "detail": f"Unknown tool '{tool_call['name']}'."}
                    )
                else:
                    if streaming:
                        listener("status", {"text": TOOL_STATUS.get(tool_call["name"], "Working on it\u2026")})
                    t0 = time.perf_counter()
                    output = selected.invoke(tool_call["args"])
                    result.tool_ms.append(round((time.perf_counter() - t0) * 1000))
                result.tool_calls.append(
                    {"name": tool_call["name"], "args": tool_call["args"], "result": output}
                )
                # The tool's name only: arguments and results hold the
                # passenger's words and voucher codes (issue #11).
                print(f"[TOOL CALL] {tool_call['name']}", flush=True)
                messages.append(ToolMessage(content=str(output), tool_call_id=tool_call["id"]))

        result.stopped_at_limit = True
        case = _open_handoff(
            "STEP_LIMIT",
            f"Agent reached its {MAX_TOOL_ITERATIONS}-step limit. Last request: {user_query[:300]}",
            question=user_query,
        )
        limit_reply = (
            "I couldn't finish this automatically, so I've passed your case to a Kenya Airways "
            "agent"
            + (f" (case #{case['case_id']})" if case else "")
            + ". They'll follow up with you shortly."
        )
        if streaming:
            if streamed:
                say("\n\n")
            say(limit_reply)
            result.reply = "".join(streamed)
        else:
            result.reply = limit_reply
        return result
    finally:
        result.total_ms = round((time.perf_counter() - started) * 1000)
        if streaming and not streamed:
            result.first_token_ms = result.total_ms
        _events.reset(token)


# Words that show what a question was about, for _context_cards.
_OPTION_WORDS = ("option", "flight", "alternative", "rebook", "earlier", "later", "next", "seat")
_ENTITLEMENT_WORDS = ("entitle", "voucher", "owed", "meal", "hotel", "points")


def _context_cards(user_query: str, reply: str) -> None:
    """Answered from CONTEXT, the reply comes with no tool event, so the
    client would draw no flight or entitlement cards. Add them, from the
    same trip the model was given: flights when the question was about
    options and the reply gives an alternative's departure time; the
    entitlements when the question was about them. A display aid only."""
    trip = _briefing.get()
    events = _events.get()
    if not trip or events is None:
        return
    kinds = {e["type"] for e in events}
    question = user_query.lower()
    alternatives = trip.get("alternatives") or []
    if (
        "alternatives" not in kinds
        and "rebooked" not in kinds
        and alternatives
        and any(w in question for w in _OPTION_WORDS)
        and any(
            (f.get("departure_local") or "")[11:16] in reply
            for f in alternatives[:BRIEFING_ALTERNATIVES]
            if f.get("departure_local")
        )
    ):
        _emit("alternatives", {"pnr_code": trip.get("pnr_code"), "count": len(alternatives),
                               "alternatives": alternatives})
    if (
        "entitlements" not in kinds
        and "rebooked" not in kinds
        and "policy" not in kinds  # a rights question: the clauses are the answer
        and trip.get("entitlements")
        and any(w in question for w in _ENTITLEMENT_WORDS)
    ):
        _emit("entitlements", {"pnr_code": trip.get("pnr_code"), **trip["entitlements"]})


# ---------------------------------------------------------------------------
# Quick replies: the matching tool, a templated reply, no model call
# ---------------------------------------------------------------------------

INTENT_TOOLS = {
    "alternatives": "find_alternative_flights_tool",
    "entitlements": "get_entitlements_tool",
    "person": "escalate_to_human_tool",
}


_when = when_text  # 'Sun 18 Oct at 16:26' (kestrel.entitlements)


def _money(amount, currency) -> str:
    return f"{currency or ''} {amount:,.0f}".strip()


def _alternatives_reply(output: dict, data: dict | None) -> str:
    if output.get("status") == "NO_OPTIONS":
        case = output.get("case_id")
        return (
            "There are no free seats in your cabin on other flights on this route right now, "
            "so I've passed your case to a Kenya Airways agent"
            + (f" (case #{case})" if case else "")
            + ". They'll look at other options with you."
        )
    flights = (data or {}).get("alternatives") or []
    if output.get("status") != "OK" or not flights:
        return "I couldn't load the flights just now. Please try again in a moment."
    best = flights[0]
    count = len(flights)
    return (
        f"Here {'is' if count == 1 else 'are'} {count} flight{'' if count == 1 else 's'} on the "
        f"same route and in your cabin, earliest arrival first. {best.get('flight_number')} on "
        f"{_when(best.get('departure_local'))} arrives first, with {best.get('available_seats')} "
        "seats left. Choose one to review it; nothing changes until you confirm."
    )


def _entitlements_reply(output: dict, data: dict | None) -> str:
    if output.get("status") != "OK" or not data:
        return "I couldn't load your entitlements just now. Please try again in a moment."
    decision = data.get("decision") or {}
    items = []
    for e in decision.get("entitlements") or []:
        if e.get("entitlement_type") == "REROUTING":
            items.append("re-routing at no extra cost")
        elif e.get("points"):
            items.append(f"{e['points']:,} Asante Rewards points")
        elif e.get("amount") is not None:
            qty = e.get("quantity") or 1
            items.append(f"{e.get('label', '').lower()} ({qty} x {_money(e['amount'], e.get('currency'))})")
        else:
            items.append(str(e.get("label", "")).lower())
    if not items:
        reply = "The rules don't give this booking any vouchers or compensation right now."
    elif len(items) == 1:
        reply = f"Here's what the rules give you now: {items[0]}."
    else:
        reply = f"Here's what the rules give you now: {', '.join(items[:-1])} and {items[-1]}."
    notes = decision.get("notes") or []
    if notes:
        reply += " " + " ".join(notes[:2])
    return reply


# What the staff queue actually shows (issue #14): the booking, a summary and
# the last question - not the whole conversation.
STAFF_SEE = "They can see your booking and your last question,"


def _person_reply(output: dict) -> str:
    if output.get("status") != "OK":
        return "I couldn't reach the disruption desk just now. Please try again, or use Help."
    return (
        f"I've passed your case to a Kenya Airways agent (case #{output.get('case_id')}). "
        f"{STAFF_SEE} and they'll contact you on the details in your booking."
    )


def _person_summary(history: list[dict] | None) -> str:
    asked = [t.get("content", "") for t in history or [] if t.get("role") == "user"]
    summary = "Passenger asked for a person (quick reply)."
    if asked:
        summary += f" Last question: {asked[-1][:300]}"
    return summary


def run_handoff(trigger: str, summary: str, question: str | None = None) -> AgentResult:
    """Hand the conversation to a person straight away (the agent service
    decided: a frustrated passenger). No model call; the reply is a template."""
    events: list = []
    token = _events.set(events)
    result = AgentResult(reply="", events=events)
    listener = _listener.get()
    started = time.perf_counter()
    try:
        if listener is not None:
            listener("status", {"text": TOOL_STATUS["escalate_to_human_tool"]})
        t0 = time.perf_counter()
        case = _open_handoff(trigger, summary, question=question)
        result.tool_ms.append(round((time.perf_counter() - t0) * 1000))
        result.tool_calls.append({"name": f"handoff:{trigger}", "args": {}, "result": json.dumps(case)})
        result.reply = (
            "I'm sorry this hasn't been easier. I've passed your case to a Kenya Airways agent"
            + (f" (case #{case['case_id']})" if case else "")
            + f". {STAFF_SEE} and they'll contact you on the details in your booking."
            if case
            else "I'm sorry this hasn't been easier. I couldn't reach the disruption desk just now; "
            "please use Help to contact Kenya Airways."
        )
        result.steps = 1
        result.first_token_ms = round((time.perf_counter() - started) * 1000)
        if listener is not None:
            listener("delta", {"text": result.reply})
        return result
    finally:
        result.total_ms = round((time.perf_counter() - started) * 1000)
        _events.reset(token)


def run_case_reminder(case: dict) -> AgentResult:
    """A frustrated passenger whose booking already has an open case (issue
    #9): no second case and no model call, a reminder that a person has it."""
    result = AgentResult(
        reply=f"Your case #{case.get('case_id')} is already with the Kenya Airways disruption desk. "
        f"{STAFF_SEE} and they'll contact you on the details in your booking. Until then I can "
        "still show your flight options or what you're entitled to.",
        steps=1,
    )
    listener = _listener.get()
    if listener is not None:
        listener("delta", {"text": result.reply})
    return result


def run_intent(intent: str, history: list[dict] | None = None) -> AgentResult:
    """A quick reply: run the matching tool directly and answer from a
    template - the same events as a model turn, no model call."""
    name = INTENT_TOOLS[intent]
    events: list = []
    token = _events.set(events)
    result = AgentResult(reply="", events=events)
    listener = _listener.get()
    started = time.perf_counter()
    try:
        if listener is not None:
            listener("status", {"text": TOOL_STATUS[name]})
        args = {"summary": _person_summary(history)} if intent == "person" else {}
        t0 = time.perf_counter()
        output = tools_by_name[name].invoke(args)
        result.tool_ms.append(round((time.perf_counter() - t0) * 1000))
        result.tool_calls.append({"name": name, "args": args, "result": output})
        parsed = json.loads(output)
        kind = {"alternatives": "alternatives", "entitlements": "entitlements"}.get(intent)
        data = next((e["data"] for e in events if e["type"] == kind), None) if kind else None
        if intent == "alternatives":
            result.reply = _alternatives_reply(parsed, data)
        elif intent == "entitlements":
            result.reply = _entitlements_reply(parsed, data)
        else:
            result.reply = _person_reply(parsed)
        result.steps = 1
        result.first_token_ms = round((time.perf_counter() - started) * 1000)
        if listener is not None:
            listener("delta", {"text": result.reply})
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
    # database access to look one up itself, by design - scripts/dev/agent_demo.py
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
