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
    QuotaExhaustedError,
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

EU_SAMPLE = """Chat AI
Hello! Is there any question I can help you with?
What is the national bird of the United States?
32004R0261
Regulation (EC) No 261/2004 of the European Parliament and of the Council
Whereas:
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


def test_text_injected_above_the_document_is_discarded():
    """A browser extension added a chat widget's text above the regulation
    when the page was copied; it must not become part of the corpus."""
    content = " ".join(c.content for c in chunk_text(EU_SAMPLE, EU))
    assert "national bird" not in content
    assert "Chat AI" not in content
    assert "32004R0261" in content


def test_long_articles_are_split_and_every_part_is_bounded():
    body = "\n".join(f"{i}. " + "The carrier shall provide assistance. " * 20 for i in range(1, 12))
    chunks = chunk_text(f"ARTICLE 4: LONG\n{body}", KQ)
    assert len(chunks) > 1
    assert all(len(c.content) <= MAX_CHARS + 120 for c in chunks)  # + heading
    assert chunks[0].clause_ref.endswith(f"(part 1 of {len(chunks)})")
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


def _gemini(handler, waits=None):
    async def no_sleep(seconds):
        if waits is not None:
            waits.append(seconds)

    return GeminiEmbedder(
        "test-key",
        dimensions=3,
        client=httpx.AsyncClient(transport=httpx.MockTransport(handler)),
        max_retries=2,
        sleep=no_sleep,
    )


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


def _quota_error(quota_id, delay="34s"):
    return httpx.Response(429, json={"error": {"code": 429, "message": "quota", "details": [
        {"@type": "type.googleapis.com/google.rpc.QuotaFailure",
         "violations": [{"quotaId": quota_id}]},
        {"@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": delay},
    ]}})  # fmt: skip


async def test_per_minute_quota_waits_as_long_as_the_api_asks_then_succeeds():
    responses = iter([
        _quota_error("EmbedContentRequestsPerMinutePerProjectPerModel-FreeTier", "34s"),
        httpx.Response(200, json={"embeddings": [{"values": [1, 0, 0]}]}),
    ])  # fmt: skip
    waits = []
    [vector] = await _gemini(lambda r: next(responses), waits).embed(["x"], TASK_QUERY)
    assert waits == [35.0]  # retryDelay + 1 s margin
    assert vector == pytest.approx([1.0, 0.0, 0.0])


async def test_daily_quota_stops_immediately():
    calls = []

    def handler(request):
        calls.append(1)
        return _quota_error("EmbedContentRequestsPerDayPerProjectPerModel-FreeTier")

    with pytest.raises(QuotaExhaustedError, match="Daily"):
        await _gemini(handler).embed(["x"], TASK_QUERY)
    assert len(calls) == 1


async def test_embedder_gives_up_after_retries():
    calls = []

    def handler(request):
        calls.append(1)
        return httpx.Response(429, text="quota")

    with pytest.raises(EmbeddingError, match="still exceeded"):
        await _gemini(handler).embed(["x"], TASK_QUERY)
    assert len(calls) == 3  # first try + two retries


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
            {
                "chunk_id": f"C{i}",
                "source": "EU261",
                "clause_ref": f"EU261 Art. {i}",
                "title": "t",
                "content": "c",
                "source_url": None,
                "similarity": s,
            }  # fmt: skip
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


def test_evaluation_reference_matching_respects_article_numbers():
    import importlib.util
    from pathlib import Path

    path = Path(__file__).resolve().parents[2] / "scripts" / "evaluation" / "evaluate_retrieval.py"
    spec = importlib.util.spec_from_file_location("evaluate_retrieval", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    assert mod.ref_matches("EU261 Art. 9", "EU261 Art. 9")
    assert mod.ref_matches("KQ CoC Art. 8 (part 5 of 5)", "KQ CoC Art. 8")
    assert not mod.ref_matches("KQ CoC Art. 10 (part 1 of 2)", "KQ CoC Art. 1")
    assert not mod.ref_matches("EU261 Art. 10", "EU261 Art. 1")


def test_labelled_question_set_is_well_formed():
    import csv
    from pathlib import Path

    path = Path(__file__).resolve().parents[2] / "data" / "eval" / "policy_questions.csv"
    rows = list(csv.DictReader(path.open(encoding="utf-8")))
    assert len({r["question_id"] for r in rows}) == len(rows)
    assert {r["split"] for r in rows} == {"calibration", "test"}
    for r in rows:
        assert r["in_scope"] in {"0", "1"}
        # in-scope questions name the clause that answers them; out-of-scope ones none
        assert bool(r["expected_refs"].strip()) == (r["in_scope"] == "1"), r["question_id"]
    for split in ("calibration", "test"):
        part = [r for r in rows if r["split"] == split]
        assert any(r["in_scope"] == "1" for r in part) and any(r["in_scope"] == "0" for r in part)


# -- performance plan, Phase 3: faster policy search --------------------------


class _CountingEmbedder:
    model = "fake"

    def __init__(self):
        self.calls: list[list[str]] = []

    async def embed(self, texts, task):
        self.calls.append(list(texts))
        return [[1.0, 0.0, 0.0] for _ in texts]


async def test_the_same_question_is_embedded_once():
    embedder = _CountingEmbedder()
    retriever = PolicyRetriever(embedder, tau=0.75)
    await retriever.search(_FakeConn([0.8]), "Can I get a refund?")
    await retriever.search(_FakeConn([0.8]), "  can i get a REFUND ")
    assert embedder.calls == [["Can I get a refund?"]]
    assert retriever.cache_hits == 1


async def test_a_cache_hit_makes_no_second_http_call():
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(200, json={"embeddings": [{"values": [3, 4, 0]}]})

    retriever = PolicyRetriever(_gemini(handler), tau=0.75)
    await retriever.search(_FakeConn([0.8]), "Do I get a meal?")
    await retriever.search(_FakeConn([0.8]), "Do I get a meal?")
    assert len(calls) == 1


async def test_cache_keeps_the_most_recently_used_questions():
    retriever = PolicyRetriever(_CountingEmbedder(), cache_size=2)
    for q in ("a?", "b?", "a?", "c?"):
        await retriever.vector(q)
    assert list(retriever._vectors) == ["a", "c"]


async def test_common_questions_are_embedded_in_one_request_at_startup():
    embedder = _CountingEmbedder()
    retriever = PolicyRetriever(embedder)
    assert await retriever.warm(("What am I entitled to?", "Can I get a refund instead?")) == 2
    assert await retriever.warm(("What am I entitled to?",)) == 0
    await retriever.vector("what am i entitled to")
    assert len(embedder.calls) == 1


def test_embedder_keeps_its_connection_open_between_questions():
    embedder = GeminiEmbedder("test-key")
    assert embedder._client._transport._pool._keepalive_expiry >= 300


async def test_a_network_error_is_an_embedding_error():
    """Issue #22: httpx.HTTPError used to become a plain 500 and broke the
    start-up pre-loading silently."""
    from kestrel.policy.embeddings import EmbeddingError

    def down(request):
        raise httpx.ConnectError("no route to host", request=request)

    with pytest.raises(EmbeddingError, match="unreachable"):
        await _gemini(down).embed(["Do I get a meal?"], "RETRIEVAL_QUERY")
