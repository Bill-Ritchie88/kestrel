"""
Frustration -> an earlier hand-off (Phase 4).

A pure, unit-tested reading of the passenger's message and the conversation
so far. Signals:

* the same question again: token-set similarity >= 0.8 with either of the
  passenger's last two messages, when both have at least 4 words ("yes",
  "ok" or a retry after a network error is not a repeat), and never for the
  app's own quick-reply labels (a chip tapped twice is not a complaint);
* strong negative wording ("useless", "waste of time", ...);
* shouting: mostly capitals, or "!!!".

On the first signal the assistant says it is sorry, answers as usual and
offers a person. On a second signal (any earlier message in the conversation
had one too), or when the passenger accepts that offer, the agent service
opens a hand-off case with trigger FRUSTRATION and a summary saying why.
The detector only reads words; it decides nothing about the booking.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from kestrel.agent import token_set_similarity
from kestrel.suggestions import QUICK_REPLY_LABELS

REPEAT_SIMILARITY = 0.8
REPEAT_MIN_WORDS = 4
SHOUT_MIN_LETTERS = 8
SHOUT_SHARE = 0.7

NEGATIVE = (
    "useless", "ridiculous", "terrible", "awful", "worst", "rubbish", "pathetic",
    "a joke", "unacceptable", "disgusting", "furious", "angry", "fed up", "sick of",
    "waste of time", "not helping", "doesn't help", "does not help", "no help", "stupid",
    "hopeless", "nonsense", "incompetent", "hate this", "wtf", "for god's sake",
    "for gods sake", "can't believe", "cannot believe",
)  # fmt: skip

# The assistant's words on the first signal. ACCEPT_MARKER is how a later
# turn recognises that the offer was made.
ACKNOWLEDGE = "I'm sorry this has been frustrating."
OFFER = (
    "If you'd rather talk to a person, I can pass your case to the Kenya Airways disruption "
    "desk now - just say yes."
)
ACCEPT_MARKER = "pass your case to the Kenya Airways disruption desk"

# The whole reply must be a yes to the offer ("yes please", "ok connect me"):
# "yes the first one" or "ok KQ116 please" accepts a flight, not a person.
_ACCEPT = (
    r"(yes|yeah|yep|yup|ok|okay|sure|please|go ahead|do it|do that|connect me|"
    r"a person|talk to a person|person)"
)
_YES = re.compile(rf"^{_ACCEPT}( {_ACCEPT})*( thanks| thank you)?$")


def signals(message: str, history: list[dict] | None = None) -> list[str]:
    """Why this message reads as frustrated, in words for the staff summary;
    empty when it does not."""
    reasons = []
    earlier = [t.get("content", "") for t in history or [] if t.get("role") == "user"][-2:]
    if _askable(message) and any(
        len(q.split()) >= REPEAT_MIN_WORDS and token_set_similarity(message, q) >= REPEAT_SIMILARITY
        for q in earlier
    ):
        reasons.append("asked the same question again")
    lower = message.lower()
    if any(w in lower for w in NEGATIVE):
        reasons.append("used strong negative words")
    letters = [c for c in message if c.isalpha()]
    capitals = sum(c.isupper() for c in letters)
    if "!!!" in message or (
        len(letters) >= SHOUT_MIN_LETTERS and capitals / len(letters) >= SHOUT_SHARE
    ):
        reasons.append("wrote in capitals or with '!!!'")
    return reasons


def _askable(text: str) -> bool:
    """A message that can count as asking again: long enough to be a
    question (issue #7), and typed rather than a chip's label (issue #8)."""
    return len(text.split()) >= REPEAT_MIN_WORDS and text.strip() not in QUICK_REPLY_LABELS


def earlier_signal(history: list[dict] | None) -> bool:
    """Whether any earlier passenger message in the conversation had a
    signal. Quick-reply taps are skipped: they are the app's words."""
    turns = list(history or [])
    for i, turn in enumerate(turns):
        content = turn.get("content", "")
        if turn.get("role") == "user" and content.strip() not in QUICK_REPLY_LABELS and signals(
            content, turns[:i]
        ):
            return True
    return False


def accepts_offer(message: str, history: list[dict] | None) -> bool:
    """The assistant's last reply offered a person and the passenger said yes."""
    last = next(
        (t.get("content", "") for t in reversed(history or []) if t.get("role") == "assistant"), ""
    )
    words = " ".join(re.findall(r"[a-z']+", message.lower()))
    return ACCEPT_MARKER in last and bool(_YES.match(words))


@dataclass
class Assessment:
    action: str = "none"  # none | acknowledge | handoff
    reasons: list[str] = field(default_factory=list)

    def summary(self, message: str) -> str:
        """For the case: why the assistant handed over, and the last words."""
        return (
            f"Passenger frustrated ({'; '.join(self.reasons)}); the assistant handed over "
            f"early. Last message: {message[:300]}"
        )


def assess(message: str, history: list[dict] | None = None) -> Assessment:
    if accepts_offer(message, history):
        return Assessment("handoff", ["accepted the offer of a person after showing frustration"])
    reasons = signals(message, history)
    if not reasons:
        return Assessment()
    if earlier_signal(history):
        return Assessment("handoff", [*reasons, "a second time in this conversation"])
    return Assessment("acknowledge", reasons)
