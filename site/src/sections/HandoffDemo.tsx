import { useState } from "react";

// The four ways a conversation reaches a person (FR-05) and what the staff
// queue receives (FR-09). Selecting a trigger shows the case it opens.

const TRIGGERS = [
  {
    id: "PASSENGER_REQUEST",
    label: "Passenger asks",
    question: "Can I bring my pet parrot in the cabin?",
    summary: "Retrieval ranked KQ CoC Art. 8 first, but below the similarity threshold. Rather than guess, the agent handed off.",
    sim: 0.61,
  },
  {
    id: "NO_ALTERNATIVES",
    label: "No seat left",
    question: null,
    summary: "No business seat on the same route within 48 hours. Needs an interline or a downgrade with compensation.",
    sim: null,
  },
  {
    id: "REBOOKING_FAILED",
    label: "Rebooking refused",
    question: null,
    summary: "Target seat claimed by a concurrent transaction. The procedure refused and audited it; one retry failed.",
    sim: null,
  },
  {
    id: "STEP_LIMIT",
    label: "Too many steps",
    question: "I need to be in Lagos by Saturday. What are my options?",
    summary: "The tool loop reached its five-step limit comparing alternatives. The case carries the full context.",
    sim: 0.72,
  },
] as const;

export function HandoffDemo() {
  const [sel, setSel] = useState<(typeof TRIGGERS)[number]["id"]>("PASSENGER_REQUEST");
  const [resolved, setResolved] = useState(false);
  const t = TRIGGERS.find((x) => x.id === sel)!;

  return (
    <div className="panel handoff">
      <div className="trigger-tabs" role="tablist">
        {TRIGGERS.map((x) => (
          <button key={x.id} role="tab" aria-selected={x.id === sel} className={x.id === sel ? "on" : ""}
            onClick={() => { setSel(x.id); setResolved(false); }}>
            {x.label}
          </button>
        ))}
      </div>
      <div className="case">
        <div className="case-top">
          <span className="mono">Case #41</span>
          <code>{t.id}</code>
          {t.sim != null && <span className="muted">similarity {t.sim.toFixed(2)}</span>}
        </div>
        {t.question && <blockquote>{t.question}</blockquote>}
        <p>{t.summary}</p>
        <div className="case-foot">
          {resolved ? (
            <span className="tag ok">Resolved by STAFF:wanjiru</span>
          ) : (
            <>
              <span className="tag warn">Open in staff queue</span>
              <button className="btn small" onClick={() => setResolved(true)}>Resolve</button>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
