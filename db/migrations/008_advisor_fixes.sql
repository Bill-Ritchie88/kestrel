-- Project Kestrel - migration 008
-- Fixes raised by the Supabase security and performance advisors after 004-007.

-- Security (lint 0011, function_search_path_mutable): pin the procedure's
-- search_path so a caller cannot shadow seats, flights or audit_logs with
-- objects in another schema.
ALTER FUNCTION public.reaccommodate_passenger_atomic(character varying, uuid, character varying)
    SET search_path = public;

-- Performance (lint 0001, unindexed_foreign_keys): covering indexes for
-- pnr_bookings' foreign keys. original_flight_id drives every "who was on the
-- cancelled flight" query (reset, disruption marking, the load test);
-- assigned_seat_id the seat joins in /api/me and the alternatives search.
CREATE INDEX IF NOT EXISTS idx_pnr_bookings_original_flight ON pnr_bookings (original_flight_id);
CREATE INDEX IF NOT EXISTS idx_pnr_bookings_reaccommodated_flight ON pnr_bookings (reaccommodated_flight_id);
CREATE INDEX IF NOT EXISTS idx_pnr_bookings_assigned_seat ON pnr_bookings (assigned_seat_id);
CREATE INDEX IF NOT EXISTS idx_pnr_bookings_passenger ON pnr_bookings (passenger_id);

-- Not changed, by decision:
--   * rls_enabled_no_policy (INFO) on every table: intended. No policy means
--     the public API sees nothing; the REST tier is the only way in.
--   * extension_in_public (WARN) for pgvector: moving it would change the
--     type of policy_chunks.embedding; deferred until the corpus is stable.
