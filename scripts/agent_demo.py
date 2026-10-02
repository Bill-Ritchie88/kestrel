"""
Project Kestrel - agent demonstration.

Runs the agent end to end for a passenger who is genuinely disrupted and has
somewhere to go. The agent cannot find such a passenger itself - it has no
database access, by design - so this script does the lookup (resetting the
demo data first if it has gone stale) and hands the PNR and surname to
kestrel.agent.

Requires the REST tier to be running (make api / .\\tasks.ps1 api).

    python scripts/agent_demo.py
    python scripts/agent_demo.py --prompt "What are my options?"

The agent may rebook the passenger, which uses up part of the disruption. That
is the point of the demonstration; the next run resets when nothing usable is
left.
"""

import argparse
import asyncio
import os
import sys

import asyncpg

from reset_demo import ensure_fresh


async def pick_passenger() -> asyncpg.Record:
    conn = await asyncpg.connect(os.environ["DATABASE_URL"], statement_cache_size=0)
    try:
        return await ensure_fresh(conn)
    finally:
        await conn.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the agent for a disrupted passenger.")
    parser.add_argument("--prompt", help="What the passenger asks (default: rebook me)")
    args = parser.parse_args()

    # reset_demo has already loaded .env by the time it is imported.
    if not os.getenv("DATABASE_URL"):
        print("[ERROR] DATABASE_URL is not set. Copy .env.example to .env first.")
        return 1

    try:
        case = asyncio.run(pick_passenger())
    except (asyncpg.PostgresError, OSError, RuntimeError) as exc:
        print(f"[ERROR] {type(exc).__name__}: {exc}")
        return 1

    print(
        f"[DEMO] PNR {case['pnr_code']} / {case['last_name']}, "
        f"disrupted on {case['origin']}-{case['destination']}"
    )

    from kestrel import agent  # imported late: it needs GOOGLE_API_KEY at import time

    argv = ["--pnr", case["pnr_code"], "--last-name", case["last_name"]]
    if args.prompt:
        argv += ["--prompt", args.prompt]
    agent.main(argv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
