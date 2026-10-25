"""
Suggested next steps: the chips under the assistant and on My trip.

Built deterministically from the booking's state and the passenger's hand-off
cases, so they are instant and never depend on the model. Each suggestion is
{label, intent?, message?}:

* intent - a quick reply. `alternatives`, `entitlements` and `person` are run
  by the agent service directly, with no model call (ChatRequest.intent);
  `calendar` and `case` are handled by the client itself (an .ics file for the
  new flight; the Help section with the open case).
* message - text sent to the assistant as if the passenger had typed it.
"""

from __future__ import annotations

# Run by the agent service without the model.
SERVER_INTENTS = frozenset({"alternatives", "entitlements", "person"})
# Handled in the client.
CLIENT_INTENTS = frozenset({"calendar", "case"})

MAX_SUGGESTIONS = 3

REFUND_QUESTION = "Can I get a refund instead?"
# Every label a chip can carry. A tap is saved as an ordinary user message,
# so kestrel.frustration skips these exact texts (issue #8).
QUICK_REPLY_LABELS = frozenset({
    "Show my flight options", "What am I entitled to?", REFUND_QUESTION,
    "Show my vouchers", "Add my new flight to my calendar", "Talk to a person", "Check my case",
    # The client's own chips (chat_screen.dart) until the server's arrive.
    "Find me another flight", "Can I take a later flight?",
})


def _intent(label: str, intent: str) -> dict:
    return {"label": label, "intent": intent}


def _message(label: str, message: str | None = None) -> dict:
    return {"label": label, "message": message or label}


def suggestions(booking: dict, cases: list[dict] | None = None) -> list[dict]:
    """What the passenger is likely to want next, most useful first.

    disrupted -> options, entitlements, the refund question;
    rebooked  -> vouchers, add to calendar, a person;
    an open hand-off case comes first as "Check my case", and replaces "Talk
    to a person" (one is already on its way).
    """
    status = booking.get("booking_status")
    has_open_case = any(c.get("status") == "OPEN" for c in cases or [])

    if status == "DISRUPTED":
        items = [
            _intent("Show my flight options", "alternatives"),
            _intent("What am I entitled to?", "entitlements"),
            _message(REFUND_QUESTION),
        ]
    elif status == "REACCOMMODATED":
        items = [
            _intent("Show my vouchers", "entitlements"),
            _intent("Add my new flight to my calendar", "calendar"),
            _intent("Talk to a person", "person"),
        ]
    else:
        items = [
            _intent("What am I entitled to?", "entitlements"),
            _intent("Talk to a person", "person"),
        ]

    if has_open_case:
        items = [_intent("Check my case", "case")] + [
            s for s in items if s.get("intent") != "person"
        ]
    return items[:MAX_SUGGESTIONS]


# What an agent event shows the passenger, so the next steps do not offer it
# again straight away.
_SHOWN_BY = {"alternatives": "alternatives", "entitlements": "entitlements", "handoff": "person"}


def after_turn(trip: dict, events: list[dict]) -> list[dict]:
    """Next steps after an assistant turn: from the booking as the turn left
    it (rebooked, a case opened) and without repeating what it just showed.
    `trip` is GET /api/trip from the start of the conversation."""
    booking = dict(trip.get("booking") or {})
    cases = list(trip.get("cases") or [])
    kinds = {e.get("type") for e in events}
    if "rebooked" in kinds:
        booking["booking_status"] = "REACCOMMODATED"
    opened = "handoff" in kinds or any(
        e.get("type") == "policy" and (e.get("data") or {}).get("case") for e in events
    )
    if opened:
        cases.append({"status": "OPEN"})
    shown = {_SHOWN_BY[k] for k in kinds if k in _SHOWN_BY}
    # A policy answer has just answered the refund question: do not offer it
    # again straight away (issue #8).
    answered = REFUND_QUESTION if "policy" in kinds else ""
    items = suggestions(booking, cases)
    fresh = [s for s in items if s.get("intent") not in shown and s.get("message") != answered]
    if len(fresh) < len(items):
        # Fill the place with the next most useful thing not just shown.
        for extra in (
            _intent("What am I entitled to?", "entitlements"),
            _message(REFUND_QUESTION),
            _intent("Talk to a person", "person"),
        ):
            if len(fresh) >= MAX_SUGGESTIONS:
                break
            if extra.get("intent") not in shown and extra not in fresh and not (
                extra.get("intent") == "person" and opened
            ) and extra.get("message") != answered:
                fresh.append(extra)
    return fresh[:MAX_SUGGESTIONS]
