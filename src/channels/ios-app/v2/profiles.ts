// Parse a projected agent profile (groups/global/profiles/<key>.md) into the
// shape the /ios/state board renders. Frontmatter is a tiny convention:
// `updated:`, `summary:`, and (Greg only) inline `levels:` / `recovery7d:`.
// Body after frontmatter = accordion detail (raw markdown).
export interface Levels {
  energy: number | null;
  stress: number | null;
  recovery: number | null;
  readiness: number | null;
}
export interface ParsedProfile {
  key: string;
  updated: string | null;
  summary: string | null;
  detail: string;
  levels: Levels | null;
  recovery7d: number[] | null;
}

function parseInlineLevels(s: string): Levels | null {
  const num = (k: string): number | null => {
    const m = s.match(new RegExp(`${k}\\s*:\\s*(-?\\d+(?:\\.\\d+)?)`));
    return m ? Number(m[1]) : null;
  };
  const energy = num('energy'),
    stress = num('stress'),
    recovery = num('recovery'),
    readiness = num('readiness');
  if (energy === null && stress === null && recovery === null && readiness === null) return null;
  return { energy, stress, recovery, readiness };
}

export function parseProfile(key: string, text: string): ParsedProfile {
  let updated: string | null = null;
  let summary: string | null = null;
  let levels: Levels | null = null;
  let recovery7d: number[] | null = null;
  let detail = text;

  const fm = text.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  if (fm) {
    const [, head, body] = fm;
    detail = body;
    for (const line of head.split('\n')) {
      const m = line.match(/^([A-Za-z0-9_]+)\s*:\s*(.*)$/);
      if (!m) continue;
      const [, k, v] = m;
      if (k === 'updated') updated = v.trim();
      else if (k === 'summary') summary = v.trim();
      else if (k === 'levels') levels = parseInlineLevels(v);
      else if (k === 'recovery7d') {
        try {
          recovery7d = JSON.parse(v.trim());
        } catch {
          recovery7d = null;
        }
      }
    }
  }
  return { key, updated, summary, detail, levels, recovery7d };
}
