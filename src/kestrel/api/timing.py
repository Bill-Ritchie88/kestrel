"""
Request timing for the REST tier.

Every response carries `Server-Timing: app;dur=<ms>` (the time the API spent
before it started answering), which the browser's developer tools show under
Network -> Timing, and every request adds one line to logs/api-requests.jsonl:

    {"at": ..., "method": "GET", "path": "/api/staff/cases/{case_id}/resolve",
     "status": 200, "ms": 41.7}

The path is the route's template, so case numbers, flight ids and booking
references never reach the log; a path no route matched keeps only the
words the app's own routes use, every other segment becomes {id} (an
all-letter booking reference included). No query strings, bodies or tokens.

A plain ASGI middleware rather than @app.middleware("http"), which would
buffer the response body.
"""

from __future__ import annotations

import asyncio
import time
from pathlib import Path

from starlette.datastructures import MutableHeaders
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from kestrel import jsonlog

LOG_FILE = "api-requests.jsonl"


_known_words: dict[int, frozenset[str]] = {}


def _route_words(app) -> frozenset[str]:
    """The literal segments of the app's own route templates ("api",
    "staff", "cases", ...), worked out once per app."""
    words = _known_words.get(id(app))
    if words is None:
        words = frozenset(
            seg
            for route in getattr(app, "routes", ())
            for seg in getattr(route, "path", "").split("/")
            if seg and "{" not in seg
        )
        _known_words[id(app)] = words
    return words


def masked_path(scope: Scope) -> str:
    route = scope.get("route")
    template = getattr(route, "path", None)
    if template:
        return template
    # No route matched: anything that is not one of the app's own words may
    # be a booking reference, all letters or not (issue #39).
    known = _route_words(scope.get("app"))
    segments = scope.get("path", "").split("/")
    return "/".join(s if not s or s in known else "{id}" for s in segments)


class RequestTimingMiddleware:
    def __init__(self, app: ASGIApp, log_dir: Path | None = None):
        self.app = app
        self.log_dir = log_dir

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        started = time.perf_counter()
        status = 500

        async def timed_send(message: Message) -> None:
            nonlocal status
            if message["type"] == "http.response.start":
                status = message["status"]
                ms = (time.perf_counter() - started) * 1000
                MutableHeaders(scope=message).append("Server-Timing", f"app;dur={ms:.1f}")
            await send(message)

        try:
            await self.app(scope, receive, timed_send)
        finally:
            # A file write in a worker thread: other requests never wait on
            # the disk (issue #27).
            await asyncio.to_thread(
                jsonlog.append,
                self.log_dir or jsonlog.LOG_DIR,
                LOG_FILE,
                {
                    "method": scope.get("method"),
                    "path": masked_path(scope),
                    "status": status,
                    "ms": round((time.perf_counter() - started) * 1000, 1),
                },
            )
