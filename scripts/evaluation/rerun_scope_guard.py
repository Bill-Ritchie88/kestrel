"""
TC-12: rerun the scope guard (out of scope -> hand-off) at the deployed tau.

Embeds every question in data/eval/policy_questions.csv against the live policy
clauses, applies the scope guard at POLICY_TAU (0.66 unless overridden) and
compares the decisions with the Sprint II run in
docs/sprint-2/03-retrieval-evaluation-scores.csv. Read-only on the database.

    python scripts/evaluation/rerun_scope_guard.py

Writes docs/sprint-3/05-tc12-scope-guard.csv and prints a Markdown summary.
"""

from __future__ import annotations

import asyncio
import csv
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from evaluate_retrieval import QUESTIONS, ROOT, load_questions, scope_metrics  # noqa: E402

from kestrel.policy.embeddings import GeminiEmbedder  # noqa: E402
from kestrel.policy.retriever import DEFAULT_TAU, PolicyRetriever  # noqa: E402

BEFORE = ROOT / "docs" / "sprint-2" / "03-retrieval-evaluation-scores.csv"
OUT = ROOT / "docs" / "sprint-3" / "05-tc12-scope-guard.csv"


async def main() -> int:
    import asyncpg

    rows = load_questions(QUESTIONS)
    embedder = GeminiEmbedder(os.getenv("GOOGLE_API_KEY") or os.getenv("GEMINI_API_KEY"))
    retriever = PolicyRetriever(embedder, tau=DEFAULT_TAU)
    conn = await asyncpg.connect(os.environ["DATABASE_URL"], statement_cache_size=0)
    try:
        for r in rows:
            res = await retriever.search(conn, r["question"], 3)
            r["top"], r["ref"] = res.top_similarity, (res.hits[0].clause_ref if res.hits else "")
    finally:
        await conn.close()
        await embedder.aclose()

    with BEFORE.open(encoding="utf-8", newline="") as f:
        before = {b["question_id"]: float(b["top_similarity"]) for b in csv.DictReader(f)}

    def decision(top: float) -> str:
        return "answer" if top >= DEFAULT_TAU else "hand-off"

    changed = 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["question_id", "split", "in_scope", "expected", "top_similarity",
                    "decision", "correct", "sprint2_top_similarity", "sprint2_decision",
                    "top_ref", "question"])  # fmt: skip
        for r in rows:
            expected = "answer" if r["in_scope"] else "hand-off"
            got = decision(r["top"])
            old = before.get(r["question_id"])
            changed += old is not None and decision(old) != got
            w.writerow([r["question_id"], r["split"], int(r["in_scope"]), expected,
                        f"{r['top']:.4f}", got, int(got == expected),
                        "" if old is None else f"{old:.4f}",
                        "" if old is None else decision(old), r["ref"], r["question"]])  # fmt: skip

    print(
        f"tau = {DEFAULT_TAU:.2f}; {len(rows)} questions; decisions changed since Sprint II: {changed}\n"
    )
    print("| set | n | precision | recall | F0.5 | false hand-off rate | TP/FP/FN/TN |")
    print("|---|---|---|---|---|---|---|")
    for name, subset in (("calibration", [r for r in rows if r["split"] == "calibration"]),
                         ("test", [r for r in rows if r["split"] == "test"]), ("all", rows)):  # fmt: skip
        m = scope_metrics(subset, DEFAULT_TAU)
        print(f"| {name} | {len(subset)} | {m['precision']:.3f} | {m['recall']:.3f} | {m['f0_5']:.3f} | "
              f"{m['false_handoff_rate']:.3f} | {m['tp']}/{m['fp']}/{m['fn']}/{m['tn']} |")  # fmt: skip
    oos = [r for r in rows if not r["in_scope"]]
    leaked = [r["question_id"] for r in oos if r["top"] >= DEFAULT_TAU]
    print(
        f"\nOut-of-scope questions handed off: {len(oos) - len(leaked)}/{len(oos)}; answered: {leaked}"
    )
    print(f"[OK] {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
