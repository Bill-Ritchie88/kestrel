"""
Policy retrieval and the semantic scope guard (FR-02, FR-05, NFR-04).

A passenger question is embedded and compared with every policy clause by
cosine similarity. If the best match falls below the threshold tau, the
question is out of scope: the agent must not answer it from its own
knowledge, and the REST tier opens a hand-off case instead.

tau starts at 0.75 (Section 4.2.1) and is calibrated by
scripts/evaluation/evaluate_retrieval.py, which picks the value maximising F0.5 on the
labelled question set. Set POLICY_TAU in .env to the calibrated value.
"""

from __future__ import annotations

import os
from collections import OrderedDict
from dataclasses import asdict, dataclass

from kestrel.policy.embeddings import TASK_QUERY, Embedder, to_pgvector

DEFAULT_TAU = float(os.getenv("POLICY_TAU", "0.75"))
DEFAULT_K = 3
CACHE_SIZE = 256

# Embedded when the REST tier starts, so the questions passengers ask most
# (the assistant's quick replies and suggestions, and the rights questions in
# the Help centre, kestrel_client/lib/widgets/public.dart) never wait on the
# embedding API.
COMMON_QUESTIONS = (
    "Can I get a refund instead?",
    "What am I entitled to?",
    "Can I take a later flight?",
    "Can I get a refund instead of a new flight?",
    "Will I pay to change to another flight?",
    "How do I use my meal or hotel voucher?",
    "What if I want a different destination?",
    "What am I entitled to while I wait?",
    "Am I entitled to compensation?",
    "Do I get a hotel room?",
)


def normalise_question(question: str) -> str:
    """The cache key: case, spacing and closing punctuation do not change
    what is asked."""
    return " ".join(question.lower().split()).rstrip("?.! ")

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
    def __init__(
        self,
        embedder: Embedder,
        tau: float = DEFAULT_TAU,
        k: int = DEFAULT_K,
        cache_size: int = CACHE_SIZE,
    ):
        self.embedder = embedder
        self.tau = tau
        self.k = k
        # Least recently used first. A question asked again (the same quick
        # reply, a retry, the agent repeating the passenger's words) costs no
        # embedding call.
        self._vectors: OrderedDict[str, list[float]] = OrderedDict()
        self.cache_size = cache_size
        self.cache_hits = 0

    def _remember(self, key: str, vector: list[float]) -> None:
        self._vectors[key] = vector
        self._vectors.move_to_end(key)
        while len(self._vectors) > self.cache_size:
            self._vectors.popitem(last=False)

    async def vector(self, question: str) -> list[float]:
        key = normalise_question(question)
        cached = self._vectors.get(key)
        if cached is not None:
            self._vectors.move_to_end(key)
            self.cache_hits += 1
            return cached
        [vector] = await self.embedder.embed([question], TASK_QUERY)
        self._remember(key, vector)
        return vector

    async def warm(self, questions: tuple[str, ...] = COMMON_QUESTIONS) -> int:
        """Embed questions ahead of time, in one request. Returns how many
        were new."""
        missing = list(
            dict.fromkeys(q for q in questions if normalise_question(q) not in self._vectors)
        )
        if missing:
            vectors = await self.embedder.embed(missing, TASK_QUERY)
            for question, vector in zip(missing, vectors, strict=True):
                self._remember(normalise_question(question), vector)
        return len(missing)

    async def search(self, conn, question: str, k: int | None = None) -> RetrievalResult:
        vector = await self.vector(question)
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
