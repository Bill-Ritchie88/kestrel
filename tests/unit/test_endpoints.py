"""
Endpoint tests for the REST tier, with no database (Section 5.5.6: "every
status code in IR-02 reproduced by a test").

The connection pool and the retriever are replaced through FastAPI's
dependency overrides. FakeConn answers each query by matching a fragment of
its SQL, so a test states only the rows it cares about. The TestClient is not
used as a context manager, so the application's lifespan (which would open a
real pool from .env) never runs.
"""

from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone

import asyncpg
import pytest
from fastapi.testclient import TestClient

from kestrel.api import auth, db, main
from kestrel.api.auth import issue_token
from kestrel.policy.retriever import PolicyHit, RetrievalResult

NOW = datetime.now(timezone.utc)


class FakeConn:
    def __init__(self, routes: dict):
        self.routes = routes
        self.calls: list[tuple[str, tuple]] = []

    def _answer(self, sql, args, default):
        self.calls.append((sql, args))
        for fragment, answer in self.routes.items():
            if fragment in sql:
                if isinstance(answer, Exception):
                    raise answer
                return answer(*args) if callable(answer) else answer
        return default

    async def fetchrow(self, sql, *args):
        return self._answer(sql, args, None)

    async def fetch(self, sql, *args):
        return self._answer(sql, args, [])

    async def fetchval(self, sql, *args):
        return self._answer(sql, args, None)

    async def execute(self, sql, *args):
        return self._answer(sql, args, "OK")

    @asynccontextmanager
    async def transaction(self):
        yield


class FakePool:
    def __init__(self, conn):
        self.conn = conn

    @asynccontextmanager
    async def acquire(self):
        yield self.conn


def booking_row(**overrides):
    row = {
        "pnr_code": "S958PC",
        "booking_status": "DISRUPTED",
        "first_name": "Joseph",
        "last_name": "Whitehead",
        "asante_rewards_tier": "GOLD",
        "original_flight_id": "f-orig",
        "original_flight_number": "KQ116",
        "origin": "AMS",
        "destination": "NBO",
        "original_departure": NOW + timedelta(hours=3),
        "original_arrival": NOW + timedelta(hours=11),
        "original_status": "CANCELLED",
        "disruption_reason": "TECHNICAL",
        "original_aircraft": "B787-8",
        "current_flight_id": None,
        "current_flight_number": None,
        "current_departure": None,
        "current_arrival": None,
        "seat_number": "24A",
        "cabin_class": "ECONOMY",
    }
    row.update(overrides)
    return row


ALTERNATIVE = {
    "flight_id": "f-alt",
    "flight_number": "KQ116",
    "origin": "AMS",
    "destination": "NBO",
    "departure_time": NOW + timedelta(hours=27),
    "arrival_time": NOW + timedelta(hours=35),
    "aircraft_type": "B787-8",
    "cabin_class": "ECONOMY",
    "available_seats": 12,
}


@pytest.fixture
def conn():
    return FakeConn({"COALESCE(s.cabin_class::text": booking_row()})


@pytest.fixture
def client(conn):
    main.app.dependency_overrides[db.get_pool] = lambda: FakePool(conn)
    auth._failed_attempts.clear()
    yield TestClient(main.app)
    main.app.dependency_overrides.clear()


@pytest.fixture
def token():
    t, _ = issue_token(
        pnr_code="S958PC", passenger_id="p-1", last_name="Whitehead", rewards_tier="GOLD"
    )
    return {"Authorization": f"Bearer {t}"}


# -- service ------------------------------------------------------------------


def test_health_reports_disconnected_without_a_pool(client):
    body = client.get("/health").json()
    assert body["status"] == "online"
    assert body["database"] == "disconnected"


def test_503_when_database_unavailable(token):
    main.app.dependency_overrides.clear()  # real get_pool, no pool open
    r = TestClient(main.app).get("/api/me", headers=token)
    assert r.status_code == 503


# -- FR-01 / FR-06 authentication ---------------------------------------------


def test_login_returns_a_token(client, conn):
    conn.routes["lower(trim(p.last_name))"] = {
        "pnr_code": "S958PC",
        "passenger_id": "p-1",
        "last_name": "Whitehead",
        "asante_rewards_tier": "GOLD",
    }
    r = client.post("/api/auth/session", json={"pnr_code": "s958pc", "last_name": "whitehead"})
    assert r.status_code == 200
    assert r.json()["token_type"] == "bearer"
    assert r.json()["expires_in"] == 15 * 60


def test_wrong_surname_is_401_with_generic_message(client):
    r = client.post("/api/auth/session", json={"pnr_code": "S958PC", "last_name": "Nobody"})
    assert r.status_code == 401
    assert r.json()["detail"] == "No booking matches that PNR and surname."


def test_sixth_failed_login_is_throttled_429(client):
    for _ in range(5):
        client.post("/api/auth/session", json={"pnr_code": "S958PC", "last_name": "x"})
    r = client.post("/api/auth/session", json={"pnr_code": "S958PC", "last_name": "x"})
    assert r.status_code == 429


def test_invalid_body_is_422(client):
    assert client.post("/api/auth/session", json={"pnr_code": "AB"}).status_code == 422


@pytest.mark.parametrize("header", [None, "Bearer not.a.token", "Token abc"])
def test_booking_endpoints_reject_missing_or_forged_tokens(client, header):
    headers = {"Authorization": header} if header else {}
    assert client.get("/api/me", headers=headers).status_code == 401


def test_me_returns_the_sessions_own_booking(client, conn, token):
    body = client.get("/api/me", headers=token).json()
    assert body["pnr_code"] == "S958PC"
    assert body["original_flight"]["status"] == "CANCELLED"
    # The PNR queried is the token's, never a client-supplied one.
    assert conn.calls[-1][1] == ("S958PC",)


# -- FR-03 alternatives and rebooking -----------------------------------------


def test_alternatives_are_same_cabin_and_limit_is_clamped(client, conn, token):
    conn.routes["WITH bk AS"] = [ALTERNATIVE]
    r = client.get("/api/flights/alternatives?limit=50", headers=token)
    assert r.status_code == 200
    assert r.json()["alternatives"][0]["cabin_class"] == "ECONOMY"
    sql, args = conn.calls[-1]
    assert "s.cabin_class::text = bk.cabin" in sql
    assert args == ("S958PC", 10)


def test_successful_rebooking_issues_entitlements(client, conn, token):
    conn.routes["reaccommodate_passenger_atomic"] = {
        "success": True,
        "assigned_seat_number": "24A",
        "message": "Passenger re-accommodated successfully.",
    }
    r = client.post("/api/reaccommodate", json={"target_flight_id": "f-alt"}, headers=token)
    assert r.status_code == 200
    assert r.json()["assigned_seat"] == "24A"
    sqls = " ".join(sql for sql, _ in conn.calls)
    assert "INSERT INTO vouchers" in sqls
    assert "ENTITLEMENTS_ISSUED" in sqls
    # The procedure receives the token's PNR and a server-derived actor.
    proc_args = next(a for s, a in conn.calls if "reaccommodate_passenger_atomic" in s)
    assert proc_args == ("S958PC", "f-alt", "PASSENGER:S958PC")


def test_refused_rebooking_is_409_with_the_procedures_reason(client, conn, token):
    conn.routes["reaccommodate_passenger_atomic"] = {
        "success": False,
        "assigned_seat_number": None,
        "message": "No economy seats remaining on the target flight.",
    }
    r = client.post("/api/reaccommodate", json={"target_flight_id": "f-alt"}, headers=token)
    assert r.status_code == 409
    assert "economy" in r.json()["detail"]


def test_malformed_flight_id_is_400(client, conn, token):
    conn.routes["reaccommodate_passenger_atomic"] = asyncpg.DataError("invalid uuid")
    r = client.post("/api/reaccommodate", json={"target_flight_id": "nope"}, headers=token)
    assert r.status_code == 400


def test_empty_procedure_result_is_502(client, conn, token):
    conn.routes["reaccommodate_passenger_atomic"] = None
    r = client.post("/api/reaccommodate", json={"target_flight_id": "f-alt"}, headers=token)
    assert r.status_code == 502


def test_reaccommodate_body_cannot_name_another_pnr(client, conn, token):
    conn.routes["reaccommodate_passenger_atomic"] = {
        "success": True,
        "assigned_seat_number": "24A",
        "message": "ok",
    }
    client.post(
        "/api/reaccommodate",
        json={"target_flight_id": "f-alt", "pnr_code": "OTHER1"},
        headers=token,
    )
    proc_args = next(a for s, a in conn.calls if "reaccommodate_passenger_atomic" in s)
    assert proc_args[0] == "S958PC"


# -- FR-02 / FR-05 policy search ----------------------------------------------


class FakeRetriever:
    def __init__(self, top):
        self.top = top

    async def search(self, conn, question, k=None):
        hit = PolicyHit("EU261-ART-9", "EU261", "EU261 Art. 9", "Right to care", "meals", None, self.top)
        return RetrievalResult(question=question, hits=[hit], tau=0.75)


def test_in_scope_question_returns_clauses_without_a_case(client, token):
    main.app.dependency_overrides[main.get_retriever] = lambda: FakeRetriever(0.86)
    body = client.get("/api/policy/search?q=Do I get a meal?", headers=token).json()
    assert body["in_scope"] is True
    assert body["hits"][0]["clause_ref"] == "EU261 Art. 9"
    assert body["case"] is None


def test_out_of_scope_question_opens_a_handoff_case(client, conn, token):
    main.app.dependency_overrides[main.get_retriever] = lambda: FakeRetriever(0.41)
    conn.routes["INSERT INTO handoff_cases"] = {
        "case_id": 7,
        "pnr_code": "S958PC",
        "trigger": "LOW_SIMILARITY",
        "booking_status": "DISRUPTED",
        "question": "Can I bring my cat?",
        "top_similarity": 0.41,
        "similarity_scores": '[{"clause_ref": "EU261 Art. 9", "similarity": 0.41}]',
        "summary": "s",
        "status": "OPEN",
        "created_at": NOW,
        "resolved_at": None,
        "resolved_by": None,
        "resolution_note": None,
    }
    body = client.get("/api/policy/search?q=Can I bring my cat?", headers=token).json()
    assert body["in_scope"] is False
    assert body["case"]["case_id"] == 7
    assert body["case"]["trigger"] == "LOW_SIMILARITY"


def test_policy_search_is_503_without_an_api_key(client, token):
    main.app.state.retriever = None
    assert client.get("/api/policy/search?q=meals please", headers=token).status_code == 503


# -- FR-04 entitlements -------------------------------------------------------


def test_entitlements_are_computed_by_the_rules(client, conn, token):
    body = client.get("/api/entitlements", headers=token).json()
    kinds = {e["entitlement_type"] for e in body["decision"]["entitlements"]}
    assert body["decision"]["regulation"] == "EU261"
    assert {"REROUTING", "MEAL", "ASANTE_POINTS"} <= kinds


# -- FR-05 / FR-09 hand-off and staff -----------------------------------------


def test_passenger_cannot_raise_a_low_similarity_case(client, token):
    r = client.post(
        "/api/handoff", json={"trigger": "LOW_SIMILARITY", "summary": "x"}, headers=token
    )
    assert r.status_code == 422


def test_staff_queue_requires_the_staff_key(client, monkeypatch):
    monkeypatch.setattr(main, "STAFF_API_KEY", "staff-secret")
    assert client.get("/api/staff/cases").status_code == 401
    assert client.get("/api/staff/cases", headers={"X-Staff-Key": "wrong"}).status_code == 401
    ok = client.get("/api/staff/cases", headers={"X-Staff-Key": "staff-secret"})
    assert ok.status_code == 200


def test_staff_queue_disabled_without_configuration(client, monkeypatch):
    monkeypatch.setattr(main, "STAFF_API_KEY", None)
    assert client.get("/api/staff/cases", headers={"X-Staff-Key": "x"}).status_code == 503


def test_resolving_an_unknown_case_is_404(client, monkeypatch):
    monkeypatch.setattr(main, "STAFF_API_KEY", "staff-secret")
    r = client.post(
        "/api/staff/cases/999/resolve",
        json={"resolved_by": "Achieng", "note": "Called the passenger"},
        headers={"X-Staff-Key": "staff-secret"},
    )
    assert r.status_code == 404
