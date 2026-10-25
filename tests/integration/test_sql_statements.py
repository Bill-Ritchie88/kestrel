"""
Every SQL statement the REST tier sends is prepared against the live schema.

Preparing makes PostgreSQL resolve every table, column, function and
parameter type without running anything. It catches the class of defect the
unit tests cannot see because they use a fake connection: in Sprint 2 the
hand-off INSERT used its PNR parameter in two places that implied different
types, and the server refused it ("inconsistent types deduced for parameter
$1"), which would have broken every hand-off. Nothing is executed.
"""

import os

import asyncpg
import pytest

from kestrel import handoff
from kestrel.api import accounts, booking, history, main
from kestrel.policy import retriever

pytestmark = pytest.mark.integration

STATEMENTS = sorted(
    {
        (f"{module.__name__.rsplit('.', 1)[-1]}.{name}", getattr(module, name))
        for module in (handoff, booking, main, retriever, accounts, history)
        for name in dir(module)
        if name.startswith("SQL_") and isinstance(getattr(module, name), str)
    }
)


@pytest.fixture
async def conn():
    connection = await asyncpg.connect(os.environ["DATABASE_URL"], statement_cache_size=0)
    try:
        yield connection
    finally:
        await connection.close()


@pytest.mark.parametrize(("name", "sql"), STATEMENTS, ids=[n for n, _ in STATEMENTS])
async def test_statement_prepares_against_the_live_schema(conn, name, sql):
    # Tables from migrations applied by hand: skip, naming the migration.
    for table, migration in (("passenger_accounts", "009"), ("chat_messages", "010")):
        if table in sql and not await conn.fetchval(f"SELECT to_regclass('public.{table}')"):
            pytest.skip(f"{table} does not exist yet: apply migration {migration}")
    if "cancelled_at" in sql and not await conn.fetchval(
        "SELECT 1 FROM information_schema.columns WHERE table_name = 'flights' AND column_name = 'cancelled_at'"
    ):
        pytest.skip("flights.cancelled_at does not exist yet: apply migration 012")
    await conn.prepare(sql)
