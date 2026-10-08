-- Project Kestrel - migration 004
-- reaccommodate_passenger_atomic v3: cabin class enforcement (Fix 5),
-- disruption eligibility, and an audit row for EVERY rejection.
--
-- Signature, argument order and return columns are unchanged from 001 and 003,
-- so the REST tier keeps working without modification.
--
-- What changed from 003, and why:
--
--   1. Fix 5 - cabin class. 003 claimed the first free seat on the target
--      flight in any cabin, so the Sprint 1 end-to-end run moved an economy
--      passenger into business seat 1A. The seat claim is now restricted to the
--      cabin of the seat the passenger currently holds. A passenger with no
--      seat on record is treated as ECONOMY: the procedure may never hand out a
--      free upgrade on its own authority.
--
--   2. Eligibility. 003 carried this check commented out. A booking must be
--      DISRUPTED (or already REACCOMMODATED, so a passenger can move again)
--      before it can be moved for free; a CONFIRMED passenger on an operating
--      flight is refused.
--
--   3. Audit completeness (FR-07). 003 returned early without an audit row when
--      the target flight was cancelled or had departed. Every rejection now
--      writes a row with a reason code.
--
-- Lock ordering is unchanged: pnr_bookings, then seats, in every code path.

CREATE OR REPLACE FUNCTION public.reaccommodate_passenger_atomic(
    p_pnr_code character varying,
    p_target_flight_id uuid,
    p_actor character varying DEFAULT 'AGENT_AI'::character varying
)
RETURNS TABLE(success boolean, assigned_seat_number character varying, message text)
LANGUAGE plpgsql
AS $function$
DECLARE
    v_passenger_id      uuid;
    v_booking_status    pnr_status;
    v_current_flight_id uuid;
    v_old_seat_id       uuid;
    v_cabin             seats.cabin_class%TYPE;
    v_target_status     flight_status;
    v_target_departure  timestamptz;
    v_seat_id           uuid;
    v_seat_num          varchar;
    v_reason            text;
    v_message           text;
BEGIN
    ------------------------------------------------------------------
    -- 1. Load and lock the booking (FOR UPDATE, no SKIP LOCKED: a second
    --    request for the same PNR must wait and then see the first result).
    ------------------------------------------------------------------
    SELECT
        passenger_id,
        booking_status,
        COALESCE(reaccommodated_flight_id, original_flight_id),
        assigned_seat_id
    INTO
        v_passenger_id, v_booking_status, v_current_flight_id, v_old_seat_id
    FROM pnr_bookings
    WHERE pnr_code = p_pnr_code
    FOR UPDATE;

    IF NOT FOUND THEN
        v_reason  := 'INVALID_PNR';
        v_message := 'Invalid PNR code provided.';
    ELSIF v_booking_status NOT IN ('DISRUPTED', 'REACCOMMODATED') THEN
        -- 2. Eligibility: only a disrupted booking is rebooked free of charge.
        v_reason  := 'BOOKING_NOT_DISRUPTED';
        v_message := 'This booking is not affected by a disruption, so it cannot be moved free of charge.';
    ELSIF v_current_flight_id = p_target_flight_id THEN
        -- 3. Idempotency guard.
        v_reason  := 'ALREADY_ON_TARGET_FLIGHT';
        v_message := 'Passenger is already booked on the requested flight.';
    END IF;

    IF v_reason IS NULL THEN
        ------------------------------------------------------------------
        -- 4. Validate the target flight.
        ------------------------------------------------------------------
        SELECT status, departure_time
        INTO v_target_status, v_target_departure
        FROM flights
        WHERE flight_id = p_target_flight_id;

        IF NOT FOUND THEN
            v_reason  := 'UNKNOWN_FLIGHT_ID';
            v_message := 'Target flight does not exist.';
        ELSIF v_target_status <> 'SCHEDULED' THEN
            v_reason  := 'FLIGHT_NOT_SCHEDULED';
            v_message := format(
                'Target flight is %s and cannot accept passengers.',
                lower(v_target_status::text)
            );
        ELSIF v_target_departure <= now() THEN
            v_reason  := 'FLIGHT_DEPARTED';
            v_message := 'Target flight has already departed.';
        END IF;
    END IF;

    IF v_reason IS NULL THEN
        ------------------------------------------------------------------
        -- 5. Resolve the passenger's cabin (Fix 5). The cabin travels with the
        --    seat the passenger currently holds; no seat on record means
        --    ECONOMY, never an implicit upgrade.
        ------------------------------------------------------------------
        SELECT cabin_class INTO v_cabin
        FROM seats
        WHERE seat_id = v_old_seat_id;

        v_cabin := COALESCE(v_cabin, 'ECONOMY');

        ------------------------------------------------------------------
        -- 6. Claim a seat in that cabin. SKIP LOCKED lets concurrent passengers
        --    take different seats instead of queueing; READ COMMITTED re-checks
        --    the status predicate after the lock, so a seat taken mid-scan is
        --    skipped rather than double-allocated. Natural row/letter order.
        ------------------------------------------------------------------
        SELECT seat_id, seat_number
        INTO v_seat_id, v_seat_num
        FROM seats
        WHERE flight_id = p_target_flight_id
            AND status = 'AVAILABLE'
            AND cabin_class = v_cabin
        ORDER BY
            NULLIF(regexp_replace(seat_number, '\D', '', 'g'), '')::int NULLS LAST,
            regexp_replace(seat_number, '\d', '', 'g')
        FOR UPDATE SKIP LOCKED
        LIMIT 1;

        IF v_seat_id IS NULL THEN
            v_reason  := 'NO_SEATS_IN_CABIN';
            v_message := format(
                'No %s seats remaining on the target flight.',
                lower(v_cabin::text)
            );
        END IF;
    END IF;

    ------------------------------------------------------------------
    -- Every rejection is audited with a reason code (FR-07).
    ------------------------------------------------------------------
    IF v_reason IS NOT NULL THEN
        INSERT INTO audit_logs (pnr_code, actor, action, details)
        VALUES (
            p_pnr_code,
            p_actor,
            'REACCOMMODATION_REJECTED',
            jsonb_build_object(
                'reason', v_reason,
                'target_flight_id', p_target_flight_id,
                'cabin_class', v_cabin
            )
        );
        RETURN QUERY SELECT false, NULL::varchar, v_message;
        RETURN;
    END IF;

    ------------------------------------------------------------------
    -- 7. Release the previously held seat, then commit the allocation.
    ------------------------------------------------------------------
    IF v_old_seat_id IS NOT NULL AND v_old_seat_id <> v_seat_id THEN
        UPDATE seats
        SET status = 'AVAILABLE', row_version = row_version + 1
        WHERE seat_id = v_old_seat_id;
    END IF;

    UPDATE seats
    SET status = 'BOOKED', row_version = row_version + 1
    WHERE seat_id = v_seat_id;

    UPDATE pnr_bookings
    SET
        reaccommodated_flight_id = p_target_flight_id,
        assigned_seat_id         = v_seat_id,
        booking_status           = 'REACCOMMODATED',
        updated_at               = now()
    WHERE pnr_code = p_pnr_code;

    INSERT INTO audit_logs (pnr_code, actor, action, details)
    VALUES (
        p_pnr_code,
        p_actor,
        'AUTOMATED_REACCOMMODATION',
        jsonb_build_object(
            'from_flight_id',   v_current_flight_id,
            'target_flight_id', p_target_flight_id,
            'released_seat_id', v_old_seat_id,
            'assigned_seat',    v_seat_num,
            'assigned_seat_id', v_seat_id,
            'cabin_class',      v_cabin
        )
    );

    RETURN QUERY SELECT
        true, v_seat_num, 'Passenger re-accommodated successfully.'::text;
END;
$function$;

-- Supports the cabin-filtered seat claim and the per-cabin availability count
-- in GET /api/flights/alternatives.
CREATE INDEX IF NOT EXISTS idx_seats_flight_cabin_available
    ON seats (flight_id, cabin_class)
    WHERE status = 'AVAILABLE';
