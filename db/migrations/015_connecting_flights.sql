-- Project Kestrel - migration 015 (supervisor review, 20 Nov 2026)
-- Connecting flights: "what happens if the cancelled flight is being used as
-- a connection?"
--
-- Scope (a stated limitation): a journey has at most two legs, both on the
-- one airline, connecting at the hub, Nairobi (NBO). Leg 1 is
-- pnr_bookings.original_flight_id (origin -> NBO), leg 2 the new
-- pnr_bookings.onward_flight_id (NBO -> final destination). A booking with no
-- onward leg is a single-flight booking and is untouched by everything here:
-- it keeps reaccommodate_passenger_atomic (013) exactly as it is.
--
-- Minimum connection time (an assumption, not a published Kenya Airways
-- figure): 60 minutes at NBO, kestrel_min_connection(). The REST tier's
-- kestrel.api.journeys.MIN_CONNECTION must agree (an integration test checks).
--
-- A connecting booking is DISRUPTED when leg 1 is cancelled, leg 2 is
-- cancelled, or leg 1's (delayed) arrival + MCT is after leg 2's departure.
-- A trigger on flights sets it, so no code path that cancels or delays a
-- flight can forget (as 012 does for cancelled_at). Only CONFIRMED bookings
-- are moved: a booking already rebooked is left to a person (a second
-- disruption is a later item).
--
-- reaccommodate_journey_atomic moves BOTH legs in one transaction or neither,
-- under the same row locks as 013: the booking FOR UPDATE, seats FOR UPDATE
-- SKIP LOCKED (Kestrel picks) or FOR UPDATE NOWAIT (the passenger chose;
-- SEAT_TAKEN at once). A leg may be KEPT (the passenger's current flight on
-- that leg, e.g. leg 1 is fine and only leg 2 was cancelled); a kept leg keeps
-- its seat unless the passenger chose another.
--
-- No BEGIN/COMMIT: the SQL editor and apply_migration run the file as one
-- transaction, and it can be previewed inside a rolled-back one:
--   KESTREL_PREVIEW_MIGRATION=db/migrations/015_connecting_flights.sql pytest tests/integration
-- Idempotent. Undo: db/rollbacks/015_connecting_flights_down.sql.

ALTER TABLE pnr_bookings
    ADD COLUMN IF NOT EXISTS onward_flight_id uuid REFERENCES flights(flight_id),
    ADD COLUMN IF NOT EXISTS onward_seat_id uuid REFERENCES seats(seat_id),
    ADD COLUMN IF NOT EXISTS reaccommodated_onward_flight_id uuid REFERENCES flights(flight_id);

CREATE INDEX IF NOT EXISTS idx_pnr_bookings_onward_flight
    ON pnr_bookings (onward_flight_id) WHERE onward_flight_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_pnr_bookings_reaccommodated_onward
    ON pnr_bookings (reaccommodated_onward_flight_id) WHERE reaccommodated_onward_flight_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_pnr_bookings_onward_seat
    ON pnr_bookings (onward_seat_id) WHERE onward_seat_id IS NOT NULL;

COMMENT ON COLUMN pnr_bookings.onward_flight_id IS
    'Leg 2 of a two-leg journey through NBO (migration 015); NULL for a single-flight booking.';

-- ---------------------------------------------------------------------------
-- Constants and the connection rule
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.kestrel_connection_hub()
RETURNS varchar LANGUAGE sql IMMUTABLE SET search_path = public
AS $$ SELECT 'NBO'::varchar $$;

CREATE OR REPLACE FUNCTION public.kestrel_min_connection()
RETURNS interval LANGUAGE sql IMMUTABLE SET search_path = public
AS $$ SELECT interval '60 minutes' $$;

-- True when the journey first -> onward cannot be flown as booked.
CREATE OR REPLACE FUNCTION public.journey_connection_broken(p_first uuid, p_onward uuid)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = public
AS $$
    SELECT a.status = 'CANCELLED'
        OR b.status = 'CANCELLED'
        OR a.arrival_time + kestrel_min_connection() > b.departure_time
    FROM flights a, flights b
    WHERE a.flight_id = p_first AND b.flight_id = p_onward
$$;

CREATE OR REPLACE FUNCTION public.mark_broken_connections()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    UPDATE pnr_bookings b
    SET booking_status = 'DISRUPTED', updated_at = now()
    WHERE b.booking_status = 'CONFIRMED'
      AND b.onward_flight_id IS NOT NULL
      AND NEW.flight_id IN (COALESCE(b.reaccommodated_flight_id, b.original_flight_id),
                            COALESCE(b.reaccommodated_onward_flight_id, b.onward_flight_id))
      AND journey_connection_broken(COALESCE(b.reaccommodated_flight_id, b.original_flight_id),
                                    COALESCE(b.reaccommodated_onward_flight_id, b.onward_flight_id));
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_flights_broken_connections ON flights;
CREATE TRIGGER trg_flights_broken_connections
    AFTER UPDATE OF status, departure_time, arrival_time ON flights
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status
          OR OLD.departure_time IS DISTINCT FROM NEW.departure_time
          OR OLD.arrival_time IS DISTINCT FROM NEW.arrival_time)
    EXECUTE FUNCTION public.mark_broken_connections();

-- ---------------------------------------------------------------------------
-- One seat on one leg, as 013 picks it. Called only by the procedure below,
-- inside its transaction, so the row locks are held until it commits.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.journey_pick_seat(
    p_flight_id uuid,
    p_cabin varchar,
    p_seat_id uuid,
    OUT o_seat_id uuid,
    OUT o_seat_number varchar,
    OUT o_reason text
)
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
    v_cabin  seats.cabin_class%TYPE;
    v_status seat_status;
BEGIN
    IF p_seat_id IS NULL THEN
        SELECT seat_id, seat_number INTO o_seat_id, o_seat_number
        FROM seats
        WHERE flight_id = p_flight_id AND status = 'AVAILABLE' AND cabin_class = p_cabin
        ORDER BY
            NULLIF(regexp_replace(seat_number, '\D', '', 'g'), '')::int NULLS LAST,
            regexp_replace(seat_number, '\d', '', 'g')
        FOR UPDATE SKIP LOCKED
        LIMIT 1;
        IF o_seat_id IS NULL THEN
            o_reason := 'NO_SEATS_IN_CABIN';
        END IF;
        RETURN;
    END IF;

    BEGIN
        SELECT seat_id, seat_number, cabin_class, status
        INTO o_seat_id, o_seat_number, v_cabin, v_status
        FROM seats
        WHERE seat_id = p_seat_id AND flight_id = p_flight_id
        FOR UPDATE NOWAIT;
        IF NOT FOUND THEN
            o_reason := 'SEAT_NOT_ON_FLIGHT';
        ELSIF v_cabin IS DISTINCT FROM p_cabin THEN
            o_reason := 'SEAT_WRONG_CABIN';
        ELSIF v_status <> 'AVAILABLE' THEN
            o_reason := 'SEAT_TAKEN';
        END IF;
    EXCEPTION WHEN lock_not_available THEN
        o_reason := 'SEAT_TAKEN';
    END;
END;
$$;

-- ---------------------------------------------------------------------------
-- The journey rebooking
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.reaccommodate_journey_atomic(character varying, uuid, uuid, character varying, uuid, uuid);

CREATE FUNCTION public.reaccommodate_journey_atomic(
    p_pnr_code character varying,
    p_first_flight_id uuid,
    p_onward_flight_id uuid,
    p_actor character varying DEFAULT 'AGENT_AI'::character varying,
    p_first_seat_id uuid DEFAULT NULL,
    p_onward_seat_id uuid DEFAULT NULL
)
RETURNS TABLE(success boolean, assigned_seat_number character varying,
              onward_seat_number character varying, message text)
LANGUAGE plpgsql
SET search_path = public
AS $function$
DECLARE
    v_status          pnr_status;
    v_orig_first      uuid;
    v_orig_onward     uuid;
    v_cur_first       uuid;
    v_cur_onward      uuid;
    v_old_seat1       uuid;
    v_old_seat2       uuid;
    v_origin          varchar;
    v_hub             varchar;
    v_final           varchar;
    v_cabin           seats.cabin_class%TYPE;
    f1                flights%ROWTYPE;
    f2                flights%ROWTYPE;
    v_keep1           boolean;
    v_keep2           boolean;
    v_seat1           uuid;
    v_seat2           uuid;
    v_num1            varchar;
    v_num2            varchar;
    v_leg             int;
    v_reason          text;
    v_message         text;
BEGIN
    SELECT booking_status, original_flight_id, onward_flight_id,
           COALESCE(reaccommodated_flight_id, original_flight_id),
           COALESCE(reaccommodated_onward_flight_id, onward_flight_id),
           assigned_seat_id, onward_seat_id
    INTO v_status, v_orig_first, v_orig_onward, v_cur_first, v_cur_onward, v_old_seat1, v_old_seat2
    FROM pnr_bookings
    WHERE pnr_code = p_pnr_code
    FOR UPDATE;

    IF NOT FOUND THEN
        v_reason  := 'INVALID_PNR';
        v_message := 'Invalid PNR code provided.';
    ELSIF v_orig_onward IS NULL THEN
        v_reason  := 'NOT_A_CONNECTION';
        v_message := 'This booking has a single flight; it has no connection to rebook.';
    ELSIF v_status NOT IN ('DISRUPTED', 'REACCOMMODATED') THEN
        v_reason  := 'BOOKING_NOT_DISRUPTED';
        v_message := 'This booking is not affected by a disruption, so it cannot be moved free of charge.';
    ELSIF p_first_flight_id = v_cur_first AND p_onward_flight_id = v_cur_onward THEN
        v_reason  := 'ALREADY_ON_TARGET_FLIGHT';
        v_message := 'Passenger is already booked on the requested flights.';
    END IF;

    IF v_reason IS NULL THEN
        SELECT origin, destination INTO v_origin, v_hub FROM flights WHERE flight_id = v_orig_first;
        SELECT destination INTO v_final FROM flights WHERE flight_id = v_orig_onward;
        SELECT * INTO f1 FROM flights WHERE flight_id = p_first_flight_id;
        SELECT * INTO f2 FROM flights WHERE flight_id = p_onward_flight_id;
        v_keep1 := p_first_flight_id = v_cur_first;
        v_keep2 := p_onward_flight_id = v_cur_onward;

        IF f1.flight_id IS NULL OR f2.flight_id IS NULL THEN
            v_reason  := 'UNKNOWN_FLIGHT_ID';
            v_message := 'Target flight does not exist.';
        ELSIF v_hub IS DISTINCT FROM kestrel_connection_hub() THEN
            v_reason  := 'NOT_A_CONNECTION';
            v_message := 'This booking does not connect at Nairobi; a member of staff must rebook it.';
        ELSIF f1.origin IS DISTINCT FROM v_origin OR f1.destination IS DISTINCT FROM v_hub
              OR f2.origin IS DISTINCT FROM v_hub OR f2.destination IS DISTINCT FROM v_final THEN
            v_reason  := 'DIFFERENT_ROUTE';
            v_message := format(
                'Target flights fly %s to %s and %s to %s; this booking can only move to %s to %s connecting to %s.',
                f1.origin, f1.destination, f2.origin, f2.destination, v_origin, v_hub, v_final
            );
        ELSIF (NOT v_keep1 AND f1.status <> 'SCHEDULED') OR f1.status = 'CANCELLED'
              OR (NOT v_keep2 AND f2.status <> 'SCHEDULED') OR f2.status = 'CANCELLED' THEN
            v_reason  := 'FLIGHT_NOT_SCHEDULED';
            v_message := 'Target flight is not scheduled and cannot accept passengers.';
        ELSIF f1.departure_time <= now() OR f2.departure_time <= now() THEN
            v_reason  := 'FLIGHT_DEPARTED';
            v_message := 'Target flight has already departed.';
        ELSIF f1.arrival_time + kestrel_min_connection() > f2.departure_time THEN
            v_reason  := 'CONNECTION_TOO_SHORT';
            v_message := format(
                'Connection too short: the onward flight must leave at least %s after the first one lands.',
                kestrel_min_connection()
            );
        END IF;
    END IF;

    -- Seats, leg 1 then leg 2 (always this order, so two rebookings never
    -- wait on each other's locks in opposite orders).
    IF v_reason IS NULL THEN
        SELECT cabin_class INTO v_cabin FROM seats WHERE seat_id = v_old_seat1;
        v_cabin := COALESCE(v_cabin, 'ECONOMY');

        v_leg := 1;
        IF v_keep1 AND (p_first_seat_id IS NULL OR p_first_seat_id = v_old_seat1) THEN
            v_seat1 := v_old_seat1;
            SELECT seat_number INTO v_num1 FROM seats WHERE seat_id = v_old_seat1;
        ELSE
            SELECT o_seat_id, o_seat_number, o_reason INTO v_seat1, v_num1, v_reason
            FROM journey_pick_seat(p_first_flight_id, v_cabin, p_first_seat_id);
        END IF;

        IF v_reason IS NULL THEN
            v_leg := 2;
            IF v_keep2 AND (p_onward_seat_id IS NULL OR p_onward_seat_id = v_old_seat2) THEN
                v_seat2 := v_old_seat2;
                SELECT seat_number INTO v_num2 FROM seats WHERE seat_id = v_old_seat2;
            ELSE
                SELECT o_seat_id, o_seat_number, o_reason INTO v_seat2, v_num2, v_reason
                FROM journey_pick_seat(p_onward_flight_id, v_cabin, p_onward_seat_id);
            END IF;
        END IF;

        v_message := CASE v_reason
            WHEN 'NO_SEATS_IN_CABIN' THEN format('No %s seats remaining on the %s flight.',
                                                 lower(v_cabin::text),
                                                 CASE v_leg WHEN 1 THEN 'first' ELSE 'onward' END)
            WHEN 'SEAT_TAKEN' THEN CASE v_leg WHEN 1 THEN 'That seat was just taken. Please pick another.'
                                   ELSE 'That seat was just taken on your onward flight. Please pick another.' END
            WHEN 'SEAT_NOT_ON_FLIGHT' THEN 'That seat is not on the chosen flight.'
            WHEN 'SEAT_WRONG_CABIN' THEN format('Seat is not in %s; you can choose a seat in %s only.',
                                                lower(v_cabin::text), lower(v_cabin::text))
        END;
    END IF;

    IF v_reason IS NOT NULL THEN
        -- All or nothing: nothing has been written; the refusal is audited.
        INSERT INTO audit_logs (pnr_code, actor, action, details)
        VALUES (p_pnr_code, p_actor, 'REACCOMMODATION_REJECTED', jsonb_build_object(
            'reason', v_reason,
            'journey', true,
            'leg', CASE WHEN v_reason IN ('NO_SEATS_IN_CABIN', 'SEAT_TAKEN', 'SEAT_NOT_ON_FLIGHT',
                                          'SEAT_WRONG_CABIN') THEN v_leg END,
            'target_flight_id', p_first_flight_id,
            'target_onward_flight_id', p_onward_flight_id,
            'cabin_class', v_cabin,
            'requested_seat_id', p_first_seat_id,
            'requested_onward_seat_id', p_onward_seat_id
        ));
        RETURN QUERY SELECT false, NULL::varchar, NULL::varchar, v_message;
        RETURN;
    END IF;

    UPDATE seats SET status = 'AVAILABLE', row_version = row_version + 1
    WHERE seat_id IN (v_old_seat1, v_old_seat2) AND seat_id IS DISTINCT FROM v_seat1
                                                AND seat_id IS DISTINCT FROM v_seat2;

    UPDATE seats SET status = 'BOOKED', row_version = row_version + 1
    WHERE seat_id IN (v_seat1, v_seat2) AND seat_id IS DISTINCT FROM v_old_seat1
                                        AND seat_id IS DISTINCT FROM v_old_seat2;

    UPDATE pnr_bookings
    SET reaccommodated_flight_id        = p_first_flight_id,
        reaccommodated_onward_flight_id = p_onward_flight_id,
        assigned_seat_id                = v_seat1,
        onward_seat_id                  = v_seat2,
        booking_status                  = 'REACCOMMODATED',
        updated_at                      = now()
    WHERE pnr_code = p_pnr_code;

    INSERT INTO audit_logs (pnr_code, actor, action, details)
    VALUES
        (p_pnr_code, p_actor, 'AUTOMATED_REACCOMMODATION', jsonb_build_object(
            'journey', true, 'leg', 1, 'kept', v_keep1,
            'from_flight_id', v_cur_first, 'target_flight_id', p_first_flight_id,
            'released_seat_id', CASE WHEN v_old_seat1 IS DISTINCT FROM v_seat1 THEN v_old_seat1 END,
            'assigned_seat', v_num1, 'assigned_seat_id', v_seat1,
            'cabin_class', v_cabin, 'seat_chosen', p_first_seat_id IS NOT NULL)),
        (p_pnr_code, p_actor, 'AUTOMATED_REACCOMMODATION', jsonb_build_object(
            'journey', true, 'leg', 2, 'kept', v_keep2,
            'from_flight_id', v_cur_onward, 'target_flight_id', p_onward_flight_id,
            'released_seat_id', CASE WHEN v_old_seat2 IS DISTINCT FROM v_seat2 THEN v_old_seat2 END,
            'assigned_seat', v_num2, 'assigned_seat_id', v_seat2,
            'cabin_class', v_cabin, 'seat_chosen', p_onward_seat_id IS NOT NULL));

    RETURN QUERY SELECT true, v_num1, v_num2, 'Journey re-accommodated successfully.'::text;
END;
$function$;

-- EXECUTE as on reaccommodate_passenger_atomic (013).
GRANT EXECUTE ON FUNCTION public.reaccommodate_journey_atomic(character varying, uuid, uuid, character varying, uuid, uuid)
    TO PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.journey_pick_seat(uuid, varchar, uuid)
    TO PUBLIC, anon, authenticated, service_role;
