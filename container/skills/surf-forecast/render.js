#!/usr/bin/env node
/**
 * Generic surf-forecast chart renderer.
 *
 * Usage:
 *   node render.js <input.json> <output.jpg>
 *
 * Input JSON schema (all fields required unless marked optional):
 * {
 *   "title":        "КАНГУ · 1 ИЮНЯ · УТРО",
 *   "byline":       "by Jarvis",                       // optional, default "by Jarvis"
 *   "tidePoints":   [{ "h": 4.05, "v": 0.82 }, ...],   // hours-of-day for cubic spline; include 1-2 extrapolated points outside [0,24] for smooth edges
 *   "tideRange":    [-0.1, 2.7],                       // optional [min, max] for vertical axis. Default auto from points.
 *   "tideMarkers":  [{ "h": 4.05, "v": 0.82, "t": "04:03", "val": "0.8 м", "above": false }, ...],
 *   "bestWindow":   { "startH": 6.0, "endH": 7.5, "label": "лучшее окно" },  // optional
 *   "waveHours":    [5, 6, 7, 8, 9],
 *   "waveH":        [0.98, 0.98, 0.98, 0.98, 0.96],
 *   "windSpeed":    [10.6, 10.7, 11.3, 10.3, 10.0],
 *   "windDir":      ["NE", "NE", "NE", "NE", "NE"],
 *   "windOffshore": [true, true, true, true, true],     // precomputed per hour by skill (shore_facing_deg known)
 *   "waveFooter":   "период: 11 с  ·  NE кросс-оффшор всё утро",
 *   "spots":        [{ "name": "Batu Bolong", "rating": "green" | "yellow" | "red", "h": "1.0 м", "p": "11 с", "hm": 0.98, "t": 11, "note": "..." }, ...],
 *   "footer":       "лучшее окно  06:00 – 07:30  ·  BB/Per до 08:30",
 *   "sources":      "Open-Meteo · surf-forecast.com"   // optional, default "Open-Meteo"
 * }
 */

const { createCanvas } = require('@napi-rs/canvas');
const fs = require('fs');

if (process.argv.length < 4) {
  console.error('Usage: node render.js <input.json> <output.jpg>');
  process.exit(2);
}
const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const outPath = process.argv[3];

// --- Layout constants ---
const SCALE = 1.5;
const BW = 750, BH = 1220;
const W = Math.round(BW * SCALE), H = Math.round(BH * SCALE);
const PAD = 32;
const CW = BW - PAD * 2;

const canvas = createCanvas(W, H);
const ctx = canvas.getContext('2d');
ctx.scale(SCALE, SCALE);

// --- Palette ---
const BG = '#0a1628', CARD = '#0f2044', ACCENT = '#1a3a6e';
const BLUE = '#4a9eff', CYAN = '#00d4ff', GREEN = '#00e676', YELLOW = '#ffcc02', RED = '#ff5252';
const TEXT = '#e8f4ff', MUTED = '#7a9fc0';

// --- Helpers ---
function naturalCubicSpline(xs, ys) {
  const n = xs.length - 1;
  const h = [], alpha = [], l = [], mu = [], z = [], c = [], b = [], d = [];
  for (let i = 0; i < n; i++) h[i] = xs[i + 1] - xs[i];
  for (let i = 1; i < n; i++)
    alpha[i] = (3 / h[i]) * (ys[i + 1] - ys[i]) - (3 / h[i - 1]) * (ys[i] - ys[i - 1]);
  l[0] = 1; mu[0] = 0; z[0] = 0;
  for (let i = 1; i < n; i++) {
    l[i] = 2 * (xs[i + 1] - xs[i - 1]) - h[i - 1] * mu[i - 1];
    mu[i] = h[i] / l[i];
    z[i] = (alpha[i] - h[i - 1] * z[i - 1]) / l[i];
  }
  l[n] = 1; z[n] = 0; c[n] = 0;
  for (let j = n - 1; j >= 0; j--) {
    c[j] = z[j] - mu[j] * c[j + 1];
    b[j] = (ys[j + 1] - ys[j]) / h[j] - h[j] * (c[j + 1] + 2 * c[j]) / 3;
    d[j] = (c[j + 1] - c[j]) / (3 * h[j]);
  }
  return (x) => {
    let i = n - 1;
    for (let j = 0; j < n; j++) { if (x <= xs[j + 1]) { i = j; break; } }
    const dx = x - xs[i];
    return ys[i] + b[i] * dx + c[i] * dx * dx + d[i] * dx * dx * dx;
  };
}

function roundRect(c, x, y, w, h, r) {
  c.beginPath();
  c.moveTo(x + r, y); c.lineTo(x + w - r, y);
  c.quadraticCurveTo(x + w, y, x + w, y + r);
  c.lineTo(x + w, y + h - r);
  c.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
  c.lineTo(x + r, y + h);
  c.quadraticCurveTo(x, y + h, x, y + h - r);
  c.lineTo(x, y + r);
  c.quadraticCurveTo(x, y, x + r, y);
  c.closePath();
}

function energyDots(hm, t) {
  const e = hm * hm * t;
  if (e > 40) return 5;
  if (e > 28) return 4;
  if (e > 18) return 3;
  if (e > 8) return 2;
  return 1;
}

function ratingColor(rating) {
  if (rating === 'green') return GREEN;
  if (rating === 'yellow') return YELLOW;
  if (rating === 'red') return RED;
  return MUTED;
}

// --- Inputs ---
const {
  title,
  byline = 'by Jarvis',
  tidePoints,
  tideRange,
  tideMarkers = [],
  bestWindow,
  waveHours,
  waveH,
  windSpeed,
  windDir,
  windOffshore,
  waveFooter = '',
  spots = [],
  footer = '',
  sources = 'Open-Meteo',
} = input;

const tideSpline = naturalCubicSpline(
  tidePoints.map((p) => p.h),
  tidePoints.map((p) => p.v),
);
const tideMin = tideRange ? tideRange[0] : Math.min(...tidePoints.map((p) => p.v)) - 0.1;
const tideMax = tideRange ? tideRange[1] : Math.max(...tidePoints.map((p) => p.v)) + 0.3;
const tideSpan = Math.max(0.1, tideMax - tideMin);

// --- Render: BG + header ---
ctx.fillStyle = BG;
ctx.fillRect(0, 0, BW, BH);

ctx.fillStyle = CARD;
ctx.fillRect(0, 0, BW, 64);
ctx.fillStyle = CYAN;
ctx.font = 'bold 30px sans-serif';
ctx.fillText(title, PAD, 44);
ctx.fillStyle = MUTED;
ctx.font = '16px sans-serif';
ctx.textAlign = 'right';
ctx.fillText(byline, BW - PAD, 42);
ctx.textAlign = 'left';

// --- Render: Tides ---
let curY = 78;
const tH = 175;

ctx.fillStyle = CARD;
roundRect(ctx, PAD - 10, curY - 10, CW + 20, tH + 62, 14); ctx.fill();

ctx.fillStyle = TEXT;
ctx.font = 'bold 18px sans-serif';
ctx.fillText('ПРИЛИВЫ', PAD, curY + 18);

const tX = PAD, tW = CW;
const tx = (hv) => tX + (hv / 24) * tW;
const ty = (v) => curY + 26 + tH - ((v - tideMin) / tideSpan) * tH;

// best-window band
if (bestWindow) {
  ctx.fillStyle = 'rgba(0, 230, 118, 0.15)';
  ctx.fillRect(tx(bestWindow.startH), curY + 22, tx(bestWindow.endH) - tx(bestWindow.startH), tH + 2);
  ctx.strokeStyle = 'rgba(0, 230, 118, 0.75)';
  ctx.lineWidth = 1.5; ctx.setLineDash([5, 3]);
  ctx.beginPath();
  ctx.moveTo(tx(bestWindow.startH), curY + 22); ctx.lineTo(tx(bestWindow.startH), curY + 22 + tH + 2);
  ctx.moveTo(tx(bestWindow.endH), curY + 22); ctx.lineTo(tx(bestWindow.endH), curY + 22 + tH + 2);
  ctx.stroke(); ctx.setLineDash([]);
  ctx.fillStyle = GREEN;
  ctx.font = 'bold 15px sans-serif';
  ctx.textAlign = 'center';
  ctx.fillText(bestWindow.label || 'лучшее окно', (tx(bestWindow.startH) + tx(bestWindow.endH)) / 2, curY + 42);
  ctx.textAlign = 'left';
}

// tide curve fill
const S = 400;
ctx.beginPath();
for (let i = 0; i <= S; i++) {
  const hv = (i / S) * 24, x = tx(hv), y = ty(tideSpline(hv));
  i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
}
ctx.lineTo(tx(24), ty(tideMin)); ctx.lineTo(tx(0), ty(tideMin)); ctx.closePath();
const grad = ctx.createLinearGradient(0, curY + 26, 0, curY + 26 + tH);
grad.addColorStop(0, 'rgba(0,212,255,0.28)');
grad.addColorStop(1, 'rgba(0,212,255,0.02)');
ctx.fillStyle = grad; ctx.fill();

// tide curve stroke
ctx.beginPath();
for (let i = 0; i <= S; i++) {
  const hv = (i / S) * 24, x = tx(hv), y = ty(tideSpline(hv));
  i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
}
ctx.strokeStyle = CYAN; ctx.lineWidth = 2.5; ctx.stroke();

// 1 m and 2 m level lines (auto-skip if outside tideRange)
[1.0, 2.0].forEach((level) => {
  if (level < tideMin || level > tideMax) return;
  const ly = ty(level);
  ctx.strokeStyle = 'rgba(122,159,192,0.45)';
  ctx.lineWidth = 1;
  ctx.setLineDash([6, 4]);
  ctx.beginPath(); ctx.moveTo(tX, ly); ctx.lineTo(tX + tW, ly); ctx.stroke();
  ctx.setLineDash([]);
  ctx.fillStyle = MUTED; ctx.font = '12px sans-serif';
  ctx.textAlign = 'right';
  ctx.fillText(level.toFixed(0) + ' м', tX + tW - 4, ly - 3);
  ctx.textAlign = 'left';
});

// tide markers
tideMarkers.forEach(({ h: mh, v, t, val, above }) => {
  const x = tx(mh), y = ty(v);
  ctx.strokeStyle = 'rgba(0,212,255,0.35)'; ctx.lineWidth = 3;
  ctx.beginPath(); ctx.arc(x, y, 9, 0, Math.PI * 2); ctx.stroke();
  ctx.fillStyle = CYAN;
  ctx.beginPath(); ctx.arc(x, y, 5, 0, Math.PI * 2); ctx.fill();
  ctx.strokeStyle = 'rgba(0,212,255,0.5)'; ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(x, above ? y - 10 : y + 10);
  ctx.lineTo(x, above ? y - 24 : y + 24);
  ctx.stroke();
  ctx.textAlign = 'center';
  ctx.fillStyle = TEXT; ctx.font = 'bold 15px sans-serif';
  ctx.fillText(t, x, above ? y - 28 : y + 38);
  ctx.fillStyle = CYAN; ctx.font = '14px sans-serif';
  ctx.fillText(val, x, above ? y - 12 : y + 53);
  ctx.textAlign = 'left';
});

// hour grid
for (let h = 0; h <= 24; h += 3) {
  const x = tx(h);
  ctx.strokeStyle = 'rgba(90,127,168,0.35)'; ctx.lineWidth = 1;
  ctx.beginPath(); ctx.moveTo(x, curY + 24); ctx.lineTo(x, curY + 26 + tH); ctx.stroke();
  ctx.fillStyle = MUTED; ctx.font = '14px sans-serif';
  ctx.textAlign = 'center';
  ctx.fillText(String(h).padStart(2, '0'), x, curY + 26 + tH + 20);
  ctx.textAlign = 'left';
}

// --- Render: Wave ---
curY += tH + 72;
const wH2 = 100;
const barSlot = CW / waveHours.length;
const barW2 = 70;
const waveMax = Math.max(2.0, ...waveH) * 1.1;

ctx.fillStyle = CARD;
roundRect(ctx, PAD - 10, curY - 10, CW + 20, wH2 + 86, 14); ctx.fill();

ctx.fillStyle = TEXT;
ctx.font = 'bold 18px sans-serif';
ctx.fillText('ВОЛНА · УТРЕННЕЕ ОКНО', PAD, curY + 18);

waveHours.forEach((h, i) => {
  const cx = PAD + i * barSlot + barSlot / 2;
  const bh = (waveH[i] / waveMax) * wH2;
  const y = curY + 28 + wH2 - bh;
  const isOff = windOffshore[i];

  ctx.fillStyle = isOff ? 'rgba(0,230,118,0.8)' : 'rgba(74,158,255,0.75)';
  roundRect(ctx, cx - barW2 / 2, y, barW2, bh, 8); ctx.fill();

  ctx.fillStyle = TEXT; ctx.font = 'bold 24px sans-serif'; ctx.textAlign = 'center';
  ctx.fillText(waveH[i].toFixed(1) + ' м', cx, y - 10);

  ctx.fillStyle = TEXT; ctx.font = 'bold 18px sans-serif';
  ctx.fillText(h + ':00', cx, curY + 28 + wH2 + 24);

  ctx.fillStyle = isOff ? GREEN : BLUE; ctx.font = '15px sans-serif';
  ctx.fillText(windDir[i] + ' ' + windSpeed[i], cx, curY + 28 + wH2 + 44);

  ctx.textAlign = 'left';
});

ctx.fillStyle = MUTED; ctx.font = '15px sans-serif';
ctx.textAlign = 'center';
ctx.fillText(waveFooter, BW / 2, curY + 28 + wH2 + 68);
ctx.textAlign = 'left';

// --- Render: Spots ---
curY += wH2 + 108;
const cardH = 140;
const cardGap = 14;

ctx.fillStyle = TEXT; ctx.font = 'bold 18px sans-serif';
ctx.fillText('СПОТЫ', PAD, curY);
curY += 16;

spots.forEach((spot, i) => {
  const y = curY + i * (cardH + cardGap);
  const color = ratingColor(spot.rating);

  ctx.fillStyle = ACCENT;
  roundRect(ctx, PAD - 10, y, CW + 20, cardH, 12); ctx.fill();

  ctx.fillStyle = color;
  roundRect(ctx, PAD - 10, y, 8, cardH, 12); ctx.fill();

  ctx.fillStyle = color;
  ctx.beginPath(); ctx.arc(PAD + 22, y + 38, 15, 0, Math.PI * 2); ctx.fill();

  ctx.fillStyle = TEXT; ctx.font = 'bold 22px sans-serif';
  ctx.fillText(spot.name, PAD + 48, y + 45);

  ctx.fillStyle = CYAN; ctx.font = 'bold 19px sans-serif';
  ctx.fillText(spot.h + '  ·  ' + spot.p, PAD + 20, y + 78);

  const dots = energyDots(spot.hm, spot.t);
  ctx.fillStyle = MUTED; ctx.font = '13px sans-serif';
  ctx.fillText('энергия', PAD + 20, y + 102);
  for (let d = 0; d < 5; d++) {
    ctx.fillStyle = d < dots ? color : 'rgba(120,160,200,0.25)';
    ctx.beginPath(); ctx.arc(PAD + 100 + d * 22, y + 97, 7, 0, Math.PI * 2); ctx.fill();
  }

  ctx.fillStyle = '#b8d8f0'; ctx.font = '17px sans-serif';
  ctx.fillText(spot.note, PAD + 20, y + 124);
});

// --- Render: Footer ---
curY += spots.length * (cardH + cardGap) + 18;
ctx.fillStyle = MUTED; ctx.font = '14px sans-serif';
ctx.fillText(sources, PAD, curY);
if (footer) {
  ctx.fillStyle = GREEN; ctx.font = 'bold 16px sans-serif';
  ctx.textAlign = 'right';
  ctx.fillText(footer, BW - PAD, curY);
  ctx.textAlign = 'left';
}

// --- Write ---
const buf = canvas.toBuffer('image/jpeg', { quality: 93 });
fs.writeFileSync(outPath, buf);
console.log(`done ${W}x${H} → ${outPath}`);
