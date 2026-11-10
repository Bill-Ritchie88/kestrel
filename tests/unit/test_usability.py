"""
Unit tests for the usability-test kit (Sprint III, FR-08): SUS scoring and
the results report (scripts/evaluation/score_usability.py), and the pure
planning in scripts/data/create_usability_bookings.py.

No database: both scripts are loaded by path.
"""

import importlib.util
import re
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def score():
    return _load("score_usability", SCRIPTS / "evaluation" / "score_usability.py")


@pytest.fixture(scope="module")
def ub():
    return _load("create_usability_bookings", SCRIPTS / "data" / "create_usability_bookings.py")


# -- SUS scoring --------------------------------------------------------------


def test_sus_all_threes_is_50(score):
    assert score.sus_score([3] * 10) == 50


def test_sus_best_answers_is_100_and_worst_is_0(score):
    assert score.sus_score([5, 1] * 5) == 100  # agree with odd items, disagree with even
    assert score.sus_score([1, 5] * 5) == 0


def test_sus_mixed_example(score):
    # odd: 4,4,4,4,4 -> 3 each = 15; even: 2,2,2,2,2 -> 3 each = 15; 30 * 2.5
    assert score.sus_score([4, 2] * 5) == 75


@pytest.mark.parametrize("answers", [[3] * 9, [3] * 11, [0] + [3] * 9, [6] + [3] * 9])
def test_sus_rejects_incomplete_or_out_of_range(score, answers):
    with pytest.raises(ValueError):
        score.sus_score(answers)


def test_mean_and_sample_sd(score):
    mean, sd = score.mean_sd([50.0, 100.0])
    assert mean == 75
    assert sd == pytest.approx(35.355, abs=1e-3)  # sample SD (n - 1), not population (25)
    assert score.mean_sd([70.0]) == (70.0, None)
    assert score.mean_sd([]) == (None, None)


def test_parse_time_accepts_seconds_and_minutes(score):
    assert score.parse_time("75") == 75
    assert score.parse_time("1:15") == 75
    assert score.parse_time("  ") is None
    assert score.mmss(75) == "1:15"


def test_report_from_filled_sheets(score, tmp_path):
    tasks = tmp_path / "tasks.csv"
    tasks.write_text(
        "participant,device,browser,task,task_name,success,time_s,errors,notes\n"
        "P1,phone,Chrome,1,Sign in,Y,40,0,\n"
        "P1,phone,Chrome,4,Rebook,N,5:00,2,gave up\n"
        "P2,laptop,Edge,1,Sign in,Y,1:20,1,\n"
        "P3,,,1,Sign in,,,,\n",  # not run: skipped
        encoding="utf-8",
    )
    sus = tmp_path / "sus.csv"
    sus.write_text(
        "participant,q1,q2,q3,q4,q5,q6,q7,q8,q9,q10,trust,voucher_clarity,instead_of_calling,comments\n"
        "P1,3,3,3,3,3,3,3,3,3,3,4,5,3,\n"
        "P2,5,1,5,1,5,1,5,1,5,1,5,,4,\n"
        "P3,,,,,,,,,,,,,,\n",
        encoding="utf-8",
    )
    md = score.report(score.read_tasks(tasks), score.read_sus(sus))
    assert "| 1. Sign in with a booking reference | 2 | 2/2 (100%) | 1:00 | 1 |" in md
    assert "| 4. Rebook and choose a seat | 1 | 0/1 (0%) | - | 2 |" in md
    assert "| **Mean (n = 2)** | **75.0** |" in md
    assert "| Sample SD (n - 1) | 35.4 |" in md
    assert "P3" not in md
    assert re.search(r"I trusted the answers Kestrel gave me \| 2 \| 4\.5 \|", md)


def test_half_filled_sus_row_is_an_error(score, tmp_path):
    sus = tmp_path / "sus.csv"
    sus.write_text(
        "participant,q1,q2,q3,q4,q5,q6,q7,q8,q9,q10\nP1,3,3,3,,,,,,,\n", encoding="utf-8"
    )
    with pytest.raises(ValueError):
        score.read_sus(sus)


def test_kit_templates_score_as_empty(score):
    md = score.report(score.read_tasks(score.TASKS_CSV), score.read_sus(score.SUS_CSV))
    assert "| **Mean (n = 0)** | **n/a** |" in md


# -- Usability bookings: planning --------------------------------------------


def test_departure_is_at_least_24_hours_ahead_on_a_five_minute_mark(ub):
    now = datetime(2026, 11, 8, 10, 2, 30, tzinfo=UTC)
    dep = ub.plan_departure(now)
    assert dep == datetime(2026, 11, 9, 11, 5, tzinfo=UTC)
    assert dep - now >= timedelta(hours=24)
    on_mark = datetime(2026, 11, 8, 10, 0, tzinfo=UTC)
    assert ub.plan_departure(on_mark) == on_mark + ub.LEAD


def _route(o, d, later=6, free=300, aircraft="E190"):
    return {"origin": o, "destination": d, "aircraft": aircraft,
            "later_flights": later, "free_economy": free}  # fmt: skip


def test_route_choice_skips_protected_and_thin_routes(ub):
    candidates = [
        _route("NBO", "MBA", later=20),  # the demo's route
        _route("NBO", "KIS", later=10),
        _route("KIS", "NBO", later=12),  # more flights, but not from the hub
        _route("NBO", "UKA", later=2),  # too few later flights
        _route("NBO", "EDL", later=15, free=3),  # not enough free seats for six
    ]
    chosen = ub.choose_route(candidates, protected={("NBO", "MBA")})
    assert (chosen["origin"], chosen["destination"]) == ("NBO", "KIS")


def test_no_route_when_nothing_qualifies(ub):
    assert ub.choose_route([_route("NBO", "UKA", later=1)], protected=set()) is None
    assert ub.choose_route([_route("NBO", "KIS", aircraft="A380")], protected=set()) is None


def test_six_participants_get_distinct_economy_seats(ub):
    for aircraft in ub.AIRCRAFT:
        seats = ub.participant_seats(aircraft)
        cabins = dict(ub.seat_map(aircraft))
        assert len(set(seats)) == len(ub.PARTICIPANTS) == 6
        assert all(cabins[s] == "ECONOMY" for s in seats)


def test_fixed_markers_cannot_collide_with_generated_or_demo_data(ub):
    # The generator writes KQ<integer>: never a leading zero.
    assert re.fullmatch(r"KQ0\d+", ub.FLIGHT_NUMBER)
    assert ub.EMAILS == [f"usability+{i}@example.com" for i in range(1, 7)]
    surnames = {s.lower() for _, s in ub.PARTICIPANTS}
    assert not surnames & {"edwards", "mueller"}


def test_cleanup_selects_only_by_fixed_markers(ub):
    statements = ub.cleanup_statements()
    for sql, args in statements:
        assert "LIKE" not in sql.upper()
        assert args in ((ub.EMAILS,), (ub.FLIGHT_NUMBER,))
    # Children before parents, the flight (and its seats) last.
    tables = [re.search(r"(?:FROM|UPDATE)\s+(\w+)", sql).group(1) for sql, _ in statements]
    assert tables.index("pnr_bookings") < tables.index("passengers") < tables.index("flights")
    assert tables[0] == "seats" and tables[-1] == "flights"
