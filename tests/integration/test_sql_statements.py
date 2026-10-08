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
from kestrel.api import booking, main
from kestrel.policy import retriever

pytestmark = pytest.mark.integration

STATEMENTS = sorted(
    {
        (f"{module.__name__.rsplit('.', 1)[-1]}.{name}", getattr(module, name))
        for module in (handoff, booking, main, retriever)
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
    await conn.prepare(sql)
