-- Project Kestrel - migration 006
-- Entitlements (FR-04, DR-06), hand-off cases (FR-05, FR-09, DR-08) and the
-- cancellation reason the entitlement rules depend on.
--
-- Run after 004 and 005. Safe to re-run. Runs as one transaction in the
-- Supabase SQL editor and through apply_migration.

-- ---------------------------------------------------------------------------
-- 1. Why a flight was cancelled.
--
-- The entitlement rules turn on it: under Regulation 261/2004 Art. 5(3) cash
-- compensation is not owed when the cancellation was caused by extraordinary
-- circumstances (weather, air traffic control, security), but care (meals,
-- hotel) is owed either way. NULL means "not recorded", which the engine
-- treats conservatively: care is given, goodwill points and compensation are
-- left for a member of staff to decide.
-- ---------------------------------------------------------------------------
ALTER TABLE flights ADD COLUMN IF NOT EXISTS disruption_reason text;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'flights_disruption_reason_check'
    ) THEN
        ALTER TABLE flights ADD CONSTRAINT flights_disruption_reason_check
            CHECK (disruption_reason IS NULL OR disruption_reason IN (
                'TECHNICAL', 'CREW', 'OPERATIONAL',          -- within the airline's control
                'WEATHER', 'ATC', 'SECURITY', 'POLITICAL'    -- extraordinary circumstances
            ));
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Vouchers.
--
-- The deployed table was created as a placeholder in Sprint 1 and nothing has
-- ever written to it (DR-06: "its final columns are set in Sprint 2"). It is
-- replaced only if it is empty; if it holds rows the migration stops rather
-- than destroy data.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_rows bigint;
    v_has_final_shape boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'vouchers'
          AND column_name = 'entitlement_type'
    ) INTO v_has_final_shape;

    IF to_regclass('public.vouchers') IS NOT NULL AND NOT v_has_final_shape THEN
        EXECUTE 'SELECT count(*) FROM public.vouchers' INTO v_rows;
        IF v_rows > 0 THEN
            RAISE EXCEPTION
                'vouchers holds % row(s) in the old shape; migrate them by hand before running 006',
                v_rows;
        END IF;
        DROP TABLE public.vouchers;
        -- The placeholder's own enum types, used by nothing else.
        DROP TYPE IF EXISTS public.voucher_type;
        DROP TYPE IF EXISTS public.voucher_status;
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS vouchers (
    voucher_id       uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    voucher_code     text        NOT NULL UNIQUE,      -- e.g. KQ-MV-8842-XT
    pnr_code         varchar     NOT NULL REFERENCES pnr_bookings (pnr_code),
    entitlement_type text        NOT NULL CHECK (entitlement_type IN (
                         'MEAL', 'HOTEL', 'TRANSPORT', 'ASANTE_POINTS', 'CASH_COMPENSATION')),
    quantity         integer     NOT NULL DEFAULT 1 CHECK (quantity >= 0),
    amount           numeric(12, 2),                   -- money value, NULL for points
    currency         char(3),
    points           integer,                          -- Asante Rewards points, NULL otherwise
    status           text        NOT NULL DEFAULT 'ISSUED' CHECK (status IN (
                         'ISSUED', 'ELIGIBLE', 'REDEEMED', 'VOID')),
    rule_id          text        NOT NULL,             -- which deterministic rule produced it
    basis            text        NOT NULL,             -- clause references, e.g. 'EU261 Art. 9(1)(a)'
    valid_until      timestamptz,
    issued_at        timestamptz NOT NULL DEFAULT now(),
    -- One entitlement of each type per booking: re-running the engine after a
    -- second rebooking updates the row instead of issuing a duplicate.
    CONSTRAINT vouchers_one_per_type UNIQUE (pnr_code, entitlement_type)
);

CREATE INDEX IF NOT EXISTS idx_vouchers_pnr ON vouchers (pnr_code);
ALTER TABLE vouchers ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 3. Hand-off cases (FR-05, FR-09).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS handoff_cases (
    case_id           bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pnr_code          varchar     NOT NULL REFERENCES pnr_bookings (pnr_code),
    trigger           text        NOT NULL CHECK (trigger IN (
                          'LOW_SIMILARITY',      -- best policy match below tau
                          'NO_ALTERNATIVES',     -- no flight with a seat in the passenger's cabin
                          'STEP_LIMIT',          -- agent reached its iteration limit
                          'REBOOKING_FAILED',    -- the procedure refused and the agent could not recover
                          'PASSENGER_REQUEST')), -- the passenger asked for a person
    booking_status    text,                     -- snapshot at the time of hand-off
    question          text,
    top_similarity    double precision,
    similarity_scores jsonb,                    -- [{"clause_ref":..., "similarity":...}, ...]
    summary           text,
    status            text        NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'RESOLVED')),
    created_at        timestamptz NOT NULL DEFAULT now(),
    resolved_at       timestamptz,
    resolved_by       text,
    resolution_note   text,
    CHECK ((status = 'RESOLVED') = (resolved_at IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS idx_handoff_cases_open
    ON handoff_cases (created_at)
    WHERE status = 'OPEN';
CREATE INDEX IF NOT EXISTS idx_handoff_cases_pnr ON handoff_cases (pnr_code);
ALTER TABLE handoff_cases ENABLE ROW LEVEL SECURITY;

