"""
Database connection pool for the REST tier.

Endpoints receive the pool through the get_pool() dependency rather than a
module global, so the endpoint tests can substitute a fake pool with
app.dependency_overrides and run without a database.

Measured from the workstation (Nairobi) to Supabase (Frankfurt): opening a
connection takes 2-4 s, a query about 390 ms (two round trips: prepare, then
execute), and asyncpg's default reset query on every release another 190 ms.
So the pool is opened and proven at start-up, keeps four connections ready
(GET /api/trip runs four queries at once; with three, the first trip request
after start-up opened the fourth and took 4.8 s), pings them every minute so
asyncpg's five-minute idle timeout never closes them, and skips the reset
query (see _keep_session).
"""

from __future__ import annotations

import asyncio
import os

import asyncpg
from fastapi import HTTPException, status

from kestrel import config  # noqa: F401  - loads .env before anything reads it

_pool: asyncpg.Pool | None = None

# /api/trip runs four queries at once, each on its own connection.
POOL_MIN_SIZE = 4
POOL_MAX_SIZE = 10
# asyncpg closes a connection left idle for max_inactive_connection_lifetime
# (300 s), even within min_size, and reopens it only when next needed.
KEEP_WARM_SECONDS = 60


async def _keep_session(conn: asyncpg.Connection) -> None:
    """Reset on release, without the round trip.

    asyncpg itself rolls back a transaction left open before calling this.
    Its default reset then sends `SELECT pg_advisory_unlock_all(); CLOSE ALL;
    UNLISTEN *; RESET ALL;` on every release, a round trip each time. The
    API never takes advisory locks, opens cursors, listens or changes
    settings, so there is nothing for it to undo.
    """


async def warm(pool: asyncpg.Pool, connections: int = POOL_MIN_SIZE) -> None:
    """Run SELECT 1 on each ready connection, all at once, so the first
    passenger request finds them open and proven."""

    async def ping() -> None:
        async with pool.acquire() as conn:
            await conn.fetchval("SELECT 1")

    await asyncio.gather(*(ping() for _ in range(connections)))


async def keep_warm(pool: asyncpg.Pool, every: float = KEEP_WARM_SECONDS) -> None:
    """Ping the ready connections every minute, for the life of the pool, so
    a passenger arriving after a quiet spell finds them open."""
    while True:
        await asyncio.sleep(every)
        try:
            await warm(pool)
        except Exception as exc:  # noqa: BLE001 - any failure: try again next minute
            # InterfaceError, ConnectionDoesNotExistError or TimeoutError must
            # not end the task for the rest of the process's life (issue #17).
            # Cancellation still stops it: CancelledError is not an Exception.
            print(f"[WARN] Keeping the database pool warm failed: {type(exc).__name__}: {exc}")


async def open_pool() -> asyncpg.Pool | None:
    """Create and warm the pool at startup. Without DATABASE_URL the API
    still starts (so /docs and /health work) and every database endpoint
    answers 503."""
    global _pool
    dsn = os.getenv("DATABASE_URL")
    if not dsn:
        print("[WARN] DATABASE_URL is not set - database endpoints will return 503.")
        return None
    _pool = await asyncpg.create_pool(
        dsn=dsn,
        min_size=POOL_MIN_SIZE,
        max_size=POOL_MAX_SIZE,
        statement_cache_size=0,  # required for asyncpg behind a Supabase pooler
        reset=_keep_session,
    )
    await warm(_pool)
    return _pool


async def close_pool() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None


def pool_is_open() -> bool:
    return _pool is not None


def get_pool() -> asyncpg.Pool:
    if _pool is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Database connection pool unavailable.",
        )
    return _pool
