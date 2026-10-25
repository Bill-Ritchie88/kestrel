"""The chat endpoint the Flutter client talks to (agent service, port 8001)."""

import json

import httpx
from fastapi.testclient import TestClient

from kestrel import agent, agent_service

client = TestClient(agent_service.app)


def test_health_names_the_model_and_rest_tier():
    body = client.get("/health").json()
    assert body["model"] == agent.GEMINI_MODEL
    assert body["rest_tier"] == agent.FASTAPI_BASE_URL


def test_chat_requires_a_bearer_token():
    assert client.post("/api/chat", json={"message": "hi"}).status_code == 401


def test_expired_session_is_401_before_the_model_runs(monkeypatch):
    rest = httpx.MockTransport(lambda r: httpx.Response(401, json={"detail": "Token has expired."}))
    monkeypatch.setattr(agent, "http_client", httpx.Client(transport=rest))

    def must_not_run(*a, **k):
        raise AssertionError("the model must not run for an invalid session")

    monkeypatch.setattr(agent, "run_agent", must_not_run)
    r = client.post("/api/chat", json={"message": "hi"}, headers={"Authorization": "Bearer x"})
    assert r.status_code == 401


def test_chat_returns_reply_and_events(monkeypatch):
    rest = httpx.MockTransport(lambda r: httpx.Response(200, json={"pnr_code": "S958PC"}))
    monkeypatch.setattr(agent, "http_client", httpx.Client(transport=rest))
    seen = {}

    def fake_run(message, history):
        seen["message"], seen["history"] = message, history
        return agent.AgentResult(reply="Done", events=[{"type": "rebooked", "data": {}}])

    monkeypatch.setattr(agent, "run_agent", fake_run)
    r = client.post(
        "/api/chat",
        json={"message": "Rebook me", "history": [{"role": "user", "content": "hello"}]},
        headers={"Authorization": "Bearer abc"},
    )
    assert r.status_code == 200
    assert r.json()["reply"] == "Done"
    assert r.json()["events"][0]["type"] == "rebooked"
    assert seen["history"] == [{"role": "user", "content": "hello"}]


def test_message_length_is_bounded():
    r = client.post("/api/chat", json={"message": "x" * 1001}, headers={"Authorization": "Bearer a"})
    assert r.status_code == 422


def _valid_session(monkeypatch):
    rest = httpx.MockTransport(lambda r: httpx.Response(200, json={"pnr_code": "S958PC"}))
    monkeypatch.setattr(agent, "http_client", httpx.Client(transport=rest))


def test_quota_error_is_a_clear_503_and_is_logged(monkeypatch, tmp_path):
    _valid_session(monkeypatch)
    monkeypatch.setattr(agent_service, "LOG_DIR", tmp_path)

    def quota(message, history):
        raise RuntimeError("429 RESOURCE_EXHAUSTED: quota exceeded")

    monkeypatch.setattr(agent, "run_agent", quota)
    r = client.post("/api/chat", json={"message": "Rebook me"}, headers={"Authorization": "Bearer a"})
    assert r.status_code == 503
    assert "usage limit" in r.json()["detail"]
    line = (tmp_path / "agent-turns.jsonl").read_text(encoding="utf-8").strip()
    assert '"error": "RuntimeError"' in line


def test_successful_turn_is_logged_with_timing(monkeypatch, tmp_path):
    _valid_session(monkeypatch)
    monkeypatch.setattr(agent_service, "LOG_DIR", tmp_path)
    monkeypatch.setattr(agent, "run_agent", lambda m, h: agent.AgentResult(reply="ok"))
    r = client.post("/api/chat", json={"message": "hi"}, headers={"Authorization": "Bearer a"})
    assert r.status_code == 200
    import json as _json

    rec = _json.loads((tmp_path / "agent-turns.jsonl").read_text(encoding="utf-8"))
    assert "total_ms" in rec and rec["tools"] == []
    # Issue #11: timings and names only, never the passenger's words.
    assert "message" not in rec and '"hi"' not in json.dumps(rec)
