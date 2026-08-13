// Throwaway separability probe. NOT a detector — it never decides anything.
// The question: across the whole daily feature vector, how unusual are the two
// pre-onset days (2026-08-08, 08-09) compared with the healthy days? Reported as
// a RANK, because a rank cannot be tuned to fire on the one episode we have.
import { loadRows, loadIntervals, deriveFromIntervals } from "/s/analyze.js";

const DB = "/w/h3.db";
const rows = loadRows(DB);
deriveFromIntervals(rows, loadIntervals(DB));

const EPISODE_FROM = "2026-08-10";
const PRE = ["2026-08-08", "2026-08-09"];

// Direction of concern per feature: +1 = high is bad, -1 = low is bad.
const FEATURES = [
  ["restingHeartRate", +1], ["hrvMorning", -1], ["respiratoryRate", +1],
  ["awakeMin", +1], ["wristTempDeviation", +1], ["spo2Min", -1],
  ["sleepHours", -1], ["deepMin", -1], ["remMin", -1], ["heartRate", +1],
];

const median = (a) => { const s = [...a].sort((x, y) => x - y); const n = s.length;
  return n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2; };
const mad = (a, m) => { const d = median(a.map((v) => Math.abs(v - m))); return d || 1e-9; };
const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);

// Two reference frames. `local14` is what the live rule uses — the trailing two
// weeks, which a slow ramp contaminates with itself. `lagged` skips the week
// before the day being scored, so a gradual entry cannot eat its own baseline.
const FRAMES = {
  local14: (i) => rows.slice(Math.max(0, i - 14), i),
  lagged:  (i) => rows.slice(Math.max(0, i - 35), Math.max(0, i - 7)),
};

function zVector(i, frame) {
  const base = FRAMES[frame](i);
  if (base.length < 10) return null;
  const out = [];
  for (const [f, dir] of FEATURES) {
    const today = num(rows[i][f]);
    const vals = base.map((r) => num(r[f])).filter((v) => v !== null);
    if (today === null || vals.length < 8) { out.push(null); continue; }
    const m = median(vals);
    // 1.4826 puts MAD on the same scale as a standard deviation.
    out.push(((today - m) / (1.4826 * mad(vals, m))) * dir);
  }
  return out;
}

// Two aggregates over the same vector. `sumsq` is two-sided — "is this day odd
// at all". `dir` counts only deviations in the direction illness moves, which is
// the question actually being asked. Both average over the features present, so
// a day missing wrist temperature is not scored lower for it.
const agg = {
  sumsq: (z) => { const v = z.filter((x) => x !== null); return v.length ? v.reduce((a, b) => a + b * b, 0) / v.length : null; },
  dir:   (z) => { const v = z.filter((x) => x !== null); return v.length ? v.reduce((a, b) => a + Math.max(0, b) ** 2, 0) / v.length : null; },
};

function run(frame, kind, smooth) {
  const scored = [];
  for (let i = 0; i < rows.length; i++) {
    const z = zVector(i, frame);
    if (!z) continue;
    const s = agg[kind](z);
    if (s === null) continue;
    scored.push({ date: rows[i].date, s });
  }
  // Rolling mean over `smooth` days: the memoryless rule scores each day alone,
  // so this is the direct test of whether the trajectory carries what the point
  // does not.
  const byDate = new Map(scored.map((r) => [r.date, r.s]));
  const dates = scored.map((r) => r.date);
  const final = scored.map((r, idx) => {
    const win = dates.slice(Math.max(0, idx - smooth + 1), idx + 1).map((d) => byDate.get(d));
    return { date: r.date, s: win.reduce((a, b) => a + b, 0) / win.length };
  });

  // Rank only against healthy days. The episode itself is excluded from the
  // pool, and the two pre-onset days are ranked as if they were candidates.
  const pool = final.filter((r) => r.date < EPISODE_FROM);
  const sorted = [...pool].sort((a, b) => b.s - a.s);
  const rankOf = (d) => sorted.findIndex((r) => r.date === d) + 1;
  const onset = final.find((r) => r.date === EPISODE_FROM);
  return {
    n: pool.length,
    pre: PRE.map((d) => ({ d, rank: rankOf(d), s: byDate.get(d) })),
    onsetS: onset ? onset.s : null,
    top: sorted.slice(0, 3).map((r) => r.date),
  };
}

for (const frame of ["local14", "lagged"]) {
  for (const kind of ["sumsq", "dir"]) {
    for (const smooth of [1, 3]) {
      const r = run(frame, kind, smooth);
      const pre = r.pre.map((p) => `${p.d.slice(5)} rank ${p.rank}/${r.n}`).join("   ");
      console.log(`${frame.padEnd(8)} ${kind.padEnd(6)} smooth=${smooth}   ${pre}` +
                  `   | onset score ${r.onsetS?.toFixed(2)}  top healthy: ${r.top.map((d) => d.slice(5)).join(",")}`);
    }
  }
}
