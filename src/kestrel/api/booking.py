"""
Booking state and entitlement issuing for the REST tier.

load_booking() is the single query that describes a passenger's situation:
the booking, the original (possibly cancelled) flight, the flight they are
now on, their seat and cabin. GET /api/me, the entitlement endpoints and the
post-rebooking issue step all build on it, so they can never disagree.
"""

from __future__ import annotations

import json
import secrets
from datetime import datetime, timezone

from kestrel.entitlements import STORABLE_TYPES, DisruptionContext, EntitlementDecision, evaluate

SQL_LOAD_BOOKING = """
    SELECT b.pnr_code,
           b.booking_status::text           AS booking_status,
           p.first_name, p.last_name, p.asante_rewards_tier,
           o.flight_id::text                AS original_flight_id,
           o.flight_number                  AS original_flight_number,
           o.origin, o.destination,
           o.departure_time                 AS original_departure,
           o.arrival_time                   AS original_arrival,
           o.status::text                   AS original_status,
           o.disruption_reason,
           o.aircraft_type                  AS original_aircraft,
           c.flight_id::text                AS current_flight_id,
           c.flight_number                  AS current_flight_number,
           c.departure_time                 AS current_departure,
           c.arrival_time                   AS current_arrival,
           s.seat_number,
           COALESCE(s.cabin_class::text, 'ECONOMY') AS cabin_class
    FROM pnr_bookings b
    JOIN passengers p ON p.passenger_id = b.passenger_id
    JOIN flights    o ON o.flight_id    = b.original_flight_id
    LEFT JOIN flights c ON c.flight_id  = b.reaccommodated_flight_id
    LEFT JOIN seats   s ON s.seat_id    = b.assigned_seat_id
    WHERE b.pnr_code = $1;
"""

SQL_VOUCHERS = """
    SELECT voucher_code, entitlement_type, quantity, amount, currency, points, status,
           rule_id, basis, valid_until, issued_at
    FROM vouchers WHERE pnr_code = $1
    ORDER BY array_position(
        ARRAY['MEAL','HOTEL','TRANSPORT','ASANTE_POINTS','CASH_COMPENSATION'], entitlement_type);
"""

SQL_UPSERT_VOUCHER = """
    INSERT INTO vouchers (voucher_code, pnr_code, entitlement_type, quantity, amount,
                          currency, points, status, rule_id, basis, valid_until)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
    ON CONFLICT (pnr_code, entitlement_type) DO UPDATE SET
        quantity    = EXCLUDED.quantity,
        amount      = EXCLUDED.amount,
        currency    = EXCLUDED.currency,
        points      = EXCLUDED.points,
        -- A voucher already redeemed stays redeemed; everything else follows
        -- the latest evaluation.
        status      = CASE WHEN vouchers.status = 'REDEEMED' THEN vouchers.status
                           ELSE EXCLUDED.status END,
        rule_id     = EXCLUDED.rule_id,
        basis       = EXCLUDED.basis,
        valid_until = EXCLUDED.valid_until;
"""

# Entitlements that applied before a rebooking but no longer do (a hotel
# night, say, after a move onto a same-day flight) are voided, not deleted.
SQL_VOID_STALE = """
    UPDATE vouchers SET status = 'VOID'
    WHERE pnr_code = $1 AND status IN ('ISSUED', 'ELIGIBLE')
      AND NOT (entitlement_type = ANY($2::text[]));
"""

SQL_AUDIT = """
    INSERT INTO audit_logs (pnr_code, actor, action, details)
    VALUES ($1, $2, 'ENTITLEMENTS_ISSUED', $3::jsonb);
"""

_CODE_PREFIX = {
    "MEAL": "MV",
    "HOTEL": "HT",
    "TRANSPORT": "TR",
    "ASANTE_POINTS": "AP",
    "CASH_COMPENSATION": "CC",
}
_CODE_LETTERS = "ABCDEFGHJKLMNPQRSTUVWXYZ"


def voucher_code(entitlement_type: str) -> str:
    """e.g. KQ-MV-8842-XT. Random, so codes cannot be guessed from a PNR."""
    digits = f"{secrets.randbelow(10_000):04d}"
    letters = "".join(secrets.choice(_CODE_LETTERS) for _ in range(2))
    return f"KQ-{_CODE_PREFIX[entitlement_type]}-{digits}-{letters}"


def _iso(dt: datetime | None) -> str | None:
    return dt.isoformat() if dt else None


def booking_to_dict(row) -> dict:
    return {
        "pnr_code": row["pnr_code"],
        "booking_status": row["booking_status"],
        "passenger": {
            "first_name": row["first_name"],
            "last_name": row["last_name"],
            "rewards_tier": row["asante_rewards_tier"],
        },
        "original_flight": {
            "flight_id": row["original_flight_id"],
            "flight_number": row["original_flight_number"],
            "origin": row["origin"],
            "destination": row["destination"],
            "departure_time": _iso(row["original_departure"]),
            "arrival_time": _iso(row["original_arrival"]),
            "status": row["original_status"],
            "disruption_reason": row["disruption_reason"],
            "aircraft_type": row["original_aircraft"],
        },
        "current_flight": (
            {
                "flight_id": row["current_flight_id"],
                "flight_number": row["current_flight_number"],
                "departure_time": _iso(row["current_departure"]),
                "arrival_time": _iso(row["current_arrival"]),
            }
            if row["current_flight_id"]
            else None
        ),
        "seat_number": row["seat_number"],
        "cabin_class": row["cabin_class"],
    }


def voucher_to_dict(row) -> dict:
    return {
        "voucher_code": row["voucher_code"],
        "entitlement_type": row["entitlement_type"],
        "quantity": row["quantity"],
        "amount": float(row["amount"]) if row["amount"] is not None else None,
        "currency": row["currency"],
        "points": row["points"],
        "status": row["status"],
        "rule_id": row["rule_id"],
        "basis": row["basis"],
        "valid_until": _iso(row["valid_until"]),
        "issued_at": _iso(row["issued_at"]),
    }


async def load_booking(conn, pnr_code: str):
    return await conn.fetchrow(SQL_LOAD_BOOKING, pnr_code)


def context_from_booking(row, now: datetime | None = None) -> DisruptionContext:
    return DisruptionContext(
        pnr_code=row["pnr_code"],
        rewards_tier=row["asante_rewards_tier"],
        booking_status=row["booking_status"],
        origin=row["origin"],
        destination=row["destination"],
        scheduled_departure=row["original_departure"],
        scheduled_arrival=row["original_arrival"],
        disruption_reason=row["disruption_reason"],
        new_departure=row["current_departure"],
        new_arrival=row["current_arrival"],
        now=now or datetime.now(timezone.utc),
    )


async def evaluate_booking(conn, pnr_code: str) -> tuple[object, EntitlementDecision] | None:
    row = await load_booking(conn, pnr_code)
    if row is None:
        return None
    return row, evaluate(context_from_booking(row))


async def issue_entitlements(conn, pnr_code: str, actor: str) -> dict | None:
    """Evaluate the rules and write the result to vouchers, in one transaction."""
    async with conn.transaction():
        evaluated = await evaluate_booking(conn, pnr_code)
        if evaluated is None:
            return None
        _, decision = evaluated
        storable = [e for e in decision.entitlements if e.entitlement_type in STORABLE_TYPES]
        for e in storable:
            await conn.execute(
                SQL_UPSERT_VOUCHER,
                voucher_code(e.entitlement_type),
                pnr_code,
                e.entitlement_type,
                e.quantity,
                e.amount,
                e.currency,
                e.points,
                e.status,
                e.rule_id,
                e.basis,
                e.valid_until,
            )
        await conn.execute(SQL_VOID_STALE, pnr_code, [e.entitlement_type for e in storable])
        await conn.execute(
            SQL_AUDIT,
            pnr_code,
            actor,
            json.dumps(
                {
                    "regulation": decision.regulation,
                    "issued": [e.entitlement_type for e in storable],
                    "rules": [e.rule_id for e in storable],
                }
            ),
        )
        vouchers = await conn.fetch(SQL_VOUCHERS, pnr_code)
    return {
        "decision": decision.to_dict(),
        "vouchers": [voucher_to_dict(v) for v in vouchers],
    }
