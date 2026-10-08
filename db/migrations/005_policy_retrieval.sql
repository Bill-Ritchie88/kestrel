-- Project Kestrel - migration 005
-- Policy retrieval store (FR-02, DR-07).
--
-- Policy clauses from the Kenya Airways Conditions of Carriage, Regulation
-- (EC) No 261/2004 and the Montreal Convention are split into article-sized
-- chunks by scripts/ingest_policies.py, embedded with Gemini
-- (gemini-embedding-001, 768 dimensions, L2-normalised) and stored here.
--
-- Retrieval is cosine similarity through pgvector's <=> operator (cosine
-- distance), so similarity = 1 - distance. The corpus is a few hundred rows,
-- so an exact scan is used deliberately: an approximate index (HNSW/IVFFlat)
-- would trade recall for speed the system does not need, and Recall@3 is one
-- of the evaluation metrics (Section 5.5).
--
-- Supabase installs extensions into the "extensions" schema, which is on the
-- default search_path. The functions below pin their search_path so they work
-- whichever schema pgvector lives in.

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA extensions;

CREATE TABLE IF NOT EXISTS policy_chunks (
    chunk_id         text        PRIMARY KEY,          -- e.g. 'EU261-ART-9'
    source           text        NOT NULL,             -- 'KQ_COC', 'EU261', 'MONTREAL_1999'
    clause_ref       text        NOT NULL,             -- human citation, e.g. 'EU261 Art. 9'
    title            text,
    content          text        NOT NULL,
    source_url       text,
    content_sha256   text        NOT NULL,             -- re-embed only when the text changes
    embedding        vector(768) NOT NULL,
    embedding_model  text        NOT NULL,
    updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_policy_chunks_source ON policy_chunks (source);

-- Same defence-in-depth rule as migration 002: no permissive policy, so the
-- table is unreachable through the Supabase public API.
ALTER TABLE policy_chunks ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- Upsert one chunk. The embedding is passed as pgvector's text form
-- '[0.1,0.2,...]' so the Python side needs no pgvector codec.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.upsert_policy_chunk(
    p_chunk_id        text,
    p_source          text,
    p_clause_ref      text,
    p_title           text,
    p_content         text,
    p_source_url      text,
    p_content_sha256  text,
    p_embedding       text,
    p_embedding_model text
)
RETURNS void
LANGUAGE sql
SET search_path = public, extensions
AS $function$
    INSERT INTO policy_chunks (
        chunk_id, source, clause_ref, title, content, source_url,
        content_sha256, embedding, embedding_model, updated_at
    )
    VALUES (
        p_chunk_id, p_source, p_clause_ref, p_title, p_content, p_source_url,
        p_content_sha256, p_embedding::vector, p_embedding_model, now()
    )
    ON CONFLICT (chunk_id) DO UPDATE SET
        source          = EXCLUDED.source,
        clause_ref      = EXCLUDED.clause_ref,
        title           = EXCLUDED.title,
        content         = EXCLUDED.content,
        source_url      = EXCLUDED.source_url,
        content_sha256  = EXCLUDED.content_sha256,
        embedding       = EXCLUDED.embedding,
        embedding_model = EXCLUDED.embedding_model,
        updated_at      = now();
$function$;

-- ---------------------------------------------------------------------------
-- Top-k clauses by cosine similarity. The threshold decision (in scope or
-- hand off) is made in the REST tier, not here, so the evaluation script can
-- read raw similarities and calibrate tau without a database change.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_policy_chunks(
    p_query_embedding text,
    p_match_count     integer DEFAULT 3
)
RETURNS TABLE (
    chunk_id    text,
    source      text,
    clause_ref  text,
    title       text,
    content     text,
    source_url  text,
    similarity  double precision
)
LANGUAGE sql
STABLE
SET search_path = public, extensions
AS $function$
    SELECT
        c.chunk_id,
        c.source,
        c.clause_ref,
        c.title,
        c.content,
        c.source_url,
        1 - (c.embedding <=> p_query_embedding::vector) AS similarity
    FROM policy_chunks c
    ORDER BY c.embedding <=> p_query_embedding::vector
    LIMIT greatest(1, least(p_match_count, 10));
$function$;
