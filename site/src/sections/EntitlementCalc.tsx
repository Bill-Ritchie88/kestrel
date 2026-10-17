import { useMemo, useState } from "react";
import { evaluate, ROUTES, type Reason, type Tier } from "../entitlements";

const REASONS: Reason[] = ["TECHNICAL", "CREW", "OPERATIONAL", "WEATHER", "ATC", "SECURITY", "POLITICAL"];
const TIERS: Tier[] = ["BLUE", "SILVER", "GOLD", "PLATINUM"];

export function EntitlementCalc() {
  const [routeId, setRouteId] = useState("AMS-NBO");
  const [reason, setReason] = useState<Reason>("TECHNICAL");
  const [tier, setTier] = useState<Tier>("GOLD");
  const [wait, setWait] = useState(26);

  const route = ROUTES.find((r) => r.id === routeId)!;
  const d = useMemo(() => evaluate(route, reason, tier, wait), [route, reason, tier, wait]);

  return (
    <div className="panel calc">
      <div className="calc-inputs">
        <label>
          <span>Route</span>
          <select value={routeId} onChange={(e) => setRouteId(e.target.value)}>
            {ROUTES.map((r) => <option key={r.id} value={r.id}>{r.origin} → {r.destination} · {r.km.toLocaleString()} km</option>)}
          </select>
        </label>
        <label>
          <span>Cause</span>
          <select value={reason} onChange={(e) => setReason(e.target.value as Reason)}>
            {REASONS.map((r) => <option key={r} value={r}>{r.toLowerCase()}</option>)}
          </select>
        </label>
        <label>
          <span>Asante tier</span>
          <select value={tier} onChange={(e) => setTier(e.target.value as Tier)}>
            {TIERS.map((t) => <option key={t} value={t}>{t.toLowerCase()}</option>)}
          </select>
        </label>
        <label className="range">
          <span>Wait for new flight <b>{wait} h</b></span>
          <input type="range" min={0} max={48} value={wait} onChange={(e) => setWait(Number(e.target.value))} aria-label="Wait in hours" />
        </label>
      </div>

      <div className="calc-out">
        <div className="calc-reg">
          {d.regulation ? <span className="tag ok">{d.regulation} applies</span> : <span className="tag">No EU/UK regulation</span>}
          <span className="muted">Distance band {d.band + 1} of 3</span>
        </div>
        <ul className="grants">
          {d.granted.map((g) => (
            <li key={g.rule}>
              <code>{g.rule}</code>
              <span className="g-label">{g.label}</span>
              <span className="g-value">{g.value}</span>
              <span className="g-basis">{g.basis}</span>
            </li>
          ))}
        </ul>
        {d.notes.length > 0 && (
          <ul className="notes">
            {d.notes.map((n) => <li key={n}>{n}</li>)}
          </ul>
        )}
      </div>
    </div>
  );
}
