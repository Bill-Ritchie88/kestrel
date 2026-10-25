"""Request and turn timing (performance plan, Phase 0)."""

import json

from fastapi.testclient import TestClient
from langchain_core.messages import AIMessage

from kestrel import agent, jsonlog
from kestrel.api import main, timing
from kestrel.api.auth import issue_token


def _lines(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def test_every_response_has_a_server_timing_header():
    r = TestClient(main.app).get("/health")
    assert r.status_code == 200
    name, dur = r.headers["Server-Timing"].split(";")
    assert name == "app"
    assert float(dur.removeprefix("dur=")) >= 0


def test_each_request_is_logged_with_ids_masked_and_no_query(tmp_path, monkeypatch):
    monkeypatch.setattr(jsonlog, "LOG_DIR", tmp_path)
    client = TestClient(main.app)
    client.post("/api/staff/cases/20419/resolve?note=secret", json={})
    client.get("/api/flights/KQX89A/seats")  # no such route
    client.get("/api/booking/ABCDEF")  # no such route, an all-letter reference
    token, _ = issue_token(pnr_code="S958PC", passenger_id="p", last_name="W", rewards_tier=None)
    client.get("/api/me", headers={"Authorization": f"Bearer {token}"})

    records = _lines(tmp_path / timing.LOG_FILE)
    assert [r["path"] for r in records] == [
        "/api/staff/cases/{case_id}/resolve",
        "/api/flights/{id}/{id}",
        "/api/{id}/{id}",
        "/api/me",
    ]
    assert records[1]["status"] == 404
    assert set(records[0]) == {"at", "method", "path", "status", "ms"}
    text = (tmp_path / timing.LOG_FILE).read_text(encoding="utf-8")
    assert "secret" not in text and "20419" not in text and token not in text
    assert "KQX89A" not in text and "ABCDEF" not in text


def test_log_to_stdout_prints_instead_of_writing(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("LOG_TO_STDOUT", "1")
    jsonlog.append(tmp_path, timing.LOG_FILE, {"path": "/api/me", "ms": 1.0})
    line = json.loads(capsys.readouterr().out)
    assert line["log"] == "api-requests" and line["path"] == "/api/me" and "at" in line
    assert not (tmp_path / timing.LOG_FILE).exists()  # no disk in a container


def test_turn_records_when_the_reply_would_start(monkeypatch):
    calls = iter([
        AIMessage(content="", tool_calls=[{"name": "nope", "args": {}, "id": "c1"}]),
        AIMessage(content="Done."),
    ])  # fmt: skip

    class LLM:
        def invoke(self, messages):
            return next(calls)

    result = agent.run_agent("hi", llm=LLM())
    t = result.timing()
    assert 0 <= t["first_token_ms"] <= t["total_ms"]
    assert t["model_calls"] == 2
