"""
Policy corpus: turn the source texts into article-sized, citable chunks.

The sources are the authoritative documents, saved verbatim as plain text in
data/policy/sources/ (see the README there). Nothing in the corpus is written
by hand or by a model: the chunker only splits the text at article headings,
so every chunk can be traced back to a clause in the original document.

Chunking rule. One chunk per article, because an article is the unit a
passenger-facing answer cites ("EU261 Art. 9"). An article longer than
MAX_CHARS is split at its numbered paragraphs, then at blank lines, so that a
single embedding is not asked to represent several unrelated provisions.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from pathlib import Path

MAX_CHARS = 2400
MIN_CHARS = 80  # fragments shorter than this are merged into their neighbour


@dataclass(frozen=True)
class Source:
    code: str  # stored in policy_chunks.source
    name: str
    citation: str  # prefix used in clause references
    url: str
    keep_preamble: bool  # text before the first article (EU recitals) is useful
    # Where the document proper begins. Anything above the first match - page
    # navigation, or text injected by a browser extension when the page was
    # copied - is discarded before chunking.
    start_pattern: str


# Keyed by the file name (without .txt) in data/policy/sources/.
SOURCES: dict[str, Source] = {
    "kq-conditions-of-carriage": Source(
        code="KQ_COC",
        name="Kenya Airways General Conditions of Carriage",
        citation="KQ CoC",
        url="https://www.kenya-airways.com/en-ke/policies/conditions-of-carriage/",
        keep_preamble=False,  # the page header and navigation precede Article 1
        start_pattern=r"^[ \t]*ARTICLE[ \t]+1\b",
    ),
    "eu261": Source(
        code="EU261",
        name="Regulation (EC) No 261/2004",
        citation="EU261",
        url="https://eur-lex.europa.eu/legal-content/EN/TXT/HTML/?uri=CELEX:32004R0261",
        keep_preamble=True,  # recital 14 defines extraordinary circumstances
        start_pattern=r"^[ \t]*(?:32004R0261|Regulation \(EC\) No 261/2004)",
    ),
    "montreal-convention": Source(
        code="MONTREAL_1999",
        name="Convention for the Unification of Certain Rules for International Carriage by Air (Montreal, 1999)",
        citation="Montreal Convention",
        url="https://eur-lex.europa.eu/legal-content/EN/TXT/HTML/?uri=CELEX:22001A0718(01)",
        keep_preamble=False,
        start_pattern=r"^[ \t]*(?:22001A0718|Convention for the Unification)",
    ),
}


@dataclass(frozen=True)
class Chunk:
    chunk_id: str
    source: str
    clause_ref: str
    title: str
    content: str
    source_url: str

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.content.encode("utf-8")).hexdigest()


# "ARTICLE 9: SCHEDULES, DELAYS..." (KQ), "Article 9" + title on the next line
# (EUR-Lex), "Article 19 - Delay" (some treaty layouts).
_ARTICLE = re.compile(r"^[ \t]*(?:ARTICLE|Article)[ \t]+(\d+[a-zA-Z]?)\b[ \t]*[:.\-–—]?[ \t]*(.*)$", re.M)
_PARAGRAPH = re.compile(r"(?m)^(?=[ \t]*(?:\d+\.\d*|\(\d+\)|\d+\))[ \t]+\S)")


def _clean(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n").replace(" ", " ")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def _split_long(body: str) -> list[str]:
    """Split an over-long article at numbered paragraphs, then blank lines."""
    if len(body) <= MAX_CHARS:
        return [body]
    pieces = [p.strip() for p in _PARAGRAPH.split(body) if p.strip()]
    if len(pieces) <= 1:
        pieces = [p.strip() for p in body.split("\n\n") if p.strip()]
    parts: list[str] = []
    current = ""
    for piece in pieces:
        if current and len(current) + len(piece) + 2 > MAX_CHARS:
            parts.append(current)
            current = piece
        else:
            current = f"{current}\n\n{piece}" if current else piece
    if current:
        parts.append(current)
    # A single paragraph longer than MAX_CHARS is cut at sentence boundaries.
    out: list[str] = []
    for part in parts:
        while len(part) > MAX_CHARS:
            cut = part.rfind(". ", 0, MAX_CHARS)
            cut = cut + 1 if cut > MAX_CHARS // 2 else MAX_CHARS
            out.append(part[:cut].strip())
            part = part[cut:].strip()
        if part:
            out.append(part)
    # Merge fragments too short to embed meaningfully.
    merged: list[str] = []
    for part in out:
        if merged and len(part) < MIN_CHARS:
            merged[-1] = f"{merged[-1]}\n\n{part}"
        else:
            merged.append(part)
    return merged


def chunk_text(text: str, source: Source) -> list[Chunk]:
    """Split one source document into citable chunks."""
    text = _clean(text)
    start = re.search(source.start_pattern, text, re.M)
    if start:
        text = text[start.start() :]
    matches = list(_ARTICLE.finditer(text))
    sections: list[tuple[str, str, str]] = []  # (article number, title, body)

    if matches and source.keep_preamble:
        preamble = text[: matches[0].start()].strip()
        if len(preamble) >= MIN_CHARS:
            sections.append(("0", "Preamble and recitals", preamble))

    for i, m in enumerate(matches):
        number, title = m.group(1), m.group(2).strip()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        body = text[m.end() : end].strip()
        if not title:
            # EUR-Lex puts the title on the line after "Article 9".
            first, _, rest = body.partition("\n")
            if first and len(first) <= 90 and not first.rstrip().endswith("."):
                title, body = first.strip(), rest.strip()
        if body:
            sections.append((number, title, body))

    if not matches and len(text) >= MIN_CHARS:
        sections.append(("0", source.name, text))

    chunks: list[Chunk] = []
    seen: dict[str, int] = {}
    for number, title, body in sections:
        base_ref = f"{source.citation} Art. {number}" if number != "0" else f"{source.citation} preamble"
        base_id = f"{source.code}-ART-{number}"
        # Treaties and regulations sometimes repeat an article number in an
        # annex; keep ids unique.
        seen[base_id] = seen.get(base_id, 0) + 1
        if seen[base_id] > 1:
            base_id = f"{base_id}-{seen[base_id]}"
        parts = _split_long(body)
        for j, part in enumerate(parts, start=1):
            suffix = f"-P{j}" if len(parts) > 1 else ""
            ref = base_ref + (f" (part {j} of {len(parts)})" if len(parts) > 1 else "")
            heading = f"{base_ref}: {title}" if title else base_ref
            chunks.append(
                Chunk(
                    chunk_id=base_id + suffix,
                    source=source.code,
                    clause_ref=ref,
                    title=title,
                    # The heading is embedded with the body: "Right to care"
                    # is often the strongest signal in the whole article.
                    content=f"{heading}\n\n{part}",
                    source_url=source.url,
                )
            )
    return chunks


def load_corpus(directory: Path) -> tuple[list[Chunk], list[str]]:
    """Chunk every known source file present. Returns (chunks, missing sources)."""
    chunks: list[Chunk] = []
    missing: list[str] = []
    for stem, source in SOURCES.items():
        path = directory / f"{stem}.txt"
        if not path.exists():
            missing.append(path.name)
            continue
        chunks.extend(chunk_text(path.read_text(encoding="utf-8", errors="replace"), source))
    return chunks, missing
