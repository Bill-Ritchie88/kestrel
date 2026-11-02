"""
Unit tests for the pure parts of the load-test harness (NFR-01, NFR-03):
the percentile, the post-condition checks and the fixture cleanup queries.

No database: the harness is loaded from scripts/evaluation by path.
"""

import importlib.util
import math
import re
from pathlib import Path

import pytest

PATH = Path(__file__).resolve().parents[2] / "scripts" / "evaluation" / "load_test.py"


@pytest.fixture(scope="module")
def lt():
    spec = importlib.util.spec_from_file_location("load_test", PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_percentile_nearest_rank(lt):
    values = [i / 100 for i in range(1, 51)]  # 0.01 .. 0.50
    assert lt.percentile(values, 95) == 0.48  # ceil(0.95 * 50) = 48th smallest
    assert lt.percentile(values, 50) == 0.25
    assert lt.percentile(values, 100) == 0.50
    assert lt.percentile([0.7], 95) == 0.7
    assert lt.percentile([3.0, 1.0, 2.0], 50) == 2.0  # order of input does not matter


def _facts(**overrides):
    facts = {
        "duplicate_seats": 0,
        "rebooked": 2,
        "booked_seats": 2,
        "seats_held": 2,
        "audit_rows": 4,
    }
    return facts | overrides


def _calls(lt, ok=2, refused=2, message=None):
    message = message or lt.NO_SEAT
    return [lt.Call(True, "ok", 0.1) for _ in range(ok)] + [
        lt.Call(False, message, 0.1) for _ in range(refused)
    ]


def test_evaluate_run_all_pass(lt):
    checks = lt.evaluate_run(_calls(lt), 4, 2, _facts(), deadlocks=0)
    assert all(checks.values()), checks


@pytest.mark.parametrize(
    ("facts", "failed"),
    [
        ({"duplicate_seats": 1}, "no_duplicate_seats"),
        ({"rebooked": 3}, "successes_eq_s"),
        ({"booked_seats": 3}, "seats_conserved"),
        ({"audit_rows": 3}, "audit_one_per_call"),
    ],
)
def test_evaluate_run_database_facts(lt, facts, failed):
    checks = lt.evaluate_run(_calls(lt), 4, 2, _facts(**facts), deadlocks=0)
    assert [k for k, v in checks.items() if not v] == [failed]


def test_evaluate_run_call_results(lt):
    # Too many successes: an over-allocation, whatever the database says.
    assert not lt.evaluate_run(_calls(lt, 3, 1), 4, 2, _facts(), 0)["successes_eq_s"]
    # A refusal that is not "no seat" (e.g. a dropped connection) fails.
    checks = lt.evaluate_run(_calls(lt, message="InterfaceError"), 4, 2, _facts(), 0)
    assert not checks["refusals_are_no_seat"]
    # A missing call fails.
    assert not lt.evaluate_run(_calls(lt, 2, 1), 4, 2, _facts(audit_rows=3), 0)[
        "all_calls_returned"
    ]


def test_evaluate_run_deadlocks(lt):
    assert not lt.evaluate_run(_calls(lt), 4, 2, _facts(), deadlocks=1)["no_deadlock"]
    # Counter not readable: a DeadlockDetectedError still counts.
    calls = _calls(lt, 2, 1) + [lt.Call(False, lt.NO_SEAT, math.nan, deadlock=True)]
    assert not lt.evaluate_run(calls, 4, 2, _facts(), deadlocks=None)["no_deadlock"]
    assert lt.evaluate_run(_calls(lt), 4, 2, _facts(), deadlocks=None)["no_deadlock"]


def _like(pattern: str, value: str) -> bool:
    """SQL LIKE with % only (the patterns use no _ or escapes)."""
    assert "_" not in pattern
    return re.fullmatch(".*".join(map(re.escape, pattern.split("%"))), value) is not None


def test_cleanup_children_first_and_parameterised(lt):
    statements = lt.cleanup_statements()
    tables = [re.match(r"DELETE FROM (\w+)", sql).group(1) for sql, _ in statements]
    assert tables == [
        "audit_logs",
        "vouchers",
        "handoff_cases",
        "chat_messages",
        "pnr_bookings",
        "passenger_accounts",
        "passengers",
        "flights",
    ]
    for sql, args in statements:
        # Every value is a bind parameter, and every placeholder has one.
        assert "'" not in sql
        assert len(set(re.findall(r"\$\d", sql))) == len(args)


def test_cleanup_patterns_select_only_the_fixture(lt):
    # A real PNR always starts with a letter (generate_dataset.make_pnr).
    assert _like(lt.PNR_LIKE, "9L0199")
    for real in ("A27Z99", "ZPEJBL", "UNGMR3", "QW3UYQ", "LT24WM"):
        assert not _like(lt.PNR_LIKE, real)
    assert _like(lt.EMAIL_LIKE, "loadtest+i200r3-17@example.invalid")
    assert not _like(lt.EMAIL_LIKE, "loadtest@example.com")
    assert _like(lt.FLIGHT_LIKE, "LT9001")
    assert not _like(lt.FLIGHT_LIKE, "KQ9001")
    # Flights are deleted only on the invented route as well.
    sql, args = lt.cleanup_statements()[-1]
    assert "destination = $2" in sql and args == (lt.FLIGHT_LIKE, "LTX")


def test_row_for_request_without_response(lt):
    # API run 7, 30 Oct: one request timed out client-side, so it had no status.
    run = lt.Run("api", 3, 1, 1, 0)
    run.calls = [
        lt.Call(True, "ok", 0.5, 200),
        lt.Call(False, lt.NO_SEAT, 0.6, 409),
        lt.Call(False, "ReadTimeout", math.nan),
    ]
    run.checks = lt.evaluate_run(run.calls, 3, 1, _facts(rebooked=1, audit_rows=3), 0)
    row = lt.row_for(run)
    assert row["statuses"] == "200 x1; 409 x1; None x1"
    assert row["max_ms"] == "600" and not row["passed"]
    assert "refusals_are_no_seat" in row["failed_checks"]
