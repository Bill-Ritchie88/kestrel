"""
Project Kestrel - deterministic entitlement engine (FR-04).

Decides which vouchers, Asante Rewards points and cash compensation a
disrupted booking is owed. The language model never sets or changes any of
these values: it can only ask the REST tier, which calls evaluate() below and
reports what it returns. This is the design response to Moffatt v. Air Canada
(2024), where a chatbot promised a refund policy that did not exist.

Two kinds of rule live here, and the difference matters for the report:

* REGULATORY rules transcribe Regulation (EC) No 261/2004 (and its UK
  retained version) - scope (Art. 3), the right to care (Arts. 5(1)(b), 9),
  compensation amounts and distance bands (Art. 7), the notice-period
  exemptions (Art. 5(1)(c)) and the extraordinary-circumstances exemption
  (Art. 5(3)). The figures are the Regulation's own.

* PROJECT rules fill gaps no public source covers: Kenya Airways does not
  publish meal-voucher values or goodwill Asante points. Those values sit in
  PROJECT_POLICY, are labelled as assumptions in every voucher's `basis`, and
  are listed in Section 4.4.4 of the report for the supervisor to confirm.

Everything is a pure function of its inputs, so every rule is unit-tested
without a database (tests/unit/test_entitlements.py).
"""

from __future__ import annotations

import math
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

# ---------------------------------------------------------------------------
# Reference data
# ---------------------------------------------------------------------------

# Airports on the simulated network: (latitude, longitude, IANA time zone,
# regulatory region). Coordinates are rounded to 0.01 degrees; they are used
# only to place a route in an Art. 7 distance band (<=1,500 km, 1,500-3,500 km,
# >3,500 km), where that precision is far more than enough.
AIRPORTS: dict[str, tuple[float, float, str, str]] = {
    "NBO": (-1.32, 36.93, "Africa/Nairobi", "KE"),
    "MBA": (-4.03, 39.59, "Africa/Nairobi", "KE"),
    "KIS": (-0.09, 34.73, "Africa/Nairobi", "KE"),
    "EDL": (0.40, 35.24, "Africa/Nairobi", "KE"),
    "MYD": (-3.23, 40.10, "Africa/Nairobi", "KE"),
    "UKA": (-4.30, 39.57, "Africa/Nairobi", "KE"),
    "EBB": (0.04, 32.44, "Africa/Kampala", "UG"),
    "DAR": (-6.88, 39.20, "Africa/Dar_es_Salaam", "TZ"),
    "ZNZ": (-6.22, 39.22, "Africa/Dar_es_Salaam", "TZ"),
    "KGL": (-1.97, 30.14, "Africa/Kigali", "RW"),
    "BJM": (-3.32, 29.32, "Africa/Bujumbura", "BI"),
    "ADD": (8.98, 38.80, "Africa/Addis_Ababa", "ET"),
    "MGQ": (2.01, 45.30, "Africa/Mogadishu", "SO"),
    "JUB": (4.87, 31.60, "Africa/Juba", "SS"),
    "HRE": (-17.93, 31.09, "Africa/Harare", "ZW"),
    "LUN": (-15.33, 28.45, "Africa/Lusaka", "ZM"),
    "LLW": (-13.79, 33.78, "Africa/Blantyre", "MW"),
    "JNB": (-26.14, 28.25, "Africa/Johannesburg", "ZA"),
    "FIH": (-4.39, 15.44, "Africa/Kinshasa", "CD"),
    "LOS": (6.58, 3.32, "Africa/Lagos", "NG"),
    "ACC": (5.61, -0.17, "Africa/Accra", "GH"),
    "ABV": (9.01, 7.26, "Africa/Lagos", "NG"),
    "DXB": (25.25, 55.36, "Asia/Dubai", "AE"),
    "BOM": (19.09, 72.87, "Asia/Kolkata", "IN"),
    "LHR": (51.47, -0.45, "Europe/London", "UK"),
    "CDG": (49.01, 2.55, "Europe/Paris", "EU"),
    "AMS": (52.31, 4.77, "Europe/Amsterdam", "EU"),
    "BKK": (13.69, 100.75, "Asia/Bangkok", "TH"),
    "JFK": (40.64, -73.78, "America/New_York", "US"),
}

# Art. 5(3): no compensation where the cancellation was caused by
# extraordinary circumstances that could not have been avoided. Recital 14
# names weather, air traffic management decisions and security risks.
EXTRAORDINARY_REASONS = frozenset({"WEATHER", "ATC", "SECURITY", "POLITICAL"})
CONTROLLABLE_REASONS = frozenset({"TECHNICAL", "CREW", "OPERATIONAL"})

# Art. 7(1) amounts by distance band. UK figures are those of the UK
# retained Regulation as amended in 2019.
COMPENSATION = {
    "EU261": {"currency": "EUR", "bands": (250, 400, 600)},
    "UK261": {"currency": "GBP", "bands": (220, 350, 520)},
}

# PROJECT ASSUMPTIONS - not published by Kenya Airways. Every voucher issued
# from these values says so in its `basis`. Change them here only.
PROJECT_POLICY = {
    # Meal voucher value per meal, in the currency of the departure airport's
    # region, so a passenger stranded in Amsterdam is not handed shillings.
    "meal_voucher": {
        "KE": (2500, "KES"),
        "EU": (15, "EUR"),
        "UK": (12, "GBP"),
        "US": (15, "USD"),
        "default": (15, "USD"),
    },
    # Art. 9(1)(b) gives a hotel "where a stay of one or more nights becomes
    # necessary". A new flight on the next calendar day is necessary but not
    # sufficient: a 23:55 departure slipping to 00:30 needs no hotel.
    "min_wait_for_hotel_hours": 6,
    "hours_per_meal": 6,  # one meal per started six hours of waiting
    "max_meals": 4,
    "meal_wait_threshold_hours": 2,  # outside the Regulation's scope
    "goodwill_points": {"BLUE": 1000, "SILVER": 2000, "GOLD": 3000, "PLATINUM": 5000},
    "voucher_validity_hours": 24,
}

PROJECT_BASIS = "Kestrel project policy (assumption pending Kenya Airways confirmation)"

# Entitlement types that are written to the vouchers table. REROUTING is
# reported to the passenger but is delivered by the rebooking itself.
STORABLE_TYPES = frozenset({"MEAL", "HOTEL", "TRANSPORT", "ASANTE_POINTS", "CASH_COMPENSATION"})


# ---------------------------------------------------------------------------
# Inputs and outputs
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class DisruptionContext:
    """Everything the rules depend on. All datetimes must be timezone-aware."""

    pnr_code: str
    rewards_tier: str | None
    booking_status: str  # DISRUPTED | REACCOMMODATED | CONFIRMED
    origin: str
    destination: str
    scheduled_departure: datetime
    scheduled_arrival: datetime | None
    disruption_reason: str | None
    new_departure: datetime | None = None  # None until the passenger is rebooked
    new_arrival: datetime | None = None
    notified_at: datetime | None = None  # when the passenger learned of it; default: now
    now: datetime | None = None


@dataclass
class Entitlement:
    entitlement_type: str
    label: str
    status: str  # ISSUED | ELIGIBLE | INFO
    rule_id: str
    basis: str
    explanation: str
    quantity: int = 1
    amount: float | None = None
    currency: str | None = None
    points: int | None = None
    valid_until: datetime | None = None

    def to_dict(self) -> dict:
        d = asdict(self)
        d["valid_until"] = self.valid_until.isoformat() if self.valid_until else None
        return d


@dataclass
class EntitlementDecision:
    """The full, explainable result: what applies and why the rest does not."""

    entitlements: list[Entitlement] = field(default_factory=list)
    regulation: str | None = None  # 'EU261', 'UK261' or None
    distance_km: int | None = None
    notes: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "regulation": self.regulation,
            "distance_km": self.distance_km,
            "entitlements": [e.to_dict() for e in self.entitlements],
            "notes": self.notes,
        }


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def great_circle_km(origin: str, destination: str) -> int:
    """Haversine distance between two airports on the network."""
    lat1, lon1, *_ = AIRPORTS[origin]
    lat2, lon2, *_ = AIRPORTS[destination]
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return round(6371.0 * 2 * math.asin(math.sqrt(a)))


def distance_band(km: int) -> int:
    """Art. 7(1): 0 for <=1,500 km, 1 for 1,500-3,500 km, 2 beyond."""
    if km <= 1500:
        return 0
    if km <= 3500:
        return 1
    return 2


def applicable_regulation(origin: str) -> str | None:
    """
    Art. 3(1). The Regulation covers (a) every departure from an EU airport,
    and (b) arrivals in the EU from a third country only when the operating
    carrier is a Community carrier. Kenya Airways is not, so only departures
    from the EU (EU261) or the UK (UK261) are in scope.
    """
    region = AIRPORTS.get(origin, (0, 0, "UTC", ""))[3]
    return {"EU": "EU261", "UK": "UK261"}.get(region)


def _local(dt: datetime, airport: str) -> datetime:
    return dt.astimezone(ZoneInfo(AIRPORTS.get(airport, (0, 0, "UTC", ""))[2]))


def _hours(delta: timedelta) -> float:
    return delta.total_seconds() / 3600


# ---------------------------------------------------------------------------
# The rules
# ---------------------------------------------------------------------------


def evaluate(ctx: DisruptionContext) -> EntitlementDecision:
    """Apply every rule to one booking. Deterministic and side-effect free."""
    now = ctx.now or datetime.now(ctx.scheduled_departure.tzinfo)
    decision = EntitlementDecision()

    if ctx.booking_status not in ("DISRUPTED", "REACCOMMODATED"):
        decision.notes.append("The booking is not affected by a disruption.")
        return decision

    if ctx.origin not in AIRPORTS or ctx.destination not in AIRPORTS:
        decision.notes.append("Route is outside the reference data; refer to a member of staff.")
        return decision

    regulation = applicable_regulation(ctx.origin)
    km = great_circle_km(ctx.origin, ctx.destination)
    band = distance_band(km)
    decision.regulation = regulation
    decision.distance_km = km
    reg_label = {"EU261": "EU261", "UK261": "UK261"}.get(regulation or "", "")

    # -- R1 Re-routing -----------------------------------------------------
    decision.entitlements.append(
        Entitlement(
            entitlement_type="REROUTING",
            label="Re-routing at no extra cost",
            status="INFO",
            rule_id="R1_REROUTING",
            basis=f"{reg_label} Art. 5(1)(a), Art. 8(1)(b)" if regulation else PROJECT_BASIS,
            explanation="A seat on the next available Kenya Airways flight on the same route, "
            "in the same cabin, without a fare difference.",
        )
    )

    # Waiting time: from the original departure to the new one. Before the
    # passenger is rebooked it is not yet known.
    wait_h = _hours(ctx.new_departure - ctx.scheduled_departure) if ctx.new_departure else None
    valid_until = ctx.new_departure or (now + timedelta(hours=PROJECT_POLICY["voucher_validity_hours"]))

    # -- R2 Meals (right to care) -----------------------------------------
    # Under the Regulation a cancellation always triggers care (Art. 5(1)(b)),
    # with meals "in a reasonable relation to the waiting time" (Art. 9(1)(a)).
    # Outside it, the project threshold applies.
    threshold = 0 if regulation else PROJECT_POLICY["meal_wait_threshold_hours"]
    if wait_h is None or wait_h >= threshold:
        meals = 1
        if wait_h is not None:
            meals = min(
                PROJECT_POLICY["max_meals"],
                max(1, math.ceil(wait_h / PROJECT_POLICY["hours_per_meal"])),
            )
        region = AIRPORTS[ctx.origin][3]
        meal_amount, meal_currency = PROJECT_POLICY["meal_voucher"].get(
            region, PROJECT_POLICY["meal_voucher"]["default"]
        )
        decision.entitlements.append(
            Entitlement(
                entitlement_type="MEAL",
                label="Meal voucher",
                status="ISSUED",
                rule_id="R2_MEAL",
                basis=(f"{reg_label} Art. 5(1)(b), Art. 9(1)(a); value: {PROJECT_BASIS}")
                if regulation
                else PROJECT_BASIS,
                explanation=f"{meals} meal(s) for the wait"
                + (f" of {wait_h:.1f} hours." if wait_h is not None else " until you are rebooked."),
                quantity=meals,
                amount=float(meal_amount),
                currency=meal_currency,
                valid_until=valid_until,
            )
        )
    else:
        decision.notes.append(
            f"No meal voucher: the new departure is {wait_h:.1f} hours after the original, "
            f"below the {threshold}-hour threshold."
        )

    # -- R3 Hotel and transport -------------------------------------------
    # Art. 5(1)(b) with Art. 9(1)(b),(c): when the new departure is at least
    # the day after the planned one, local time at the departure airport.
    if ctx.new_departure is not None:
        nights = (
            _local(ctx.new_departure, ctx.origin).date()
            - _local(ctx.scheduled_departure, ctx.origin).date()
        ).days
        if nights >= 1 and wait_h >= PROJECT_POLICY["min_wait_for_hotel_hours"]:
            basis = f"{reg_label} Art. 5(1)(b), Art. 9(1)(b)" if regulation else PROJECT_BASIS
            decision.entitlements.append(
                Entitlement(
                    entitlement_type="HOTEL",
                    label="Hotel accommodation",
                    status="ISSUED",
                    rule_id="R3_HOTEL",
                    basis=basis,
                    explanation=f"{nights} night(s): your new flight leaves on a later day.",
                    quantity=nights,
                    valid_until=ctx.new_departure,
                )
            )
            decision.entitlements.append(
                Entitlement(
                    entitlement_type="TRANSPORT",
                    label="Airport-hotel transfer",
                    status="ISSUED",
                    rule_id="R3_TRANSPORT",
                    basis=f"{reg_label} Art. 9(1)(c)" if regulation else PROJECT_BASIS,
                    explanation="Return transfer between the airport and the hotel.",
                    quantity=1,
                    valid_until=ctx.new_departure,
                )
            )
        else:
            decision.notes.append(
                "No hotel: your new flight leaves the same day or shortly after midnight."
            )
    else:
        decision.notes.append("Hotel accommodation is decided once you are rebooked.")

    reason = ctx.disruption_reason
    controllable = reason in CONTROLLABLE_REASONS
    extraordinary = reason in EXTRAORDINARY_REASONS

    # -- R4 Cash compensation (Art. 7) ------------------------------------
    if regulation is None:
        decision.notes.append(
            "No cash compensation under EU261/UK261: the flight does not depart from the "
            "EU or UK, and Kenya Airways is not a Community carrier (Art. 3(1))."
        )
    elif extraordinary:
        decision.notes.append(
            f"No cash compensation: the cancellation was caused by {reason.lower()}, an "
            f"extraordinary circumstance ({reg_label} Art. 5(3))."
        )
    elif not controllable:
        decision.notes.append(
            "The cause of the cancellation is not recorded, so cash compensation will be "
            "assessed by a member of staff."
        )
    else:
        notified = ctx.notified_at or now
        notice_days = _hours(ctx.scheduled_departure - notified) / 24
        exempt = notice_days >= 14
        if not exempt and ctx.new_departure and ctx.new_arrival and ctx.scheduled_arrival:
            dep_early_h = _hours(ctx.scheduled_departure - ctx.new_departure)
            arr_late_h = _hours(ctx.new_arrival - ctx.scheduled_arrival)
            # Art. 5(1)(c)(ii): 7-14 days' notice, rerouted to leave no more than
            # 2 h early and arrive less than 4 h late. (iii): under 7 days'
            # notice, no more than 1 h early and less than 2 h late.
            if 7 <= notice_days < 14 and dep_early_h <= 2 and arr_late_h < 4:
                exempt = True
            if notice_days < 7 and dep_early_h <= 1 and arr_late_h < 2:
                exempt = True
        if exempt:
            decision.notes.append(
                f"No cash compensation: the notice and re-routing meet {reg_label} Art. 5(1)(c)."
            )
        else:
            table = COMPENSATION[regulation]
            amount = table["bands"][band]
            reduced = False
            if ctx.new_arrival and ctx.scheduled_arrival:
                late_h = _hours(ctx.new_arrival - ctx.scheduled_arrival)
                # Art. 7(2): halved when the rerouted arrival is within 2/3/4 h.
                if late_h <= (2, 3, 4)[band]:
                    amount = amount / 2
                    reduced = True
            decision.entitlements.append(
                Entitlement(
                    entitlement_type="CASH_COMPENSATION",
                    label="Cash compensation",
                    status="ELIGIBLE",
                    rule_id="R4_COMPENSATION",
                    basis=f"{reg_label} Art. 5(1)(c), Art. 7(1)"
                    + (", Art. 7(2)" if reduced else ""),
                    explanation=f"{km:,} km route"
                    + (" (halved: you arrive close to the original time)." if reduced else ".")
                    + " Paid by Kenya Airways customer care after review.",
                    amount=float(amount),
                    currency=table["currency"],
                )
            )

    # -- R5 Goodwill Asante Rewards points --------------------------------
    if controllable:
        tier = (ctx.rewards_tier or "BLUE").upper()
        points = PROJECT_POLICY["goodwill_points"].get(tier, PROJECT_POLICY["goodwill_points"]["BLUE"])
        decision.entitlements.append(
            Entitlement(
                entitlement_type="ASANTE_POINTS",
                label="Asante Rewards goodwill points",
                status="ISSUED",
                rule_id="R5_GOODWILL",
                basis=PROJECT_BASIS,
                explanation=f"Goodwill for a cancellation within Kenya Airways' control "
                f"({tier.title()} tier).",
                points=points,
            )
        )
    elif extraordinary:
        decision.notes.append("No goodwill points: the cancellation was outside the airline's control.")

    return decision
