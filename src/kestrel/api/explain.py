"""
Why this flight: plain reasons and badges for each alternative (Phase 4).

A pure function of the alternatives and the booking row, so it is unit-tested
without a database. It explains; it decides nothing. The flights and their
order come from SQL_FIND_ALTERNATIVES (earliest arrival first), and what an
option would include comes from the same rules engine that issues vouchers
(kestrel.entitlements.evaluate, asked "what if the passenger took this one?").
Rebooking still goes through reaccommodate_passenger_atomic.

Badges:
    EARLIEST_ARRIVAL  arrives first of the options shown
    MOST_SEATS        most free seats in the passenger's cabin (if not a tie)
    SAME_DAY          leaves on the original departure's local date
    NEXT_DAY_HOTEL    leaves on a later day, so the rules give a hotel night
                      and transfers with it
    ALMOST_FULL       ALMOST_FULL_SEATS or fewer free seats in the cabin
"""

from __future__ import annotations

from dataclasses import replace
from datetime import datetime

from kestrel.airports import city as _city
from kestrel.api.booking import context_from_booking
from kestrel.entitlements import evaluate, local_iso, when_text

ALMOST_FULL_SEATS = 5


def _when(dt: datetime | None, airport: str) -> str:
    """'Mon 19 Oct at 05:26', local to the airport."""
    return when_text(local_iso(dt, airport))


def _local_date(dt: datetime, airport: str):
    return datetime.fromisoformat(local_iso(dt, airport)).date()


def explain_alternatives(alternatives: list[dict], booking, context=None) -> list[dict]:
    """Each alternative (as alternative_to_dict made it, plus the datetimes
    under `_departure` / `_arrival`) gains `reasons`, `badges`, `wait_hours`
    and `includes` (what the rules would give with it). `booking` is the
    load_booking row; `context` its DisruptionContext (made here if not
    given). Returns new dicts; the `_` keys are dropped."""
    if not alternatives:
        return []
    ctx = context if context is not None else context_from_booking(booking)
    origin, destination = booking["origin"], booking["destination"]
    original = booking["original_departure"]
    seats = [a["available_seats"] for a in alternatives]
    most = max(seats)
    most_is_unique = seats.count(most) == 1

    out = []
    for i, alt in enumerate(alternatives):
        dep, arr = alt["_departure"], alt["_arrival"]
        wait_h = round((dep - original).total_seconds() / 3600, 1)
        badges: list[str] = []
        reasons: list[str] = []

        if i == 0:
            badges.append("EARLIEST_ARRIVAL")
            reasons.append(
                f"Gets you to {_city(destination)} first: arrives {_when(arr, destination)}."
            )
        same_day = _local_date(dep, origin) == _local_date(original, origin)
        if same_day:
            badges.append("SAME_DAY")
            reasons.append(
                f"Leaves the same day as your original flight, {abs(wait_h):g} hours "
                + ("later." if wait_h >= 0 else "earlier.")
            )

        decision = evaluate(replace(ctx, new_departure=dep, new_arrival=arr))
        kinds = {e.entitlement_type for e in decision.entitlements}
        if "HOTEL" in kinds:
            badges.append("NEXT_DAY_HOTEL")
            nights = next(e.quantity for e in decision.entitlements if e.entitlement_type == "HOTEL")
            reasons.append(
                f"Leaves on a later day, so {'a hotel night' if nights == 1 else f'{nights} hotel nights'} "
                "and airport transfers come with it."
            )
        elif not same_day:
            reasons.append(
                f"Leaves {_when(dep, origin)}, {abs(wait_h):g} hours "
                + ("after" if wait_h >= 0 else "before")
                + " your original flight."
            )

        if most_is_unique and alt["available_seats"] == most and len(alternatives) > 1:
            badges.append("MOST_SEATS")
            reasons.append(f"Most seats left of these flights ({most}).")
        if alt["available_seats"] <= ALMOST_FULL_SEATS:
            badges.append("ALMOST_FULL")
            reasons.append(
                f"Only {alt['available_seats']} seat{'s' if alt['available_seats'] != 1 else ''} "
                "left in your cabin: choose soon if you want it."
            )

        public = {k: v for k, v in alt.items() if not k.startswith("_")}
        out.append({
            **public,
            "wait_hours": wait_h,
            "badges": badges,
            "reasons": reasons,
            "includes": [
                {
                    "entitlement_type": e.entitlement_type,
                    "label": e.label,
                    "quantity": e.quantity,
                    "amount": e.amount,
                    "currency": e.currency,
                    "points": e.points,
                }
                for e in decision.entitlements
                if e.status in ("ISSUED", "ELIGIBLE")
            ],
        })
    return out
