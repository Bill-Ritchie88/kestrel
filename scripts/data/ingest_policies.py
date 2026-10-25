"""
Load the policy corpus into Supabase (FR-02).

Reads the verbatim source texts in data/policy/sources/, splits them into
article-sized chunks (kestrel.policy.corpus), embeds the chunks with Gemini and
upserts them into policy_chunks (migration 005). Chunks whose text has not
changed since the last run are not re-embedded, so re-running is cheap.

    python scripts/data/ingest_policies.py --dry-run     # chunk only: no network, no database
    python scripts/data/ingest_policies.py               # embed and load
    python scripts/data/ingest_policies.py --prune       # also delete chunks no longer in the sources
    python scripts/data/ingest_policies.py --manifest    # record the SHA-256 of each source file
"""

import argparse
import asyncio
import hashlib
import os
import sys
from collections import Counter
from datetime import date
from pathlib import Path

from kestrel import config  # noqa: F401  - loads .env
from kestrel.policy.corpus import load_corpus
from kestrel.policy.embeddings import (
    BATCH_SIZE,
    TASK_DOCUMENT,
    GeminiEmbedder,
    QuotaExhaustedError,
    to_pgvector,
)

SOURCES_DIR = Path(__file__).resolve().parents[2] / "data" / "policy" / "sources"


async def ingest(prune: bool) -> int:
    import asyncpg

    chunks, missing = load_corpus(SOURCES_DIR)
    for name in missing:
        print(f"[WARN] {name} not found in {SOURCES_DIR} - skipped")
    if not chunks:
        print("[ERROR] No source texts to ingest.")
        return 1

    api_key = os.getenv("GOOGLE_API_KEY") or os.getenv("GEMINI_API_KEY")
    embedder = GeminiEmbedder(
        api_key,
        on_wait=lambda s, why: print(f"[WAIT] Gemini rate limit ({why}); retrying in {s:.0f}s"),
    )
    conn = await asyncpg.connect(os.environ["DATABASE_URL"], statement_cache_size=0)
    try:
        existing = {
            r["chunk_id"]: r["content_sha256"]
            for r in await conn.fetch("SELECT chunk_id, content_sha256 FROM policy_chunks")
        }
        changed = [c for c in chunks if existing.get(c.chunk_id) != c.sha256]
        print(f"[INFO] {len(chunks)} chunks, {len(changed)} new or changed")

        # Embed and store one batch at a time, so a quota stop part-way keeps
        # everything already stored; the next run skips it by content hash.
        done = 0
        try:
            for start in range(0, len(changed), BATCH_SIZE):
                batch = changed[start : start + BATCH_SIZE]
                vectors = await embedder.embed([c.content for c in batch], TASK_DOCUMENT)
                async with conn.transaction():
                    for chunk, vector in zip(batch, vectors, strict=True):
                        await conn.execute(
                            "SELECT upsert_policy_chunk($1,$2,$3,$4,$5,$6,$7,$8,$9)",
                            chunk.chunk_id,
                            chunk.source,
                            chunk.clause_ref,
                            chunk.title,
                            chunk.content,
                            chunk.source_url,
                            chunk.sha256,
                            to_pgvector(vector),
                            embedder.model,
                        )
                done += len(batch)
                print(f"[INFO] stored {done}/{len(changed)}")
        except QuotaExhaustedError as exc:
            print(f"[STOP] {exc}")
            print(f"[STOP] {done}/{len(changed)} stored this run; re-run to continue.")
            return 1

        stale = set(existing) - {c.chunk_id for c in chunks}
        if stale and prune:
            await conn.execute("DELETE FROM policy_chunks WHERE chunk_id = ANY($1)", list(stale))
            print(f"[INFO] Pruned {len(stale)} chunks no longer in the sources")
        elif stale:
            print(f"[WARN] {len(stale)} stored chunks are no longer in the sources (use --prune)")

        total = await conn.fetchval("SELECT count(*) FROM policy_chunks")
        print(f"[OK]   policy_chunks now holds {total} chunks ({embedder.model})")
    finally:
        await conn.close()
        await embedder.aclose()
    return 0


def write_manifest() -> int:
    """Record which exact source texts the corpus was built from."""
    lines = [f"# Policy source texts, recorded {date.today().isoformat()}"]
    for path in sorted(SOURCES_DIR.glob("*.txt")):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        lines.append(f"{digest}  {path.name}")
    (SOURCES_DIR / "MANIFEST.sha256").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))
    return 0


def dry_run() -> int:
    chunks, missing = load_corpus(SOURCES_DIR)
    for name in missing:
        print(f"[WARN] {name} not found - skipped")
    by_source = Counter(c.source for c in chunks)
    for source, n in by_source.items():
        lengths = [len(c.content) for c in chunks if c.source == source]
        print(f"{source:15} {n:4} chunks   {min(lengths):5}-{max(lengths):5} chars")
    for c in chunks[:5]:
        print(f"  {c.chunk_id:22} {c.clause_ref:35} {c.title[:40]!r}")
    print(f"[OK]   {len(chunks)} chunks; nothing was embedded or written (--dry-run)")
    return 0 if chunks else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Ingest the policy corpus.")
    parser.add_argument("--dry-run", action="store_true", help="Chunk only; no network")
    parser.add_argument("--prune", action="store_true", help="Delete chunks no longer in sources")
    parser.add_argument("--manifest", action="store_true", help="Write MANIFEST.sha256 and exit")
    args = parser.parse_args()
    if args.manifest:
        sys.exit(write_manifest())
    if args.dry_run:
        sys.exit(dry_run())
    code = asyncio.run(ingest(args.prune))
    if code == 0:
        write_manifest()
    sys.exit(code)
