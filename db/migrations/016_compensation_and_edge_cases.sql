-- Project Kestrel - migration 016: compensation claims, refunds, delays and
-- second disruptions. Requires 015. Idempotent; no BEGIN/COMMIT, so it can be
-- previewed inside a rolled-back transaction (KESTREL_PREVIEW_MIGRATION).
--
-- 1. compensation_claims: a passenger's claim for the cash compensation the
--    rules give (R4), or for a refund after cancelling. States:
--      (CALCULATED: the rules give an amount, no row yet)
--      CLAIMED -> APPROVED -> PAID
--              -> REJECTED (with a reason)
--    A trigger refuses any other move, so no state is skipped or reversed,
--    whoever writes the row. Another writes every change to audit_logs.
-- 2. flights.scheduled_departure_time / scheduled_arrival_time: the times
--    before the first change, so a delay can be measured.
-- 3. Second disruption: a rebooked passenger whose new flight is cancelled (or
--    whose new journey breaks) is DISRUPTED again and can choose once more.
-- 4. cancel_booking_for_refund(): "Cancel and request a refund", atomic.

-- ---------------------------------------------------------------------------
-- 1. Claims
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS compensation_claims (
    claim_id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pnr_code          varchar     NOT NULL REFERENCES pnr_bookings (pnr_code),
    kind              text        NOT NULL CHECK (kind IN ('COMPENSATION', 'REFUND')),
    status            text        NOT NULL DEFAULT 'CLAIMED'
                                  CHECK (status IN ('CLAIMED', 'APPROVED', 'REJECTED', 'PAID')),
    amount            numeric(12,2),           -- NULL for a refund: no fare data is held
    currency          char(3),
    rule_id           text        NOT NULL,
    basis             text        NOT NULL,
    claimed_by        text        NOT NULL,
    decided_by        text,
    reason            text,                    -- why a claim was rejected
    paid_by           text,
    payout_reference  text,                    -- entered by staff; no money moves here
    created_at        timestamptz NOT NULL DEFAULT now(),
    decided_at        timestamptz,
    paid_at           timestamptz,
    UNIQUE (pnr_code, kind),
    CHECK (status <> 'REJECTED' OR length(trim(reason)) > 0),
    CHECK (status <> 'PAID' OR length(trim(payout_reference)) > 0),
    -- Only staff decide or pay: a passenger cannot approve their own claim.
    CHECK (decided_by IS NULL OR decided_by LIKE 'STAFF:%'),
    CHECK (paid_by IS NULL OR paid_by LIKE 'STAFF:%')
);

CREATE INDEX IF NOT EXISTS idx_compensation_claims_open
    ON compensation_claims (created_at) WHERE status IN ('CLAIMED', 'APPROVED');
ALTER TABLE compensation_claims ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.compensation_claim_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'CLAIMED' THEN
            RAISE EXCEPTION 'A claim starts as CLAIMED, not %', NEW.status
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.pnr_code IS DISTINCT FROM OLD.pnr_code OR NEW.kind IS DISTINCT FROM OLD.kind
       OR NEW.amount IS DISTINCT FROM OLD.amount OR NEW.currency IS DISTINCT FROM OLD.currency THEN
        RAISE EXCEPTION 'A claim''s booking, kind and amount cannot change'
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status IS DISTINCT FROM OLD.status
       AND (OLD.status, NEW.status) NOT IN (('CLAIMED', 'APPROVED'), ('CLAIMED', 'REJECTED'),
                                            ('APPROVED', 'PAID')) THEN
        RAISE EXCEPTION 'A claim cannot move from % to %', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_compensation_claim_guard ON compensation_claims;
CREATE TRIGGER trg_compensation_claim_guard
    BEFORE INSERT OR UPDATE ON compensation_claims
    FOR EACH ROW EXECUTE FUNCTION public.compensation_claim_guard();

CREATE OR REPLACE FUNCTION public.compensation_claim_audit()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.status IS NOT DISTINCT FROM OLD.status THEN
        RETURN NULL;
    END IF;
    INSERT INTO audit_logs (pnr_code, actor, action, details)
    VALUES (
        NEW.pnr_code,
        left(CASE NEW.status WHEN 'CLAIMED' THEN NEW.claimed_by
                             WHEN 'PAID' THEN NEW.paid_by
                             ELSE NEW.decided_by END, 50),
        CASE WHEN TG_OP = 'INSERT' THEN NEW.kind || '_CLAIMED' ELSE 'CLAIM_' || NEW.status END,
        jsonb_build_object('claim_id', NEW.claim_id, 'kind', NEW.kind,
                           'from', CASE WHEN TG_OP = 'UPDATE' THEN OLD.status END, 'to', NEW.status,
                           'amount', NEW.amount, 'currency', NEW.currency, 'rule_id', NEW.rule_id,
                           'reason', NEW.reason, 'payout_reference', NEW.payout_reference)
    );
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_compensation_claim_audit ON compensation_claims;
CREATE TRIGGER trg_compensation_claim_audit
    AFTER INSERT OR UPDATE ON compensation_claims
    FOR EACH ROW EXECUTE FUNCTION public.compensation_claim_audit();

-- ---------------------------------------------------------------------------
-- 2. Scheduled times, kept on the first change (a delay)
-- ---------------------------------------------------------------------------

ALTER TABLE flights
    ADD COLUMN IF NOT EXISTS scheduled_departure_time timestamptz,
    ADD COLUMN IF NOT EXISTS scheduled_arrival_time timestamptz;

CREATE OR REPLACE FUNCTION public.keep_scheduled_times()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF NEW.scheduled_departure_time IS NULL AND NEW.departure_time IS DISTINCT FROM OLD.departure_time THEN
        NEW.scheduled_departure_time := OLD.departure_time;
    END IF;
    IF NEW.scheduled_arrival_time IS NULL AND NEW.arrival_time IS DISTINCT FROM OLD.arrival_time THEN
        NEW.scheduled_arrival_time := OLD.arrival_time;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_flights_keep_scheduled_times ON flights;
CREATE TRIGGER trg_flights_keep_scheduled_times
    BEFORE UPDATE OF departure_time, arrival_time ON flights
    FOR EACH ROW EXECUTE FUNCTION public.keep_scheduled_times();

-- ---------------------------------------------------------------------------
-- 3. Second disruption: replaces 015's function (same trigger). A journey,
--    as booked or as rebooked, is DISRUPTED when its current legs no longer
--    connect; a single-flight booking that was rebooked is DISRUPTED again
--    when its new flight is cancelled. Each change is audited.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.mark_broken_connections()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    WITH hit AS (
        UPDATE pnr_bookings b
        SET booking_status = 'DISRUPTED', updated_at = now()
        WHERE (b.onward_flight_id IS NOT NULL
               AND b.booking_status IN ('CONFIRMED', 'REACCOMMODATED')
               AND NEW.flight_id IN (COALESCE(b.reaccommodated_flight_id, b.original_flight_id),
                                     COALESCE(b.reaccommodated_onward_flight_id, b.onward_flight_id))
               AND journey_connection_broken(COALESCE(b.reaccommodated_flight_id, b.original_flight_id),
                                             COALESCE(b.reaccommodated_onward_flight_id, b.onward_flight_id)))
           OR (b.onward_flight_id IS NULL
               AND b.booking_status = 'REACCOMMODATED'
               AND b.reaccommodated_flight_id = NEW.flight_id
               AND NEW.status = 'CANCELLED')
        RETURNING b.pnr_code, b.reaccommodated_flight_id
    )
    INSERT INTO audit_logs (pnr_code, actor, action, details)
    SELECT pnr_code, 'SYSTEM',
           CASE WHEN reaccommodated_flight_id IS NULL THEN 'BOOKING_DISRUPTED' ELSE 'BOOKING_DISRUPTED_AGAIN' END,
           jsonb_build_object('flight_id', NEW.flight_id, 'flight_status', NEW.status)
    FROM hit;
    RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Cancel and request a refund (Art. 8(1)(a)). Allowed while the booking is
--    DISRUPTED, or CONFIRMED on a flight delayed by 5 hours or more (Art.
--    6(1)(c)(iii)); refused once rebooked or once the flight has left. The
--    seats go back on sale and a REFUND claim (CLAIMED) is opened, for staff
--    to process like any other claim.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.cancel_booking_for_refund(
    p_pnr_code varchar,
    p_actor varchar,
    p_basis text
)
RETURNS TABLE (success boolean, reason text, message text, claim_id bigint)
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
    v_status    pnr_status;
    v_flight    uuid;
    v_seat      uuid;
    v_onward    uuid;
    f_status    flight_status;
    f_departure timestamptz;
    f_scheduled timestamptz;
    v_reason    text;
    v_message   text;
    v_claim     bigint;
BEGIN
    SELECT b.booking_status, COALESCE(b.reaccommodated_flight_id, b.original_flight_id),
           b.assigned_seat_id, b.onward_seat_id
    INTO v_status, v_flight, v_seat, v_onward
    FROM pnr_bookings b WHERE b.pnr_code = p_pnr_code
    FOR UPDATE;

    SELECT f.status, f.departure_time, f.scheduled_departure_time
    INTO f_status, f_departure, f_scheduled
    FROM flights f WHERE f.flight_id = v_flight;

    IF v_status IS NULL THEN
        v_reason := 'INVALID_PNR';
        v_message := 'Invalid PNR code provided.';
    ELSIF v_status = 'CANCELLED' THEN
        v_reason := 'ALREADY_CANCELLED';
        v_message := 'This booking is already cancelled.';
    ELSIF v_status = 'REACCOMMODATED' THEN
        v_reason := 'ALREADY_REBOOKED';
        v_message := 'You have already been rebooked, so this booking can no longer be cancelled for a refund here.';
    ELSIF f_status = 'IN_FLIGHT' OR (f_status <> 'CANCELLED' AND f_departure <= now()) THEN
        v_reason := 'FLIGHT_DEPARTED';
        v_message := 'Your flight has already left, so it can no longer be cancelled for a refund.';
    ELSIF v_status = 'CONFIRMED'
          AND NOT (f_status = 'DELAYED' AND f_scheduled IS NOT NULL
                   AND f_departure - f_scheduled >= interval '5 hours') THEN
        v_reason := 'NOT_ELIGIBLE';
        v_message := 'A refund is offered when your flight is cancelled or delayed by 5 hours or more.';
    END IF;

    IF v_reason IS NOT NULL THEN
        INSERT INTO audit_logs (pnr_code, actor, action, details)
        SELECT p_pnr_code, p_actor, 'REFUND_REJECTED', jsonb_build_object('reason', v_reason)
        WHERE v_status IS NOT NULL;
        RETURN QUERY SELECT false, v_reason, v_message, NULL::bigint;
        RETURN;
    END IF;

    UPDATE seats SET status = 'AVAILABLE', row_version = row_version + 1
    WHERE seat_id IN (v_seat, v_onward);
    UPDATE pnr_bookings
    SET booking_status = 'CANCELLED', assigned_seat_id = NULL, onward_seat_id = NULL, updated_at = now()
    WHERE pnr_code = p_pnr_code;
    INSERT INTO compensation_claims (pnr_code, kind, rule_id, basis, claimed_by)
    VALUES (p_pnr_code, 'REFUND', 'R6_REFUND', p_basis, p_actor)
    RETURNING compensation_claims.claim_id INTO v_claim;
    INSERT INTO audit_logs (pnr_code, actor, action, details)
    VALUES (p_pnr_code, p_actor, 'BOOKING_CANCELLED',
            jsonb_build_object('previous_status', v_status, 'flight_id', v_flight, 'claim_id', v_claim));
    RETURN QUERY SELECT true, NULL::text, 'Your booking is cancelled and your refund has been requested.'::text, v_claim;
END;
$$;

GRANT EXECUTE ON FUNCTION public.cancel_booking_for_refund(varchar, varchar, text)
    TO PUBLIC, anon, authenticated, service_role;
