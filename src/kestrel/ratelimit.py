"""
Project Kestrel - rate limits on chat and sign-in (NFR-05).

A token bucket per caller: a bucket holds up to `burst` requests and refills
at `per_minute` a minute; a request with no token left is 429 with
Retry-After (whole seconds). Chat routes are keyed by the bearer token, so one
passenger cannot use up the free Gemini quota for everyone; sign-in routes are
unauthenticated, so they are keyed by the client's IP address.

The sign-in throttle in api/auth.py (5 failed attempts per booking reference
or account) stays: it stops guessing at one booking, while this stops one
address spraying requests across many.

A plain ASGI middleware, like api/timing.py: @app.middleware("http") would
buffer the streamed chat reply.
"""

from __future__ import annotations

import hmac
import math
import time
from collections import OrderedDict
from typing import Protocol

from starlette.datastructures import Headers
from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

# Swapped in the tests to move time forward.
clock = time.monotonic


class BucketStore(Protocol):
    """Where the buckets live. A Redis store with the same method could
    replace MemoryStore to share limits between instances."""

    def take(self, key: str, now: float) -> float:
        """Spend one request for `key`: 0 if allowed, else the seconds until
        the next one is."""
        ...


class MemoryStore:
    """Buckets in this process's memory, least recently used first.

    shortcut: per-process state, so each Render instance or uvicorn worker
    has its own buckets (N workers let a caller through N times as often);
    move to a shared store (Redis) before running more than one.
    """

    def __init__(self, per_minute: float = 20, burst: int = 5, max_keys: int = 10_000):
        self.rate = per_minute / 60  # requests a second
        self.burst = burst
        self.max_keys = max_keys
        self._buckets: OrderedDict[str, tuple[float, float]] = OrderedDict()  # key -> (tokens, at)

    def take(self, key: str, now: float) -> float:
        tokens, at = self._buckets.pop(key, (self.burst, now))
        tokens = min(self.burst, tokens + (now - at) * self.rate)
        wait = 0.0 if tokens >= 1 else (1 - tokens) / self.rate
        self._buckets[key] = (tokens - 1 if wait == 0 else tokens, now)
        # Memory stays bounded: the bucket idle longest goes first (an idle
        # bucket has refilled, so dropping it changes nothing for its caller).
        while len(self._buckets) > self.max_keys:
            self._buckets.popitem(last=False)
        return wait

    def clear(self) -> None:
        self._buckets.clear()


# One store per kind of route; the REST tier and the agent service each have
# their own copy, being separate processes.
CHAT = MemoryStore(per_minute=20, burst=5)
# A burst of 10, so for one booking the sign-in throttle (5 failures) answers
# first, with its own message.
SIGN_IN = MemoryStore(per_minute=20, burst=10)


def client_ip(scope: Scope, headers: Headers) -> str:
    """The caller's address. Behind Render's proxy that is the first hop of
    X-Forwarded-For. The client can write that header itself, so a caller
    who changes it on every request escapes the per-IP limit (not the
    per-token one); trusting the last hop the proxy appended would close
    that, at the cost of tying the code to one proxy's behaviour."""
    forwarded = headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    client = scope.get("client")
    return client[0] if client else "unknown"


def slow_down_message(seconds: int) -> str:
    unit = "second" if seconds == 1 else "seconds"
    return f"You're sending messages quickly. Please wait {seconds} {unit} and try again."


class RateLimitMiddleware:
    """`rules`: (path prefix, store, keyed by token?). The first matching
    prefix applies. A request carrying `agent_key` as X-Agent-Key (the agent
    service saving a conversation) is not counted: the passenger's turn was
    already counted by the agent service."""

    def __init__(
        self,
        app: ASGIApp,
        rules: list[tuple[str, BucketStore, bool]],
        agent_key: str | None = None,
    ):
        self.app = app
        self.rules = rules
        self.agent_key = agent_key

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope.get("method") == "OPTIONS":
            await self.app(scope, receive, send)
            return
        path = scope.get("path", "")
        rule = next((r for r in self.rules if path.startswith(r[0])), None)
        if rule is None:
            await self.app(scope, receive, send)
            return
        headers = Headers(scope=scope)
        if self.agent_key and hmac.compare_digest(
            headers.get("x-agent-key", "").encode(), self.agent_key.encode()
        ):
            await self.app(scope, receive, send)
            return
        _, store, by_token = rule
        auth = headers.get("authorization", "")
        if by_token and auth.startswith("Bearer "):
            key = "token:" + auth.removeprefix("Bearer ").strip()
        else:
            key = "ip:" + client_ip(scope, headers)
        wait = store.take(key, clock())
        if wait:
            seconds = max(1, math.ceil(wait))
            response = JSONResponse(
                {"detail": slow_down_message(seconds)},
                status_code=429,
                headers={"Retry-After": str(seconds)},
            )
            await response(scope, receive, send)
            return
        await self.app(scope, receive, send)
