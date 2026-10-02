-- Project Kestrel - migration 003
-- Corrected atomic re-accommodation procedure.
--
-- Signature, argument order and return columns are unchanged from 001, so
-- main.py and database.py continue to work without modification.
--
-- Lock ordering is pnr_bookings then seats, in every code path. A consistent
-- global ordering is what prevents deadlock between two concurrent agent loops
-- contending for the same booking and the same cabin.

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
    v_target_status     flight_status;
    v_target_departure  timestamptz;
    v_seat_id           uuid;
    v_seat_num          varchar;
BEGIN
    ------------------------------------------------------------------
    -- 1. Load and lock the booking.
    --
    -- FOR UPDATE without SKIP LOCKED is deliberate here: a second concurrent
    -- request for the SAME PNR must wait, then observe the committed result
    -- of the first and be rejected by the guard in step 2. Skipping instead
    -- of waiting would let one passenger consume two seats.
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
        -- Audited even though it fails: an unrecognised PNR arriving from an
        -- autonomous agent is exactly the signal a human reviewer needs.
        INSERT INTO audit_logs (pnr_code, actor, action, details)
        VALUES (
            p_pnr_code,
            p_actor,
            'REACCOMMODATION_REJECTED',
            jsonb_build_object(
                'reason', 'INVALID_PNR',
                'target_flight_id', p_target_flight_id
            )
        );
        RETURN QUERY SELECT
            false, NULL::varchar, 'Invalid PNR code provided.'::text;
        RETURN;
    END IF;

    ------------------------------------------------------------------
    -- 2. Idempotency guard.
    ------------------------------------------------------------------
    IF v_current_flight_id = p_target_flight_id THEN
        INSERT INTO audit_logs (pnr_code, actor, action, details)
        VALUES (
            p_pnr_code,
            p_actor,
            'REACCOMMODATION_REJECTED',
            jsonb_build_object(
                'reason', 'ALREADY_ON_TARGET_FLIGHT',
                'target_flight_id', p_target_flight_id
            )
        );
        RETURN QUERY SELECT
            false,
            NULL::varchar,
            'Passenger is already booked on the requested flight.'::text;
        RETURN;
    END IF;

    -- Optional policy guard. Enable once your seed data marks disrupted
    -- bookings correctly, so that a passenger on an operating flight cannot
    -- move themselves for free.
    -- IF v_booking_status <> 'DISRUPTED' THEN
    --     RETURN QUERY SELECT
    --         false,
    --         NULL::varchar,
    --         'Booking is not flagged as disrupted.'::text;
    --     RETURN;
    -- END IF;

    ------------------------------------------------------------------
    -- 3. Validate the target flight.
    --
    -- Missing in 001 entirely, which meant a hallucinated UUID or a cancelled
    -- flight both surfaced as the misleading message 'No available seats'.
    ------------------------------------------------------------------
    SELECT status, departure_time
    INTO v_target_status, v_target_departure
    FROM flights
    WHERE flight_id = p_target_flight_id;

    IF NOT FOUND THEN
        INSERT INTO audit_logs (pnr_code, actor, action, details)
        VALUES (
            p_pnr_code,
            p_actor,
            'REACCOMMODATION_REJECTED',
            jsonb_build_object(
                'reason', 'UNKNOWN_FLIGHT_ID',
                'target_flight_id', p_target_flight_id
            )
        );
        RETURN QUERY SELECT
            false, NULL::varchar, 'Target flight does not exist.'::text;
        RETURN;
    END IF;

    IF v_target_status <> 'SCHEDULED' THEN
        RETURN QUERY SELECT
            false,
            NULL::varchar,
            format(
                'Target flight is %s and cannot accept passengers.',
                lower(v_target_status::text)
            )::text;
        RETURN;
    END IF;

    IF v_target_departure <= now() THEN
        RETURN QUERY SELECT
            false, NULL::varchar, 'Target flight has already departed.'::text;
        RETURN;
    END IF;

    ------------------------------------------------------------------
    -- 4. Claim a seat.
    --
    -- SKIP LOCKED is the correct choice for contention across DIFFERENT
    -- passengers: a concurrent agent holding a lock on 12A does not block this
    -- transaction, it simply moves to 12B. Under READ COMMITTED, PostgreSQL
    -- re-evaluates the status predicate after acquiring the lock, so a seat
    -- booked by a transaction that committed mid-scan is discarded rather
    -- than double-allocated.
    --
    -- The ORDER BY splits the seat number into its numeric and alphabetic
    -- parts. Sorting the raw varchar put 10A ahead of 2A.
    ------------------------------------------------------------------
    SELECT seat_id, seat_number
    INTO v_seat_id, v_seat_num
    FROM seats
    WHERE flight_id = p_target_flight_id
        AND status = 'AVAILABLE'
    ORDER BY
        NULLIF(regexp_replace(seat_number, '\D', '', 'g'), '')::int NULLS LAST,
        regexp_replace(seat_number, '\d', '', 'g')
    FOR UPDATE SKIP LOCKED
    LIMIT 1;

    IF v_seat_id IS NULL THEN
        INSERT INTO audit_logs (pnr_code, actor, action, details)
        VALUES (
            p_pnr_code,
            p_actor,
            'REACCOMMODATION_REJECTED',
            jsonb_build_object(
                'reason', 'NO_SEATS_AVAILABLE',
                'target_flight_id', p_target_flight_id
            )
        );
        RETURN QUERY SELECT
            false,
            NULL::varchar,
            'No available seats remaining on the target flight.'::text;
        RETURN;
    END IF;

    ------------------------------------------------------------------
    -- 5. Release the previously held seat.
    --
    -- Absent from 001. Without it every re-accommodation permanently removed
    -- one seat from sellable inventory, and a passenger moved twice leaked
    -- two. On a mass disruption this silently destroys capacity on exactly
    -- the flights the recovery process depends on.
    ------------------------------------------------------------------
    IF v_old_seat_id IS NOT NULL AND v_old_seat_id <> v_seat_id THEN
        UPDATE seats
        SET
            status = 'AVAILABLE',
            row_version = row_version + 1
        WHERE seat_id = v_old_seat_id;
    END IF;

    ------------------------------------------------------------------
    -- 6. Commit the allocation.
    ------------------------------------------------------------------
    UPDATE seats
    SET
        status = 'BOOKED',
        row_version = row_version + 1
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
            'from_flight_id',    v_current_flight_id,
            'target_flight_id',  p_target_flight_id,
            'released_seat_id',  v_old_seat_id,
            'assigned_seat',     v_seat_num,
            'assigned_seat_id',  v_seat_id
        )
    );

    RETURN QUERY SELECT
        true, v_seat_num, 'Passenger re-accommodated successfully.'::text;
END;
$function$;
