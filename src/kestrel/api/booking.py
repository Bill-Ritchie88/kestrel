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
from dataclasses import replace
from datetime import UTC, datetime, timedelta

import asyncpg

from kestrel.api.journeys import leg_statuses
from kestrel.entitlements import (
    STORABLE_TYPES,
    DisruptionContext,
    evaluate,
    local_iso,
)

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
           o.cancelled_at,
           -- Migration 016: the times before a delay (NULL if never moved).
           o.scheduled_departure_time       AS original_scheduled_departure,
           o.scheduled_arrival_time         AS original_scheduled_arrival,
           c.flight_id::text                AS current_flight_id,
           c.flight_number                  AS current_flight_number,
           c.departure_time                 AS current_departure,
           c.arrival_time                   AS current_arrival,
           s.seat_number,
           COALESCE(s.cabin_class::text, 'ECONOMY') AS cabin_class,
           -- Migration 015: the onward leg of a journey through NBO (NULL
           -- for a single-flight booking), as booked and as rebooked.
           w.flight_id::text                AS onward_flight_id,
           w.flight_number                  AS onward_flight_number,
           w.origin                         AS onward_origin,
           w.destination                    AS onward_destination,
           w.departure_time                 AS onward_departure,
           w.arrival_time                   AS onward_arrival,
           w.status::text                   AS onward_status,
           w.disruption_reason              AS onward_disruption_reason,
           w.aircraft_type                  AS onward_aircraft,
           w.cancelled_at                   AS onward_cancelled_at,
           cw.flight_id::text               AS current_onward_flight_id,
           cw.flight_number                 AS current_onward_flight_number,
           cw.departure_time                AS current_onward_departure,
           cw.arrival_time                  AS current_onward_arrival,
           ws.seat_number                   AS onward_seat_number
    FROM pnr_bookings b
    JOIN passengers p ON p.passenger_id = b.passenger_id
    JOIN flights    o ON o.flight_id    = b.original_flight_id
    LEFT JOIN flights c ON c.flight_id  = b.reaccommodated_flight_id
    LEFT JOIN seats   s ON s.seat_id    = b.assigned_seat_id
    LEFT JOIN flights w  ON w.flight_id  = b.onward_flight_id
    LEFT JOIN flights cw ON cw.flight_id = b.reaccommodated_onward_flight_id
    LEFT JOIN seats   ws ON ws.seat_id   = b.onward_seat_id
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
    """e.g. KQ-MV-8842-XTRB. Random, so codes cannot be guessed from a PNR.
    About 3.3 billion codes per voucher type (issue #16: two letters gave 5.8
    million, an 8% chance of a clash per 1,000 passengers)."""
    digits = f"{secrets.randbelow(10_000):04d}"
    letters = "".join(secrets.choice(_CODE_LETTERS) for _ in range(4))
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
            "departure_local": local_iso(row["original_departure"], row["origin"]),
            "arrival_local": local_iso(row["original_arrival"], row["destination"]),
            "status": row["original_status"],
            "disruption_reason": row["disruption_reason"],
            "aircraft_type": row["original_aircraft"],
            # Migration 016: a delay, against the time before it (None: not delayed or unknown).
            "scheduled_departure_local": local_iso(row.get("original_scheduled_departure"), row["origin"]),
            "delay_minutes": delay_minutes(row),
        },
        "refundable": refundable(row),
        "current_flight": (
            {
                "flight_id": row["current_flight_id"],
                "flight_number": row["current_flight_number"],
                "departure_time": _iso(row["current_departure"]),
                "arrival_time": _iso(row["current_arrival"]),
                "departure_local": local_iso(row["current_departure"], row["origin"]),
                "arrival_local": local_iso(row["current_arrival"], row["destination"]),
            }
            if row["current_flight_id"]
            else None
        ),
        "seat_number": row["seat_number"],
        "cabin_class": row["cabin_class"],
        **_journey_fields(row),
    }


REFUND_DELAY = timedelta(hours=5)


def delay_minutes(row) -> int | None:
    """How late the booked flight now leaves (migration 016), if it was delayed."""
    scheduled = row.get("original_scheduled_departure")
    if row["original_status"] != "DELAYED" or scheduled is None:
        return None
    return round((row["original_departure"] - scheduled).total_seconds() / 60)


def refundable(row, now: datetime | None = None) -> bool:
    """Whether "Cancel and request a refund" is offered: the same rule that
    cancel_booking_for_refund (migration 016) enforces, for the button only."""
    status = row["booking_status"]
    current = row["current_departure"] or row["original_departure"]
    if status not in ("DISRUPTED", "CONFIRMED"):
        return False
    if row["original_status"] != "CANCELLED" and current <= (now or datetime.now(UTC)):
        return False
    if status == "CONFIRMED":
        minutes = delay_minutes(row)
        return minutes is not None and minutes >= REFUND_DELAY.total_seconds() / 60
    return True


def is_connecting(row) -> bool:
    """A journey through NBO (migration 015). .get: the unit tests' fake rows
    have no onward columns."""
    return bool(row.get("onward_flight_id"))


def _journey_fields(row) -> dict:
    """The onward leg and both legs' status (My trip's "Missed connection").
    A single-flight booking: no legs and no onward flight."""
    if not is_connecting(row):
        return {"legs": [], "onward_flight": None, "current_onward_flight": None,
                "onward_seat_number": None, "final_destination": row["destination"]}  # fmt: skip
    first, onward = leg_statuses(
        row["original_status"], row["original_arrival"], row["onward_status"], row["onward_departure"]
    )
    hub, final = row["onward_origin"], row["onward_destination"]
    onward_flight = {
        "flight_id": row["onward_flight_id"],
        "flight_number": row["onward_flight_number"],
        "origin": hub,
        "destination": final,
        "departure_time": _iso(row["onward_departure"]),
        "arrival_time": _iso(row["onward_arrival"]),
        "departure_local": local_iso(row["onward_departure"], hub),
        "arrival_local": local_iso(row["onward_arrival"], final),
        "status": row["onward_status"],
        "disruption_reason": row["onward_disruption_reason"],
        "aircraft_type": row["onward_aircraft"],
    }
    legs = [
        {"leg": 1, "flight_id": row["original_flight_id"], "flight_number": row["original_flight_number"],
         "origin": row["origin"], "destination": row["destination"],
         "departure_local": local_iso(row["original_departure"], row["origin"]),
         "arrival_local": local_iso(row["original_arrival"], row["destination"]),
         "leg_status": first},
        {"leg": 2, "flight_id": row["onward_flight_id"], "flight_number": row["onward_flight_number"],
         "origin": hub, "destination": final,
         "departure_local": onward_flight["departure_local"], "arrival_local": onward_flight["arrival_local"],
         "leg_status": onward},
    ]  # fmt: skip
    current_onward = (
        {
            "flight_id": row["current_onward_flight_id"],
            "flight_number": row["current_onward_flight_number"],
            "departure_time": _iso(row["current_onward_departure"]),
            "arrival_time": _iso(row["current_onward_arrival"]),
            "departure_local": local_iso(row["current_onward_departure"], hub),
            "arrival_local": local_iso(row["current_onward_arrival"], final),
        }
        if row["current_onward_flight_id"]
        else None
    )
    return {"legs": legs, "onward_flight": onward_flight, "current_onward_flight": current_onward,
            "onward_seat_number": row["onward_seat_number"], "final_destination": final}  # fmt: skip


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


def context_from_booking(row, now: datetime | None = None, no_alternatives: bool = False) -> DisruptionContext:
    """The rules' view of a booking. no_alternatives: no later flight has a seat
    (an open NO_ALTERNATIVES case), which gives a stranded passenger a hotel."""
    if is_connecting(row):
        return replace(_journey_context(row, now), no_alternatives=no_alternatives)
    # Disrupted again (016): the rebooked flight was cancelled too, so it no
    # longer counts as the new flight.
    rebooked = row["booking_status"] != "DISRUPTED"
    if row.get("original_status") == "DELAYED":
        # A delay: the scheduled times are those before it, the new times are the flight's own.
        return DisruptionContext(
            pnr_code=row["pnr_code"],
            rewards_tier=row["asante_rewards_tier"],
            booking_status=row["booking_status"],
            origin=row["origin"],
            destination=row["destination"],
            scheduled_departure=row.get("original_scheduled_departure") or row["original_departure"],
            scheduled_arrival=row.get("original_scheduled_arrival") or row["original_arrival"],
            disruption_reason=row["disruption_reason"],
            new_departure=row["original_departure"] if row.get("original_scheduled_departure") else None,
            new_arrival=row["original_arrival"] if row.get("original_scheduled_arrival") else None,
            now=now or datetime.now(UTC),
            flight_status="DELAYED",
            no_alternatives=no_alternatives,
        )
    return DisruptionContext(
        pnr_code=row["pnr_code"],
        rewards_tier=row["asante_rewards_tier"],
        booking_status=row["booking_status"],
        origin=row["origin"],
        destination=row["destination"],
        scheduled_departure=row["original_departure"],
        scheduled_arrival=row["original_arrival"],
        disruption_reason=row["disruption_reason"],
        new_departure=row["current_departure"] if rebooked else None,
        new_arrival=row["current_arrival"] if rebooked else None,
        # When the flight was cancelled (migration 012's trigger), so the
        # EU261 notice rule gives the same answer whatever day it is asked
        # (issue #13). None only for a flight that is not cancelled.
        notified_at=row.get("cancelled_at"),
        now=now or datetime.now(UTC),
        flight_status=row.get("original_status"),
        no_alternatives=no_alternatives,
    )


def _journey_context(row, now: datetime | None) -> DisruptionContext:
    """A journey through NBO, for the rules engine.

    The Regulation's scope and distance band are the journey's, from the first
    origin to the final destination (a connecting journey on one booking counts
    as one), and the delay is measured at the FINAL destination against the
    onward leg's scheduled arrival. Cause and notice are those of the leg that
    broke the journey. The wait for care starts at the first leg that changes:
    the original departure when leg 1 moves, the onward departure (at the hub)
    when leg 1 is kept."""
    if row["original_status"] == "CANCELLED" or row["onward_status"] != "CANCELLED":
        reason, notified = row["disruption_reason"], row.get("cancelled_at")
    else:
        reason, notified = row["onward_disruption_reason"], row.get("onward_cancelled_at")
    ctx = DisruptionContext(
        pnr_code=row["pnr_code"],
        rewards_tier=row["asante_rewards_tier"],
        booking_status=row["booking_status"],
        origin=row["origin"],
        destination=row["onward_destination"],
        scheduled_departure=row["original_departure"],
        scheduled_arrival=row["onward_arrival"],
        disruption_reason=reason,
        notified_at=notified,
        now=now or datetime.now(UTC),
        # shortcut: a refunded journey counts as cancelled and a delay that keeps the
        # connection gets no delay rules; add per-leg delays if journeys need them.
        flight_status="CANCELLED" if row["booking_status"] == "CANCELLED" else None,
    )
    if not row["current_flight_id"] or row["booking_status"] == "DISRUPTED":
        return ctx
    first_kept = row["current_flight_id"] == row["original_flight_id"]
    departure = row["current_onward_departure"] if first_kept else row["current_departure"]
    return journey_option_context(ctx, row, departure, row["current_onward_arrival"], first_kept)


def journey_option_context(ctx, row, departure, final_arrival, first_kept: bool) -> DisruptionContext:
    """ctx as if the passenger flew a journey whose first changed leg leaves at
    `departure` and which reaches the final destination at `final_arrival`."""
    if first_kept:
        # shortcut: hotel nights are counted in the origin's time zone, not the hub's;
        # the same zone on the demo routes (East Africa), revisit for origins elsewhere.
        return replace(ctx, scheduled_departure=row["onward_departure"], new_departure=departure,
                       new_arrival=final_arrival)  # fmt: skip
    return replace(ctx, new_departure=departure, new_arrival=final_arrival)


ISSUE_ATTEMPTS = 3


async def issue_entitlements(conn, pnr_code: str, actor: str, no_alternatives: bool = False) -> dict | None:
    """Evaluate the rules and write the result to vouchers, in one
    transaction. A new voucher code that clashes with an existing one rolls
    the transaction back; it is tried again with fresh codes, so the
    passenger never silently loses their vouchers (issue #16)."""
    for attempt in range(1, ISSUE_ATTEMPTS + 1):
        try:
            return await _issue_once(conn, pnr_code, actor, no_alternatives)
        except asyncpg.UniqueViolationError:
            if attempt == ISSUE_ATTEMPTS:
                raise
    return None  # pragma: no cover


async def _issue_once(conn, pnr_code: str, actor: str, no_alternatives: bool) -> dict | None:
    async with conn.transaction():
        row = await load_booking(conn, pnr_code)
        if row is None:
            return None
        decision = evaluate(context_from_booking(row, no_alternatives=no_alternatives))
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
