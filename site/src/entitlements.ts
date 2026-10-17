// A browser port of src/kestrel/entitlements.py, reduced to the inputs the
// demo exposes. The figures and rule IDs are the engine's own; the scenario
// fixes the original departure at 22:00 local and assumes the passenger was
// told less than seven days ahead.

export type Tier = "BLUE" | "SILVER" | "GOLD" | "PLATINUM";
export type Reason = "TECHNICAL" | "CREW" | "OPERATIONAL" | "WEATHER" | "ATC" | "SECURITY" | "POLITICAL";

export interface Route {
  id: string;
  origin: string;
  destination: string;
  km: number;
  region: "KE" | "EU" | "UK";
}

export const ROUTES: Route[] = [
  { id: "NBO-BKK", origin: "NBO", destination: "BKK", km: 7186, region: "KE" },
  { id: "NBO-MBA", origin: "NBO", destination: "MBA", km: 441, region: "KE" },
  { id: "AMS-NBO", origin: "AMS", destination: "NBO", km: 6646, region: "EU" },
  { id: "LHR-NBO", origin: "LHR", destination: "NBO", km: 6818, region: "UK" },
];

const CONTROLLABLE: Reason[] = ["TECHNICAL", "CREW", "OPERATIONAL"];
const COMPENSATION = { EU: { currency: "EUR", bands: [250, 400, 600] }, UK: { currency: "GBP", bands: [220, 350, 520] } };
const MEAL = { KE: [2500, "KES"], EU: [15, "EUR"], UK: [12, "GBP"] } as const;
const POINTS: Record<Tier, number> = { BLUE: 1000, SILVER: 2000, GOLD: 3000, PLATINUM: 5000 };
const ORIGINAL_DEPARTURE_HOUR = 22;

export interface Outcome {
  rule: string;
  label: string;
  value: string;
  basis: string;
  status: "INFO" | "ISSUED" | "ELIGIBLE";
}

export interface Decision {
  regulation: "EU261" | "UK261" | null;
  band: 0 | 1 | 2;
  granted: Outcome[];
  notes: string[];
}

const PROJECT = "Kestrel project policy";

export function evaluate(route: Route, reason: Reason, tier: Tier, waitHours: number): Decision {
  const regulation = route.region === "EU" ? "EU261" : route.region === "UK" ? "UK261" : null;
  const band = (route.km <= 1500 ? 0 : route.km <= 3500 ? 1 : 2) as 0 | 1 | 2;
  const reg = regulation ?? "";
  const granted: Outcome[] = [];
  const notes: string[] = [];

  granted.push({
    rule: "R1_REROUTING", label: "Re-routing", value: "Same route, same cabin", status: "INFO",
    basis: regulation ? `${reg} Art. 5(1)(a), 8(1)(b)` : PROJECT,
  });

  const threshold = regulation ? 0 : 2;
  if (waitHours >= threshold) {
    const meals = Math.min(4, Math.max(1, Math.ceil(waitHours / 6)));
    const [amount, currency] = MEAL[route.region];
    granted.push({
      rule: "R2_MEAL", label: "Meal vouchers", value: `${meals} × ${amount.toLocaleString()} ${currency}`, status: "ISSUED",
      basis: regulation ? `${reg} Art. 9(1)(a)` : PROJECT,
    });
  } else {
    notes.push(`No meal voucher: a ${waitHours} h wait is under the ${threshold} h threshold.`);
  }

  const nights = Math.floor((ORIGINAL_DEPARTURE_HOUR + waitHours) / 24);
  if (nights >= 1 && waitHours >= 6) {
    granted.push({
      rule: "R3_HOTEL", label: "Hotel", value: `${nights} night${nights > 1 ? "s" : ""}`, status: "ISSUED",
      basis: regulation ? `${reg} Art. 9(1)(b)` : PROJECT,
    });
    granted.push({
      rule: "R3_TRANSPORT", label: "Airport–hotel transfer", value: "Return", status: "ISSUED",
      basis: regulation ? `${reg} Art. 9(1)(c)` : PROJECT,
    });
  } else {
    notes.push("No hotel: the new flight leaves the same night.");
  }

  const controllable = CONTROLLABLE.includes(reason);
  if (!regulation) {
    notes.push("No cash compensation: the flight does not depart from the EU or UK (Art. 3(1)).");
  } else if (!controllable) {
    notes.push(`No cash compensation: ${reason.toLowerCase()} is an extraordinary circumstance (Art. 5(3)).`);
  } else if (waitHours < 2) {
    notes.push("No cash compensation: re-routed within the Art. 5(1)(c)(iii) window.");
  } else {
    const table = COMPENSATION[route.region as "EU" | "UK"];
    let amount = table.bands[band];
    const halved = waitHours <= [2, 3, 4][band];
    if (halved) amount /= 2;
    granted.push({
      rule: "R4_COMPENSATION", label: "Cash compensation", value: `${amount} ${table.currency}`, status: "ELIGIBLE",
      basis: `${reg} Art. 7(1)${halved ? ", 7(2)" : ""}`,
    });
  }

  if (controllable) {
    granted.push({
      rule: "R5_GOODWILL", label: "Asante Rewards points", value: `${POINTS[tier].toLocaleString()} pts`, status: "ISSUED",
      basis: PROJECT,
    });
  } else {
    notes.push("No goodwill points: the cause was outside the airline's control.");
  }

  return { regulation, band, granted, notes };
}
