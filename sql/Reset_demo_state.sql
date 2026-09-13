-- Project Kestrel - migration 004
-- Demo state reset. Safe to run repeatedly.
--
-- Puts the system back into a known pre-disruption state with every flight in
-- the future, so a demonstration behaves identically whether it runs today or
-- in three months. Operates on rows already present; use
-- scripts/dataset_generator.py to create them in the first place.
--
-- No PNR, flight or seat identifier is hardcoded. The disruption is chosen by
-- booking volume at runtime, so this file survives a regenerated dataset.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Reschedule every flight relative to now(), preserving the original
--    spacing between departures so that "next available flight" still has a
--    meaningful answer. The earliest flight lands two hours from now.
-- ---------------------------------------------------------------------------
WITH anchor AS (
    SELECT min(departure_time) AS t0 FROM flights
)
UPDATE flights f
SET departure_time = now() + interval '2 hours' + (f.departure_time - a.t0),
    arrival_time   = now() + interval '2 hours' + (f.arrival_time   - a.t0)
FROM anchor a;

-- ---------------------------------------------------------------------------
-- 2. Every flight operating, every seat free, every booking on its original
--    flight with no recovery applied.
-- ---------------------------------------------------------------------------
UPDATE flights SET status = 'SCHEDULED';

UPDATE seats
SET status = 'AVAILABLE', row_version = row_version + 1
WHERE status <> 'AVAILABLE';

UPDATE pnr_bookings
SET reaccommodated_flight_id = NULL,
    booking_status           = 'CONFIRMED',
    updated_at               = now();

-- ---------------------------------------------------------------------------
-- 3. Re-occupy the seat each booking already holds, so cabins are not empty.
--    Any booking whose seat belongs to a different flight is left unseated
--    rather than silently corrupted.
-- ---------------------------------------------------------------------------
UPDATE seats s
SET status = 'BOOKED', row_version = row_version + 1
FROM pnr_bookings b
WHERE b.assigned_seat_id = s.seat_id
  AND s.flight_id = b.original_flight_id;

UPDATE pnr_bookings b
SET assigned_seat_id = NULL
WHERE b.assigned_seat_id IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM seats s
      WHERE s.seat_id = b.assigned_seat_id
        AND s.flight_id = b.original_flight_id
  );

-- ---------------------------------------------------------------------------
-- 4. Create the disruption: cancel the two future flights carrying the most
--    passengers. Choosing by booking volume guarantees genuine contention for
--    the remaining seats, which is the condition the pessimistic locking in
--    reaccommodate_passenger_atomic exists to handle.
-- ---------------------------------------------------------------------------
UPDATE flights SET status = 'CANCELLED'
WHERE flight_id IN (
    SELECT f.flight_id
    FROM flights f
    JOIN pnr_bookings b ON b.original_flight_id = f.flight_id
    WHERE f.departure_time > now()
    GROUP BY f.flight_id
    ORDER BY count(b.pnr_code) DESC
    LIMIT 2
);

UPDATE pnr_bookings b
SET booking_status = 'DISRUPTED', updated_at = now()
FROM flights f
WHERE f.flight_id = b.original_flight_id
  AND f.status = 'CANCELLED';

-- ---------------------------------------------------------------------------
-- 5. Optional. Clears the audit trail. Left commented out: the log
--    accumulated across runs is evidence for Chapter 5.
-- ---------------------------------------------------------------------------
-- DELETE FROM audit_logs;

COMMIT;

-- ---------------------------------------------------------------------------
-- Verification and demo credentials.
--
-- Returns one disrupted passenger to test with, plus how many alternatives
-- exist on that route. If alternatives_on_route is 0, the agent has nowhere to
-- rebook and the dataset needs more frequency on that route.
-- ---------------------------------------------------------------------------
SELECT b.pnr_code      AS demo_pnr,
       p.last_name     AS demo_surname,
       f.flight_number AS cancelled_flight,
       f.origin || '-' || f.destination AS route,
       (SELECT count(*)
          FROM flights alt
         WHERE alt.origin = f.origin
           AND alt.destination = f.destination
           AND alt.flight_id <> f.flight_id
           AND alt.status = 'SCHEDULED'
           AND alt.departure_time > now())  AS alternatives_on_route,
       (SELECT count(*)
          FROM pnr_bookings d
         WHERE d.booking_status = 'DISRUPTED') AS total_disrupted
FROM pnr_bookings b
JOIN passengers p ON p.passenger_id = b.passenger_id
JOIN flights    f ON f.flight_id    = b.original_flight_id
WHERE b.booking_status = 'DISRUPTED'
LIMIT 1;