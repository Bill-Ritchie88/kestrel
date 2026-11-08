# Seat selection (FR-16)

Added on 8 November 2026. UC4, mockup M10 "Choose seat, row lock".

## What changed

Before, the passenger chose a flight and confirmed; the stored procedure gave them the first free seat
in their cabin. Now a seat map sits between choosing a flight and Confirm:

```
My trip / Flights / Assistant  ->  Choose your seat (M10)  ->  Confirm (M11)  ->  Rebooked (M12)
                                    pick a seat, or
                                    "Let Kestrel choose"
```

| Tier | Change |
|---|---|
| Database | Migration `013_seat_selection.sql`: `reaccommodate_passenger_atomic` takes an optional fourth parameter `p_seat_id` (default NULL) |
| REST tier | `GET /api/flights/{flight_id}/seats`; `POST /api/reaccommodate` accepts an optional `seat_id` |
| Kestrel Web | `screens/seat_map_screen.dart`; Confirm shows the chosen seat |

## Locking: NOWAIT for a chosen seat, SKIP LOCKED for auto-assign

Both paths first lock the passenger's booking row (`FOR UPDATE`), as before, so one booking can never be
moved twice at once.

- **Auto-assign (`p_seat_id` NULL)** is unchanged from 011: `FOR UPDATE SKIP LOCKED LIMIT 1` over the free
  seats in the cabin. Any free seat will do, so a seat another transaction is claiming is skipped and the
  next one taken. Concurrent passengers never wait on each other. The assistant's tool and every
  existing 3-argument call use this path.
- **Chosen seat** uses `SELECT ... WHERE seat_id = p_seat_id AND flight_id = p_target_flight_id FOR UPDATE
  NOWAIT`. Only that seat will do, so skipping it is meaningless, and waiting would queue the passenger
  behind a transaction that will most likely take it. NOWAIT fails at once with `lock_not_available`
  (55P03). The procedure catches that in a sub-block and answers `SEAT_TAKEN`, so the passenger is told
  straight away and picks again. A seat that is already `BOOKED` (or `LOCKED`) is `SEAT_TAKEN` too.

Whichever transaction gets the row lock first holds it until it commits, and by then the seat is
`BOOKED`. Every later caller therefore fails NOWAIT or finds the seat booked, and a seat cannot be given
twice. The concurrency test checks this with 2 and 10 passengers choosing the same seat at the same moment
(exactly 1 success, the rest `SEAT_TAKEN`, 0 seats held twice).

The seat map does not hold seats. A seat shows as free until someone confirms it, so two passengers can
select the same seat. The second to confirm gets HTTP 409 with `X-Refusal-Reason: SEAT_TAKEN`. The client
then goes back to the map, shows "That seat was just taken. Please pick another" and reloads the map.
Holding seats while a passenger browses would need expiry and clean-up, for no gain in integrity.

## Refusal codes

All refusals write only their `audit_logs` row (`REACCOMMODATION_REJECTED`, now with `requested_seat_id`).
The API maps each one to 409 and names it in `X-Refusal-Reason`.

| Reason | When |
|---|---|
| `SEAT_TAKEN` | The seat is booked, or another rebooking holds its row lock right now |
| `SEAT_WRONG_CABIN` | The seat is not in the passenger's cabin (no upgrades, as in Fix 5) |
| `SEAT_NOT_ON_FLIGHT` | The seat is on another flight, or does not exist |

The route, schedule, departure and booking rules of 011 still run first and are unchanged.

## Backward compatibility

`CREATE OR REPLACE` with an extra parameter would have added a second overload, and every 3-argument call
would then fail with "function is not unique". Migration 013 drops the 3-argument signature and creates
the 4-argument one in a single transaction. It pins `search_path` and grants EXECUTE as before (PUBLIC,
anon, authenticated, service_role, checked on the live database first). A 3-argument call resolves to the
new function with `p_seat_id` NULL. This was verified on the live database after 013 was applied, with
main's exact `SQL_REACCOMMODATE` in a rolled-back transaction, so the deployed REST tier keeps working
until the new code is deployed. To undo 013, run `db/rollbacks/013_seat_selection_down.sql`.

## Seat map endpoint

`GET /api/flights/{flight_id}/seats` needs the passenger's token. It reuses the alternatives query's
conditions (same route, scheduled, departing later, not the current flight, the booking's cabin), so it
answers 404 for any flight the booking could not move to. It returns each seat (`seat_number`, `row`,
`letter`, `status` free or taken) and the cabin's `layout`, e.g. `"ABC DEF"`, with a space for each aisle.
The layouts follow the dataset generator's aircraft. An unknown aircraft gets one aisle down the middle.

## Tests

| Test | What it shows |
|---|---|
| `tests/integration/test_seat_selection.py` (rolled back, synthetic fixture) | A chosen seat is assigned and audited with `seat_chosen`. Booked seat → `SEAT_TAKEN`, business seat → `SEAT_WRONG_CABIN`, seat on another flight or unknown → `SEAT_NOT_ON_FLIGHT`, each writing nothing but the audit row. A 3-argument call and an explicit NULL both still auto-assign. Route rules come first |
| same file, committed fixture deleted in `finally` | 2 and 10 passengers choose one seat at once: 1 success, the rest `SEAT_TAKEN`, 0 duplicates. A seat whose row lock is held elsewhere is refused at once (NOWAIT) |
| `tests/unit/test_endpoints.py` | Seat map shape and layout, 404 for a non-alternative, 401/422, `seat_id` passed to the procedure, 409 `SEAT_TAKEN` header, malformed `seat_id` 422 before the database, the API's prefixes match 013's messages |
| `kestrel_client/test/seat_map_test.dart` | Grid with aisle and legend at 375 px and 1440 px, 48 px seats. Selecting a seat, and a taken seat that cannot be selected. Chosen seat on Confirm and in the request. 409 → message, reloaded map, pick again. "Let Kestrel choose" sends no seat |

Results on 8 November 2026: `pytest` 311 passed, 11 skipped, 0 failed. The 11 skips are existing tests
that need disrupted demo bookings with a free alternative; the demo data is stale and was not reset,
because only synthetic data may be touched. `flutter analyze` clean, `flutter test` 80 passed. 013 was
first run inside a rolled-back transaction (`KESTREL_PREVIEW_MIGRATION`) before it was applied.
