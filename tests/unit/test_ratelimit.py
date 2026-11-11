"""NFR-05: the token bucket, and 429 + Retry-After on the chat and sign-in routes."""

import pytest
from fastapi.testclient import TestClient
from starlette.applications import Starlette
from starlette.responses import PlainTextResponse
from starlette.routing import Route

from kestrel import ratelimit
from kestrel.api import auth, db, main
from kestrel.api.auth import issue_token
from tests.conftest import FakeConn, FakePool


@pytest.fixture
def now(monkeypatch):
    """A clock the test moves by hand."""
    t = [1000.0]
    monkeypatch.setattr(ratelimit, "clock", lambda: t[0])
    return t


# -- the bucket ---------------------------------------------------------------


def test_a_burst_of_five_then_wait_three_seconds():
    store = ratelimit.MemoryStore(per_minute=20, burst=5)
    assert [store.take("a", 0) for _ in range(5)] == [0] * 5
    assert store.take("a", 0) == pytest.approx(3.0)  # 20 a minute: one every 3 s


def test_the_bucket_refills_at_twenty_a_minute():
    store = ratelimit.MemoryStore(per_minute=20, burst=5)
    for _ in range(5):
        store.take("a", 0)
    assert store.take("a", 1.5) == pytest.approx(1.5)  # half a token back
    assert store.take("a", 3.0) == 0
    # Steady at one every 3 s: 20 in the next minute, all allowed.
    assert all(store.take("a", 3.0 + 3 * i) == 0 for i in range(1, 21))
    # Never more than the burst, however long it was idle.
    assert [store.take("b", 0) for _ in range(5)] == [0] * 5
    assert [store.take("b", 10_000) == 0 for _ in range(6)] == [True] * 5 + [False]


def test_a_refused_request_does_not_spend_a_token():
    store = ratelimit.MemoryStore(per_minute=20, burst=1)
    store.take("a", 0)
    for _ in range(10):
        store.take("a", 0)
    assert store.take("a", 3.0) == 0


def test_idle_buckets_are_evicted_least_recently_used_first():
    store = ratelimit.MemoryStore(per_minute=20, burst=1, max_keys=2)
    store.take("old", 0)
    store.take("mid", 1)
    store.take("old", 2)  # used again: now the newest
    store.take("new", 3)
    assert list(store._buckets) == ["old", "new"]


def test_client_ip_is_the_first_forwarded_hop():
    from starlette.datastructures import Headers

    scope = {"client": ("10.0.0.1", 1234)}
    assert ratelimit.client_ip(scope, Headers({"x-forwarded-for": "203.0.113.7, 10.1.1.1"})) == "203.0.113.7"
    assert ratelimit.client_ip(scope, Headers({})) == "10.0.0.1"


# -- the middleware on a toy app ------------------------------------------------


def _toy(agent_key=None):
    app = Starlette(routes=[Route("/api/chat", lambda r: PlainTextResponse("ok"), methods=["POST"])])
    app.add_middleware(
        ratelimit.RateLimitMiddleware, rules=[("/api/chat", ratelimit.CHAT, True)], agent_key=agent_key
    )
    return TestClient(app)


def test_the_agent_key_is_not_counted(now):
    client = _toy(agent_key="k")
    headers = {"Authorization": "Bearer t", "X-Agent-Key": "k"}
    assert all(client.post("/api/chat", headers=headers).status_code == 200 for _ in range(10))
    wrong = {"Authorization": "Bearer t", "X-Agent-Key": "guess"}
    assert [client.post("/api/chat", headers=wrong).status_code for _ in range(6)][-1] == 429


def test_without_a_token_chat_is_limited_per_address(now):
    client = _toy()
    codes = [client.post("/api/chat", headers={"X-Forwarded-For": "198.51.100.1"}).status_code for _ in range(6)]
    assert codes == [200] * 5 + [429]
    assert client.post("/api/chat", headers={"X-Forwarded-For": "198.51.100.2"}).status_code == 200


# -- the REST tier ----------------------------------------------------------------


@pytest.fixture
def rest():
    main.app.dependency_overrides[db.get_pool] = lambda: FakePool(FakeConn({"FROM chat_messages": []}))
    auth._failed_attempts.clear()
    yield TestClient(main.app)
    main.app.dependency_overrides.clear()


def _bearer(pnr):
    token, _ = issue_token(pnr_code=pnr, passenger_id="p-1", last_name="Test", rewards_tier=None)
    return {"Authorization": f"Bearer {token}"}


def test_sixth_chat_request_in_a_burst_is_429_with_retry_after(rest, now):
    mine = _bearer("RLTST1")
    codes = [rest.get("/api/chat/history", headers=mine).status_code for _ in range(5)]
    assert codes == [200] * 5
    r = rest.get("/api/chat/history", headers=mine)
    assert r.status_code == 429
    assert r.headers["Retry-After"] == "3"
    assert "Please wait 3 seconds" in r.json()["detail"]
    # Another passenger's token has its own bucket.
    assert rest.get("/api/chat/history", headers=_bearer("RLTST2")).status_code == 200
    # After Retry-After, the first passenger may go again.
    now[0] += 3
    assert rest.get("/api/chat/history", headers=mine).status_code == 200


def test_twenty_first_request_in_a_minute_after_the_burst_is_429(rest, now):
    mine = _bearer("RLTST3")
    for _ in range(5):
        assert rest.get("/api/chat/history", headers=mine).status_code == 200
    # 20 more, one every 3 s, then one too soon.
    for _ in range(20):
        now[0] += 3
        assert rest.get("/api/chat/history", headers=mine).status_code == 200
    assert rest.get("/api/chat/history", headers=mine).status_code == 429


def test_sign_in_is_limited_per_address_not_per_header_token(rest, now):
    body = {"pnr_code": "RLTST4", "last_name": "Nobody"}
    ip = {"X-Forwarded-For": "192.0.2.10"}
    for i in range(10):
        # A fresh booking each time, so the per-booking throttle never fires.
        rest.post("/api/auth/session", json={**body, "pnr_code": f"RLT{i:03d}"}, headers=ip)
    # A made-up bearer header does not buy a new bucket on a sign-in route.
    r = rest.post("/api/auth/session", json=body, headers={**ip, "Authorization": "Bearer fresh"})
    assert r.status_code == 429
    assert int(r.headers["Retry-After"]) >= 1
    other = rest.post("/api/auth/session", json=body, headers={"X-Forwarded-For": "192.0.2.11"})
    assert other.status_code != 429


@pytest.mark.parametrize("module", ["kestrel.api.main", "kestrel.agent_service"])
def test_the_browser_may_read_a_429_and_its_retry_after(module):
    import importlib

    app = importlib.import_module(module).app
    cors = next(m for m in app.user_middleware if m.cls.__name__ == "CORSMiddleware")
    assert "Retry-After" in cors.kwargs["expose_headers"]
    # user_middleware is outermost first: CORS must wrap the limiter, or a
    # 429 reaches the browser without CORS headers and cannot be read.
    names = [m.cls.__name__ for m in app.user_middleware]
    assert names.index("CORSMiddleware") < names.index("RateLimitMiddleware")


# -- the agent service --------------------------------------------------------------


def test_agent_chat_is_limited_per_token(now, monkeypatch):
    from kestrel import agent_service

    monkeypatch.setattr(agent_service, "briefing_for", lambda token: (_ for _ in ()).throw(
        agent_service.HTTPException(status_code=401, detail="Session expired.")))
    client = TestClient(agent_service.app)
    mine = {"Authorization": "Bearer agent-rl-1"}
    codes = [client.post("/api/chat", json={"message": "hi"}, headers=mine).status_code for _ in range(6)]
    assert codes == [401] * 5 + [429]
    r = client.post("/api/chat/stream", json={"message": "hi"}, headers=mine)
    assert r.status_code == 429 and r.headers["Retry-After"] == "3"
    other = client.post("/api/chat/stream", json={"message": "hi"}, headers={"Authorization": "Bearer agent-rl-2"})
    assert other.status_code == 401
