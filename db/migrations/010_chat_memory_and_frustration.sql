-- Project Kestrel - migration 010
-- Conversation memory per booking, and a hand-off trigger for frustrated
-- passengers (performance and intelligence plan, Phase 4).
--
-- chat_messages: the REST tier stores each passenger and assistant turn so a
-- passenger who returns later continues the same conversation. Only the
-- server's own connection reads or writes it (RLS on, no policy, as in
-- 002/008/009). Turns are capped by the server, not here.
--
-- handoff_cases.trigger gains 'FRUSTRATION': the agent service opens a case
-- when a passenger repeats a question or shows clear frustration, and staff
-- see that reason on the case.

CREATE TABLE IF NOT EXISTS chat_messages (
    message_id  bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pnr_code    varchar(6)   NOT NULL REFERENCES pnr_bookings (pnr_code) ON DELETE CASCADE,
    role        varchar(10)  NOT NULL CHECK (role IN ('user', 'assistant')),
    content     text         NOT NULL CHECK (char_length(content) <= 4000),
    created_at  timestamptz  NOT NULL DEFAULT now()
);

-- History is always read newest-first for one booking.
CREATE INDEX IF NOT EXISTS idx_chat_messages_pnr_created
    ON chat_messages (pnr_code, created_at DESC);

ALTER TABLE chat_messages ENABLE ROW LEVEL SECURITY;

ALTER TABLE handoff_cases DROP CONSTRAINT IF EXISTS handoff_cases_trigger_check;
ALTER TABLE handoff_cases ADD CONSTRAINT handoff_cases_trigger_check
    CHECK (trigger = ANY (ARRAY['LOW_SIMILARITY'::text, 'NO_ALTERNATIVES'::text,
                                'STEP_LIMIT'::text, 'REBOOKING_FAILED'::text,
                                'PASSENGER_REQUEST'::text, 'FRUSTRATION'::text]));
