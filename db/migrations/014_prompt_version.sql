-- Project Kestrel - migration 014
-- The system-prompt version on each assistant turn (Sprint III gap: provenance
-- for each answer, plan sections 5 and 6.3).
--
-- chat_messages (010) is the turn log the agent service writes through POST
-- /api/chat/history. Each assistant turn now records the version of the system
-- prompt that produced it, e.g. '2.0.0+3fa9c2d1' (a semantic version and the
-- first 8 hex digits of the prompt's SHA-256, kestrel.agent.PROMPT_VERSION).
-- Nullable: user turns, and assistant turns saved before this migration, have
-- none. The staff queue shows the latest one for each case's booking.
--
-- Row-level security is per table and stays on with no policy (010): only the
-- server's own connection reads or writes the table, so no grant changes.
-- Idempotent, and no BEGIN/COMMIT, so it can be previewed inside a
-- rolled-back transaction. Undo: db/rollbacks/014_prompt_version_down.sql.

ALTER TABLE public.chat_messages
    ADD COLUMN IF NOT EXISTS prompt_version text
    CONSTRAINT chat_messages_prompt_version_length CHECK (char_length(prompt_version) <= 64);

COMMENT ON COLUMN public.chat_messages.prompt_version IS
    'System-prompt version that produced an assistant turn (semver+sha256 prefix); NULL for user turns and turns before 014.';
