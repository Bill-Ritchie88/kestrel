"""
Timing logs, one JSON object per line.

Both services append their evidence for the latency log here: the agent
service one line per chat turn (logs/agent-turns.jsonl), the REST tier one
line per request (logs/api-requests.jsonl). KESTREL_LOG_DIR moves the folder;
the test suite points it at a temporary one.

LOG_TO_STDOUT=1 prints each line to standard output instead, with a "log"
field naming the file it would have gone to: a container has no persistent
disk, and Cloud Run and Fly.io collect standard output.

Records hold timings and identifiers only, never request bodies or tokens.
"""

from __future__ import annotations

import json
import os
from datetime import UTC, datetime
from pathlib import Path

LOG_DIR = Path(os.getenv("KESTREL_LOG_DIR", Path(__file__).resolve().parents[2] / "logs"))


def to_stdout() -> bool:
    return os.getenv("LOG_TO_STDOUT", "").strip().lower() in ("1", "true", "yes")


def append(log_dir: Path, filename: str, record: dict) -> None:
    """Append one record, stamped with the time. Never raises: logging must
    not break a passenger's request."""
    record = {"at": datetime.now(UTC).isoformat(timespec="seconds"), **record}
    if to_stdout():
        print(json.dumps({"log": filename.removesuffix(".jsonl"), **record}), flush=True)
        return
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
        with (log_dir / filename).open("a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")
    except OSError:
        pass
