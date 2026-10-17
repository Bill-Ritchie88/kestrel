import { useEffect, useRef, useState } from "react";

// A replay of end-to-end runs E2E-01 and E2E-02 from the Sprint 2 test log:
// passenger A27Z99, GOLD tier, business seat 5G on KQ886 NBO-BKK, cancelled
// for a technical reason. Timings are the measured ones from AG-02.

type Step =
  | { at: number; kind: "user"; text: string }
  | { at: number; kind: "agent"; text: string }
  | { at: number; kind: "tool"; name: string; ms: number; detail: string }
  | { at: number; kind: "model"; ms: number }
  | { at: number; kind: "flight" }
  | { at: number; kind: "vouchers" };

const SCRIPT: Step[] = [
  { at: 400, kind: "user", text: "My flight to Bangkok was cancelled. Can you get me on the next one?" },
  { at: 1300, kind: "model", ms: 2010 },
  { at: 2100, kind: "tool", name: "find_alternative_flights_tool", ms: 1310, detail: "GET /api/flights/alternatives · same route, BUSINESS" },
  { at: 3000, kind: "flight" },
  { at: 3600, kind: "agent", text: "KQ886 leaves tomorrow at 21:55 with a business seat free. Shall I move you onto it?" },
  { at: 5200, kind: "user", text: "Yes please." },
  { at: 6000, kind: "tool", name: "reaccommodate_passenger_tool", ms: 1180, detail: "POST /api/reaccommodate · row lock on seat 1C" },
  { at: 6900, kind: "model", ms: 3090 },
  { at: 7600, kind: "vouchers" },
  { at: 8100, kind: "agent", text: "Done. You're in seat 1C, business. Seat 5G is released, and your meal, hotel and transfer vouchers are below." },
];
const LOOP_MS = 13_000;

export function HeroDemo() {
  const [t, setT] = useState(0);
  const [paused, setPaused] = useState(false);
  const started = useRef(performance.now());
  const reduced = typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  useEffect(() => {
    if (reduced) {
      setT(LOOP_MS);
      return;
    }
    if (paused) return;
    started.current = performance.now() - t;
    let raf = 0;
    const tick = () => {
      const e = performance.now() - started.current;
      setT(e % LOOP_MS);
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [paused, reduced]);

  const visible = SCRIPT.filter((s) => s.at <= t);
  const chat = visible.filter((s) => s.kind === "user" || s.kind === "agent" || s.kind === "flight" || s.kind === "vouchers");
  const trace = visible.filter((s) => s.kind === "tool" || s.kind === "model");
  const typing = !reduced && SCRIPT.some((s) => s.kind === "agent" && s.at > t && s.at - t < 900);
  const elapsed = trace.reduce((n, s) => n + ("ms" in s ? s.ms : 0), 0);

  return (
    <div className="window" onMouseEnter={() => setPaused(true)} onMouseLeave={() => setPaused(false)}>
      <div className="window-bar">
        <span className="dots"><i /><i /><i /></span>
        <span className="window-title">Kestrel · PNR <b>A27Z99</b> · Edwards</span>
        <span className="window-badge">KQ886 NBO → BKK <em>Cancelled · technical</em></span>
      </div>
      <div className="window-body">
        <aside className="win-side">
          <div className="side-label">Booking</div>
          <dl>
            <dt>Tier</dt><dd>Gold</dd>
            <dt>Cabin</dt><dd>Business</dd>
            <dt>Seat</dt><dd className={t >= 7600 ? "struck" : ""}>5G</dd>
            {t >= 7600 && <><dt>New seat</dt><dd className="ok">1C</dd></>}
            <dt>Status</dt><dd>{t >= 7600 ? <span className="tag ok">Re-accommodated</span> : <span className="tag bad">Disrupted</span>}</dd>
          </dl>
          <div className="side-label">Session</div>
          <p className="side-note">PNR + surname, HMAC token. The agent never sees database credentials.</p>
        </aside>

        <div className="win-chat" aria-live="polite">
          {chat.map((s, i) => {
            if (s.kind === "user") return <div key={i} className="msg user">{s.text}</div>;
            if (s.kind === "agent") return <div key={i} className="msg agent">{s.text}</div>;
            if (s.kind === "flight")
              return (
                <div key={i} className="card flight">
                  <div><b>KQ886</b> NBO → BKK</div>
                  <div className="muted">Tomorrow 21:55 · Boeing 787-8 · 3 business seats</div>
                </div>
              );
            return (
              <div key={i} className="card vouchers">
                <div className="voucher"><span>Meal × 4</span><code>KQ-MV-0496-VC</code></div>
                <div className="voucher"><span>Hotel · 1 night</span><code>R3_HOTEL</code></div>
                <div className="voucher"><span>Transfer</span><code>R3_TRANSPORT</code></div>
                <div className="voucher"><span>3,000 Asante pts</span><code>R5_GOODWILL</code></div>
              </div>
            );
          })}
          {typing && <div className="msg agent typing"><i /><i /><i /></div>}
        </div>

        <aside className="win-trace">
          <div className="side-label">Agent trace <span className="muted">{(elapsed / 1000).toFixed(1)} s</span></div>
          <ol>
            {trace.map((s, i) =>
              s.kind === "tool" ? (
                <li key={i} className="trace tool">
                  <span className="mono">{s.name}</span>
                  <span className="muted">{s.detail}</span>
                  <span className="ms">{(s.ms / 1000).toFixed(1)} s</span>
                </li>
              ) : (
                <li key={i} className="trace model">
                  <span>Model call</span>
                  <span className="ms">{((s as { ms: number }).ms / 1000).toFixed(1)} s</span>
                </li>
              ),
            )}
          </ol>
          {t >= 7600 && (
            <div className="audit">
              <div className="side-label">Audit row</div>
              <code>REACCOMMODATED · 5G → 1C · AGENT:A27Z99</code>
            </div>
          )}
        </aside>
      </div>
    </div>
  );
}
