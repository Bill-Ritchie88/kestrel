"""
Unit tests for policy chunking, embedding and the scope guard (FR-02, FR-05).

No network: the Gemini endpoint is replaced with an httpx MockTransport.
"""

import json

import httpx
import pytest

from kestrel.policy.corpus import MAX_CHARS, SOURCES, chunk_text
from kestrel.policy.embeddings import (
    TASK_QUERY,
    EmbeddingError,
    GeminiEmbedder,
    normalise,
    to_pgvector,
)
from kestrel.policy.retriever import PolicyRetriever, RetrievalResult

KQ = SOURCES["kq-conditions-of-carriage"]
EU = SOURCES["eu261"]

KQ_SAMPLE = """Kenya Airways PLC | Conditions of Carriage
Book  Manage  Help
ARTICLE 1: WHAT PARTICULAR EXPRESSIONS MEAN IN THESE CONDITIONS
"We" means Kenya Airways PLC. "You" means any person carried pursuant to a Ticket.

ARTICLE 9: SCHEDULES, DELAYS, CANCELLATION OF FLIGHTS
9.1 Schedules. The flight times shown in timetables may change.
9.2 Cancellation. If we cancel a flight we shall carry you on another of our services.
"""

EU_SAMPLE = """Whereas:
(14) Obligations on operating air carriers should be limited or excluded in cases where an event has been caused by extraordinary circumstances which could not have been avoided even if all reasonable measures had been taken.
Article 9
Right to care
1. Where reference is made to this Article, passengers shall be offered free of charge:
(a) meals and refreshments in a reasonable relation to the waiting time;
"""


def test_kq_articles_become_citable_chunks():
    chunks = chunk_text(KQ_SAMPLE, KQ)
    ids = [c.chunk_id for c in chunks]
    assert ids == ["KQ_COC-ART-1", "KQ_COC-ART-9"]
    art9 = chunks[1]
    assert art9.clause_ref == "KQ CoC Art. 9"
    assert art9.title.startswith("SCHEDULES, DELAYS")
    assert "carry you on another of our services" in art9.content


def test_page_navigation_before_article_1_is_dropped_for_kq():
    assert all("Book  Manage" not in c.content for c in chunk_text(KQ_SAMPLE, KQ))


def test_eurlex_title_on_next_line_and_recitals_kept():
    chunks = chunk_text(EU_SAMPLE, EU)
    preamble, art9 = chunks
    assert preamble.clause_ref == "EU261 preamble"
    assert "extraordinary circumstances" in preamble.content
    assert art9.title == "Right to care"
    assert art9.clause_ref == "EU261 Art. 9"


def test_long_articles_are_split_and_every_part_is_bounded():
    body = "\n".join(f"{i}. " + "The carrier shall provide assistance. " * 20 for i in range(1, 12))
    chunks = chunk_text(f"ARTICLE 4: LONG\n{body}", KQ)
    assert len(chunks) > 1
    assert all(len(c.content) <= MAX_CHARS + 120 for c in chunks)  # + heading
    assert chunks[0].clause_ref.endswith("(part 1 of %d)" % len(chunks))
    assert len({c.chunk_id for c in chunks}) == len(chunks)


def test_chunk_hash_changes_only_with_content():
    a = chunk_text(KQ_SAMPLE, KQ)[1]
    b = chunk_text(KQ_SAMPLE, KQ)[1]
    assert a.sha256 == b.sha256


def test_normalise_and_pgvector_format():
    v = normalise([3.0, 4.0])
    assert v == pytest.approx([0.6, 0.8])
    assert to_pgvector(v) == "[0.6,0.8]"
    with pytest.raises(ValueError):
        normalise([0.0, 0.0])


def _gemini(handler):
    return GeminiEmbedder("test-key", dimensions=3, client=httpx.AsyncClient(
        transport=httpx.MockTransport(handler)), max_retries=1)  # fmt: skip


async def test_embedder_sends_task_type_and_normalises():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["body"] = json.loads(request.content)
        seen["key"] = request.headers["x-goog-api-key"]
        return httpx.Response(200, json={"embeddings": [{"values": [3, 4, 0]}]})

    [vector] = await _gemini(handler).embed(["meals"], TASK_QUERY)
    assert vector == pytest.approx([0.6, 0.8, 0.0])
    req = seen["body"]["requests"][0]
    assert req["taskType"] == "RETRIEVAL_QUERY"
    assert req["outputDimensionality"] == 3
    assert seen["key"] == "test-key"  # header, never the URL


async def test_embedder_retries_quota_errors_then_fails_clearly():
    calls = []

    def handler(request):
        calls.append(1)
        return httpx.Response(429, text="quota")

    with pytest.raises(EmbeddingError, match="429"):
        await _gemini(handler).embed(["x"], TASK_QUERY)
    assert len(calls) == 2  # first try + one retry


class _FakeEmbedder:
    model = "fake"

    async def embed(self, texts, task):
        return [[1.0, 0.0, 0.0] for _ in texts]


class _FakeConn:
    def __init__(self, sims):
        self.sims = sims

    async def fetch(self, sql, vector, k):
        assert "match_policy_chunks" in sql
        assert vector.startswith("[")
        return [
            {"chunk_id": f"C{i}", "source": "EU261", "clause_ref": f"EU261 Art. {i}",
             "title": "t", "content": "c", "source_url": None, "similarity": s}  # fmt: skip
            for i, s in enumerate(self.sims[:k])
        ]


@pytest.mark.parametrize(("top", "in_scope"), [(0.82, True), (0.75, True), (0.7499, False)])
async def test_scope_guard_threshold_is_inclusive(top, in_scope):
    retriever = PolicyRetriever(_FakeEmbedder(), tau=0.75)
    result = await retriever.search(_FakeConn([top, 0.5, 0.4]), "Am I owed a meal?")
    assert result.in_scope is in_scope
    assert result.top_similarity == top


def test_empty_result_is_out_of_scope():
    assert RetrievalResult("q", [], 0.75).in_scope is False
