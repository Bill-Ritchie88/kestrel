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
from typing import Protocol

import httpx

GEMINI_API_BASE = "https://generativelanguage.googleapis.com/v1beta"
DEFAULT_EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "gemini-embedding-001")
EMBEDDING_DIMENSIONS = 768  # must match vector(768) in migration 005
BATCH_SIZE = 100  # the API's per-request limit

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


class GeminiEmbedder:
    """Embeds text with the Gemini API. One instance per process is enough."""

    def __init__(
        self,
        api_key: str,
        model: str = DEFAULT_EMBEDDING_MODEL,
        dimensions: int = EMBEDDING_DIMENSIONS,
        client: httpx.AsyncClient | None = None,
        max_retries: int = 3,
    ):
        if not api_key:
            raise EmbeddingError("GOOGLE_API_KEY is not set.")
        self.model = model
        self.dimensions = dimensions
        self._api_key = api_key
        self._client = client or httpx.AsyncClient(timeout=30.0)
        self._max_retries = max_retries

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
            response = await self._client.post(
                url, json=body, headers={"x-goog-api-key": self._api_key}
            )
            # 429 (quota) and 5xx are retried with backoff; anything else is a
            # configuration error worth surfacing immediately.
            if response.status_code == 429 or response.status_code >= 500:
                if attempt < self._max_retries:
                    await asyncio.sleep(2**attempt)
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
