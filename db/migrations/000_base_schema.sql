-- Project Kestrel - migration 000 (BASE SCHEMA)
--
-- Generated from the deployed Supabase database by
-- scripts/export_schema.py. Do not hand-edit: regenerate instead, so
-- this file cannot drift from the database the way the ERD did.
--
-- Generated: 2026-10-08 21:15 UTC
--
-- Apply FIRST, before the migrations in Table 5.4:
--   000_base_schema.sql   <- this file
--   001_baseline_reaccommodate_passenger_atomic.sql
--   002_indexes_and_rls.sql
--   003_reaccommodate_passenger_atomic_v2.sql
--   ../seeds/reset_demo_state.sql

BEGIN;

-- -------------------------------------------------------------------------
-- Enumerated types
-- -------------------------------------------------------------------------

DO $$ BEGIN
    CREATE TYPE flight_status AS ENUM ('SCHEDULED', 'DELAYED', 'CANCELLED', 'IN_FLIGHT');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE pnr_status AS ENUM ('CONFIRMED', 'DISRUPTED', 'REACCOMMODATED', 'CANCELLED');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE seat_status AS ENUM ('AVAILABLE', 'LOCKED', 'BOOKED');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE voucher_status AS ENUM ('ISSUED', 'REDEEMED', 'EXPIRED');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE voucher_type AS ENUM ('MEAL', 'HOTEL', 'TRANSPORT');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- -------------------------------------------------------------------------
-- Tables
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.passengers (
    passenger_id uuid DEFAULT uuid_generate_v4() NOT NULL,
    first_name character varying(50) NOT NULL,
    last_name character varying(50) NOT NULL,
    email character varying(100) NOT NULL,
    phone_number character varying(20) NOT NULL,
    asante_rewards_tier character varying(20) DEFAULT 'BLUE'::character varying,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT passengers_pkey PRIMARY KEY (passenger_id),
    CONSTRAINT passengers_email_key UNIQUE (email)
);

CREATE TABLE IF NOT EXISTS public.flights (
    flight_id uuid DEFAULT uuid_generate_v4() NOT NULL,
    flight_number character varying(10) NOT NULL,
    origin character varying(3) NOT NULL,
    destination character varying(3) NOT NULL,
    departure_time timestamp with time zone NOT NULL,
    arrival_time timestamp with time zone NOT NULL,
    status flight_status DEFAULT 'SCHEDULED'::flight_status,
    aircraft_type character varying(50) NOT NULL,
    disruption_reason text,
    CONSTRAINT flights_pkey PRIMARY KEY (flight_id),
    CONSTRAINT flights_disruption_reason_check CHECK (((disruption_reason IS NULL) OR (disruption_reason = ANY (ARRAY['TECHNICAL'::text, 'CREW'::text, 'OPERATIONAL'::text, 'WEATHER'::text, 'ATC'::text, 'SECURITY'::text, 'POLITICAL'::text]))))
);

CREATE TABLE IF NOT EXISTS public.seats (
    seat_id uuid DEFAULT uuid_generate_v4() NOT NULL,
    flight_id uuid,
    seat_number character varying(5) NOT NULL,
    cabin_class character varying(20) NOT NULL,
    status seat_status DEFAULT 'AVAILABLE'::seat_status,
    row_version integer DEFAULT 1,
    CONSTRAINT seats_pkey PRIMARY KEY (seat_id),
    CONSTRAINT seats_flight_id_seat_number_key UNIQUE (flight_id, seat_number)
);

CREATE TABLE IF NOT EXISTS public.pnr_bookings (
    pnr_code character varying(6) NOT NULL,
    passenger_id uuid,
    original_flight_id uuid,
    reaccommodated_flight_id uuid,
    assigned_seat_id uuid,
    booking_status pnr_status DEFAULT 'CONFIRMED'::pnr_status,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pnr_bookings_pkey PRIMARY KEY (pnr_code)
);

CREATE TABLE IF NOT EXISTS public.vouchers (
    voucher_id uuid DEFAULT gen_random_uuid() NOT NULL,
    voucher_code text NOT NULL,
    pnr_code character varying NOT NULL,
    entitlement_type text NOT NULL,
    quantity integer DEFAULT 1 NOT NULL,
    amount numeric(12,2),
    currency character(3),
    points integer,
    status text DEFAULT 'ISSUED'::text NOT NULL,
    rule_id text NOT NULL,
    basis text NOT NULL,
    valid_until timestamp with time zone,
    issued_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT vouchers_pkey PRIMARY KEY (voucher_id),
    CONSTRAINT vouchers_one_per_type UNIQUE (pnr_code, entitlement_type),
    CONSTRAINT vouchers_voucher_code_key UNIQUE (voucher_code),
    CONSTRAINT vouchers_entitlement_type_check CHECK ((entitlement_type = ANY (ARRAY['MEAL'::text, 'HOTEL'::text, 'TRANSPORT'::text, 'ASANTE_POINTS'::text, 'CASH_COMPENSATION'::text]))),
    CONSTRAINT vouchers_quantity_check CHECK ((quantity >= 0)),
    CONSTRAINT vouchers_status_check CHECK ((status = ANY (ARRAY['ISSUED'::text, 'ELIGIBLE'::text, 'REDEEMED'::text, 'VOID'::text])))
);

CREATE TABLE IF NOT EXISTS public.audit_logs (
    log_id uuid DEFAULT uuid_generate_v4() NOT NULL,
    pnr_code character varying(6),
    actor character varying(50) NOT NULL,
    action character varying(100) NOT NULL,
    details jsonb NOT NULL,
    timestamp timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT audit_logs_pkey PRIMARY KEY (log_id)
);

-- -------------------------------------------------------------------------
-- Foreign keys
-- -------------------------------------------------------------------------

ALTER TABLE public.seats DROP CONSTRAINT IF EXISTS seats_flight_id_fkey;
ALTER TABLE public.seats ADD CONSTRAINT seats_flight_id_fkey FOREIGN KEY (flight_id) REFERENCES flights(flight_id) ON DELETE CASCADE;

ALTER TABLE public.pnr_bookings DROP CONSTRAINT IF EXISTS pnr_bookings_assigned_seat_id_fkey;
ALTER TABLE public.pnr_bookings ADD CONSTRAINT pnr_bookings_assigned_seat_id_fkey FOREIGN KEY (assigned_seat_id) REFERENCES seats(seat_id);

ALTER TABLE public.pnr_bookings DROP CONSTRAINT IF EXISTS pnr_bookings_original_flight_id_fkey;
ALTER TABLE public.pnr_bookings ADD CONSTRAINT pnr_bookings_original_flight_id_fkey FOREIGN KEY (original_flight_id) REFERENCES flights(flight_id);

ALTER TABLE public.pnr_bookings DROP CONSTRAINT IF EXISTS pnr_bookings_passenger_id_fkey;
ALTER TABLE public.pnr_bookings ADD CONSTRAINT pnr_bookings_passenger_id_fkey FOREIGN KEY (passenger_id) REFERENCES passengers(passenger_id);

ALTER TABLE public.pnr_bookings DROP CONSTRAINT IF EXISTS pnr_bookings_reaccommodated_flight_id_fkey;
ALTER TABLE public.pnr_bookings ADD CONSTRAINT pnr_bookings_reaccommodated_flight_id_fkey FOREIGN KEY (reaccommodated_flight_id) REFERENCES flights(flight_id);

ALTER TABLE public.vouchers DROP CONSTRAINT IF EXISTS vouchers_pnr_code_fkey1;
ALTER TABLE public.vouchers ADD CONSTRAINT vouchers_pnr_code_fkey1 FOREIGN KEY (pnr_code) REFERENCES pnr_bookings(pnr_code);

-- -------------------------------------------------------------------------
-- Indexes
-- -------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_passengers_last_name_lower ON public.passengers USING btree (lower(TRIM(BOTH FROM last_name)));
CREATE INDEX IF NOT EXISTS idx_flights_route_departure ON public.flights USING btree (origin, destination, departure_time) WHERE (status = 'SCHEDULED'::flight_status);
CREATE INDEX IF NOT EXISTS idx_seats_flight_available ON public.seats USING btree (flight_id) WHERE (status = 'AVAILABLE'::seat_status);
CREATE INDEX IF NOT EXISTS idx_seats_flight_cabin_available ON public.seats USING btree (flight_id, cabin_class) WHERE (status = 'AVAILABLE'::seat_status);
CREATE INDEX IF NOT EXISTS idx_seats_lookup ON public.seats USING btree (flight_id, status);
CREATE INDEX IF NOT EXISTS idx_pnr_bookings_assigned_seat ON public.pnr_bookings USING btree (assigned_seat_id);
CREATE INDEX IF NOT EXISTS idx_pnr_bookings_original_flight ON public.pnr_bookings USING btree (original_flight_id);
CREATE INDEX IF NOT EXISTS idx_pnr_bookings_passenger ON public.pnr_bookings USING btree (passenger_id);
CREATE INDEX IF NOT EXISTS idx_pnr_bookings_pnr_upper ON public.pnr_bookings USING btree (upper((pnr_code)::text));
CREATE INDEX IF NOT EXISTS idx_pnr_bookings_reaccommodated_flight ON public.pnr_bookings USING btree (reaccommodated_flight_id);
CREATE INDEX IF NOT EXISTS idx_pnr_code ON public.pnr_bookings USING btree (pnr_code);
CREATE INDEX IF NOT EXISTS idx_vouchers_pnr ON public.vouchers USING btree (pnr_code);
CREATE INDEX IF NOT EXISTS idx_audit_logs_pnr_time ON public.audit_logs USING btree (pnr_code, "timestamp" DESC);

COMMIT;
