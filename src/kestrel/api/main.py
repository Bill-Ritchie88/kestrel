"""
Project Kestrel - Re-accommodation Engine (REST API Tier)

Deterministic layer between the agent tier, the Flutter client and the
database. The agent never touches the database; it can only invoke the
endpoints below, and every endpoint that reads or changes a booking takes the
booking from the authenticated session token, never from the request.

Endpoint map (Sprint 2):

    GET  /health                         liveness, database and retrieval status
    POST /api/auth/session               FR-01, FR-06  PNR + surname -> bearer token
    POST /api/auth/account               social sign-in (Supabase), linked once -> bearer token
    DELETE /api/auth/account/link        unlink the signed-in account (its own link only)
    GET  /api/me                         the passenger's booking and flights
    GET  /api/trip                       booking, alternatives, entitlements, cases and
                                         suggestions in one call (the client's TripStore)
    GET  /api/chat/history               the booking's conversation (last 20 turns)
    POST /api/chat/history               append one turn (assistant turns: agent service only)
    DELETE /api/chat/history             "Start over"
    GET  /api/flights/alternatives       FR-03  same route, same cabin, seats left
    POST /api/reaccommodate              FR-03, FR-07  atomic rebooking + entitlements
    GET  /api/policy/search              FR-02, FR-05  grounded clauses or a hand-off
    GET  /api/entitlements               FR-04  what the rules say, with reasons
    GET  /api/vouchers                   FR-04  issued vouchers
    POST /api/handoff                    FR-05  passenger or agent asks for a person
    GET  /api/handoff                    the passenger's own cases
    GET  /api/staff/cases                FR-09  staff queue (X-Staff-Key)
    POST /api/staff/cases/{id}/resolve   FR-09
"""

import asyncio
import hmac
import os
from contextlib import asynccontextmanager
from typing import Literal

import asyncpg
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from pydantic import BaseModel, Field

from kestrel import __version__, config  # noqa: F401  - config loads .env first
from kestrel.airports import cities_for
from kestrel.api import accounts, db, history
from kestrel.api.auth import (
    PassengerSession,
    clear_attempts,
    current_passenger,
    is_throttled,
    issue_token,
    register_failed_attempt,
)
from kestrel.api.booking import (
    SQL_LOAD_BOOKING,
    SQL_VOUCHERS,
    booking_to_dict,
    context_from_booking,
    issue_entitlements,
    load_booking,
    voucher_to_dict,
)
from kestrel.api.explain import explain_alternatives
from kestrel.api.timing import RequestTimingMiddleware
from kestrel.entitlements import evaluate, local_iso
from kestrel.handoff import (
    PASSENGER_TRIGGERS,
    SQL_LIST_BY_STATUS,
    SQL_LIST_FOR_PNR,
    SQL_RESOLVE,
    case_to_dict,
    open_case,
)
from kestrel.policy.embeddings import EmbeddingError, GeminiEmbedder
from kestrel.policy.retriever import PolicyRetriever
from kestrel.suggestions import suggestions

# ---------------------------------------------------------------------------
# SQL. Centralised so that a schema rename is a single-file edit.
# Verified against the deployed Supabase schema, not the Chapter 4 ERD.
# ---------------------------------------------------------------------------

SQL_AUTHENTICATE = """
    SELECT b.pnr_code,
        p.passenger_id::text AS passenger_id,
        p.last_name,
        p.asante_rewards_tier
    FROM pnr_bookings b
    JOIN passengers p ON p.passenger_id = b.passenger_id
    WHERE upper(b.pnr_code) = upper($1)
    AND lower(trim(p.last_name)) = lower(trim($2))
    LIMIT 1;
"""

# Same route, same cabin (migration 004 will not move a passenger across
# cabins), scheduled and in the future, with at least one free seat in that
# cabin. Ordered by arrival, because getting there is what the passenger
# cares about (wireframe M09).
SQL_FIND_ALTERNATIVES = """
    WITH bk AS (
        SELECT b.pnr_code,
               COALESCE(b.reaccommodated_flight_id, b.original_flight_id) AS current_flight,
               COALESCE(cs.cabin_class::text, 'ECONOMY')                  AS cabin
        FROM pnr_bookings b
        LEFT JOIN seats cs ON cs.seat_id = b.assigned_seat_id
        WHERE b.pnr_code = $1
    )
    SELECT alt.flight_id::text AS flight_id,
           alt.flight_number,
           alt.origin,
           alt.destination,
           alt.departure_time,
           alt.arrival_time,
           alt.aircraft_type,
           bk.cabin            AS cabin_class,
           count(s.seat_id)    AS available_seats
    FROM bk
    JOIN flights orig ON orig.flight_id = bk.current_flight
    JOIN flights alt  ON alt.origin = orig.origin
                     AND alt.destination = orig.destination
    JOIN seats   s    ON s.flight_id = alt.flight_id
                     AND s.status = 'AVAILABLE'
                     AND s.cabin_class::text = bk.cabin
    WHERE alt.flight_id <> orig.flight_id
      AND alt.status = 'SCHEDULED'
      AND alt.departure_time > now()
    GROUP BY alt.flight_id, alt.flight_number, alt.origin, alt.destination,
             alt.departure_time, alt.arrival_time, alt.aircraft_type, bk.cabin
    ORDER BY alt.arrival_time ASC NULLS LAST, alt.departure_time ASC
    LIMIT $2;
"""

SQL_REACCOMMODATE = "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3);"

# reaccommodate_passenger_atomic returns (success, seat, message) and records
# its reason code only in audit_logs; the message prefix identifies it.
_REFUSAL_PREFIXES = {"Target flight flies ": "DIFFERENT_ROUTE"}


def refusal_reason(message: str | None) -> str | None:
    return next((r for p, r in _REFUSAL_PREFIXES.items() if (message or "").startswith(p)), None)

STAFF_API_KEY = os.getenv("STAFF_API_KEY")
# Shared with the agent service, which sends it as X-Agent-Key to save the
# assistant's turns. Unset: assistant turns are refused (issue #12).
AGENT_HISTORY_KEY = os.getenv("AGENT_HISTORY_KEY")


@asynccontextmanager
async def lifespan(app: FastAPI):
    print("[INFO] Initializing database connection pool...")
    pool = await db.open_pool()
    keep_warm = asyncio.create_task(db.keep_warm(pool)) if pool is not None else None
    api_key = os.getenv("GOOGLE_API_KEY") or os.getenv("GEMINI_API_KEY")
    # No retry: a passenger is waiting on this request, so a rate limit is a
    # 502 at once rather than a wait of up to two minutes (issue #10;
    # ingestion retries).
    app.state.retriever = (
        PolicyRetriever(GeminiEmbedder(api_key, max_retries=0)) if api_key else None
    )
    warming = None
    if app.state.retriever is None:
        print("[WARN] GOOGLE_API_KEY is not set - policy search will return 503.")
    else:
        # In the background: the API answers at once; the common questions'
        # vectors arrive a second later.
        warming = asyncio.create_task(_warm_retriever(app.state.retriever))
    yield
    for task in (warming, keep_warm):
        if task is not None:
            task.cancel()
    print("[INFO] Closing database connection pool...")
    await db.close_pool()
    await accounts.aclose()
    if app.state.retriever is not None:
        await app.state.retriever.embedder.aclose()


async def _warm_retriever(retriever: PolicyRetriever) -> None:
    try:
        count = await retriever.warm()
        print(f"[INFO] Pre-embedded {count} common policy questions.")
    except EmbeddingError as exc:
        print(f"[WARN] Common policy questions not pre-embedded: {exc}")


app = FastAPI(
    title="Project Kestrel - Re-accommodation Engine",
    version=__version__,
    lifespan=lifespan,
)

# JSON bodies above 1 kB (alternatives, entitlements, the whole trip) shrink
# several times over a mobile connection.
app.add_middleware(GZipMiddleware, minimum_size=1000)

# The Flutter client (web build) is served from a different origin. Exact
# origins only: Starlette does not expand wildcards such as localhost:*.
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in os.getenv("ALLOWED_ORIGINS", "").split(",") if o.strip()],
    allow_credentials=True,
    allow_methods=["GET", "POST", "DELETE"],
    allow_headers=["Authorization", "Content-Type", "X-Staff-Key"],
    expose_headers=["X-Refusal-Reason"],
)
# Outermost, so the time covers everything the API does with a request.
app.add_middleware(RequestTimingMiddleware)


def get_retriever(request: Request) -> PolicyRetriever:
    retriever = getattr(request.app.state, "retriever", None)
    if retriever is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Policy search is unavailable: GOOGLE_API_KEY is not configured.",
        )
    return retriever


def require_staff(x_staff_key: str | None = Header(default=None)) -> str:
    """FR-09. A shared staff key for the Sprint 2 case queue; individual staff
    accounts are out of scope (Section 5.7)."""
    if not STAFF_API_KEY:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Staff access is disabled: STAFF_API_KEY is not configured.",
        )
    if not x_staff_key or not hmac.compare_digest(x_staff_key, STAFF_API_KEY):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid staff key.")
    return "STAFF"


# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------


class AuthRequest(BaseModel):
    pnr_code: str = Field(..., min_length=5, max_length=8, examples=["KQX89A"])
    last_name: str = Field(..., min_length=1, max_length=80, examples=["Otieno"])


class AccountRequest(BaseModel):
    """A Supabase access token, and optionally the booking to link it to."""

    access_token: str = Field(..., min_length=20, max_length=4096)
    pnr_code: str | None = Field(default=None, min_length=5, max_length=8, examples=["KQX89A"])
    last_name: str | None = Field(default=None, min_length=1, max_length=80, examples=["Otieno"])


class UnlinkRequest(BaseModel):
    access_token: str = Field(..., min_length=20, max_length=4096)


class ReaccommodateRequest(BaseModel):
    """
    Note what is absent: pnr_code and agent_id.

    The PNR is read from the authenticated session, which closes the
    horizontal privilege escalation that an untrusted body field allowed.
    The agent identifier is derived server-side, so the audit trail written
    by reaccommodate_passenger_atomic cannot be forged by a caller.
    """

    target_flight_id: str = Field(..., examples=["c2eebc99-9c0b-4ef8-bb6d-6bb9bd380a33"])


class HandoffRequest(BaseModel):
    trigger: Literal[
        "PASSENGER_REQUEST", "NO_ALTERNATIVES", "STEP_LIMIT", "REBOOKING_FAILED", "FRUSTRATION"
    ]
    question: str | None = Field(default=None, max_length=1000)
    summary: str = Field(..., min_length=1, max_length=2000)


class ChatTurnRequest(BaseModel):
    role: Literal["user", "assistant"]
    content: str = Field(..., min_length=1, max_length=history.MAX_CONTENT)


class ResolveRequest(BaseModel):
    resolved_by: str = Field(..., min_length=1, max_length=80)
    note: str = Field(..., min_length=1, max_length=2000)


# ---------------------------------------------------------------------------
# Service endpoints
# ---------------------------------------------------------------------------


@app.get("/")
async def root():
    return {
        "status": "online",
        "system": "Project Kestrel Re-accommodation Engine",
        "docs_url": "/docs",
    }


@app.get("/health")
async def health_check(request: Request):
    return {
        "status": "online",
        "version": __version__,
        "database": "connected" if db.pool_is_open() else "disconnected",
        "policy_search": "ready" if getattr(request.app.state, "retriever", None) else "unavailable",
    }


# ---------------------------------------------------------------------------
# Authentication and booking
# ---------------------------------------------------------------------------


@app.post("/api/auth/session")
async def create_session(payload: AuthRequest, pool: asyncpg.Pool = Depends(db.get_pool)):
    """FR-01. Exchange PNR + surname for a short-lived bearer token."""
    _count_attempt(payload.pnr_code)

    async with pool.acquire() as conn:
        row = await conn.fetchrow(SQL_AUTHENTICATE, payload.pnr_code, payload.last_name)

    if row is None:
        # One generic message for both wrong PNR and wrong surname, so the
        # endpoint cannot be used to enumerate valid booking codes.
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="No booking matches that PNR and surname.",
        )

    clear_attempts(payload.pnr_code)
    return _session_response(row)


def _count_attempt(*keys: str) -> None:
    """Refuse a throttled sign-in, else count this attempt as a failure
    until it succeeds (clear_attempts). Counted before any await (issue #3):
    guesses sent all at once each see the ones before them, so no more than
    MAX_FAILED_ATTEMPTS reach the database."""
    if any(is_throttled(k) for k in keys):
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Too many failed attempts for this booking. Try again in five minutes.",
        )
    for k in keys:
        register_failed_attempt(k)


def _session_response(row) -> dict:
    """The bearer token for an authenticated booking, as both sign-in
    endpoints return it."""
    token, expires_in = issue_token(
        pnr_code=row["pnr_code"],
        passenger_id=row["passenger_id"],
        last_name=row["last_name"],
        rewards_tier=row["asante_rewards_tier"],
    )
    return {
        "access_token": token,
        "token_type": "bearer",
        "expires_in": expires_in,
        "passenger": {
            "last_name": row["last_name"],
            "rewards_tier": row["asante_rewards_tier"],
            "pnr_code": row["pnr_code"],
        },
    }


@app.post("/api/auth/account")
async def create_account_session(payload: AccountRequest, pool: asyncpg.Pool = Depends(db.get_pool)):
    """
    Social sign-in. Supabase proves who the person is (Google, or an emailed
    one-time code); the account is linked to one passenger, and the answer is
    the same short-lived Kestrel token as /api/auth/session, with `linked`.

    - Already linked: sign in to that passenger's booking (disrupted first).
    - Not linked: an account is linked ONLY when the booking's passenger has
      the email address Supabase verified (issue #1). Booking reference +
      surname for someone else's booking opens that one booking for this
      visit, exactly as a guest sign-in would, and links nothing: references
      and surnames are printed on boarding passes and bag tags.
    - Booking reference alone, under another email address: 403.
    - Otherwise: {"link_required": true, "suggestions": [...]}, listing only
      bookings under the verified email address.

    Every attempt with a booking reference counts against that booking and
    against the account (the login limit, issue #31).
    """
    user_id, email, provider = await accounts.verify_supabase_user(payload.access_token)

    async with pool.acquire() as conn:
        linked = await conn.fetchrow(accounts.SQL_LINKED_PASSENGER, user_id)
        if linked is not None:
            row = await conn.fetchrow(accounts.SQL_LATEST_BOOKING, linked["passenger_id"])
            if row is None:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail="There are no bookings for this account.",
                )
            return {**_session_response(row), "linked": True}

        if payload.pnr_code:
            account_key = f"ACCOUNT:{user_id}"
            _count_attempt(payload.pnr_code, account_key)
            if payload.last_name:
                row = await conn.fetchrow(SQL_AUTHENTICATE, payload.pnr_code, payload.last_name)
                if row is None:
                    # The same message whether or not the booking exists, so
                    # this endpoint cannot be used to find valid codes either.
                    raise HTTPException(
                        status_code=status.HTTP_401_UNAUTHORIZED,
                        detail="No booking matches that PNR and surname.",
                    )
                owned = await conn.fetchrow(accounts.SQL_BOOKING_FOR_EMAIL, payload.pnr_code, email)
                method = "PNR_SURNAME"
            else:
                row = owned = await conn.fetchrow(accounts.SQL_BOOKING_FOR_EMAIL, payload.pnr_code, email)
                method = "EMAIL_MATCH"
                if row is None:
                    raise HTTPException(
                        status_code=status.HTTP_403_FORBIDDEN,
                        detail="That booking isn't under your email address. Add the surname on the "
                        "booking to open it.",
                    )
            clear_attempts(payload.pnr_code)
            clear_attempts(account_key)
            if owned is None:
                return {**_session_response(row), "linked": False}
            try:
                await accounts.link(
                    conn,
                    user_id=user_id,
                    passenger_id=row["passenger_id"],
                    email=email,
                    provider=provider,
                    pnr_code=row["pnr_code"],
                    method=method,
                )
            except accounts.AlreadyLinked:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="This booking is already linked to another account.",
                ) from None
            return {**_session_response(row), "linked": True}

        rows = await conn.fetch(accounts.SQL_SUGGESTIONS, email)
    return {
        "link_required": True,
        "suggestions": [accounts.suggestion_to_dict(r) for r in rows],
        "cities": cities_for(*(c for r in rows for c in (r["origin"], r["destination"]))),
    }


@app.delete("/api/auth/account/link")
async def unlink_account(payload: UnlinkRequest, pool: asyncpg.Pool = Depends(db.get_pool)):
    """'Unlink this booking': removes the link of the account Supabase vouches
    for, and nothing else (the request names no passenger or booking). The
    next sign-in with that account asks for a booking again."""
    user_id, _email, provider = await accounts.verify_supabase_user(payload.access_token)
    async with pool.acquire() as conn:
        unlinked = await accounts.unlink(conn, user_id=user_id, provider=provider)
    return {"unlinked": unlinked}


@app.get("/api/me")
async def me(
    session: PassengerSession = Depends(current_passenger),
    pool: asyncpg.Pool = Depends(db.get_pool),
):
    """The authenticated passenger's booking, original flight and current flight."""
    async with pool.acquire() as conn:
        row = await load_booking(conn, session.pnr_code)
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Booking not found.")
    return booking_to_dict(row)


@app.get("/api/flights/alternatives")
async def find_alternatives(
    limit: int = 5,
    session: PassengerSession = Depends(current_passenger),
    pool: asyncpg.Pool = Depends(db.get_pool),
):
    """
    Candidate recovery flights on the same route and in the same cabin as the
    passenger's current booking. Exists so the agent and the client discover a
    real flight_id rather than relying on the passenger to supply a UUID.
    """
    limit = max(1, min(limit, 10))

    # The booking is read alongside, on its own connection, for the reasons.
    rows, booking = await asyncio.gather(
        _fetch(pool, SQL_FIND_ALTERNATIVES, session.pnr_code, limit),
        _fetchrow(pool, SQL_LOAD_BOOKING, session.pnr_code),
    )
    return {
        "pnr_code": session.pnr_code,
        "count": len(rows),
        "alternatives": _explained(rows, booking),
    }


def _explained(rows, booking) -> list[dict]:
    """The alternatives with their reasons and badges (kestrel.api.explain)."""
    if booking is None:
        return [alternative_to_dict(r) for r in rows]
    return explain_alternatives(
        [
            {**alternative_to_dict(r), "_departure": r["departure_time"], "_arrival": r["arrival_time"]}
            for r in rows
        ],
        booking,
    )


def alternative_to_dict(r) -> dict:
    return {
        "flight_id": r["flight_id"],
        "flight_number": r["flight_number"],
        "origin": r["origin"],
        "destination": r["destination"],
        "departure_time": r["departure_time"].isoformat(),
        "arrival_time": r["arrival_time"].isoformat() if r["arrival_time"] else None,
        "departure_local": local_iso(r["departure_time"], r["origin"]),
        "arrival_local": local_iso(r["arrival_time"], r["destination"]),
        "aircraft_type": r["aircraft_type"],
        "cabin_class": r["cabin_class"],
        "available_seats": r["available_seats"],
    }


# ---------------------------------------------------------------------------
# The whole trip in one call (performance plan, Phase 2)
# ---------------------------------------------------------------------------

TRIP_ALTERNATIVES = 5


async def _fetchrow(pool: asyncpg.Pool, sql: str, *args):
    async with pool.acquire() as conn:
        return await conn.fetchrow(sql, *args)


async def _fetch(pool: asyncpg.Pool, sql: str, *args):
    async with pool.acquire() as conn:
        return await conn.fetch(sql, *args)


@app.get("/api/trip")
async def trip(
    session: PassengerSession = Depends(current_passenger),
    pool: asyncpg.Pool = Depends(db.get_pool),
):
    """
    Everything My trip, Flights, Vouchers and Help show, in one call: the
    booking (as GET /api/me), the top five alternatives (as GET
    /api/flights/alternatives), the entitlements (as GET /api/entitlements),
    the hand-off cases (as GET /api/handoff) and suggested next steps.

    The four queries do not depend on each other, so they run at once, each
    on its own pooled connection: the call costs one query's round trips, not
    four. The entitlement decision is computed from the booking row, with no
    further query.
    """
    booking, alternatives, vouchers, cases = await asyncio.gather(
        _fetchrow(pool, SQL_LOAD_BOOKING, session.pnr_code),
        _fetch(pool, SQL_FIND_ALTERNATIVES, session.pnr_code, TRIP_ALTERNATIVES),
        _fetch(pool, SQL_VOUCHERS, session.pnr_code),
        _fetch(pool, SQL_LIST_FOR_PNR, session.pnr_code),
    )
    if booking is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Booking not found.")
    booking_body = booking_to_dict(booking)
    case_bodies = [case_to_dict(r) for r in cases]
    return {
        "pnr_code": session.pnr_code,
        "booking": booking_body,
        "alternatives": _explained(alternatives, booking),
        "entitlements": {
            "decision": evaluate(context_from_booking(booking)).to_dict(),
            "vouchers": [voucher_to_dict(v) for v in vouchers],
        },
        "cases": case_bodies,
        "suggestions": suggestions(booking_body, case_bodies),
        # Airport names for the client (kestrel.airports, the one list).
        "cities": cities_for(booking["origin"], booking["destination"]),
    }


@app.post("/api/reaccommodate")
async def reaccommodate_passenger(
    payload: ReaccommodateRequest,
    session: PassengerSession = Depends(current_passenger),
    pool: asyncpg.Pool = Depends(db.get_pool),
):
    """
    FR-03. Delegates the state change to the atomic stored procedure, then
    applies the entitlement rules to the new itinerary (FR-04), so a passenger
    who has just been rebooked can see their vouchers straight away.
    """
    async with pool.acquire() as conn:
        try:
            result = await conn.fetchrow(
                SQL_REACCOMMODATE,
                session.pnr_code,  # from the token, never the request body
                payload.target_flight_id,
                session.audit_actor(),  # server-derived, unforgeable
            )
        except asyncpg.DataError as exc:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="target_flight_id is not a valid flight identifier.",
            ) from exc

        # A procedure that returns no row is a failure mode the first version
        # crashed on with a TypeError before it could return a useful status.
        if result is None:
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail="Re-accommodation procedure returned no result.",
            )

        if not result["success"]:
            # The procedure's own words, plus which refusal it was when the
            # caller must react differently (the agent offers same-route
            # flights again after DIFFERENT_ROUTE, migration 011).
            reason = refusal_reason(result["message"])
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=result["message"],
                headers={"X-Refusal-Reason": reason} if reason else None,
            )

        # The rebooking has already committed; entitlements are a separate
        # transaction. If issuing them fails, the passenger is still rebooked
        # and GET /api/entitlements can be retried.
        try:
            issued = await issue_entitlements(conn, session.pnr_code, session.audit_actor())
        except asyncpg.PostgresError as exc:
            print(f"[WARN] Entitlements not issued for {session.pnr_code}: {exc}")
            issued = None
        booking = await load_booking(conn, session.pnr_code)

    return {
        "success": True,
        "assigned_seat": result["assigned_seat_number"],
        "message": result["message"],
        "booking": booking_to_dict(booking) if booking else None,
        "entitlements": issued,
    }


# ---------------------------------------------------------------------------
# Policy retrieval (FR-02, FR-05)
# ---------------------------------------------------------------------------


@app.get("/api/policy/search")
async def search_policy(
    q: str = Query(..., min_length=3, max_length=500),
    k: int = Query(3, ge=1, le=5),
    handoff: bool = Query(True, description="Open a hand-off case when out of scope"),
    session: PassengerSession = Depends(current_passenger),
    pool: asyncpg.Pool = Depends(db.get_pool),
    retriever: PolicyRetriever = Depends(get_retriever),
):
    """
    Top-k policy clauses for a question, with cosine similarities. When the
    best similarity is below tau the question is out of scope: no clauses are
    offered as grounding and a hand-off case is opened instead.
    """
    try:
        # The question's vector first, holding no connection: a slow or
        # rate-limited embedding call must not tie up the pool (issue #10).
        # search() then finds it in the retriever's cache.
        await retriever.vector(q)
        async with pool.acquire() as conn:
            result = await retriever.search(conn, q, k)
            body = result.to_dict()
            body["case"] = None
            if not result.in_scope and handoff:
                body["case"] = await open_case(
                    conn,
                    pnr_code=session.pnr_code,
                    trigger="LOW_SIMILARITY",
                    actor=session.audit_actor(),
                    question=q,
                    summary="Policy question could not be grounded in the policy corpus.",
                    top_similarity=result.top_similarity,
                    similarity_scores=[
                        {"clause_ref": h.clause_ref, "similarity": round(h.similarity, 4)}
                        for h in result.hits
                    ],
                )
    except EmbeddingError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY, detail=f"Embedding service error: {exc}"
        ) from exc
    except asyncpg.UndefinedFunctionError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Policy store not installed: apply migration 005 and run ingest_policies.py.",
        ) from exc
    return body


# ---------------------------------------------------------------------------
# Entitlements (FR-04)
# ---------------------------------------------------------------------------


@app.get("/api/entitlements")
async def get_entitlements(
    session: PassengerSession = Depends(current_passenger),
    pool: asyncpg.Pool = Depends(db.get_pool),
):
    """What the deterministic rules give this booking right now, with reasons
    for anything that does not apply, plus the vouchers already issued. The
    two reads are independent, so they run at once on two connections (the
    same answer as before, in one query's time)."""
    booking, vouchers = await asyncio.gather(
        _fetchrow(pool, SQL_LOAD_BOOKING, session.pnr_code),
        _fetch(pool, SQL_VOUCHERS, session.pnr_code),
    )
    if booking is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Booking not found.")
    decision = evaluate(context_from_booking(booking))
    return {
        "pnr_code": session.pnr_code,
        "decision": decision.to_dict(),
        "vouchers": [voucher_to_dict(v) for v in vouchers],
    }


@app.get("/api/vouchers")
async def list_vouchers(
    session: PassengerSession = Depends(current_passenger),
    pool: asyncpg.Pool = Depends(db.get_pool),
):
    async with pool.acquire() as conn:
        rows = await conn.fetch(SQL_VOUCHERS, session.pnr_code)
    return {"pnr_code": session.pnr_code, "vouchers": [voucher_to_dict(r) for r in rows]}


# ---------------------------------------------------------------------------
# Conversation memory (Phase 4)
# ---------------------------------------------------------------------------


@app.get("/api/chat/history")
async def chat_history(
    session: PassengerSession = Depends(current_passenger),
    pool: asyncpg.Pool = Depends(db.get_pool),
):
    """The booking's last 20 turns, oldest first."""
    async with pool.acquire() as conn:
        rows = await conn.fetch(history.SQL_HISTORY, session.pnr_code, history.HISTORY_TURNS)
    return {"pnr_code": session.pnr_code, "turns": [history.turn_to_dict(r) for r in rows]}


@app.post("/api/chat/history", status_code=status.HTTP_201_CREATED)
async def append_chat_turn(
    payload: ChatTurnRequest,
    session: PassengerSession = Depends(current_passenger),
    pool: asyncpg.Pool = Depends(db.get_pool),
    x_agent_key: str | None = Header(default=None),
):
    """One turn (the agent service saves both after each completed reply).

    An assistant turn is replayed to the model on the next visit, so only the
    agent service may write one: it proves itself with X-Agent-Key. A
    passenger token alone can add user turns only (issue #12). Storage is
    capped at the newest 100 turns per booking by migration 012's trigger."""
    if payload.role == "assistant" and not (
        AGENT_HISTORY_KEY and x_agent_key and hmac.compare_digest(x_agent_key, AGENT_HISTORY_KEY)
    ):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only the assistant service can save the assistant's turns.",
        )
    async with pool.acquire() as conn:
        row = await conn.fetchrow(history.SQL_APPEND, session.pnr_code, payload.role, payload.content)
    return history.turn_to_dict(row)


@app.delete("/api/chat/history")
async def clear_chat_history(
    session: PassengerSession = Depends(current_passenger),
    pool: asyncpg.Pool = Depends(db.get_pool),
):
    """'Start over': the booking's conversation is deleted."""
    async with pool.acquire() as conn:
        result = await conn.execute(history.SQL_CLEAR, session.pnr_code)
    return {"pnr_code": session.pnr_code, "deleted": int(result.split()[-1]) if result else 0}


# ---------------------------------------------------------------------------
# Hand-off (FR-05) and the staff queue (FR-09)
# ---------------------------------------------------------------------------


@app.post("/api/handoff", status_code=status.HTTP_201_CREATED)
async def create_handoff(
    payload: HandoffRequest,
    session: PassengerSession = Depends(current_passenger),
    pool: asyncpg.Pool = Depends(db.get_pool),
):
    assert payload.trigger in PASSENGER_TRIGGERS  # guaranteed by the Literal type
    async with pool.acquire() as conn:
        try:
            case = await open_case(
                conn,
                pnr_code=session.pnr_code,
                trigger=payload.trigger,
                actor=session.audit_actor(),
                question=payload.question,
                summary=payload.summary,
            )
        except LookupError as exc:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc
    return case


@app.get("/api/handoff")
async def my_handoffs(
    session: PassengerSession = Depends(current_passenger),
    pool: asyncpg.Pool = Depends(db.get_pool),
):
    async with pool.acquire() as conn:
        rows = await conn.fetch(SQL_LIST_FOR_PNR, session.pnr_code)
    return {"pnr_code": session.pnr_code, "cases": [case_to_dict(r) for r in rows]}


@app.get("/api/staff/cases")
async def staff_cases(
    status_filter: Literal["OPEN", "RESOLVED", "ALL"] = Query("OPEN", alias="status"),
    limit: int = Query(50, ge=1, le=200),
    _: str = Depends(require_staff),
    pool: asyncpg.Pool = Depends(db.get_pool),
):
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            SQL_LIST_BY_STATUS, None if status_filter == "ALL" else status_filter, limit
        )
    return {"count": len(rows), "cases": [case_to_dict(r) for r in rows]}


@app.post("/api/staff/cases/{case_id}/resolve")
async def resolve_case(
    case_id: int,
    payload: ResolveRequest,
    _: str = Depends(require_staff),
    pool: asyncpg.Pool = Depends(db.get_pool),
):
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            SQL_RESOLVE, case_id, f"STAFF:{payload.resolved_by}", payload.note
        )
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="No open case with that id."
        )
    return case_to_dict(row)
