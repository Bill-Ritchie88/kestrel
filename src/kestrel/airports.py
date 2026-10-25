"""
Airport names on the simulated network: the one copy (issue #38).

The REST tier uses them in its reasons ("Gets you to Mombasa first") and
sends the names the client needs with the trip and the account
suggestions (`cities`), so the client keeps no list of its own.
"""

from __future__ import annotations

CITIES = {
    "NBO": "Nairobi", "MBA": "Mombasa", "KIS": "Kisumu", "EDL": "Eldoret",
    "MYD": "Malindi", "UKA": "Ukunda", "EBB": "Entebbe", "DAR": "Dar es Salaam",
    "ZNZ": "Zanzibar", "KGL": "Kigali", "BJM": "Bujumbura", "ADD": "Addis Ababa",
    "MGQ": "Mogadishu", "JUB": "Juba", "HRE": "Harare", "LUN": "Lusaka",
    "LLW": "Lilongwe", "JNB": "Johannesburg", "FIH": "Kinshasa", "LOS": "Lagos",
    "ACC": "Accra", "ABV": "Abuja", "DXB": "Dubai", "BOM": "Mumbai",
    "LHR": "London", "CDG": "Paris", "AMS": "Amsterdam", "BKK": "Bangkok",
    "JFK": "New York",
}  # fmt: skip


def city(code: str | None) -> str:
    return CITIES.get(code or "", code or "")


def cities_for(*codes: str | None) -> dict[str, str]:
    """{code: name} for the codes given that have a name."""
    return {c: CITIES[c] for c in codes if c in CITIES}
