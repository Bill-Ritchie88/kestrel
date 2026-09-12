"""
Project Kestrel - Passenger session authentication.

A passenger session is a short-lived, HMAC-signed bearer token issued by
POST /api/auth/session after a successful PNR + surname lookup. It carries
just enough claims for main.py to authorize the passenger's own booking
without a second database round trip, and it is what lets
audit_actor() derive an unforgeable actor string for the audit trail.

No JWT library is used deliberately: the project has no requirements.txt and
the token only needs to survive one process's lifetime, so a minimal
stdlib-only HMAC scheme avoids an undeclared dependency.
"""

import base64
import hashlib
import hmac
import json
import os
import secrets
import time
from dataclasses import dataclass

from fastapi import Header, HTTPException, status

# ---------------------------------------------------------------------------
# Signing secret.
#
# Set SESSION_SECRET in .env for tokens that survive a process restart. When
# it is absent we fall back to a random secret generated for this process
# only, so the API still starts, but every session is invalidated the next
# time it restarts. That trade-off is fine for development; it is not fine
# for a real deployment.
# ---------------------------------------------------------------------------

SESSION_SECRET = os.getenv("SESSION_SECRET")
if not SESSION_SECRET:
    SESSION_SECRET = secrets.token_hex(32)
    print(
        "[WARN] SESSION_SECRET is not set in .env - using a random secret for "
        "this process only. All bearer tokens will be invalidated on restart. "
        "Set SESSION_SECRET before deploying."
    )

TOKEN_TTL_SECONDS = 15 * 60  # matches the "short-lived" claim in main.py's docstring

MAX_FAILED_ATTEMPTS = 5
THROTTLE_WINDOW_SECONDS = 5 * 60


def _b64url_encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _b64url_decode(data: str) -> bytes:
    padding = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + padding)


def _sign(payload_b64: str) -> str:
    digest = hmac.new(
        SESSION_SECRET.encode(), payload_b64.encode(), hashlib.sha256
    ).digest()
    return _b64url_encode(digest)


@dataclass
class PassengerSession:
    pnr_code: str
    passenger_id: str
    last_name: str
    rewards_tier: str | None

    def audit_actor(self) -> str:
        """
        Server-derived actor string for the audit_logs.actor column.

        Distinguishes a passenger acting on their own booking from the
        autonomous agent tier ('AGENT_AI' / 'GEMINI_REBOOKING_AGENT'), and
        cannot be forged by a request body field.
        """
        return f"PASSENGER:{self.pnr_code}"


def issue_token(
    *, pnr_code: str, passenger_id: str, last_name: str, rewards_tier: str | None
) -> tuple[str, int]:
    """Create a signed bearer token for a successfully authenticated passenger."""
    payload = {
        "pnr_code": pnr_code,
        "passenger_id": passenger_id,
        "last_name": last_name,
        "rewards_tier": rewards_tier,
        "exp": int(time.time()) + TOKEN_TTL_SECONDS,
    }
    payload_b64 = _b64url_encode(json.dumps(payload, separators=(",", ":")).encode())
    token = f"{payload_b64}.{_sign(payload_b64)}"
    return token, TOKEN_TTL_SECONDS


def _decode_token(token: str) -> PassengerSession:
    try:
        payload_b64, signature = token.split(".", 1)
    except ValueError:
        raise ValueError("Malformed token.")

    if not hmac.compare_digest(signature, _sign(payload_b64)):
        raise ValueError("Invalid token signature.")

    try:
        payload = json.loads(_b64url_decode(payload_b64))
    except (ValueError, UnicodeDecodeError):
        raise ValueError("Malformed token payload.")

    if payload.get("exp", 0) < time.time():
        raise ValueError("Token has expired.")

    return PassengerSession(
        pnr_code=payload["pnr_code"],
        passenger_id=payload["passenger_id"],
        last_name=payload["last_name"],
        rewards_tier=payload.get("rewards_tier"),
    )


async def current_passenger(
    authorization: str | None = Header(default=None),
) -> PassengerSession:
    """
    FastAPI dependency used by endpoints that act on the caller's own booking.

    Verifies the bearer token issued by /api/auth/session and raises 401 for
    anything missing, malformed, tampered with, or expired.
    """
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing or malformed Authorization header.",
            headers={"WWW-Authenticate": "Bearer"},
        )

    token = authorization.removeprefix("Bearer ").strip()
    try:
        return _decode_token(token)
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=str(exc),
            headers={"WWW-Authenticate": "Bearer"},
        )


# ---------------------------------------------------------------------------
# Login throttling for /api/auth/session.
#
# In-memory and per-process: correct for a single-instance deployment, but it
# will not share state across multiple workers or replicas.
# ---------------------------------------------------------------------------

_failed_attempts: dict[str, list[float]] = {}


def _normalize(pnr_code: str) -> str:
    return pnr_code.strip().upper()


def _recent_attempts(key: str, now: float) -> list[float]:
    attempts = [t for t in _failed_attempts.get(key, []) if now - t < THROTTLE_WINDOW_SECONDS]
    _failed_attempts[key] = attempts
    return attempts


def register_failed_attempt(pnr_code: str) -> None:
    key = _normalize(pnr_code)
    now = time.time()
    attempts = _recent_attempts(key, now)
    attempts.append(now)
    _failed_attempts[key] = attempts


def is_throttled(pnr_code: str) -> bool:
    key = _normalize(pnr_code)
    return len(_recent_attempts(key, time.time())) >= MAX_FAILED_ATTEMPTS


def clear_attempts(pnr_code: str) -> None:
    _failed_attempts.pop(_normalize(pnr_code), None)
