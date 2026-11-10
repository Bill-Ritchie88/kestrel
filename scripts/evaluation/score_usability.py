"""
Score the usability test (Sprint III, FR-08) and print Markdown tables for
Chapter 5.

Reads the two results sheets in docs/sprint-3/usability/ once they are filled
in (05-results-template-tasks.csv and 05-results-template-sus.csv, or copies
of them):

    python scripts/evaluation/score_usability.py
    python scripts/evaluation/score_usability.py my-tasks.csv my-sus.csv > results.md

Rows left blank (a participant who did not take part, a task not reached) are
skipped. A half-filled SUS row is an error, because a SUS score needs all ten
answers.

SUS (Brooke, 1996): odd items score - 1, even items 5 - score, the sum times
2.5, giving 0-100. The standard deviation is the sample SD (n - 1). Mean time
per task is over successful attempts only; the time of a failed attempt is
mostly the time limit.
"""

import argparse
import csv
import statistics
import sys
from pathlib import Path

KIT = Path(__file__).resolve().parents[2] / "docs" / "sprint-3" / "usability"
TASKS_CSV = KIT / "05-results-template-tasks.csv"
SUS_CSV = KIT / "05-results-template-sus.csv"

TASKS = {
    1: "Sign in with a booking reference",
    2: "Find what you're entitled to",
    3: "Ask the assistant a policy question",
    4: "Rebook and choose a seat",
    5: "Find your voucher code",
}
SUS_ITEMS = [f"q{i}" for i in range(1, 11)]
EXTRA_ITEMS = {
    "trust": "I trusted the answers Kestrel gave me",
    "voucher_clarity": "It was clear what my vouchers were and how to use them",
    "instead_of_calling": "I would use Kestrel instead of calling the airline",
}
SUS_AVERAGE = 68


def sus_score(answers: list[int]) -> float:
    """System Usability Scale score, 0-100, from the ten answers in order."""
    if len(answers) != 10 or any(a not in (1, 2, 3, 4, 5) for a in answers):
        raise ValueError(f"SUS needs ten answers from 1 to 5, got {answers}")
    # Item 1 is index 0: odd items are the even indexes.
    return 2.5 * sum(a - 1 if i % 2 == 0 else 5 - a for i, a in enumerate(answers))


def parse_time(text: str) -> float | None:
    """Seconds from '75' or '1:15'; None when blank."""
    text = text.strip()
    if not text:
        return None
    if ":" in text:
        minutes, seconds = text.split(":")
        return int(minutes) * 60 + float(seconds)
    return float(text)


def mmss(seconds: float | None) -> str:
    if seconds is None:
        return "-"
    s = round(seconds)
    return f"{s // 60}:{s % 60:02d}"


def mean_sd(values: list[float]) -> tuple[float | None, float | None]:
    """Mean and sample standard deviation; None where undefined."""
    if not values:
        return None, None
    return statistics.mean(values), (statistics.stdev(values) if len(values) > 1 else None)


def fmt(x: float | None, digits: int = 1) -> str:
    return "n/a" if x is None else f"{x:.{digits}f}"


def read_tasks(path: Path) -> list[dict]:
    rows = []
    with open(path, newline="", encoding="utf-8-sig") as f:
        for line, r in enumerate(csv.DictReader(f), start=2):
            success = (r.get("success") or "").strip().upper()
            if not success:
                continue
            if success not in ("Y", "N"):
                raise ValueError(
                    f"{path.name} line {line}: success must be Y or N, got {success!r}"
                )
            rows.append({
                "participant": r["participant"].strip(),
                "task": int(r["task"]),
                "success": success == "Y",
                "time": parse_time(r.get("time_s") or ""),
                "errors": int((r.get("errors") or "0").strip() or 0),
                "notes": (r.get("notes") or "").strip(),
            })  # fmt: skip
    return rows


def read_sus(path: Path) -> list[dict]:
    rows = []
    with open(path, newline="", encoding="utf-8-sig") as f:
        for line, r in enumerate(csv.DictReader(f), start=2):
            raw = [(r.get(q) or "").strip() for q in SUS_ITEMS]
            if not any(raw):
                continue
            if not all(raw):
                raise ValueError(f"{path.name} line {line}: all ten SUS answers are needed")
            extras = {k: int(v) for k in EXTRA_ITEMS if (v := (r.get(k) or "").strip())}
            rows.append({
                "participant": r["participant"].strip(),
                "sus": sus_score([int(a) for a in raw]),
                "extras": extras,
            })  # fmt: skip
    return rows


def report(tasks: list[dict], sus: list[dict]) -> str:
    out = []
    participants = sorted({r["participant"] for r in tasks})
    cell = {(r["participant"], r["task"]): r for r in tasks}

    out.append("### Task outcomes per participant\n")
    out.append("Y = completed without help within the time limit; time in m:ss.\n")
    out.append("| Participant | " + " | ".join(f"T{t}" for t in TASKS) + " |")
    out.append("|---|" + "---|" * len(TASKS))
    for p in participants:
        cells = []
        for t in TASKS:
            r = cell.get((p, t))
            if r is None:
                cells.append("-")
            else:
                errs = f", {r['errors']} err" if r["errors"] else ""
                cells.append(f"{'Y' if r['success'] else 'N'} {mmss(r['time'])}{errs}")
        out.append(f"| {p} | " + " | ".join(cells) + " |")

    out.append("\n### Task success and time\n")
    out.append("| Task | n | Success rate | Mean time (successful) | Errors |")
    out.append("|---|---|---|---|---|")
    for t, name in TASKS.items():
        rs = [r for r in tasks if r["task"] == t]
        if not rs:
            out.append(f"| {t}. {name} | 0 | - | - | - |")
            continue
        ok = [r for r in rs if r["success"]]
        mean_t, _ = mean_sd([r["time"] for r in ok if r["time"] is not None])
        out.append(
            f"| {t}. {name} | {len(rs)} | {len(ok)}/{len(rs)} ({100 * len(ok) / len(rs):.0f}%) "
            f"| {mmss(mean_t)} | {sum(r['errors'] for r in rs)} |"
        )
    if tasks:
        ok_all = sum(r["success"] for r in tasks)
        out.append(
            f"\nOverall: {ok_all}/{len(tasks)} task attempts succeeded "
            f"({100 * ok_all / len(tasks):.0f}%)."
        )

    out.append("\n### System Usability Scale\n")
    out.append("| Participant | SUS |")
    out.append("|---|---|")
    for r in sorted(sus, key=lambda r: r["participant"]):
        out.append(f"| {r['participant']} | {r['sus']:.1f} |")
    mean, sd = mean_sd([r["sus"] for r in sus])
    out.append(f"| **Mean (n = {len(sus)})** | **{fmt(mean)}** |")
    out.append(f"| Sample SD (n - 1) | {fmt(sd)} |")
    if mean is not None:
        side = "above" if mean > SUS_AVERAGE else "below" if mean < SUS_AVERAGE else "at"
        out.append(f"\nMean SUS {mean:.1f}, {side} the commonly used average of {SUS_AVERAGE}.")

    out.append("\n### Kestrel questions (1 = strongly disagree, 5 = strongly agree)\n")
    out.append("| Statement | n | Mean | Sample SD |")
    out.append("|---|---|---|---|")
    for key, text in EXTRA_ITEMS.items():
        vals = [r["extras"][key] for r in sus if key in r["extras"]]
        m, s = mean_sd(vals)
        out.append(f"| {text} | {len(vals)} | {fmt(m)} | {fmt(s)} |")
    return "\n".join(out) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Score the Kestrel usability test.")
    parser.add_argument("tasks", nargs="?", type=Path, default=TASKS_CSV)
    parser.add_argument("sus", nargs="?", type=Path, default=SUS_CSV)
    args = parser.parse_args()
    try:
        print(report(read_tasks(args.tasks), read_sus(args.sus)), end="")
    except (OSError, ValueError, KeyError) as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
