-- Project Kestrel - migration 011
-- reaccommodate_passenger_atomic: refuse a target flight on another route
-- (issue #2, 18 Oct review). Same route = the origin and destination of the
-- booking's ORIGINAL flight; rebooking stays on the same route and airline
-- (agreed scope). Before this, only the AI prompt prevented a passenger
-- from sending another route's flight_id. Everything else is unchanged from
-- migration 004; SET search_path = public is restated because CREATE OR
-- REPLACE would otherwise drop it.

CREATE OR REPLACE FUNCTION public.reaccommodate_passenger_atomic(
    p_pnr_code character varying,
    p_target_flight_id uuid,
    p_actor character varying DEFAULT 'AGENT_AI'::character varying
)
RETURNS TABLE(success boolean, assigned_seat_number character varying, message text)
LANGUAGE plpgsql
SET search_path = public
AS $function$
DECLARE
    v_passenger_id      uuid;
    v_booking_status    pnr_status;
    v_original_flight   uuid;
    v_current_flight_id uuid;
    v_old_seat_id       uuid;
    v_cabin             seats.cabin_class%TYPE;
    v_route_origin      varchar;
    v_route_destination varchar;
    v_target_status     flight_status;
    v_target_departure  timestamptz;
    v_target_origin     varchar;
    v_target_destination varchar;
    v_seat_id           uuid;
    v_seat_num          varchar;
    v_reason            text;
    v_message           text;
BEGIN
    SELECT
        passenger_id,
        booking_status,
        original_flight_id,
        COALESCE(reaccommodated_flight_id, original_flight_id),
        assigned_seat_id
    INTO
        v_passenger_id, v_booking_status, v_original_flight, v_current_flight_id, v_old_seat_id
    FROM pnr_bookings
    WHERE pnr_code = p_pnr_code
    FOR UPDATE;

    IF NOT FOUND THEN
        v_reason  := 'INVALID_PNR';
        v_message := 'Invalid PNR code provided.';
    ELSIF v_booking_status NOT IN ('DISRUPTED', 'REACCOMMODATED') THEN
        v_reason  := 'BOOKING_NOT_DISRUPTED';
        v_message := 'This booking is not affected by a disruption, so it cannot be moved free of charge.';
    ELSIF v_current_flight_id = p_target_flight_id THEN
        v_reason  := 'ALREADY_ON_TARGET_FLIGHT';
        v_message := 'Passenger is already booked on the requested flight.';
    END IF;

    IF v_reason IS NULL THEN
        SELECT origin, destination
        INTO v_route_origin, v_route_destination
        FROM flights
        WHERE flight_id = v_original_flight;

        SELECT status, departure_time, origin, destination
        INTO v_target_status, v_target_departure, v_target_origin, v_target_destination
        FROM flights
        WHERE flight_id = p_target_flight_id;

        IF NOT FOUND THEN
            v_reason  := 'UNKNOWN_FLIGHT_ID';
            v_message := 'Target flight does not exist.';
        ELSIF v_target_origin IS DISTINCT FROM v_route_origin
              OR v_target_destination IS DISTINCT FROM v_route_destination THEN
            v_reason  := 'DIFFERENT_ROUTE';
            v_message := format(
                'Target flight flies %s to %s; this booking can only move to another %s to %s flight.',
                v_target_origin, v_target_destination, v_route_origin, v_route_destination
            );
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
        SELECT cabin_class INTO v_cabin
        FROM seats
        WHERE seat_id = v_old_seat_id;

        v_cabin := COALESCE(v_cabin, 'ECONOMY');

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
