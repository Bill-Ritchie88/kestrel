-- Project Kestrel - migration 002
-- Supersedes the earlier draft, which added origin/destination columns that
-- the deployed schema already has. Only indexes remain.

-- Authentication lookup. SQL_AUTHENTICATE filters on lower(trim(last_name))
-- and upper(pnr_code); without matching expression indexes every login is a
-- sequential scan.
CREATE INDEX IF NOT EXISTS idx_passengers_last_name_lower
    ON passengers (lower(trim(last_name)));

CREATE INDEX IF NOT EXISTS idx_pnr_bookings_pnr_upper
    ON pnr_bookings (upper(pnr_code));

-- Seat claim path. The procedure scans seats by flight_id filtered on
-- AVAILABLE; a partial index keeps that scan small as cabins fill up.
CREATE INDEX IF NOT EXISTS idx_seats_flight_available
    ON seats (flight_id)
    WHERE status = 'AVAILABLE';

-- Alternative-flight discovery.
CREATE INDEX IF NOT EXISTS idx_flights_route_departure
    ON flights (origin, destination, departure_time)
    WHERE status = 'SCHEDULED';

-- Audit queries are almost always "what happened to this booking".
CREATE INDEX IF NOT EXISTS idx_audit_logs_pnr_time
    ON audit_logs (pnr_code, timestamp DESC);

-- Defence in depth: Supabase exposes these tables over PostgREST with the anon
-- key. RLS enabled with no permissive policy means the only path to booking
-- data is through FastAPI, where the session check lives.
ALTER TABLE passengers    ENABLE ROW LEVEL SECURITY;
ALTER TABLE pnr_bookings  ENABLE ROW LEVEL SECURITY;
ALTER TABLE seats         ENABLE ROW LEVEL SECURITY;
ALTER TABLE vouchers      ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs    ENABLE ROW LEVEL SECURITY;