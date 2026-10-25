"""The REST tier's database pool: opened warm, without the reset round trip."""

from contextlib import asynccontextmanager

import asyncpg

from kestrel.api import db


class CountingPool:
    def __init__(self):
        self.queries = []
        self.out = 0
        self.most = 0

    @asynccontextmanager
    async def acquire(self):
        import asyncio

        self.out += 1
        self.most = max(self.most, self.out)
        await asyncio.sleep(0.01)
        try:
            yield self
        finally:
            self.out -= 1

    async def fetchval(self, sql):
        self.queries.append(sql)
        return 1


async def test_pool_opens_with_four_ready_connections_and_proves_them(monkeypatch):
    seen = {}
    pool = CountingPool()

    async def create_pool(**kwargs):
        seen.update(kwargs)
        return pool

    monkeypatch.setenv("DATABASE_URL", "postgresql://example")
    monkeypatch.setattr(asyncpg, "create_pool", create_pool)
    try:
        assert await db.open_pool() is pool
    finally:
        db._pool = None

    # Four: GET /api/trip runs four queries at once.
    assert seen["min_size"] == 4 and seen["max_size"] == 10
    assert seen["statement_cache_size"] == 0  # Supabase pooler
    assert seen["reset"] is db._keep_session
    # SELECT 1 on four connections at once, before the first request.
    assert pool.queries == ["SELECT 1"] * 4
    assert pool.most == 4


async def test_the_pool_is_pinged_until_it_closes():
    import asyncio

    pool = CountingPool()
    task = asyncio.create_task(db.keep_warm(pool, every=0.01))
    # Waits for two rounds rather than a fixed time: a busy machine is slower.
    for _ in range(200):
        if len(pool.queries) >= 4 * 2:
            break
        await asyncio.sleep(0.01)
    task.cancel()
    assert len(pool.queries) >= 4 * 2  # at least two rounds of four


async def test_release_sends_no_reset_query():
    class Conn:
        async def execute(self, *a):
            raise AssertionError("no round trip on release")

    await db._keep_session(Conn())


async def test_keep_warm_survives_any_error():
    """Issue #17: InterfaceError, ConnectionDoesNotExistError or TimeoutError
    used to end the task for the rest of the process's life."""
    import asyncio

    import asyncpg

    class FlakyPool:
        def __init__(self):
            self.pings = 0

        def acquire(self):
            pool = self

            class Ctx:
                async def __aenter__(self):
                    pool.pings += 1
                    if pool.pings <= 4:
                        raise asyncpg.InterfaceError("connection is closed")
                    if pool.pings <= 8:
                        raise TimeoutError
                    return self

                async def __aexit__(self, *a):
                    return False

                async def fetchval(self, *a):
                    return 1

            return Ctx()

    pool = FlakyPool()
    task = asyncio.create_task(db.keep_warm(pool, every=0.005))
    for _ in range(400):
        if pool.pings > 12:
            break
        await asyncio.sleep(0.005)
    assert not task.done()  # still running after both kinds of failure
    task.cancel()
    assert pool.pings > 12
