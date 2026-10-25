"""
Project Kestrel - Agent service (chat endpoint for the Flutter client).

Runs as its own process, separate from the REST tier, so the architecture in
Figure 4.5 holds at runtime: the agent process makes HTTP calls to the REST
tier and has no database connection of its own. It removes DATABASE_URL from
its environment when the server starts so it cannot open one by accident.

    uvicorn kestrel.agent_service:app --port 8001

The client sends the bearer token it obtained from POST /api/auth/session on
the REST tier. The token is bound to the request's context and forwarded on
every tool call; it never enters the model's prompt.

    POST /api/chat           one JSON reply when the turn is done
    POST /api/chat/stream    the same turn as Server-Sent Events: status lines
                             while tools run, the reply as it is written, the
                             structured events, then `done` (or `error`)

Both take {message, history, intent?}. With an intent (a quick-reply chip:
alternatives, entitlements, person) the matching tool runs directly and the
reply is a template - no model call.
"""

from __future__ import annotations

import asyncio
import json
import os
import time
from contextlib import asynccontextmanager
from typing import Literal

from fastapi import BackgroundTasks, FastAPI, Header, HTTPException, status
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from kestrel import (  # noqa: F401  - config loads .env first
    __version__,
    agent,
    config,
    frustration,
    jsonlog,
)
from kestrel.suggestions import after_turn


@asynccontextmanager
async def lifespan(app: FastAPI):
    # The agent tier holds no database credentials. Removed when the server
    # starts rather than at import, so importing this module in the test
    # suite does not hide DATABASE_URL from the integration tests.
    os.environ.pop("DATABASE_URL", None)
    # Build the model client now, in the background: importing the Gemini
    # library and connecting took about 3 s, paid by the first passenger.
    asyncio.get_running_loop().run_in_executor(None, _warm_model)
    yield


def _warm_model() -> None:
    try:
        agent.get_llm()
    except Exception as exc:  # noqa: BLE001 - e.g. no API key: the first turn says so
        print(f"[WARN] Model client not prepared: {type(exc).__name__}", flush=True)


app = FastAPI(title="Project Kestrel - Agent Service", version=__version__, lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in os.getenv("ALLOWED_ORIGINS", "").split(",") if o.strip()],
    allow_credentials=True,
    allow_methods=["GET", "POST"],
    allow_headers=["Authorization", "Content-Type"],
)


class ChatTurn(BaseModel):
    role: str = Field(..., pattern="^(user|assistant)$")
    content: str = Field(..., max_length=4000)


class ChatRequest(BaseModel):
    message: str = Field(..., min_length=1, max_length=1000)
    history: list[ChatTurn] = Field(default_factory=list, max_length=40)
    # Sent only by the client's quick-reply chips, never with typed text.
    intent: Literal["alternatives", "entitlements", "person"] | None = None


@app.get("/health")
def health():
    return {
        "status": "online",
        "version": __version__,
        "model": agent.GEMINI_MODEL,
        "rest_tier": agent.FASTAPI_BASE_URL,
    }


# Every chat turn is appended to logs/agent-turns.jsonl (one JSON object per
# line: timing, tools used, or the error). The file is the evidence for the
# NFR-02 latency log and survives the service window being closed.
LOG_DIR = jsonlog.LOG_DIR


def _log_turn(record: dict) -> None:
    jsonlog.append(LOG_DIR, "agent-turns.jsonl", record)


def _is_quota_error(exc: Exception) -> bool:
    text = f"{type(exc).__name__} {exc}"
    return "429" in text or "RESOURCE_EXHAUSTED" in text or "ResourceExhausted" in text


def _http_error(exc: Exception) -> HTTPException:
    """The status and words a failed turn reaches the passenger with."""
    if isinstance(exc, HTTPException):
        return exc
    if isinstance(exc, ValueError):  # missing API key
        return HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc))
    if _is_quota_error(exc):
        return HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Kestrel's AI service has reached its usage limit for now. "
            "Please try again in a few minutes, or use 'Talk to a person'.",
        )
    return HTTPException(
        status_code=status.HTTP_502_BAD_GATEWAY,
        detail="Kestrel couldn't complete that request. Please try again.",
    )


# ---------------------------------------------------------------------------
# The booking briefing: GET /api/trip on every turn
# ---------------------------------------------------------------------------


def briefing_for(token: str) -> dict:
    """The passenger's trip, for the CONTEXT message. It is also the session
    check: an expired token is 401 before the model runs.

    Fetched on every turn, never cached (issue #5): the Confirm page rebooks
    through the REST tier directly, and a cached trip kept the assistant
    thinking the passenger was still DISRUPTED for up to two minutes. One
    call, about 0.4 s."""
    response = agent.http_client.get(
        f"{agent.FASTAPI_BASE_URL}/api/trip",
        headers={"Authorization": f"Bearer {token}"},
    )
    if response.status_code == 401:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Session expired.")
    if response.status_code != 200:
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail="REST tier unavailable.")
    return response.json()


def _open_case(trip: dict | None) -> dict | None:
    return next((c for c in (trip or {}).get("cases") or [] if c.get("status") == "OPEN"), None)


# ---------------------------------------------------------------------------
# A turn
# ---------------------------------------------------------------------------


def _run(
    token: str,
    message: str,
    history: list[dict],
    trip: dict | None = None,
    intent: str | None = None,
    emit=None,
) -> dict:
    # Runs in a worker thread with its own copy of the request context, so the
    # token, trip and listener bound here belong to this conversation only.
    agent.bind_token(token)
    agent.bind_briefing(trip)
    agent.bind_listener(emit)
    started = time.perf_counter()
    # Quick replies are taps on a chip, not words: they are not read for
    # frustration (tapping the same chip twice is not a repeated complaint).
    mood = frustration.assess(message, history) if not intent else frustration.Assessment()
    try:
        if intent:
            result = agent.run_intent(intent, history)
        elif mood.action == "handoff" and (case := _open_case(trip)) is not None:
            # A person already has this booking (issue #9): no second case and
            # no repeated hand-off message, a reminder instead.
            result = agent.run_case_reminder(case)
        elif mood.action == "handoff":
            result = agent.run_handoff("FRUSTRATION", mood.summary(message), question=message)
        else:
            if mood.action == "acknowledge" and emit is not None:
                emit("delta", {"text": frustration.ACKNOWLEDGE + "\n\n"})
            if agent.looks_like_rights_question(message):
                agent.start_speculative_search(message)
            result = agent.run_agent(message, history)
            if mood.action == "acknowledge":
                # Sorry first, the answer, then the offer of a person. The
                # deltas carry the same words, so they still join to the reply.
                if emit is not None:
                    emit("delta", {"text": "\n\n" + frustration.OFFER})
                result.reply = f"{frustration.ACKNOWLEDGE}\n\n{result.reply}\n\n{frustration.OFFER}"
        body = result.to_dict()
    except Exception as exc:
        # Timings and names only: never the passenger's words (issue #11).
        _log_turn({
            "intent": intent,
            "streamed": emit is not None,
            "error": type(exc).__name__,
            "elapsed_ms": round((time.perf_counter() - started) * 1000),
        })
        print(f"[ERROR] {type(exc).__name__}: {str(exc)[:300]}", flush=True)
        raise
    body["suggestions"] = after_turn(trip or {}, body["events"])
    if mood.action == "acknowledge":
        body["suggestions"] = [{"label": "Talk to a person", "intent": "person"}] + [
            s for s in body["suggestions"] if s.get("intent") != "person"
        ][:2]
    body["frustration"] = mood.reasons or None
    # One line per turn in the service window: evidence for the NFR-02 latency
    # log without opening the browser's developer tools.
    t = body["timing"]
    tools = ",".join(c["name"] for c in body["tool_calls"]) or "-"
    print(
        f"[TIMING] total={t['total_ms']}ms first_token={t['first_token_ms']}ms "
        f"model={t['model_ms']} tools={t['tool_ms']} calls={t['model_calls']} used={tools}"
        + (f" intent={intent}" if intent else ""),
        flush=True,
    )
    _log_turn({
        "intent": intent,
        "streamed": emit is not None,
        "frustration": mood.action if mood.action != "none" else None,
        "steps": body["steps"],
        "tools": [c["name"] for c in body["tool_calls"]],
        "model": body["model"],
        "thinking_level": body["thinking_level"],
        **t,
    })
    return body


# Shared with the REST tier (main.AGENT_HISTORY_KEY).
AGENT_HISTORY_KEY = os.getenv("AGENT_HISTORY_KEY", "")


def save_turns(token: str, message: str, reply: str) -> None:
    """Both turns, to the booking's conversation on the REST tier, so the
    passenger can come back to it. Run after the reply has gone out; a
    failure loses only the memory, never the reply."""
    headers = {"Authorization": f"Bearer {token}"}
    try:
        for role, content in (("user", message), ("assistant", reply)):
            if not content:
                continue
            response = agent.http_client.post(
                f"{agent.FASTAPI_BASE_URL}/api/chat/history",
                json={"role": role, "content": content[:4000]},
                # The REST tier saves an assistant turn only with this key.
                headers={**headers, "X-Agent-Key": AGENT_HISTORY_KEY} if role == "assistant" else headers,
            )
            if response.status_code >= 400:
                print(f"[WARN] Conversation not saved: {response.status_code}", flush=True)
                return
    except Exception as exc:  # noqa: BLE001 - saving must never break a turn
        print(f"[WARN] Conversation not saved: {type(exc).__name__}", flush=True)


def _bearer(authorization: str | None) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing or malformed Authorization header.",
        )
    return authorization.removeprefix("Bearer ").strip()


@app.post("/api/chat")
async def chat(
    payload: ChatRequest,
    background: BackgroundTasks,
    authorization: str | None = Header(default=None),
):
    token = _bearer(authorization)
    # The REST tier is the authority on whether the token is valid; fetching
    # the trip first gives the client a clean 401 instead of a confused reply,
    # and gives the model the booking without a tool call.
    trip = await run_in_threadpool(briefing_for, token)
    try:
        body = await run_in_threadpool(
            _run, token, payload.message, [t.model_dump() for t in payload.history], trip, payload.intent
        )
    except Exception as exc:
        raise _http_error(exc) from exc
    background.add_task(save_turns, token, payload.message, body["reply"])
    return body


# Stream turns still running (see chat_stream).
_turns: set[asyncio.Task] = set()


def _sse(kind: str, data: dict) -> str:
    return f"event: {kind}\ndata: {json.dumps(data)}\n\n"


@app.post("/api/chat/stream")
async def chat_stream(payload: ChatRequest, authorization: str | None = Header(default=None)):
    """The same turn as /api/chat, as Server-Sent Events, in this order:
    `status` {text} when a tool starts; `delta` {text} as the reply is
    written; `event` {type, data} for each structured result; then `done`
    {reply, events, suggestions, timing} or `error` {status, detail}.
    A missing or expired session is a plain 401 before the stream starts."""
    token = _bearer(authorization)
    trip = await run_in_threadpool(briefing_for, token)
    history = [t.model_dump() for t in payload.history]
    loop = asyncio.get_running_loop()
    queue: asyncio.Queue[tuple[str, dict] | None] = asyncio.Queue()

    def emit(kind: str, data: dict) -> None:  # called from the worker thread
        loop.call_soon_threadsafe(queue.put_nowait, (kind, data))

    async def turn() -> None:
        try:
            body = await run_in_threadpool(
                _run, token, payload.message, history, trip, payload.intent, emit
            )
            queue.put_nowait(("done", {
                "reply": body["reply"],
                "events": body["events"],
                "suggestions": body["suggestions"],
                "timing": body["timing"],
            }))
        except Exception as exc:  # noqa: BLE001 - every failure becomes an error event
            error = _http_error(exc)
            queue.put_nowait(("error", {"status": error.status_code, "detail": error.detail}))
            return
        finally:
            queue.put_nowait(None)
        # After `done` has gone out: the passenger is not kept waiting for it.
        await run_in_threadpool(save_turns, token, payload.message, body["reply"])

    task = asyncio.create_task(turn())
    # Held until it finishes, so a passenger closing the page cannot leave
    # the turn (a rebooking, say) to the garbage collector (issue #23).
    _turns.add(task)
    task.add_done_callback(_turns.discard)

    async def events():
        # If the passenger closes the page, the turn still finishes in its
        # thread (a rebooking must not be cut in half); nothing more is sent.
        while (item := await queue.get()) is not None:
            yield _sse(*item)

    return StreamingResponse(
        events(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
