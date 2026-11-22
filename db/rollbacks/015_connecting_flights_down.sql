-- Project Kestrel - rollback of migration 015. Not a migration: run it only to undo 015.
-- Deploy the previous API first: the REST tier from 015 on reads the onward columns.
-- Connecting bookings lose their onward leg (remove them first with
-- scripts/data/create_connecting_bookings.py --cleanup).
DROP TRIGGER IF EXISTS trg_flights_broken_connections ON flights;
DROP FUNCTION IF EXISTS public.mark_broken_connections();
DROP FUNCTION IF EXISTS public.reaccommodate_journey_atomic(character varying, uuid, uuid, character varying, uuid, uuid);
DROP FUNCTION IF EXISTS public.journey_pick_seat(uuid, varchar, uuid);
DROP FUNCTION IF EXISTS public.journey_connection_broken(uuid, uuid);
DROP FUNCTION IF EXISTS public.kestrel_min_connection();
DROP FUNCTION IF EXISTS public.kestrel_connection_hub();
ALTER TABLE pnr_bookings
    DROP COLUMN IF EXISTS reaccommodated_onward_flight_id,
    DROP COLUMN IF EXISTS onward_seat_id,
    DROP COLUMN IF EXISTS onward_flight_id;
