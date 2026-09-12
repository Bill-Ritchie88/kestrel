"""
Project Kestrel - Re-accommodation Engine (REST API Tier)

Deterministic layer between the agentic AI tier and the database tier.
The agent never touches the database; it can only invoke the endpoints below,
and every endpoint that mutates booking state requires an authenticated session.
"""

import os
from contextlib import asynccontextmanager
from pathlib import Path

import asyncpg
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, HTTPException, status
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from auth import (
    PassengerSession,
    clear_attempts,
    current_passenger,
    is_throttled,
    issue_token,
    register_failed_attempt,
)

env_path = Path(__file__).resolve().parent / ".env"
load_dotenv(dotenv_path=env_path)

DATABASE_URL = os.getenv("DATABASE_URL")
db_pool: asyncpg.Pool | None = None

# ---------------------------------------------------------------------------
# SQL. Centralised so that a schema rename is a single-file edit.
# Verified against the deployed Supabase schema (information_schema dump,
# 12 September 2026), not against the Chapter 4 ERD, which is out of date.
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

SQL_FIND_ALTERNATIVES = """
    SELECT alt.flight_id::text  AS flight_id,
        alt.flight_number,
        alt.departure_time,
        count(s.seat_id)     AS available_seats
    FROM pnr_bookings b
    JOIN flights orig ON orig.flight_id =
    COALESCE(b.reaccommodated_flight_id, b.original_flight_id)
    JOIN flights alt  ON alt.origin = orig.origin
    AND alt.destination = orig.destination
    JOIN seats   s    ON s.flight_id = alt.flight_id
    AND s.status = 'AVAILABLE'
    WHERE upper(b.pnr_code) = upper($1)
    AND alt.flight_id <> orig.flight_id
    AND alt.status = 'SCHEDULED'
    AND alt.departure_time > now()
    GROUP BY alt.flight_id, alt.flight_number, alt.departure_time
    ORDER BY alt.departure_time ASC
    LIMIT $2;
"""

SQL_REACCOMMODATE = "SELECT * FROM reaccommodate_passenger_atomic($1, $2, $3);"


@asynccontextmanager
async def lifespan(app: FastAPI):
    global db_pool
    print("[INFO] Initializing database connection pool...")
    db_pool = await asyncpg.create_pool(
        dsn=DATABASE_URL,
        min_size=1,
        max_size=5,
        statement_cache_size=0,  # required for asyncpg behind a Supabase pooler
    )
    yield
    print("[INFO] Closing database connection pool...")
    if db_pool:
        await db_pool.close()


app = FastAPI(
    title="Project Kestrel - Re-accommodation Engine",
    version="2.0.0",
    lifespan=lifespan,
)

# The Flutter client is served from a different origin.
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.getenv("ALLOWED_ORIGINS", "http://localhost:*").split(","),
    allow_credentials=True,
    allow_methods=["GET", "POST"],
    allow_headers=["Authorization", "Content-Type"],
)


def require_pool() -> asyncpg.Pool:
    if not db_pool:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Database connection pool unavailable.",
        )
    return db_pool


# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------


class AuthRequest(BaseModel):
    pnr_code: str = Field(..., min_length=5, max_length=8, examples=["KQX89A"])
    last_name: str = Field(..., min_length=1, max_length=80, examples=["Otieno"])


class ReaccommodateRequest(BaseModel):
    """
    Note what is absent: pnr_code and agent_id.

    The PNR is read from the authenticated session, which closes the
    horizontal privilege escalation that an untrusted body field allowed.
    The agent identifier is derived server-side, so the audit trail written
    by reaccommodate_passenger_atomic cannot be forged by a caller.
    """

    target_flight_id: str = Field(
        ..., examples=["c2eebc99-9c0b-4ef8-bb6d-6bb9bd380a33"]
    )


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@app.get("/")
async def root():
    return {
        "status": "online",
        "system": "Project Kestrel Re-accommodation Engine",
        "docs_url": "/docs",
    }


@app.get("/health")
async def health_check():
    return {"status": "online", "database": "connected" if db_pool else "disconnected"}


@app.post("/api/auth/session")
async def create_session(payload: AuthRequest):
    """FR-01. Exchange PNR + surname for a short-lived bearer token."""
    pool = require_pool()

    if is_throttled(payload.pnr_code):
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Too many failed attempts for this booking. Try again in five minutes.",
        )

    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            SQL_AUTHENTICATE, payload.pnr_code, payload.last_name
        )

    if row is None:
        register_failed_attempt(payload.pnr_code)
        # One generic message for both wrong PNR and wrong surname, so the
        # endpoint cannot be used to enumerate valid booking codes.
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="No booking matches that PNR and surname.",
        )

    clear_attempts(payload.pnr_code)
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


@app.get("/api/flights/alternatives")
async def find_alternatives(
    limit: int = 5,
    session: PassengerSession = Depends(current_passenger),
):
    """
    Candidate recovery flights on the same route as the passenger's current
    booking. Exists so the agent can discover a real flight_id rather than
    relying on the passenger to supply a UUID, which no passenger ever has.
    """
    pool = require_pool()
    limit = max(1, min(limit, 10))

    async with pool.acquire() as conn:
        rows = await conn.fetch(SQL_FIND_ALTERNATIVES, session.pnr_code, limit)

    return {
        "pnr_code": session.pnr_code,
        "count": len(rows),
        "alternatives": [
            {
                "flight_id": r["flight_id"],
                "flight_number": r["flight_number"],
                "departure_time": r["departure_time"].isoformat(),
                "available_seats": r["available_seats"],
            }
            for r in rows
        ],
    }


@app.post("/api/reaccommodate")
async def reaccommodate_passenger(
    payload: ReaccommodateRequest,
    session: PassengerSession = Depends(current_passenger),
):
    """FR-03. Delegates the actual state change to the atomic stored procedure."""
    pool = require_pool()

    async with pool.acquire() as conn:
        try:
            result = await conn.fetchrow(
                SQL_REACCOMMODATE,
                session.pnr_code,          # from the token, never the request body
                payload.target_flight_id,
                session.audit_actor(),     # server-derived, unforgeable
            )
        except asyncpg.DataError:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="target_flight_id is not a valid flight identifier.",
            )

    # A procedure that returns no row is a failure mode the previous version
    # crashed on with a TypeError before it could return a useful status.
    if result is None:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Re-accommodation procedure returned no result.",
        )

    if not result["success"]:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=result["message"],
        )

    return {
        "success": True,
        "assigned_seat": result["assigned_seat_number"],
        "message": result["message"],
    }