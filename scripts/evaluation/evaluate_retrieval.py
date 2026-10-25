"""
Retrieval evaluation and threshold calibration (FR-05, NFR-04, Objective iv).

Input: data/eval/policy_questions.csv, a hand-labelled set of passenger
questions with columns

    question_id, split, in_scope, expected_refs, topic, question, label_note

  split          calibration | test   (tau is chosen on calibration, reported on test)
  in_scope       1 if the policy corpus should answer it, 0 if it should be handed off
  expected_refs  for in-scope questions, the clause reference(s) that answer it,
                 separated by ';' - e.g. "EU261 Art. 9;KQ CoC Art. 9"

Every question is embedded once and its top-3 clauses retrieved. Then:

  * Recall@3 - share of in-scope questions with at least one expected clause in
    the top 3 (a reference matches the clause itself or any of its parts, so
    "EU261 Art. 9" matches "EU261 Art. 9 (part 1 of 2)" but "KQ CoC Art. 1"
    does not match "KQ CoC Art. 10").
  * For every candidate tau, the scope guard is scored as a binary classifier
    whose positive class is "answer" (top similarity >= tau). F0.5 weights
    precision over recall: answering an out-of-scope question (the Moffatt
    failure) is worse than handing off one that could have been answered.

The tau with the highest F0.5 on the calibration split is chosen; precision,
recall, F0.5 and the false hand-off rate are reported on the test split at
that tau. Results are written to docs/sprint-2/03-retrieval-evaluation.md and a
CSV of every question's scores, so the report quotes measured numbers only.

    python scripts/evaluation/evaluate_retrieval.py
"""

import asyncio
import csv
import os
import sys
from datetime import datetime
from pathlib import Path

from kestrel import config  # noqa: F401  - loads .env
from kestrel.policy.embeddings import GeminiEmbedder
from kestrel.policy.retriever import PolicyRetriever

ROOT = Path(__file__).resolve().parents[2]
QUESTIONS = ROOT / "data" / "eval" / "policy_questions.csv"
OUT_DIR = ROOT / "docs" / "sprint-2"
BETA = 0.5


def load_questions(path: Path) -> list[dict]:
    with path.open(encoding="utf-8", newline="") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        r["in_scope"] = r["in_scope"].strip() == "1"
        r["expected_refs"] = [x.strip() for x in r.get("expected_refs", "").split(";") if x.strip()]
    return rows


def scope_metrics(rows: list[dict], tau: float) -> dict:
    tp = sum(1 for r in rows if r["in_scope"] and r["top"] >= tau)
    fp = sum(1 for r in rows if not r["in_scope"] and r["top"] >= tau)
    fn = sum(1 for r in rows if r["in_scope"] and r["top"] < tau)
    tn = sum(1 for r in rows if not r["in_scope"] and r["top"] < tau)
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    b2 = BETA * BETA
    f_beta = (
        (1 + b2) * precision * recall / (b2 * precision + recall) if precision + recall else 0.0
    )
    in_scope = tp + fn
    return {
        "tau": tau,
        "tp": tp,
        "fp": fp,
        "fn": fn,
        "tn": tn,
        "precision": precision,
        "recall": recall,
        "f0_5": f_beta,
        # In-scope questions wrongly sent to a person.
        "false_handoff_rate": fn / in_scope if in_scope else 0.0,
    }


def ref_matches(ref: str, expected: str) -> bool:
    """'EU261 Art. 9' matches 'EU261 Art. 9' and 'EU261 Art. 9 (part 1 of 2)',
    but 'KQ CoC Art. 1' must not match 'KQ CoC Art. 10'."""
    return ref == expected or ref.startswith(expected + " ")


def hit_at_k(row: dict) -> bool:
    return any(ref_matches(ref, exp) for ref in row["refs"] for exp in row["expected_refs"])


def recall_at_k(rows: list[dict]) -> float:
    scored = [r for r in rows if r["in_scope"] and r["expected_refs"]]
    if not scored:
        return 0.0
    return sum(1 for r in scored if hit_at_k(r)) / len(scored)


async def main() -> int:
    import asyncpg

    if not QUESTIONS.exists():
        print(f"[ERROR] {QUESTIONS} not found.")
        return 1
    rows = load_questions(QUESTIONS)
    api_key = os.getenv("GOOGLE_API_KEY") or os.getenv("GEMINI_API_KEY")
    embedder = GeminiEmbedder(api_key)
    retriever = PolicyRetriever(embedder)
    conn = await asyncpg.connect(os.environ["DATABASE_URL"], statement_cache_size=0)
    try:
        for r in rows:
            result = await retriever.search(conn, r["question"], 3)
            r["top"] = result.top_similarity
            r["refs"] = [h.clause_ref for h in result.hits]
            r["sims"] = [round(h.similarity, 4) for h in result.hits]
    finally:
        await conn.close()
        await embedder.aclose()

    cal = [r for r in rows if r["split"] == "calibration"]
    test = [r for r in rows if r["split"] == "test"]
    candidates = [round(0.50 + 0.01 * i, 2) for i in range(46)]  # 0.50 .. 0.95
    sweep = [scope_metrics(cal, t) for t in candidates]
    best = max(sweep, key=lambda m: (m["f0_5"], m["tau"]))  # ties -> stricter tau
    at_start = scope_metrics(test, 0.75)
    at_best = scope_metrics(test, best["tau"])

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M")
    with (OUT_DIR / "03-retrieval-evaluation-scores.csv").open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["question_id", "split", "in_scope", "topic", "top_similarity", "hit_at_3",
                    "top3_refs", "top3_sims", "question"])  # fmt: skip
        for r in rows:
            hit = int(hit_at_k(r)) if r["in_scope"] else ""
            w.writerow([r["question_id"], r["split"], int(r["in_scope"]), r.get("topic", ""),
                        f"{r['top']:.4f}", hit, " | ".join(r["refs"]),
                        " | ".join(map(str, r["sims"])), r["question"]])  # fmt: skip

    def line(m: dict) -> str:
        return (f"| {m['tau']:.2f} | {m['precision']:.3f} | {m['recall']:.3f} | {m['f0_5']:.3f} | "
                f"{m['false_handoff_rate']:.3f} | {m['tp']}/{m['fp']}/{m['fn']}/{m['tn']} |")  # fmt: skip

    report = [
        "# Retrieval evaluation",
        "",
        f"Run {stamp}, embedding model `{embedder.model}`, {len(rows)} labelled questions "
        f"({len(cal)} calibration, {len(test)} test). Generated by `scripts/evaluation/evaluate_retrieval.py`.",
        "",
        f"* Recall@3 (test, in-scope): **{recall_at_k(test):.3f}**",
        f"* Recall@3 (all, in-scope): {recall_at_k(rows):.3f}",
        f"* Calibrated tau (max F0.5 on calibration): **{best['tau']:.2f}**",
        "",
        "Scope guard on the held-out test split:",
        "",
        "| tau | precision | recall | F0.5 | false hand-off rate | TP/FP/FN/TN |",
        "|---|---|---|---|---|---|",
        line(at_start) + " starting value",
        line(at_best) + " calibrated",
        "",
        "Calibration sweep:",
        "",
        "| tau | precision | recall | F0.5 | false hand-off rate | TP/FP/FN/TN |",
        "|---|---|---|---|---|---|",
        *[line(m) for m in sweep],
    ]
    (OUT_DIR / "03-retrieval-evaluation.md").write_text("\n".join(report) + "\n", encoding="utf-8")
    print("\n".join(report[:12]))
    print(f"\n[OK]   Set POLICY_TAU={best['tau']:.2f} in .env and restart the API.")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
