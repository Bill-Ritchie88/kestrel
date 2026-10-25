"""
Latency measurement for the REST tier and the agent service (NFR-01, NFR-02).

Signs in as the demo booking, calls each passenger endpoint --rest-runs times
and asks the assistant each question --chat-runs times, then prints p50 / p90
/ max per call and writes a Markdown report.

    python scripts/evaluation/measure_latency.py
    python scripts/evaluation/measure_latency.py --label "Phase 2" --out docs/sprint-2/performance/2-warm-pool-trip-endpoint-gzip.md

DEMO_PNR / DEMO_SURNAME choose the booking (default A27Z99 / Edwards). Both
services must be running (.\\tasks.ps1 up). Nothing is rebooked; a question
the policies cannot answer may open a hand-off case, as it would for a
passenger. The agent service saves every turn to the booking's conversation
(GET /api/chat/history); if that was empty before the run, the script
deletes what the run added.

"wall" is what the client waited (network included); "app" is the REST tier's
own Server-Timing; "first" is the first of the runs, which pays for any cold
start (a new database connection, an empty cache).
"""

from __future__ import annotations

import argparse
import json
import math
import os
import platform
import statistics
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

import httpx

from kestrel import config  # noqa: F401  - loads .env

ROOT = Path(__file__).resolve().parents[2]

REST_CALLS = [
    ("GET /api/me", "/api/me"),
    ("GET /api/flights/alternatives", "/api/flights/alternatives"),
    ("GET /api/entitlements", "/api/entitlements"),
    ("GET /api/handoff", "/api/handoff"),
]
# Measured as well once it exists (Phase 2); skipped with a note before.
OPTIONAL_REST_CALLS = [("GET /api/trip", "/api/trip")]

QUESTIONS = [
    "What are my options?",
    "What am I entitled to?",
    "Can I get a refund instead?",
]

# The assistant's quick-reply chips (Phase 3): answered from the tool, no
# model. "Talk to a person" is left out: it would open a hand-off case.
QUICK_REPLIES = [
    ("Find me another flight", "alternatives"),
    ("What am I entitled to?", "entitlements"),
]


def percentile(values: list[float], p: float) -> float:
    """Nearest-rank percentile: p90 of ten runs is the ninth fastest."""
    ordered = sorted(values)
    return ordered[max(0, math.ceil(p / 100 * len(ordered)) - 1)]


class Row:
    def __init__(self, name: str):
        self.name = name
        self.wall: list[float] = []
        self.app: list[float] = []
        self.first_token: list[float] = []
        self.model_calls: list[int | None] = []
        self.errors: list[str] = []

    def error_text(self) -> str:
        return ", ".join(f"{e} x{self.errors.count(e)}" for e in dict.fromkeys(self.errors))

    def summary(self) -> dict:
        if not self.wall:
            return {"n": 0}
        return {
            "n": len(self.wall),
            "p50": statistics.median(self.wall),
            "p90": percentile(self.wall, 90),
            "max": max(self.wall),
            "first": self.wall[0],
            "app_p50": statistics.median(self.app) if self.app else None,
            "first_token_p50": statistics.median(self.first_token) if self.first_token else None,
            "first_token_p90": percentile(self.first_token, 90) if self.first_token else None,
            "model_calls": sorted({c for c in self.model_calls if c is not None}),
        }


def _server_ms(response: httpx.Response) -> float | None:
    header = response.headers.get("Server-Timing", "")
    for part in header.split(";"):
        if part.strip().startswith("dur="):
            return float(part.strip()[4:])
    return None


def sign_in(client: httpx.Client, api: str, pnr: str, surname: str) -> str:
    r = client.post(f"{api}/api/auth/session", json={"pnr_code": pnr, "last_name": surname})
    if r.status_code != 200:
        raise SystemExit(f"[ERROR] Sign-in as {pnr} failed ({r.status_code}): {r.text[:200]}")
    return r.json()["access_token"]


def measure_rest(client, api, headers, name, path, runs) -> Row:
    row = Row(name)
    for _ in range(runs):
        t0 = time.perf_counter()
        r = client.get(f"{api}{path}", headers=headers)
        wall = (time.perf_counter() - t0) * 1000
        if r.status_code != 200:
            row.errors.append(f"{r.status_code}")
            continue
        row.wall.append(wall)
        if (ms := _server_ms(r)) is not None:
            row.app.append(ms)
    return row



def measure_chat(client, agent_base, headers, question, runs, pause) -> Row:
    row = Row(f'Assistant: "{question}"')
    for _ in range(runs):
        time.sleep(pause)  # keeps the free tier's per-minute model quota
        t0 = time.perf_counter()
        try:
            r = client.post(
                f"{agent_base}/api/chat", json={"message": question}, headers=headers, timeout=90
            )
        except httpx.HTTPError as exc:
            row.errors.append(type(exc).__name__)
            continue
        wall = (time.perf_counter() - t0) * 1000
        if r.status_code != 200:
            row.errors.append(
                f"{r.status_code} quota" if "usage limit" in r.text else f"{r.status_code}"
            )
            continue
        row.wall.append(wall)
        timing = r.json().get("timing") or {}
        if timing.get("first_token_ms") is not None:
            row.first_token.append(timing["first_token_ms"])
        row.model_calls.append(timing.get("model_calls"))
    return row


def _sse_events(response: httpx.Response):
    """(event, data) pairs from a Server-Sent Events response, as they arrive."""
    kind = None
    for line in response.iter_lines():
        if not line:
            kind = None
            continue
        if line.startswith("event:"):
            kind = line[6:].strip()
        elif line.startswith("data:") and kind:
            yield kind, json.loads(line[5:].strip())


def measure_stream(client, agent_base, headers, question, runs, pause, intent=None) -> Row:
    """POST /api/chat/stream: the time to the first words the passenger sees
    (first `delta`) and to the whole answer (`done`)."""
    label = f'Quick reply: "{question}" ({intent})' if intent else f'Streamed: "{question}"'
    row = Row(label)
    body = {"message": question, **({"intent": intent} if intent else {})}
    for _ in range(runs):
        time.sleep(pause)
        t0 = time.perf_counter()
        first = None
        try:
            with client.stream(
                "POST", f"{agent_base}/api/chat/stream", json=body, headers=headers, timeout=90
            ) as r:
                if r.status_code != 200:
                    r.read()
                    row.errors.append(
                        f"{r.status_code} quota" if "usage limit" in r.text else f"{r.status_code}"
                    )
                    continue
                outcome = None
                for kind, data in _sse_events(r):
                    if kind == "delta" and first is None:
                        first = (time.perf_counter() - t0) * 1000
                    if kind in ("done", "error"):
                        outcome = (kind, data)
        except httpx.HTTPError as exc:
            row.errors.append(type(exc).__name__)
            continue
        wall = (time.perf_counter() - t0) * 1000
        if outcome is None or outcome[0] == "error":
            detail = (outcome or ("", {}))[1]
            row.errors.append(
                f"{detail.get('status', 'cut')} quota" if "usage limit" in str(detail) else
                f"{detail.get('status', 'cut off')}"
            )
            continue
        row.wall.append(wall)
        row.first_token.append(first if first is not None else wall)
        row.model_calls.append(outcome[1].get("timing", {}).get("model_calls"))
    return row


def _fmt(v: float | None) -> str:
    return "-" if v is None else f"{v:,.0f}"


def report(rows: list[Row], meta: dict) -> str:
    lines = [
        f"# Kestrel latency - {meta['label']}",
        "",
        f"Measured {meta['at']} with `scripts/evaluation/measure_latency.py` on {meta['host']}.",
        f"REST tier {meta['api']}, agent service {meta['agent']}; booking {meta['pnr']} "
        f"({meta['booking_status']}). REST calls x{meta['rest_runs']}, assistant questions "
        f"x{meta['chat_runs']} ({meta['chat_pause']:.0f} s apart, for the model's per-minute "
        "quota), one after another over one keep-alive connection.",
        "",
        f"Assistant model: `{meta['model']}`.",
        "",
        "All times in milliseconds. *wall*: what the client waited (for a streamed reply, "
        "until `done`). *app*: the REST tier's own time (Server-Timing). *first*: the first run, "
        "which pays any cold start. *first words*: streamed - when the first `delta` reached "
        "the client; not streamed - when the reply text would start (agent `first_token_ms`). "
        "*calls*: model calls per turn.",
        "",
        "| Call | n | p50 | p90 | max | first | app p50 | first words p50 / p90 | calls | errors |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]
    for row in rows:
        s = row.summary()
        errors = row.error_text()
        if s["n"] == 0:
            lines.append(f"| {row.name} | 0 | - | - | - | - | - | - | - | {errors or 'not run'} |")
            continue
        words = (
            f"{_fmt(s['first_token_p50'])} / {_fmt(s['first_token_p90'])}"
            if s["first_token_p50"] is not None else "-"
        )
        calls = ", ".join(str(c) for c in s["model_calls"]) or "-"
        lines.append(
            f"| {row.name} | {s['n']} | {_fmt(s['p50'])} | {_fmt(s['p90'])} | {_fmt(s['max'])} "
            f"| {_fmt(s['first'])} | {_fmt(s['app_p50'])} | {words} | {calls} | {errors} |"
        )
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Measure Kestrel's REST and assistant latency.")
    parser.add_argument("--api", default=os.getenv("FASTAPI_BASE_URL", "http://127.0.0.1:8000"))
    parser.add_argument("--agent", default=os.getenv("AGENT_BASE_URL", "http://127.0.0.1:8001"))
    parser.add_argument("--rest-runs", type=int, default=10)
    parser.add_argument("--chat-runs", type=int, default=3)
    parser.add_argument(
        "--chat-pause",
        type=float,
        default=15,
        help="seconds between assistant questions; a turn makes about two model calls",
    )
    parser.add_argument("--stream-runs", type=int, default=0,
                        help="also ask each question this many times over /api/chat/stream")
    parser.add_argument("--quick-runs", type=int, default=0,
                        help="also send each quick reply (intent, no model) this many times")
    parser.add_argument("--label", default="baseline")
    parser.add_argument("--out", default=str(ROOT / "docs" / "sprint-2" / "performance" / "0-baseline.md"))
    args = parser.parse_args(argv)

    pnr = os.getenv("DEMO_PNR", "A27Z99")
    surname = os.getenv("DEMO_SURNAME", "Edwards")
    rows: list[Row] = []
    with httpx.Client(timeout=30) as client:
        try:
            token = sign_in(client, args.api, pnr, surname)
        except httpx.HTTPError as exc:
            print(f"[ERROR] The REST tier at {args.api} is not reachable ({type(exc).__name__}).")
            print("        Start both services first: .\\tasks.ps1 up")
            return 1
        headers = {"Authorization": f"Bearer {token}"}
        status = client.get(f"{args.api}/api/me", headers=headers).json().get("booking_status")
        print(f"[INFO] Signed in as {pnr} ({status}).")
        saved = client.get(f"{args.api}/api/chat/history", headers=headers)
        clean_up = saved.status_code == 200 and not saved.json().get("turns")

        for name, path in REST_CALLS:
            rows.append(measure_rest(client, args.api, headers, name, path, args.rest_runs))
        for name, path in OPTIONAL_REST_CALLS:
            if client.get(f"{args.api}{path}", headers=headers).status_code == 404:
                continue
            rows.append(measure_rest(client, args.api, headers, name, path, args.rest_runs))
        for question in QUESTIONS if args.chat_runs > 0 else ():
            print(f"[INFO] Asking: {question}")
            rows.append(
                measure_chat(client, args.agent, headers, question, args.chat_runs, args.chat_pause)
            )
        for question in QUESTIONS if args.stream_runs > 0 else ():
            print(f"[INFO] Asking (streamed): {question}")
            rows.append(measure_stream(
                client, args.agent, headers, question, args.stream_runs, args.chat_pause
            ))
        for question, intent in QUICK_REPLIES if args.quick_runs > 0 else ():
            print(f"[INFO] Quick reply: {question}")
            rows.append(measure_stream(
                client, args.agent, headers, question, args.quick_runs, 0.2, intent=intent
            ))
        try:
            model = client.get(f"{args.agent}/health", timeout=5).json().get("model")
        except (httpx.HTTPError, ValueError):
            model = "unknown"
        if clean_up:
            time.sleep(1)  # the last turn is saved just after its reply
            client.delete(f"{args.api}/api/chat/history", headers=headers)
        elif saved.status_code == 200:
            print("[INFO] The booking already had a saved conversation; this run's turns were added to it.")

    print(f"\n{'Call':<52} {'n':>3} {'p50':>7} {'p90':>7} {'max':>7} {'first':>7}")
    for row in rows:
        s = row.summary()
        if s["n"] == 0:
            print(f"{row.name:<52} {0:>3}  errors: {row.error_text()}")
            continue
        print(
            f"{row.name:<52} {s['n']:>3} {s['p50']:>7.0f} {s['p90']:>7.0f} "
            f"{s['max']:>7.0f} {s['first']:>7.0f}"
            + (f"   errors: {row.error_text()}" if row.errors else "")
        )

    meta = {
        "label": args.label,
        "at": datetime.now(UTC).astimezone().strftime("%Y-%m-%d %H:%M %Z"),
        "host": f"{platform.system()} {platform.release()}, Python {platform.python_version()}",
        "api": args.api,
        "agent": args.agent,
        "pnr": pnr,
        "booking_status": status,
        "rest_runs": args.rest_runs,
        "chat_runs": args.chat_runs,
        "chat_pause": args.chat_pause,
        "model": model,
    }
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(report(rows, meta), encoding="utf-8", newline="\n")
    print(f"\n[INFO] Written to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
