import { useEffect, useRef, useState } from "react";

// LT-01 as an animation: twelve business passengers from the cancelled flight
// try to claim the last three business seats at the same moment. Each attempt
// takes a row lock (SELECT ... FOR UPDATE SKIP LOCKED in spirit); exactly three
// succeed and the rest are told, cleanly, that the seat is gone.

type Attempt = { id: number; pnr: string; seat: string | null; state: "waiting" | "locking" | "won" | "lost"; at: number };

const PNRS = ["A27Z99", "KQX89A", "M4T2QD", "R7HB2L", "Z9PKW3", "B3NQ7T", "H8LC2E", "P5VW9K", "T2JD4M", "W6RX1A", "C9GF3S", "N4YK8U"];
const SEATS = ["1A", "1C", "2D"];

function plan(): Attempt[] {
  const order = [...PNRS].sort(() => Math.random() - 0.5);
  return order.map((pnr, i) => ({ id: i, pnr, seat: null, state: "waiting", at: 150 + i * 70 + Math.random() * 120 }));
}

export function SeatRace() {
  const [attempts, setAttempts] = useState<Attempt[]>(() => plan().map((a) => ({ ...a })));
  const [running, setRunning] = useState(false);
  const [runs, setRuns] = useState(0);
  const timers = useRef<number[]>([]);

  const run = () => {
    timers.current.forEach(clearTimeout);
    timers.current = [];
    const p = plan();
    setAttempts(p);
    setRunning(true);
    const free = [...SEATS];
    const sorted = [...p].sort((a, b) => a.at - b.at);
    sorted.forEach((a, idx) => {
      timers.current.push(window.setTimeout(() => {
        setAttempts((all) => all.map((x) => (x.id === a.id ? { ...x, state: "locking" } : x)));
      }, a.at));
      timers.current.push(window.setTimeout(() => {
        const seat = free.shift() ?? null;
        setAttempts((all) => all.map((x) => (x.id === a.id ? { ...x, state: seat ? "won" : "lost", seat } : x)));
        if (idx === sorted.length - 1) {
          setRunning(false);
          setRuns((r) => r + 1);
        }
      }, a.at + 380));
    });
  };

  useEffect(() => () => timers.current.forEach(clearTimeout), []);

  const won = attempts.filter((a) => a.state === "won");
  const lost = attempts.filter((a) => a.state === "lost").length;

  return (
    <div className="panel race">
      <div className="panel-head">
        <span className="mono">reaccommodate_passenger_atomic</span>
        <button className="btn small" onClick={run} disabled={running}>{runs ? "Run again" : "Run load test"}</button>
      </div>
      <div className="race-seats">
        {SEATS.map((s) => {
          const owner = won.find((a) => a.seat === s);
          return (
            <div key={s} className={`seat ${owner ? "taken" : ""}`}>
              <span className="seat-no">{s}</span>
              <span className="seat-owner mono">{owner?.pnr ?? "free"}</span>
            </div>
          );
        })}
      </div>
      <ul className="race-list">
        {attempts.map((a) => (
          <li key={a.id} className={`att ${a.state}`}>
            <span className="mono">{a.pnr}</span>
            <span className="att-state">
              {a.state === "waiting" && "queued"}
              {a.state === "locking" && "row lock…"}
              {a.state === "won" && `seat ${a.seat}`}
              {a.state === "lost" && "SEAT_UNAVAILABLE · audited"}
            </span>
          </li>
        ))}
      </ul>
      <div className="panel-foot">
        <span><b>{won.length}</b> rebooked</span>
        <span><b>{lost}</b> refused cleanly</span>
        <span><b>0</b> seats held twice</span>
      </div>
    </div>
  );
}
