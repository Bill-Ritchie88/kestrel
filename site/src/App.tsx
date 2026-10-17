import { useEffect, useState } from "react";
import { EntitlementCalc } from "./sections/EntitlementCalc";
import { HandoffDemo } from "./sections/HandoffDemo";
import { HeroDemo } from "./sections/HeroDemo";
import { SeatRace } from "./sections/SeatRace";

const NAV = [
  ["#understand", "Agent"],
  ["#rebook", "Rebooking"],
  ["#entitle", "Entitlements"],
  ["#handoff", "Hand-off"],
  ["#architecture", "Architecture"],
] as const;

export default function App() {
  const [scrolled, setScrolled] = useState(false);
  useEffect(() => {
    const on = () => setScrolled(window.scrollY > 8);
    on();
    window.addEventListener("scroll", on, { passive: true });
    return () => window.removeEventListener("scroll", on);
  }, []);

  // Fade sections in as they enter the viewport.
  useEffect(() => {
    const io = new IntersectionObserver(
      (entries) => entries.forEach((e) => e.isIntersecting && e.target.setAttribute("data-in", "")),
      { rootMargin: "0px 0px -10% 0px" },
    );
    document.querySelectorAll(".reveal").forEach((el) => io.observe(el));
    return () => io.disconnect();
  }, []);

  return (
    <>
      <header className={`nav ${scrolled ? "scrolled" : ""}`}>
        <div className="container nav-inner">
          <a href="#top" className="brand" aria-label="Kestrel home">
            <Mark /> Kestrel
          </a>
          <nav className="nav-links" aria-label="Sections">
            {NAV.map(([href, label]) => <a key={href} href={href}>{label}</a>)}
          </nav>
          <a className="btn pill" href="#demo">See it work</a>
        </div>
      </header>

      <main id="top">
        {/* Hero ------------------------------------------------------------ */}
        <section className="hero container">
          <h1 className="reveal">
            From cancelled flight<br />to confirmed seat<br /><span className="grad">in one conversation</span>
          </h1>
          <div className="hero-sub reveal">
            <p>Kestrel lets a disrupted passenger talk to an agent that finds, holds and books their new flight, while a transactional core makes sure every seat and voucher is legitimate.</p>
            <a href="#architecture" className="hero-link"><b>How it works</b> Agent decides, database enforces →</a>
          </div>
        </section>
        <div className="container hero-window reveal" id="demo">
          <HeroDemo />
          <p className="caption">Replay of a recorded test run on synthetic data. Hover to pause.</p>
        </div>

        {/* Intro ----------------------------------------------------------- */}
        <section className="container intro reveal">
          <h2>A language model that can't overbook.<span className="muted"> Kestrel splits recovery into the part a model is good at and the part it must never touch.</span></h2>
          <div className="pillars">
            <Pillar n="01" title="The agent decides" body="Gemini reads the passenger's request, calls one of five tools and explains the result in plain language." />
            <Pillar n="02" title="The database enforces" body="A PL/pgSQL procedure checks the route, cabin and seat under row locks, then commits the change or refuses it with a reason." />
            <Pillar n="03" title="People handle the rest" body="Anything the rules can't settle opens a case for staff, with the context already written." />
          </div>
        </section>

        {/* 1.0 Understand -------------------------------------------------- */}
        <Feature id="understand" n="1.0" kicker="Understand" title="Answers grounded in the conditions of carriage"
          body="Passengers sign in with their booking reference and surname. The agent searches 120 indexed policy clauses and cites the one it relied on. If no clause is similar enough to the question, it hands the conversation to a person instead of improvising."
          points={["PNR + surname sign-in with throttling", "Semantic search over the carriage conditions", "Similarity threshold as a scope guard", "Conversation history across turns"]}>
          <div className="panel policy">
            <div className="msg user">Do I get a refund if I don't want the new flight?</div>
            <div className="tool-line"><code>search_policy_tool</code><span className="muted">top match 0.84 · above threshold</span></div>
            <div className="msg agent">
              Yes. If you'd rather not travel, you can ask for a refund of the unused part of your ticket instead of re-routing.
              <span className="cite">Source: Conditions of Carriage, Art. 10 · Refunds</span>
            </div>
          </div>
        </Feature>

        {/* 2.0 Rebook ------------------------------------------------------- */}
        <Feature id="rebook" flip n="2.0" kicker="Rebook" title="Every seat is claimed exactly once"
          body="The agent can only ask for a rebooking. The stored procedure does the work: it checks that the new flight is on the same route and in the same cabin, locks the target seat and releases the old one, and writes an audit row in the same transaction. Run the load test: twelve passengers, three seats."
          points={["Same route, same cabin, no fare difference", "Row-level locks, one transaction", "Every refusal audited with a reason code", "Agent holds no database credentials"]}>
          <SeatRace />
        </Feature>

        {/* 3.0 Entitle ------------------------------------------------------ */}
        <Feature id="entitle" n="3.0" kicker="Entitle" title="Entitlements from rules, not from the model"
          body="Meals, hotel nights, transfers, compensation and goodwill points come from a deterministic rules engine that transcribes EU261 and UK261. The model only reports what the engine returns, so it can't promise a policy that doesn't exist. Try changing the route or the cause."
          points={["Distance bands and Art. 7 amounts", "Extraordinary-circumstance exemptions", "One voucher per type, stable codes", "Each value cites its legal or project basis"]}>
          <EntitlementCalc />
        </Feature>

        {/* 4.0 Hand off ----------------------------------------------------- */}
        <Feature id="handoff" flip n="4.0" kicker="Hand off" title="Knowing when to stop"
          body="Four situations end the conversation with the agent: the passenger asks for a person, no alternative exists, the rebooking is refused, or the agent hits its step limit. Each opens a case in the staff queue with a summary, so nobody has to ask the passenger to repeat themselves."
          points={["Four explicit hand-off triggers", "Five-step bound on the tool loop", "Staff queue with resolution notes", "Retrieval scores kept for review"]}>
          <HandoffDemo />
        </Feature>

        {/* Architecture ---------------------------------------------------- */}
        <section id="architecture" className="container arch reveal">
          <div className="section-head">
            <span className="kicker">Architecture</span>
            <h2>Three tiers. One way in.</h2>
            <p className="muted">The agent talks to the REST tier over HTTP with the passenger's session token, never to the database. All writes go through one audited procedure.</p>
          </div>
          <div className="arch-flow">
            <ArchNode title="Flutter client" sub="Phone and web · voice dictation" />
            <Arrow label="HTTPS" />
            <ArchNode title="Agent tier" sub="Gemini · LangChain · 5 tools" accent />
            <Arrow label="Bearer token" />
            <ArchNode title="FastAPI REST tier" sub="Validation · auth · rules engine" />
            <Arrow label="asyncpg" />
            <ArchNode title="PostgreSQL" sub="Row locks · RLS · audit_logs" />
          </div>
        </section>

        {/* Numbers --------------------------------------------------------- */}
        <section className="container numbers reveal">
          <Num v="146" l="Automated tests passing" />
          <Num v="6.4 s" l="Rebooking turn, end to end" />
          <Num v="120" l="Policy clauses indexed" />
          <Num v="0" l="Seats held twice under load" />
        </section>

        {/* Sprint log ------------------------------------------------------ */}
        <section className="container log reveal">
          <div className="section-head">
            <span className="kicker">Sprint log</span>
            <h2>Built in the open</h2>
          </div>
          <ol className="log-list">
            <LogItem date="Oct 15, 2026" tag="Sprint 2" title="Bounded model calls" body="Two attempts, 20 s each. A rebooking turn now completes in 6.4 s." />
            <LogItem date="Oct 9, 2026" tag="Sprint 2" title="Hand-off and staff queue" body="Four triggers, case summaries and resolution notes. 146 tests passing." />
            <LogItem date="Oct 3, 2026" tag="Sprint 2" title="Cabin class preserved" body="Business passengers stay in business; every refusal is audited." />
            <LogItem date="Sep 24, 2026" tag="Sprint 1" title="Reproducible from scratch" body="Schema migrations, synthetic dataset generator, locked dependencies." />
          </ol>
        </section>

        {/* CTA ------------------------------------------------------------- */}
        <section className="container cta reveal">
          <h2>Ready for the next cancellation.</h2>
          <div className="cta-actions">
            <a className="btn pill" href="#demo">Replay the demo</a>
            <a className="btn ghost" href="#entitle">Try the rules engine</a>
          </div>
        </section>
      </main>

      <footer className="footer">
        <div className="container footer-grid">
          <div>
            <a href="#top" className="brand"><Mark /> Kestrel</a>
            <p className="muted small">Agentic passenger re-accommodation.</p>
          </div>
          <FooterCol title="System" links={[["#understand", "Agent"], ["#rebook", "Rebooking"], ["#entitle", "Entitlements"], ["#handoff", "Hand-off"]]} />
          <FooterCol title="Project" links={[["#architecture", "Architecture"], ["#demo", "Demo"]]} />
          <p className="disclaimer">
            Kestrel is an independent academic project. It uses synthetic data only and is not affiliated with or endorsed by Kenya Airways.
          </p>
        </div>
      </footer>
    </>
  );
}

function Mark() {
  return (
    <svg width="22" height="22" viewBox="0 0 32 32" aria-hidden="true">
      <rect width="32" height="32" rx="8" fill="var(--accent)" />
      <path d="M5 18c4-1 7-3.5 9.5-7.5L16 8l1.5 2.5C20 14.5 23 17 27 18c-3.5.3-6.6 1.6-9 4l-2 3-2-3c-2.4-2.4-5.5-3.7-9-4z" fill="#fff" />
    </svg>
  );
}

function Pillar({ n, title, body }: { n: string; title: string; body: string }) {
  return (
    <div className="pillar">
      <span className="pillar-n">{n}</span>
      <h3>{title}</h3>
      <p>{body}</p>
    </div>
  );
}

function Feature(props: { id: string; flip?: boolean; n: string; kicker: string; title: string; body: string; points: string[]; children: React.ReactNode }) {
  return (
    <section id={props.id} className={`container feature reveal ${props.flip ? "flip" : ""}`}>
      <div className="feature-text">
        <span className="kicker"><b>{props.n}</b> {props.kicker}</span>
        <h2>{props.title}</h2>
        <p>{props.body}</p>
        <ul className="points">{props.points.map((p) => <li key={p}>{p}</li>)}</ul>
      </div>
      <div className="feature-demo">{props.children}</div>
    </section>
  );
}

function ArchNode({ title, sub, accent }: { title: string; sub: string; accent?: boolean }) {
  return (
    <div className={`arch-node ${accent ? "accent" : ""}`}>
      <b>{title}</b>
      <span>{sub}</span>
    </div>
  );
}

function Arrow({ label }: { label: string }) {
  return (
    <div className="arch-arrow" aria-hidden="true">
      <span>{label}</span>
    </div>
  );
}

function Num({ v, l }: { v: string; l: string }) {
  return (
    <div className="num">
      <b>{v}</b>
      <span>{l}</span>
    </div>
  );
}

function LogItem({ date, tag, title, body }: { date: string; tag: string; title: string; body: string }) {
  return (
    <li>
      <time>{date}</time>
      <span className="tag">{tag}</span>
      <div>
        <b>{title}</b>
        <p className="muted">{body}</p>
      </div>
    </li>
  );
}

function FooterCol({ title, links }: { title: string; links: [string, string][] }) {
  return (
    <div className="footer-col">
      <span>{title}</span>
      {links.map(([h, l]) => <a key={h} href={h}>{l}</a>)}
    </div>
  );
}
