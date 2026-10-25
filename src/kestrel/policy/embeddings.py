"""
Text embeddings for policy retrieval.

Gemini's embedding endpoint is called over plain HTTPS with httpx, which the
project already depends on, rather than through another SDK. The request and
response shapes are those of the Gemini API v1beta `batchEmbedContents`
method.

Vectors are L2-normalised before storage and before querying. Gemini returns
unit vectors only at its full dimensionality; when a smaller output size is
requested (768 here, to keep the pgvector column small) the vectors must be
normalised by the caller for cosine similarity to be comparable.
"""

from __future__ import annotations

import asyncio
import math
import os
import re
from collections.abc import Awaitable, Callable
from typing import Protocol

import httpx

GEMINI_API_BASE = "https://generativelanguage.googleapis.com/v1beta"
DEFAULT_EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "gemini-embedding-001")
EMBEDDING_DIMENSIONS = 768  # must match vector(768) in migration 005
# Texts per request. The API accepts up to 100, but every text counts against
# the per-minute token quota, and on the free tier 100 article-length clauses
# exceed it in a single request. Small batches let the retry logic pace the
# load instead of failing it.
BATCH_SIZE = int(os.getenv("EMBEDDING_BATCH_SIZE", "20"))
MAX_RETRY_WAIT_SECONDS = 120

TASK_DOCUMENT = "RETRIEVAL_DOCUMENT"
TASK_QUERY = "RETRIEVAL_QUERY"


class Embedder(Protocol):
    model: str

    async def embed(self, texts: list[str], task: str) -> list[list[float]]: ...


def normalise(vector: list[float]) -> list[float]:
    norm = math.sqrt(sum(x * x for x in vector))
    if norm == 0:
        raise ValueError("Cannot normalise a zero vector.")
    return [x / norm for x in vector]


def to_pgvector(vector: list[float]) -> str:
    """pgvector's text input format, e.g. '[0.12,-0.5,...]'."""
    return "[" + ",".join(f"{x:.7g}" for x in vector) + "]"


class EmbeddingError(RuntimeError):
    pass


class QuotaExhaustedError(EmbeddingError):
    """A daily quota is used up: waiting a minute will not help."""


def _quota_details(response: httpx.Response) -> tuple[str, list[str], float | None]:
    """(message, quota ids, retry delay in seconds) from a Gemini error body."""
    try:
        error = response.json().get("error", {})
    except ValueError:
        return response.text[:300], [], None
    quota_ids: list[str] = []
    delay: float | None = None
    for detail in error.get("details", []):
        for violation in detail.get("violations", []):
            quota_ids.append(violation.get("quotaId") or violation.get("quotaMetric", ""))
        if "retryDelay" in detail:
            match = re.match(r"([\d.]+)s", str(detail["retryDelay"]))
            delay = float(match.group(1)) if match else None
    return error.get("message", "")[:300], quota_ids, delay


class GeminiEmbedder:
    """Embeds text with the Gemini API. One instance per process is enough."""

    def __init__(
        self,
        api_key: str,
        model: str = DEFAULT_EMBEDDING_MODEL,
        dimensions: int = EMBEDDING_DIMENSIONS,
        client: httpx.AsyncClient | None = None,
        max_retries: int = 6,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
        on_wait: Callable[[float, str], None] | None = None,
    ):
        if not api_key:
            raise EmbeddingError("GOOGLE_API_KEY is not set.")
        self.model = model
        self.dimensions = dimensions
        self._api_key = api_key
        # One client for the life of the process, keeping its connection to
        # the API open between questions: httpx closes an idle connection
        # after 5 s by default, and a new TLS connection costs several round
        # trips. Google may still close it sooner; httpx then reconnects.
        self._client = client or httpx.AsyncClient(
            timeout=30.0, limits=httpx.Limits(keepalive_expiry=300)
        )
        self._max_retries = max_retries
        self._sleep = sleep
        self._on_wait = on_wait

    async def embed(self, texts: list[str], task: str) -> list[list[float]]:
        vectors: list[list[float]] = []
        for start in range(0, len(texts), BATCH_SIZE):
            vectors.extend(await self._embed_batch(texts[start : start + BATCH_SIZE], task))
        return vectors

    async def _embed_batch(self, texts: list[str], task: str) -> list[list[float]]:
        body = {
            "requests": [
                {
                    "model": f"models/{self.model}",
                    "content": {"parts": [{"text": t}]},
                    "taskType": task,
                    "outputDimensionality": self.dimensions,
                }
                for t in texts
            ]
        }
        url = f"{GEMINI_API_BASE}/models/{self.model}:batchEmbedContents"
        for attempt in range(self._max_retries + 1):
            try:
                response = await self._client.post(
                    url, json=body, headers={"x-goog-api-key": self._api_key}
                )
            except httpx.HTTPError as exc:
                # A network failure is the embedding service's failure: 502,
                # and start-up pre-loading reports it (issue #22).
                raise EmbeddingError(f"Embedding service unreachable: {type(exc).__name__}") from exc
            # 429 (quota) and 5xx are retried, waiting as long as the API asks;
            # anything else is a configuration error worth surfacing at once.
            if response.status_code == 429:
                message, quota_ids, delay = _quota_details(response)
                if any("PerDay" in q for q in quota_ids):
                    raise QuotaExhaustedError(
                        f"Daily Gemini quota exhausted ({', '.join(quota_ids)}). "
                        "Re-run tomorrow, or enable billing on the API key's project; "
                        "chunks already stored are kept and skipped next time."
                    )
                if attempt < self._max_retries:
                    wait = min(MAX_RETRY_WAIT_SECONDS, (delay or 2**attempt * 5) + 1)
                    if self._on_wait:
                        self._on_wait(wait, ", ".join(quota_ids) or message)
                    await self._sleep(wait)
                    continue
                raise EmbeddingError(f"Embedding quota still exceeded after retries: {message}")
            if response.status_code >= 500 and attempt < self._max_retries:
                await self._sleep(2**attempt)
                continue
            if response.status_code != 200:
                raise EmbeddingError(
                    f"Embedding request failed ({response.status_code}): {response.text[:300]}"
                )
            data = response.json()
            embeddings = data.get("embeddings", [])
            if len(embeddings) != len(texts):
                raise EmbeddingError("Embedding response did not match the request size.")
            vectors = [normalise(e["values"]) for e in embeddings]
            if any(len(v) != self.dimensions for v in vectors):
                raise EmbeddingError(
                    f"Expected {self.dimensions}-dimensional vectors from {self.model}."
                )
            return vectors
        raise EmbeddingError("Embedding request failed after retries.")  # pragma: no cover

    async def aclose(self) -> None:
        await self._client.aclose()
