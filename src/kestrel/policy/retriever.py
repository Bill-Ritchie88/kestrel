"""
Policy retrieval and the semantic scope guard (FR-02, FR-05, NFR-04).

A passenger question is embedded and compared with every policy clause by
cosine similarity. If the best match falls below the threshold tau, the
question is out of scope: the agent must not answer it from its own
knowledge, and the REST tier opens a hand-off case instead.

tau starts at 0.75 (Section 4.2.1) and is calibrated by
scripts/evaluate_retrieval.py, which picks the value maximising F0.5 on the
labelled question set. Set POLICY_TAU in .env to the calibrated value.
"""

from __future__ import annotations

import os
from dataclasses import asdict, dataclass

from kestrel.policy.embeddings import TASK_QUERY, Embedder, to_pgvector

DEFAULT_TAU = float(os.getenv("POLICY_TAU", "0.75"))
DEFAULT_K = 3

SQL_MATCH = "SELECT * FROM match_policy_chunks($1, $2);"


@dataclass
class PolicyHit:
    chunk_id: str
    source: str
    clause_ref: str
    title: str | None
    content: str
    source_url: str | None
    similarity: float


@dataclass
class RetrievalResult:
    question: str
    hits: list[PolicyHit]
    tau: float

    @property
    def top_similarity(self) -> float:
        return self.hits[0].similarity if self.hits else 0.0

    @property
    def in_scope(self) -> bool:
        return self.top_similarity >= self.tau

    def to_dict(self) -> dict:
        return {
            "question": self.question,
            "in_scope": self.in_scope,
            "tau": self.tau,
            "top_similarity": round(self.top_similarity, 4),
            "hits": [{**asdict(h), "similarity": round(h.similarity, 4)} for h in self.hits],
        }


class PolicyRetriever:
    def __init__(self, embedder: Embedder, tau: float = DEFAULT_TAU, k: int = DEFAULT_K):
        self.embedder = embedder
        self.tau = tau
        self.k = k

    async def search(self, conn, question: str, k: int | None = None) -> RetrievalResult:
        [vector] = await self.embedder.embed([question], TASK_QUERY)
        rows = await conn.fetch(SQL_MATCH, to_pgvector(vector), k or self.k)
        hits = [
            PolicyHit(
                chunk_id=r["chunk_id"],
                source=r["source"],
                clause_ref=r["clause_ref"],
                title=r["title"],
                content=r["content"],
                source_url=r["source_url"],
                similarity=float(r["similarity"]),
            )
            for r in rows
        ]
        return RetrievalResult(question=question, hits=hits, tau=self.tau)
