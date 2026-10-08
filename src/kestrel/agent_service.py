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
"""

from __future__ import annotations

import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, Header, HTTPException, status
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from kestrel import __version__, agent, config  # noqa: F401  - config loads .env first


@asynccontextmanager
async def lifespan(app: FastAPI):
    # The agent tier holds no database credentials. Removed when the server
    # starts rather than at import, so importing this module in the test
    # suite does not hide DATABASE_URL from the integration tests.
    os.environ.pop("DATABASE_URL", None)
    yield


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


@app.get("/health")
def health():
    return {
        "status": "online",
        "version": __version__,
        "model": agent.GEMINI_MODEL,
        "rest_tier": agent.FASTAPI_BASE_URL,
    }


def _run(token: str, message: str, history: list[dict]) -> dict:
    # Runs in a worker thread with its own copy of the request context, so the
    # token bound here is visible to this conversation's tool calls only.
    agent.bind_token(token)
    body = agent.run_agent(message, history).to_dict()
    # One line per turn in the service window: evidence for the NFR-02 latency
    # log without opening the browser's developer tools.
    t = body["timing"]
    tools = ",".join(c["name"] for c in body["tool_calls"]) or "-"
    print(
        f"[TIMING] total={t['total_ms']}ms model={t['model_ms']} tools={t['tool_ms']} "
        f"calls={t['model_calls']} used={tools}",
        flush=True,
    )
    return body


@app.post("/api/chat")
async def chat(payload: ChatRequest, authorization: str | None = Header(default=None)):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing or malformed Authorization header.",
        )
    token = authorization.removeprefix("Bearer ").strip()
    # The REST tier is the authority on whether the token is valid; checking
    # here first gives the client a clean 401 instead of a confused reply.
    me = await run_in_threadpool(
        agent.http_client.get,
        f"{agent.FASTAPI_BASE_URL}/api/me",
        headers={"Authorization": f"Bearer {token}"},
    )
    if me.status_code == 401:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Session expired.")
    if me.status_code != 200:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY, detail="REST tier unavailable."
        )
    try:
        return await run_in_threadpool(
            _run, token, payload.message, [t.model_dump() for t in payload.history]
        )
    except ValueError as exc:  # missing API key
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc
