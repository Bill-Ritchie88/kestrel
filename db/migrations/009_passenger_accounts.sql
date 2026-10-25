-- Project Kestrel - migration 009
-- Passenger accounts for social sign-in (Google, or a one-time code sent by
-- email).
--
-- Supabase Auth proves who the person is. The REST tier then links that
-- account to one passenger, once (POST /api/auth/account), and keeps issuing
-- its own short-lived Kestrel token (auth.py), so every other endpoint is
-- unchanged. Written for review; apply it with the other migrations.

CREATE TABLE IF NOT EXISTS passenger_accounts (
    auth_user_id uuid         PRIMARY KEY,          -- the Supabase auth user's id
    passenger_id uuid         NOT NULL REFERENCES passengers (passenger_id),
    email        varchar(100) NOT NULL,             -- as verified by Supabase when linked
    provider     varchar(20)  NOT NULL,             -- 'google' or 'email'
    linked_at    timestamptz  NOT NULL DEFAULT now()
);

-- One account per passenger: a booking cannot be claimed by a second login.
CREATE UNIQUE INDEX IF NOT EXISTS idx_passenger_accounts_passenger
    ON passenger_accounts (passenger_id);

-- Linking by verified email and the "is this your booking?" suggestions
-- compare lower(email); without a matching expression index (as 002 does for
-- surnames) each lookup is a sequential scan of passengers.
CREATE INDEX IF NOT EXISTS idx_passengers_email_lower
    ON passengers (lower(email));

-- Same stance as 002 and 008: RLS on with no policy, so the public API (anon
-- key) sees nothing; only the server's own connection reads or writes links.
ALTER TABLE passenger_accounts ENABLE ROW LEVEL SECURITY;

-- A link is audited as ACCOUNT:<provider>:<auth_user_id>, up to 65
-- characters ('ACCOUNT:google:' plus a 36-character uuid is already 51), and
-- audit_logs.actor was varchar(50). Widening is backward compatible: every
-- existing actor value still fits.
ALTER TABLE audit_logs ALTER COLUMN actor TYPE varchar(80);
