# Intelligence features

Sprint 2, performance plan Phase 4 (with the Phase 3 assistant changes they build on). Each
feature makes Kestrel more useful without moving a decision away from the code that owns it:
**the AI decides, the code enforces** still holds. The model may explain and suggest; only
the rules code (`kestrel/entitlements.py`) decides what a passenger is owed, and only the
stored procedure `reaccommodate_passenger_atomic` moves a booking and assigns a seat.

| Feature | Where | Model involved? |
|---|---|---|
| Why this flight | REST tier, `api/explain.py` | No |
| Kestrel recommends | Client, `state/recommend.dart` | No |
| Next steps (suggestions) | REST + agent service, `suggestions.py` | No |
| Quick replies | Agent service, `agent.run_intent` | No |
| Booking briefing (CONTEXT) | Agent service, `agent.briefing_text` | Reads it |
| Frustration → earlier hand-off | Agent service, `frustration.py` | No |
| Conversation memory | REST tier, `api/history.py` (table `chat_messages`) | No |

## Why this flight

`GET /api/flights/alternatives` and `GET /api/trip` add to each alternative:

- `badges`: `EARLIEST_ARRIVAL` (arrives first of the options shown), `MOST_SEATS` (most free
  seats in the passenger's cabin, when not a tie), `SAME_DAY` (leaves on the original
  departure's local date), `NEXT_DAY_HOTEL` (leaves on a later day and the rules give a hotel
  night and transfers with it), `ALMOST_FULL` (5 or fewer seats left);
- `reasons`: the same in plain sentences, in local airport time;
- `wait_hours`: hours after the original departure;
- `includes`: what the rules would give with that flight.

**Constraints.** The flights, their order (earliest arrival) and the cabin come from
`SQL_FIND_ALTERNATIVES`, unchanged. `includes` and `NEXT_DAY_HOTEL` come from calling the
existing `evaluate()` with the option's times ("what if"); no rule was added or changed.
Choosing still goes through Confirm and the stored procedure. On the flight cards the badges
are words (colour only repeats them); "Why this flight?" opens the reasons below the card, not
as part of its "choose" target.

## Kestrel recommends

A card at the top of My trip, and the assistant's first message, written in the client from
`GET /api/trip` alone, so it is instant: the best option (the first alternative - the server's
earliest arrival), why (from its badges and seats), what the passenger is owed with it (its
`includes`, i.e. the rules), and one primary action: **Review and confirm** (opens Confirm for
that flight). A rebooked passenger is shown their flight and vouchers instead; a passenger with
no alternative is offered a person.

**Constraints.** It states only what the REST tier returned; it books nothing. "Shall I book
it?" in the assistant leads, if the passenger says yes, to the model calling
`reaccommodate_passenger_tool` with the `flight_id` from CONTEXT - the same path as any
rebooking.

## Next steps (suggestions)

`GET /api/trip` and the stream's `done` event carry `suggestions`, a short list of
`{label, intent?, message?}` built by `kestrel/suggestions.py` from the booking state and the
last turn:

- disrupted → options, entitlements, "Can I get a refund instead?";
- rebooked → vouchers, add to calendar, talk to a person;
- an open hand-off case → "Check my case" first (and no second "talk to a person");
- after a turn, what it just showed is not offered again.

The client draws its chips from them. `alternatives`, `entitlements`, `person` are quick
replies; `calendar` (an .ics file of the booked flight, made in the browser) and `case` (the
Help section) are done in the client; a `message` is sent as if typed.

## Quick replies

A chip sends `intent` with the message; the agent service then runs the matching tool
(`find_alternative_flights_tool`, `get_entitlements_tool`, `escalate_to_human_tool`) and
answers from a template - the same structured events, **no model call** (about 0.4 s instead of
5-8 s). Typed text never carries an intent, and only those three are accepted (422 otherwise).

## Booking briefing (CONTEXT)

When a conversation starts, the agent service fetches `GET /api/trip` with the passenger's
token (cached per token for 120 s, dropped after a rebooking or a hand-off, never past the
token's expiry) and adds a compact CONTEXT system message: first name, tier, booking status,
original flight, the top three alternatives with `flight_id`, seats left and local times, and
the rules' entitlements. Questions about options and entitlements can then be answered in one
model call.

**Constraints** (in `SYSTEM_PROMPT`): rebooking **must** call `reaccommodate_passenger_tool`
with a `flight_id` from CONTEXT or from `find_alternative_flights_tool` (the REST tier refuses
any other); rights questions **must** call `search_policy_tool` and cite clauses, and an
out-of-scope result is handed to a person; amounts are only those the rules returned. The token
never enters the prompt.

## Frustration → earlier hand-off

`kestrel/frustration.py` reads the passenger's message and the conversation so far:

- the same question again (token-set similarity ≥ 0.8 with either of their last two messages);
- strong negative wording ("useless", "waste of time", ...);
- shouting (mostly capitals, or "!!!").

On the first signal the reply starts "I'm sorry this has been frustrating.", answers as usual,
and ends by offering a person (and "Talk to a person" becomes the first chip). On a second
signal, or if the passenger accepts the offer, the agent service opens a hand-off case with
trigger **`FRUSTRATION`** and a summary that says why ("Passenger frustrated (asked the same
question again; ...)"); no model call. Staff see it as "Frustrated passenger".

**Constraints.** Quick-reply taps are not read (tapping the same chip twice is not a
complaint). The detector only reads words; it changes nothing about the booking. One open case
per booking and trigger, as for every hand-off.

## Conversation memory

The REST tier keeps each booking's conversation (`chat_messages`, migration 010):
`GET /api/chat/history` (last 20 turns, oldest first), `POST /api/chat/history` (one turn,
≤ 4,000 characters, role `user` or `assistant`), `DELETE /api/chat/history` ("Start over").
All three act on the token's own booking only. The agent service saves both turns after each
reply has gone out (a failure loses the memory, never the reply). On sign-in the client loads
the history and shows "Continuing your conversation from <day, time>" with **Start over**.

**Constraints.** The agent tier still has no database access: it saves through the REST tier
with the passenger's token. The memory is text only; structured events (cards) are not stored.
