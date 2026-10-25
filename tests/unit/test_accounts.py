"""
POST /api/auth/account - social sign-in, with no database and no Supabase.

Supabase is replaced at the HTTP layer (httpx.MockTransport), so the real
verify_supabase_user() runs and its request can be checked. The database is
the shared fake in tests/conftest.py: each query is
answered by matching a fragment of its SQL.
"""

import json
from datetime import UTC, datetime
from types import SimpleNamespace

import httpx
import pytest
from fastapi.testclient import TestClient

from kestrel.api import accounts, auth, db, main
from tests.conftest import FakeConn, FakePool

USER_ID = "8d0f3a52-6c1e-4d2a-9b7f-2f6e1c9a4b10"
EMAIL = "grace.edwards@example.com"
GOOD_TOKEN = "supabase-access-token-good"
BAD_TOKEN = "supabase-access-token-bad!"

SUPABASE_USER = {
    "id": USER_ID,
    "email": EMAIL,
    "email_confirmed_at": "2026-10-17T09:00:00Z",
    "app_metadata": {"provider": "google", "providers": ["google"]},
}

BOOKING = {
    "pnr_code": "A27Z99",
    "passenger_id": "11111111-2222-3333-4444-555555555555",
    "last_name": "Edwards",
    "asante_rewards_tier": "GOLD",
}


# Fragments that pick out each statement.
LINKED = "FROM passenger_accounts"
LATEST = "WHERE b.passenger_id = $1"
AUTHENTICATE = "lower(trim(p.last_name))"
BY_EMAIL = "AND lower(p.email) = lower($2)"
SUGGEST = "WHERE lower(p.email) = lower($1)"
INSERT_LINK = "INSERT INTO passenger_accounts"
AUDIT = "INSERT INTO audit_logs"


@pytest.fixture
def supabase(monkeypatch):
    """A stand-in for Supabase's GET /auth/v1/user: the user it returns for
    the good token (a test may change it) and the requests it received."""
    monkeypatch.setenv("SUPABASE_URL", "https://project.supabase.co")
    monkeypatch.setenv("SUPABASE_ANON_KEY", "anon-key-for-tests")
    stub = SimpleNamespace(user=dict(SUPABASE_USER), requests=[])

    def handler(request: httpx.Request) -> httpx.Response:
        stub.requests.append(request)
        if request.headers.get("authorization") == f"Bearer {GOOD_TOKEN}":
            return httpx.Response(200, json=stub.user)
        return httpx.Response(401, json={"msg": "invalid JWT"})

    monkeypatch.setattr(accounts, "_transport", httpx.MockTransport(handler))
    return stub


@pytest.fixture
def conn():
    return FakeConn({LINKED: None, INSERT_LINK: {"passenger_id": BOOKING["passenger_id"]}})


@pytest.fixture
def client(conn):
    main.app.dependency_overrides[db.get_pool] = lambda: FakePool(conn)
    auth._failed_attempts.clear()
    yield TestClient(main.app)
    main.app.dependency_overrides.clear()
    auth._failed_attempts.clear()


def post(client, **body):
    return client.post("/api/auth/account", json={"access_token": GOOD_TOKEN, **body})


def assert_signed_in(response, pnr="A27Z99"):
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["token_type"] == "bearer"
    assert body["expires_in"] == 15 * 60
    assert body["passenger"]["pnr_code"] == pnr
    session = auth._decode_token(body["access_token"])  # a real Kestrel token
    assert session.pnr_code == pnr


# -- the cases the account flow must get right -------------------------------


def test_linked_user_gets_a_token(client, conn, supabase):
    conn.routes[LINKED] = {"passenger_id": BOOKING["passenger_id"]}
    conn.routes[LATEST] = BOOKING
    assert_signed_in(post(client))
    assert conn.called(LATEST) == [(BOOKING["passenger_id"],)]
    assert conn.called(INSERT_LINK) == []  # already linked: nothing written


def test_reference_and_surname_under_the_verified_email_links(client, conn, supabase):
    conn.routes[AUTHENTICATE] = BOOKING
    conn.routes[BY_EMAIL] = lambda pnr, email: BOOKING if email == EMAIL else None
    r = post(client, pnr_code="a27z99", last_name="edwards")
    assert_signed_in(r)
    assert r.json()["linked"] is True

    assert conn.called(BY_EMAIL) == [("a27z99", EMAIL)]
    assert conn.called(INSERT_LINK) == [(USER_ID, BOOKING["passenger_id"], EMAIL, "google")]
    (audit,) = conn.called(AUDIT)
    assert audit[0] == "A27Z99"
    assert audit[1] == f"ACCOUNT:google:{USER_ID}"
    assert json.loads(audit[2]) == {"provider": "google", "method": "PNR_SURNAME"}


def test_reference_and_surname_of_someone_else_signs_in_without_linking(client, conn, supabase):
    """Issue #1: a reference and surname read off a bag tag must not tie the
    booking's passenger to this account."""
    conn.routes[AUTHENTICATE] = BOOKING
    conn.routes[BY_EMAIL] = None  # the passenger's email is not the account's
    r = post(client, pnr_code="A27Z99", last_name="Edwards")
    assert_signed_in(r)  # the one booking, for this visit, as a guest would get
    assert r.json()["linked"] is False
    assert conn.called(INSERT_LINK) == []
    assert conn.called(AUDIT) == []


def test_case_of_the_email_does_not_matter(client, conn, supabase):
    supabase.user["email"] = "Grace.Edwards@Example.com"
    # SQL_BOOKING_FOR_EMAIL compares lower(p.email) = lower($2)
    assert "lower(p.email) = lower($2)" in accounts.SQL_BOOKING_FOR_EMAIL
    conn.routes[AUTHENTICATE] = BOOKING
    conn.routes[BY_EMAIL] = lambda pnr, email: BOOKING if email.lower() == EMAIL else None
    assert post(client, pnr_code="A27Z99", last_name="Edwards").json()["linked"] is True


def test_unlinked_with_reference_under_the_same_email_links(client, conn, supabase):
    conn.routes[BY_EMAIL] = lambda pnr, email: BOOKING if email == EMAIL else None
    assert_signed_in(post(client, pnr_code="A27Z99"))
    assert conn.called(BY_EMAIL) == [("A27Z99", EMAIL)]
    assert json.loads(conn.called(AUDIT)[0][2])["method"] == "EMAIL_MATCH"


def test_unlinked_with_reference_under_another_email_is_refused(client, conn, supabase):
    conn.routes[BY_EMAIL] = None  # the booking's passenger has a different address
    r = post(client, pnr_code="Z9PKW3")
    assert r.status_code == 403
    assert "access_token" not in r.json()
    assert conn.called(INSERT_LINK) == []


def test_no_link_and_no_reference_suggests_only_bookings_under_the_verified_email(client, conn, supabase):
    departure = datetime(2026, 10, 17, 20, 45, tzinfo=UTC)  # 23:45 in Nairobi
    conn.routes[SUGGEST] = lambda email: (
        [
            {
                "pnr_code": "A27Z99",
                "origin": "NBO",
                "destination": "AMS",
                "departure_time": departure,
                "booking_status": "DISRUPTED",
            }
        ]
        if email == EMAIL
        else []
    )
    # A request cannot widen the search: the address comes from Supabase.
    r = client.post("/api/auth/account", json={"access_token": GOOD_TOKEN, "email": "someone@else.com"})
    assert r.status_code == 200
    assert r.json() == {
        "link_required": True,
        "suggestions": [
            {
                "pnr_code": "A27Z99",
                "origin": "NBO",
                "destination": "AMS",
                "departure_date": "2026-10-17",
                "booking_status": "DISRUPTED",
            }
        ],
        "cities": {"NBO": "Nairobi", "AMS": "Amsterdam"},  # kestrel.airports, for the client
    }
    assert conn.called(SUGGEST) == [(EMAIL,)]
    assert conn.called(INSERT_LINK) == []


def test_invalid_supabase_token_is_401_and_touches_nothing(client, conn, supabase):
    r = client.post("/api/auth/account", json={"access_token": BAD_TOKEN, "pnr_code": "A27Z99", "last_name": "Edwards"})
    assert r.status_code == 401
    assert conn.calls == []


def test_throttle_still_applies(client, conn, supabase):
    conn.routes[AUTHENTICATE] = None  # wrong surname every time
    for _ in range(auth.MAX_FAILED_ATTEMPTS):
        assert post(client, pnr_code="A27Z99", last_name="Wrong").status_code == 401
    r = post(client, pnr_code="A27Z99", last_name="Edwards")
    assert r.status_code == 429
    # The email-only route counts against the same booking.
    assert post(client, pnr_code="a27z99").status_code == 429


# -- edges -------------------------------------------------------------------


def test_request_to_supabase_carries_the_token_and_the_anon_key(client, conn, supabase):
    post(client)
    (request,) = supabase.requests
    assert str(request.url) == "https://project.supabase.co/auth/v1/user"
    assert request.headers["authorization"] == f"Bearer {GOOD_TOKEN}"
    assert request.headers["apikey"] == "anon-key-for-tests"


def test_unverified_email_is_401(client, conn, supabase):
    supabase.user["email_confirmed_at"] = None
    supabase.user.pop("confirmed_at", None)
    assert post(client, pnr_code="A27Z99").status_code == 401
    assert conn.calls == []


def test_booking_linked_to_another_account_is_409(client, conn, supabase):
    conn.routes[AUTHENTICATE] = BOOKING
    conn.routes[BY_EMAIL] = BOOKING
    conn.routes[INSERT_LINK] = None  # the passenger already has an account
    r = post(client, pnr_code="A27Z99", last_name="Edwards")
    assert r.status_code == 409
    assert conn.called(AUDIT) == []


def test_linked_account_without_bookings_is_404(client, conn, supabase):
    conn.routes[LINKED] = {"passenger_id": BOOKING["passenger_id"]}
    conn.routes[LATEST] = None
    assert post(client).status_code == 404


def test_not_configured_is_503(client, conn, supabase, monkeypatch):
    monkeypatch.delenv("SUPABASE_URL")
    assert post(client).status_code == 503


def test_supabase_unreachable_is_503(client, conn, supabase, monkeypatch):
    def down(request):
        raise httpx.ConnectError("no route to host", request=request)

    monkeypatch.setattr(accounts, "_transport", httpx.MockTransport(down))
    assert post(client).status_code == 503


def test_audit_actor_fits_the_widened_column():
    # migration 009 widens audit_logs.actor to 80 characters
    assert len(accounts.audit_actor("google", USER_ID)) <= 80


# -- issue #31: the login limit on this endpoint -----------------------------


def test_one_account_cannot_try_many_bookings(client, conn, supabase):
    """The limit also counts per account, so one verified account cannot
    walk through booking references."""
    conn.routes[AUTHENTICATE] = None
    for i in range(auth.MAX_FAILED_ATTEMPTS):
        assert post(client, pnr_code=f"ZZZZZ{i}", last_name="Wrong").status_code == 401
    assert post(client, pnr_code="A27Z99", last_name="Edwards").status_code == 429


async def test_concurrent_account_guesses_reach_the_database_at_most_five_times(conn, supabase):
    import asyncio

    import httpx as _httpx

    lookups = 0

    async def slow_lookup(*_):
        nonlocal lookups
        lookups += 1
        await asyncio.sleep(0.01)
        return None

    conn.routes[AUTHENTICATE] = None
    conn.fetchrow = _slow_fetchrow(conn, AUTHENTICATE, slow_lookup)
    main.app.dependency_overrides[db.get_pool] = lambda: FakePool(conn)
    auth._failed_attempts.clear()
    try:
        transport = _httpx.ASGITransport(app=main.app)
        async with _httpx.AsyncClient(transport=transport, base_url="http://test") as ac:
            responses = await asyncio.gather(*(
                ac.post("/api/auth/account", json={
                    "access_token": GOOD_TOKEN, "pnr_code": "A27Z99", "last_name": "Wrong"})
                for _ in range(10)
            ))
    finally:
        main.app.dependency_overrides.clear()
        auth._failed_attempts.clear()
    assert lookups <= auth.MAX_FAILED_ATTEMPTS
    assert sorted(r.status_code for r in responses).count(429) >= 10 - auth.MAX_FAILED_ATTEMPTS


def _slow_fetchrow(conn, fragment, slow):
    original = conn.fetchrow

    async def fetchrow(sql, *args):
        if fragment in sql:
            conn.calls.append((sql, args))
            return await slow(*args)
        return await original(sql, *args)

    return fetchrow


# -- "Unlink this booking" ---------------------------------------------------

DELETE_LINK = "DELETE FROM passenger_accounts"


def unlink(client, token=GOOD_TOKEN):
    return client.request("DELETE", "/api/auth/account/link", json={"access_token": token})


def test_unlink_removes_only_the_signed_in_accounts_link_and_audits_it(client, conn, supabase):
    conn.routes = {DELETE_LINK: {"passenger_id": BOOKING["passenger_id"]}, **conn.routes}  # before LINKED
    r = unlink(client)
    assert r.status_code == 200
    assert r.json() == {"unlinked": True}
    assert conn.called(DELETE_LINK) == [(USER_ID,)]  # the id Supabase gave, never one sent
    (audit,) = conn.called("ACCOUNT_UNLINKED")
    assert audit[0] == f"ACCOUNT:google:{USER_ID}"
    assert json.loads(audit[1]) == {"passenger_id": BOOKING["passenger_id"]}


def test_unlink_without_a_link_changes_nothing(client, conn, supabase):
    conn.routes[DELETE_LINK] = None
    assert unlink(client).json() == {"unlinked": False}
    assert conn.called("ACCOUNT_UNLINKED") == []


def test_unlink_needs_a_valid_account_token(client, conn, supabase):
    assert unlink(client, BAD_TOKEN).status_code == 401
    assert conn.calls == []


def test_one_http_client_serves_every_sign_in(client, conn, supabase):
    """Issue #30: a new client (a new TLS connection to Supabase) per sign-in."""
    post(client)
    first = accounts._http()
    post(client)
    assert accounts._http() is first
    assert len(supabase.requests) == 2
