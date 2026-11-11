-- Project Kestrel - rollback of migration 014. Not a migration: run it only to undo 014.
-- Deploy the previous API first: the REST tier from 014 on reads and writes the column.
ALTER TABLE public.chat_messages DROP COLUMN IF EXISTS prompt_version;
