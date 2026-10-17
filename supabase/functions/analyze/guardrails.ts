// Pure functions (no network, no database) that decide what the plant-health agent is allowed
// to do. Kept separate so they can be tested on their own.

export const MAX_STEP = 0.25;            // a single change may move a setting by at most 25%
export const COOLDOWN_HOURS = 24;        // at most one applied change per zone per day
export const MAX_PHOTO_AGE_HOURS = 12;   // do not decide from an old photo
export const MAX_SENSOR_AGE_HOURS = 3;   // do not decide from stale readings
export const MIN_INTERVAL_MIN = 1;
export const MAX_INTERVAL_MIN = 525600;
export const MIN_DURATION_SEC = 1;

export const STATUSES = ["healthy", "watch", "stressed", "critical", "unknown"] as const;
export const CONFIDENCES = ["low", "medium", "high"] as const;
export type Status = typeof STATUSES[number];
export type Confidence = typeof CONFIDENCES[number];

export interface AgentOutput {
  status: Status;
  confidence: Confidence;
  summary: string;
  observations: string[];
  recommendation: { interval_min?: number; duration_sec?: number; reason: string } | null;
}

function clean(s: unknown, max: number): string {
  return typeof s === "string" ? s.replace(/\s+/g, " ").trim().slice(0, max) : "";
}

// The model's output is untrusted text: check every field before using any of it.
export function validateAgentOutput(raw: unknown): { ok: true; value: AgentOutput } | { ok: false; error: string } {
  if (!raw || typeof raw !== "object") return { ok: false, error: "output is not an object" };
  const r = raw as Record<string, unknown>;
  if (!STATUSES.includes(r.status as Status)) return { ok: false, error: "bad status" };
  if (!CONFIDENCES.includes(r.confidence as Confidence)) return { ok: false, error: "bad confidence" };
  const summary = clean(r.summary, 500);
  if (!summary) return { ok: false, error: "missing summary" };

  const observations = Array.isArray(r.observations)
    ? r.observations.map((o) => clean(o, 200)).filter(Boolean).slice(0, 8)
    : [];

  let recommendation: AgentOutput["recommendation"] = null;
  if (r.recommendation && typeof r.recommendation === "object") {
    const rec = r.recommendation as Record<string, unknown>;
    const reason = clean(rec.reason, 400);
    const out: NonNullable<AgentOutput["recommendation"]> = { reason };
    for (const key of ["interval_min", "duration_sec"] as const) {
      const v = rec[key];
      if (v === undefined || v === null) continue;
      if (typeof v !== "number" || !Number.isFinite(v)) return { ok: false, error: `bad ${key}` };
      out[key] = Math.round(v);
    }
    if (reason && (out.interval_min !== undefined || out.duration_sec !== undefined)) recommendation = out;
  }

  return { ok: true, value: { status: r.status as Status, confidence: r.confidence as Confidence, summary, observations, recommendation } };
}

// Move `current` toward `wanted`, but never by more than MAX_STEP (always allowing at least +/-1,
// so small whole numbers such as a 2 second burst are not frozen), and always inside [min, max].
export function clampStep(current: number, wanted: number, min: number, max: number): number {
  const lo = Math.max(min, Math.min(current - 1, Math.ceil(current * (1 - MAX_STEP))));
  const hi = Math.min(max, Math.max(current + 1, Math.floor(current * (1 + MAX_STEP))));
  return Math.round(Math.min(Math.max(wanted, lo), hi));
}

export interface ProposalInput {
  current: { interval_min: number; duration_sec: number };
  maxOnSec: number;               // hardware ceiling for this zone's hardware type
  output: AgentOutput;
  avoidHardware: boolean;         // plant profile says "avoid" for this hardware type
  lastAppliedAt: Date | null;     // last proposal for this zone that a person approved
  hasPending: boolean;            // an unanswered proposal already exists for this zone
  photoTakenAt: Date;
  latestReadingAt: Date | null;
  now: Date;
}

export type ProposalResult =
  | { proposal: { proposed_settings: Record<string, number>; reason: string } }
  | { skip: string };

const hours = (a: Date, b: Date) => (a.getTime() - b.getTime()) / 3_600_000;

export function buildProposal(i: ProposalInput): ProposalResult {
  const rec = i.output.recommendation;
  if (!rec) return { skip: "no change recommended" };
  if (i.output.status === "critical") return { skip: "critical findings go to a person as an alert, not as a settings change" };
  if (i.output.confidence === "low") return { skip: "confidence too low to propose a change" };
  if (i.output.status === "unknown") return { skip: "status unknown" };
  if (i.avoidHardware) return { skip: "plant profile says to avoid this hardware; no changes proposed" };
  if (i.hasPending) return { skip: "a proposal is already waiting for approval" };
  if (hours(i.now, i.photoTakenAt) > MAX_PHOTO_AGE_HOURS) return { skip: "photo is too old" };
  if (!i.latestReadingAt || hours(i.now, i.latestReadingAt) > MAX_SENSOR_AGE_HOURS) return { skip: "sensor readings are missing or stale" };
  if (i.lastAppliedAt && hours(i.now, i.lastAppliedAt) < COOLDOWN_HOURS) return { skip: "a change was applied less than 24 hours ago" };

  const proposed: Record<string, number> = {};
  let limited = false;

  if (rec.interval_min !== undefined) {
    const v = clampStep(i.current.interval_min, rec.interval_min, MIN_INTERVAL_MIN, MAX_INTERVAL_MIN);
    if (v !== rec.interval_min) limited = true;
    if (v !== i.current.interval_min) proposed.interval_min = v;
  }
  if (rec.duration_sec !== undefined) {
    const v = clampStep(i.current.duration_sec, rec.duration_sec, MIN_DURATION_SEC, i.maxOnSec);
    if (v !== rec.duration_sec) limited = true;
    if (v !== i.current.duration_sec) proposed.duration_sec = v;
  }
  if (Object.keys(proposed).length === 0) return { skip: "recommended values are the same as the current settings" };

  const reason = limited ? `${rec.reason} (Change limited to a 25% step and the hardware safety limit.)` : rec.reason;
  return { proposal: { proposed_settings: proposed, reason } };
}

export interface ReadingRow { taken_at: string; temp_c: number | null; humidity_pct: number | null }

export function summarizeReadings(rows: ReadingRow[], now: Date) {
  const hum = rows.map((r) => r.humidity_pct).filter((v): v is number => v !== null && Number.isFinite(v));
  const tmp = rows.map((r) => r.temp_c).filter((v): v is number => v !== null && Number.isFinite(v));
  const stat = (v: number[]) => v.length
    ? { min: Math.min(...v), max: Math.max(...v), avg: Math.round((v.reduce((a, b) => a + b, 0) / v.length) * 10) / 10 }
    : null;
  const last = rows.length ? rows[rows.length - 1] : null;
  return {
    count: rows.length,
    humidity_pct: stat(hum),
    temp_c: stat(tmp),
    latest: last ? { taken_at: last.taken_at, humidity_pct: last.humidity_pct, temp_c: last.temp_c, minutes_ago: Math.round((now.getTime() - new Date(last.taken_at).getTime()) / 60000) } : null,
  };
}
