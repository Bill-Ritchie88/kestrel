-- Project Kestrel - migration 012 (18 Oct review)
--
-- Issue #13: the EU261 notice rule needs WHEN the passenger was told. Until
-- now nothing stored it, so the rule used "now" and the answer changed with
-- the day you asked. flights.cancelled_at records it; a trigger sets it the
-- moment any code path sets status = 'CANCELLED', so no caller can forget.
-- Flights already cancelled get the time of this migration (the earliest
-- moment the system can vouch for).
--
-- Issue #12: chat_messages keeps at most the newest 100 turns per booking.
-- Migration 010 said "capped by the server" but only reads were capped; this
-- trigger caps storage for every writer.

ALTER TABLE flights ADD COLUMN IF NOT EXISTS cancelled_at timestamptz;

UPDATE flights SET cancelled_at = now()
WHERE status = 'CANCELLED' AND cancelled_at IS NULL;

CREATE OR REPLACE FUNCTION public.set_flight_cancelled_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF NEW.status = 'CANCELLED' AND NEW.cancelled_at IS NULL THEN
        NEW.cancelled_at := now();
    ELSIF NEW.status <> 'CANCELLED' THEN
        NEW.cancelled_at := NULL;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_flights_cancelled_at ON flights;
CREATE TRIGGER trg_flights_cancelled_at
    BEFORE INSERT OR UPDATE OF status, cancelled_at ON flights
    FOR EACH ROW EXECUTE FUNCTION public.set_flight_cancelled_at();

CREATE OR REPLACE FUNCTION public.cap_chat_messages()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    DELETE FROM chat_messages
    WHERE pnr_code = NEW.pnr_code
      AND message_id NOT IN (
          SELECT message_id FROM chat_messages
          WHERE pnr_code = NEW.pnr_code
          ORDER BY created_at DESC, message_id DESC
          LIMIT 100
      );
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_chat_messages_cap ON chat_messages;
CREATE TRIGGER trg_chat_messages_cap
    AFTER INSERT ON chat_messages
    FOR EACH ROW EXECUTE FUNCTION public.cap_chat_messages();
