"""
Database connection pool for the REST tier.

Endpoints receive the pool through the get_pool() dependency rather than a
module global, so the endpoint tests can substitute a fake pool with
app.dependency_overrides and run without a database.
"""

from __future__ import annotations

import os

import asyncpg
from fastapi import HTTPException, status

from kestrel import config  # noqa: F401  - loads .env before anything reads it

_pool: asyncpg.Pool | None = None


async def open_pool() -> asyncpg.Pool | None:
    """Create the pool at startup. Without DATABASE_URL the API still starts
    (so /docs and /health work) and every database endpoint answers 503."""
    global _pool
    dsn = os.getenv("DATABASE_URL")
    if not dsn:
        print("[WARN] DATABASE_URL is not set - database endpoints will return 503.")
        return None
    _pool = await asyncpg.create_pool(
        dsn=dsn,
        min_size=1,
        max_size=5,
        statement_cache_size=0,  # required for asyncpg behind a Supabase pooler
    )
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
