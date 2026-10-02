"""
Shared test fixtures.

auth.py reads SESSION_SECRET at import time, so it has to be in the
environment before the module is imported anywhere in the test session. That
is why this is done at module scope rather than in a fixture.
"""

import os

import pytest

# A fixed secret makes token tests deterministic and stops auth.py from
# printing its "using a random secret" warning during the run.
os.environ.setdefault("SESSION_SECRET", "test-secret-not-used-anywhere-real")

# Load .env now, so whether integration tests run depends only on whether a
# DATABASE_URL is configured - not on which other test modules happened to
# import kestrel first. Values already in the environment (above) still win.
import kestrel.config  # noqa: E402, F401


def pytest_collection_modifyitems(config, items):
    """Skip integration tests unless a database is configured.

    The suite must pass on a machine with no credentials - that is what makes
    it runnable in CI, where no DATABASE_URL exists.
    """
    if os.getenv("DATABASE_URL"):
        return
    skip = pytest.mark.skip(reason="DATABASE_URL is not set; integration tests skipped")
    for item in items:
        if "integration" in item.keywords:
            item.add_marker(skip)


@pytest.fixture
def session_kwargs():
    return {
        "pnr_code": "S958PC",
        "passenger_id": "c2eebc99-9c0b-4ef8-bb6d-6bb9bd380a33",
        "last_name": "Whitehead",
        "rewards_tier": "GOLD",
    }
