export interface SummaryCfg {
  tz: string;
  windowStartMin: number; // minutes-of-day, inclusive
  windowEndMin: number; // minutes-of-day; also the hard deadline
  quietMs: number; // settle: fire when no new card for this long
}

// Morning publish cron is `45 8 * * *` in the agent TZ (Asia/Makassar). Window
// 08:40–09:15 brackets the batch with margin; v1 owner-only uses this constant
// (multi-person would resolve TZ per person later).
export const DEFAULT_SUMMARY_CFG: SummaryCfg = {
  tz: 'Asia/Makassar',
  windowStartMin: 8 * 60 + 40, // 520
  windowEndMin: 9 * 60 + 15, // 555
  quietMs: 3 * 60 * 1000, // 180000
};

export interface DecideInput {
  nowMs: number;
  cardMtimesMs: number[];
  lastNotifiedDate: string | null; // YYYY-MM-DD in cfg.tz
  cfg: SummaryCfg;
}

export interface DecideResult {
  fire: boolean;
  count: number;
  today: string; // YYYY-MM-DD in cfg.tz (for persisting on fire)
}

// --- TZ helpers (pure; epoch in, derived fields out) ---
function partsInTz(ms: number, tz: string): { date: string; minutes: number } {
  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone: tz,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  });
  const p: Record<string, string> = {};
  for (const part of fmt.formatToParts(new Date(ms))) p[part.type] = part.value;
  const date = `${p.year}-${p.month}-${p.day}`;
  let hour = parseInt(p.hour, 10);
  if (hour === 24) hour = 0; // some engines emit 24 for midnight
  const minutes = hour * 60 + parseInt(p.minute, 10);
  return { date, minutes };
}

export function decideSummaryNotify(input: DecideInput): DecideResult {
  const { nowMs, cardMtimesMs, lastNotifiedDate, cfg } = input;
  const now = partsInTz(nowMs, cfg.tz);
  const today = now.date;

  if (lastNotifiedDate === today) return { fire: false, count: 0, today };

  // Cards whose projection landed today, within the morning window.
  const morning = cardMtimesMs.filter((ms) => {
    const p = partsInTz(ms, cfg.tz);
    return p.date === today && p.minutes >= cfg.windowStartMin && p.minutes <= cfg.windowEndMin;
  });
  if (morning.length === 0) return { fire: false, count: 0, today };

  const newest = Math.max(...morning);
  const settled = nowMs - newest >= cfg.quietMs;
  const pastDeadline = now.minutes >= cfg.windowEndMin;

  return { fire: settled || pastDeadline, count: morning.length, today };
}

export function pluralRu(n: number): string {
  const noun = ((): string => {
    const mod100 = n % 100;
    const mod10 = n % 10;
    if (mod100 >= 11 && mod100 <= 14) return 'карточек';
    if (mod10 === 1) return 'карточка';
    if (mod10 >= 2 && mod10 <= 4) return 'карточки';
    return 'карточек';
  })();
  return `${n} ${noun}`;
}
