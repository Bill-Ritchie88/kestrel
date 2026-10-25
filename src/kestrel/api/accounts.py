"""
Project Kestrel - passenger accounts (social sign-in).

Supabase Auth proves who the person is: a Google sign-in, or a 6-digit code
emailed to them. This module checks a Supabase access token by asking
Supabase which user it belongs to, and links that account to one passenger,
once (migration 009, passenger_accounts). After that, POST /api/auth/account
issues the same short-lived Kestrel token as POST /api/auth/session, so every
other endpoint is unchanged.

No JWT library: GET /auth/v1/user makes Supabase validate the token itself
(signature, expiry, sign-out), which also keeps working when it rotates its
signing keys.
"""

import json
import os

import httpx
from fastapi import HTTPException, status

from kestrel import config  # noqa: F401  - loads .env before anything reads it
from kestrel.entitlements import local_iso

SUPABASE_TIMEOUT_SECONDS = 5.0

# The endpoint tests swap in an httpx.MockTransport to stand in for Supabase.
_transport: httpx.AsyncBaseTransport | None = None

# One client for the life of the process (issue #30): every sign-in used to
# open a new connection (TLS, several round trips) to Supabase. Rebuilt only
# if a test swaps the transport.
_client: httpx.AsyncClient | None = None
_client_transport: httpx.AsyncBaseTransport | None = None


def _http() -> httpx.AsyncClient:
    global _client, _client_transport
    if _client is None or _client.is_closed or _client_transport is not _transport:
        _client = httpx.AsyncClient(timeout=SUPABASE_TIMEOUT_SECONDS, transport=_transport)
        _client_transport = _transport
    return _client


async def aclose() -> None:
    if _client is not None:
        await _client.aclose()

# ---------------------------------------------------------------------------
# SQL
# ---------------------------------------------------------------------------

SQL_LINKED_PASSENGER = """
    SELECT passenger_id::text AS passenger_id
    FROM passenger_accounts
    WHERE auth_user_id = $1::uuid;
"""

# The linked passenger's booking to sign in to: a disrupted one first (that is
# why they are here), then one already rebooked, then the most recently
# changed.
SQL_LATEST_BOOKING = """
    SELECT b.pnr_code,
        p.passenger_id::text AS passenger_id,
        p.last_name,
        p.asante_rewards_tier
    FROM pnr_bookings b
    JOIN passengers p ON p.passenger_id = b.passenger_id
    WHERE b.passenger_id = $1::uuid
    ORDER BY CASE b.booking_status
                 WHEN 'DISRUPTED' THEN 0
                 WHEN 'REACCOMMODATED' THEN 1
                 ELSE 2
             END,
             b.updated_at DESC NULLS LAST
    LIMIT 1;
"""

# A booking reference alone links only when the booking's passenger has the
# email address Supabase verified.
SQL_BOOKING_FOR_EMAIL = """
    SELECT b.pnr_code,
        p.passenger_id::text AS passenger_id,
        p.last_name,
        p.asante_rewards_tier
    FROM pnr_bookings b
    JOIN passengers p ON p.passenger_id = b.passenger_id
    WHERE upper(b.pnr_code) = upper($1)
    AND lower(p.email) = lower($2)
    LIMIT 1;
"""

# "Is this your booking?" - only bookings under the verified email address.
SQL_SUGGESTIONS = """
    SELECT b.pnr_code,
        f.origin,
        f.destination,
        f.departure_time,
        b.booking_status::text AS booking_status
    FROM pnr_bookings b
    JOIN passengers p ON p.passenger_id = b.passenger_id
    LEFT JOIN flights f ON f.flight_id = COALESCE(b.reaccommodated_flight_id, b.original_flight_id)
    WHERE lower(p.email) = lower($1)
    ORDER BY CASE b.booking_status
                 WHEN 'DISRUPTED' THEN 0
                 WHEN 'REACCOMMODATED' THEN 1
                 ELSE 2
             END,
             f.departure_time DESC NULLS LAST
    LIMIT 10;
"""

# Inserts nothing if the account or the passenger is already linked; the
# caller tells those two apart.
SQL_INSERT_LINK = """
    INSERT INTO passenger_accounts (auth_user_id, passenger_id, email, provider)
    VALUES ($1::uuid, $2::uuid, $3, $4)
    ON CONFLICT DO NOTHING
    RETURNING passenger_id::text AS passenger_id;
"""

SQL_AUDIT_LINK = """
    INSERT INTO audit_logs (pnr_code, actor, action, details)
    VALUES ($1, $2, 'ACCOUNT_LINKED', $3::jsonb);
"""

# "Unlink this booking": only the signed-in account's own row.
SQL_DELETE_LINK = """
    DELETE FROM passenger_accounts
    WHERE auth_user_id = $1::uuid
    RETURNING passenger_id::text AS passenger_id;
"""

SQL_AUDIT_UNLINK = """
    INSERT INTO audit_logs (pnr_code, actor, action, details)
    VALUES (NULL, $1, 'ACCOUNT_UNLINKED', $2::jsonb);
"""

# ---------------------------------------------------------------------------
# Supabase
# ---------------------------------------------------------------------------


def _unauthorized(detail: str = "Your sign-in could not be verified. Please sign in again.") -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": "Bearer"},
    )


async def verify_supabase_user(access_token: str) -> tuple[str, str, str]:
    """
    Ask Supabase who this access token belongs to.

    Returns (user_id, email, provider), e.g. ('8d0f…', 'grace@example.com',
    'google'). Raises 401 for a token Supabase does not accept or a user
    without a verified email address, and 503 when Supabase is not configured
    or cannot be reached.
    """
    url = os.getenv("SUPABASE_URL", "").rstrip("/")
    anon_key = os.getenv("SUPABASE_ANON_KEY", "")
    if not url or not anon_key:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Account sign-in is not configured: SUPABASE_URL or SUPABASE_ANON_KEY is not set.",
        )
    try:
        res = await _http().get(
            f"{url}/auth/v1/user",
            headers={"Authorization": f"Bearer {access_token}", "apikey": anon_key},
        )
    except httpx.HTTPError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="The sign-in service could not be reached. Please try again.",
        ) from exc

    if res.status_code != 200:
        raise _unauthorized()
    try:
        user = res.json()
    except ValueError:
        raise _unauthorized() from None

    user_id = user.get("id")
    email = (user.get("email") or "").strip()
    # Google confirms the address; an emailed code confirms it by arriving.
    # An unconfirmed address must never match a booking.
    confirmed = user.get("email_confirmed_at") or user.get("confirmed_at")
    if not user_id or not email or not confirmed:
        raise _unauthorized("Your email address isn't verified yet. Please sign in again.")
    provider = str((user.get("app_metadata") or {}).get("provider") or "email")[:20]
    return str(user_id), email, provider


# ---------------------------------------------------------------------------
# Linking
# ---------------------------------------------------------------------------


def audit_actor(provider: str, user_id: str) -> str:
    return f"ACCOUNT:{provider}:{user_id}"


class AlreadyLinked(Exception):
    """The booking's passenger is linked to a different account."""


async def link(conn, *, user_id: str, passenger_id: str, email: str, provider: str, pnr_code: str, method: str) -> None:
    """Link the account to the passenger and audit it, in one transaction.

    Raises AlreadyLinked if the passenger already belongs to another account.
    Linking the same account to the same passenger again is a no-op.
    """
    async with conn.transaction():
        inserted = await conn.fetchrow(SQL_INSERT_LINK, user_id, passenger_id, email, provider)
        if inserted is None:
            existing = await conn.fetchrow(SQL_LINKED_PASSENGER, user_id)
            if existing is None or existing["passenger_id"] != passenger_id:
                raise AlreadyLinked
            return
        await conn.execute(
            SQL_AUDIT_LINK,
            pnr_code,
            audit_actor(provider, user_id),
            json.dumps({"provider": provider, "method": method}),
        )


async def unlink(conn, *, user_id: str, provider: str) -> bool:
    """Remove this account's link, if any, and audit it. Returns whether a
    link was removed."""
    async with conn.transaction():
        row = await conn.fetchrow(SQL_DELETE_LINK, user_id)
        if row is None:
            return False
        await conn.execute(
            SQL_AUDIT_UNLINK,
            audit_actor(provider, user_id),
            json.dumps({"passenger_id": row["passenger_id"]}),
        )
    return True


def suggestion_to_dict(row) -> dict:
    departure = local_iso(row["departure_time"], row["origin"]) if row["origin"] else None
    return {
        "pnr_code": row["pnr_code"],
        "origin": row["origin"],
        "destination": row["destination"],
        "departure_date": departure[:10] if departure else None,
        "booking_status": row["booking_status"],
    }
