-- Project Kestrel - migration 007
-- Row-level security on flights.
--
-- Migration 002 enabled RLS on every other table but missed flights, so the
-- anon key could read and modify the schedule through the Supabase public
-- API (flagged by the Supabase security advisor, 9 October 2026). With RLS on
-- and no permissive policy, only the table owner - the REST tier's
-- connection - can reach it, as for the other tables.
ALTER TABLE public.flights ENABLE ROW LEVEL SECURITY;
