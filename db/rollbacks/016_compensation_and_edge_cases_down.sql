-- Project Kestrel - rollback of migration 016. Not a migration: run it only to undo 016.
-- Deploy the previous API first: the REST tier from 016 on reads the claims table and
-- flights.scheduled_*_time. Claims are deleted; cancelled bookings stay CANCELLED.
DROP FUNCTION IF EXISTS public.cancel_booking_for_refund(varchar, varchar, text);
DROP TRIGGER IF EXISTS trg_flights_keep_scheduled_times ON flights;
DROP FUNCTION IF EXISTS public.keep_scheduled_times();
ALTER TABLE flights
    DROP COLUMN IF EXISTS scheduled_arrival_time,
    DROP COLUMN IF EXISTS scheduled_departure_time;
DROP TABLE IF EXISTS compensation_claims;
DROP FUNCTION IF EXISTS public.compensation_claim_audit();
DROP FUNCTION IF EXISTS public.compensation_claim_guard();

-- 015's mark_broken_connections (CONFIRMED journeys only), as it was.
CREATE OR REPLACE FUNCTION public.mark_broken_connections()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    UPDATE pnr_bookings b
    SET booking_status = 'DISRUPTED', updated_at = now()
    WHERE b.booking_status = 'CONFIRMED'
      AND b.onward_flight_id IS NOT NULL
      AND NEW.flight_id IN (COALESCE(b.reaccommodated_flight_id, b.original_flight_id),
                            COALESCE(b.reaccommodated_onward_flight_id, b.onward_flight_id))
      AND journey_connection_broken(COALESCE(b.reaccommodated_flight_id, b.original_flight_id),
                                    COALESCE(b.reaccommodated_onward_flight_id, b.onward_flight_id));
    RETURN NULL;
END;
$$;
