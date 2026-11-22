"""
Connecting journeys (migration 015): the passenger's options to reach their
final destination when one leg of a two-leg journey through Nairobi is
cancelled or delayed past the minimum connection time.

Scope, a stated limitation: at most two legs, one airline, connecting at NBO.
A booking with no onward leg never comes here.

Everything below SQL_JOURNEY_LEGS is pure, so it is unit-tested without a
database (tests/unit/test_journeys.py). It proposes; it decides nothing.
reaccommodate_journey_atomic re-checks every rule under row locks.
"""

from __future__ import annotations

from datetime import datetime, timedelta

from kestrel.entitlements import local_iso

HUB = "NBO"
# An assumption, not a published Kenya Airways figure. Must equal
# kestrel_min_connection() in migration 015 (an integration test checks).
MIN_CONNECTION = timedelta(minutes=60)
# Candidate flights per leg read from the schedule, earliest first.
LEG_CANDIDATES = 40

# Every flight the booking could fly on either leg: scheduled and in the
# future with its free seats in the passenger's cabin, plus the flight the
# passenger holds on each leg (kept: it may be delayed, but not cancelled).
# No rows for a single-flight booking (no onward leg, so no final destination).
SQL_JOURNEY_LEGS = """
    WITH bk AS (
        SELECT COALESCE(b.reaccommodated_flight_id, b.original_flight_id)       AS cur_first,
               COALESCE(b.reaccommodated_onward_flight_id, b.onward_flight_id) AS cur_onward,
               COALESCE(cs.cabin_class::text, 'ECONOMY')                       AS cabin,
               o.origin, o.destination AS hub, w.destination AS final
        FROM pnr_bookings b
        JOIN flights o ON o.flight_id = b.original_flight_id
        JOIN flights w ON w.flight_id = b.onward_flight_id
        LEFT JOIN seats cs ON cs.seat_id = b.assigned_seat_id
        WHERE b.pnr_code = $1
    ), legs AS (
        SELECT f.flight_id, f.flight_number, f.origin, f.destination, f.departure_time,
               f.arrival_time, f.aircraft_type, bk.cabin,
               CASE WHEN f.origin = bk.origin THEN 1 ELSE 2 END              AS leg,
               f.flight_id IN (bk.cur_first, bk.cur_onward)                  AS kept,
               row_number() OVER (PARTITION BY f.origin ORDER BY f.departure_time) AS n
        FROM bk
        JOIN flights f ON ((f.origin = bk.origin AND f.destination = bk.hub)
                        OR (f.origin = bk.hub AND f.destination = bk.final))
        WHERE f.departure_time > now()
          AND (f.status = 'SCHEDULED'
               OR (f.flight_id IN (bk.cur_first, bk.cur_onward) AND f.status <> 'CANCELLED'))
    )
    SELECT l.flight_id::text AS flight_id, l.flight_number, l.origin, l.destination,
           l.departure_time, l.arrival_time, l.aircraft_type, l.cabin AS cabin_class,
           l.leg, l.kept,
           (SELECT count(*) FROM seats s
            WHERE s.flight_id = l.flight_id AND s.status = 'AVAILABLE'
              AND s.cabin_class::text = l.cabin)                             AS available_seats
    FROM legs l
    WHERE l.n <= $2 OR l.kept
    ORDER BY l.leg, l.departure_time;
"""


def connection_broken(
    first_status: str | None,
    first_arrival: datetime | None,
    onward_status: str | None,
    onward_departure: datetime | None,
) -> bool:
    """journey_connection_broken() in Python: a leg cancelled, or too little
    time at the hub."""
    if first_status == "CANCELLED" or onward_status == "CANCELLED":
        return True
    if first_arrival is None or onward_departure is None:
        return False
    return first_arrival + MIN_CONNECTION > onward_departure


def leg_statuses(first_status, first_arrival, onward_status, onward_departure) -> tuple[str, str]:
    """What My trip shows on each leg: CANCELLED, DELAYED, MISSED_CONNECTION
    or SCHEDULED."""
    first = first_status if first_status in ("CANCELLED", "DELAYED") else "SCHEDULED"
    if onward_status == "CANCELLED":
        onward = "CANCELLED"
    elif connection_broken(first_status, first_arrival, onward_status, onward_departure):
        onward = "MISSED_CONNECTION"
    else:
        onward = onward_status if onward_status == "DELAYED" else "SCHEDULED"
    return first, onward


def leg_to_dict(r) -> dict:
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
        "available_seats": r["available_seats"],
        "kept": bool(r["kept"]),
    }


def build_journeys(rows, limit: int) -> list[dict]:
    """Journey options from SQL_JOURNEY_LEGS rows, earliest arrival at the
    final destination first.

    For each first leg: the onward flight the passenger already holds when it
    still connects (fewest changes), and the earliest-arriving new onward
    flight when it arrives sooner. A new leg needs a free seat; the passenger's
    current journey is not an option. Each option is shaped like a
    single-flight alternative (its first leg at the top level, as the client
    and the assistant already read them) plus `onward` and the arrival at the
    final destination, with `_departure` / `_arrival` / `_first_kept` for
    explain_alternatives."""
    firsts = [r for r in rows if r["leg"] == 1 and (r["kept"] or r["available_seats"] > 0)]
    onwards = [r for r in rows if r["leg"] == 2 and (r["kept"] or r["available_seats"] > 0)]
    options = []
    for a in firsts:
        if a["arrival_time"] is None:
            continue
        connecting = [
            b for b in onwards
            if b["arrival_time"] is not None and b["departure_time"] >= a["arrival_time"] + MIN_CONNECTION
        ]  # fmt: skip
        kept = next((b for b in connecting if b["kept"]), None)
        new = min((b for b in connecting if not b["kept"]), key=lambda b: b["arrival_time"], default=None)
        picks = [kept] if kept else []
        if new is not None and (kept is None or new["arrival_time"] < kept["arrival_time"]):
            picks.append(new)
        for b in picks:
            if a["kept"] and b["kept"]:
                continue  # the journey the passenger already has
            options.append((a, b))
    options.sort(key=lambda ab: (ab[1]["arrival_time"], ab[0]["departure_time"], not ab[0]["kept"]))
    return [_journey_to_dict(a, b) for a, b in options[:limit]]


def _journey_to_dict(a, b) -> dict:
    first, onward = leg_to_dict(a), leg_to_dict(b)
    seats = [x["available_seats"] for x in (first, onward) if not x["kept"]]
    return {
        **{k: v for k, v in first.items() if k != "available_seats"},
        "cabin_class": a["cabin_class"],
        "available_seats": min(seats),
        "onward": onward,
        "final_destination": b["destination"],
        "final_arrival_time": onward["arrival_time"],
        "final_arrival_local": onward["arrival_local"],
        "connection_minutes": int((b["departure_time"] - a["arrival_time"]).total_seconds() // 60),
        "_departure": b["departure_time"] if a["kept"] else a["departure_time"],
        "_arrival": b["arrival_time"],
        "_first_kept": bool(a["kept"]),
    }


def find_journey(options: list[dict], first_id: str, onward_id: str | None) -> dict | None:
    return next(
        (
            o
            for o in options
            if o["flight_id"] == first_id.lower() and o["onward"]["flight_id"] == (onward_id or "").lower()
        ),
        None,
    )
