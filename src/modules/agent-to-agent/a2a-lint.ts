/**
 * Build-time consistency check for the agent contract layer.
 *
 * Three things check the protocol, at three different moments: this lint (build),
 * `public-profiles.ts` (fragment projection), and the runtime a2a gate
 * (`agent-route.ts`). The gate catches "a skill sends what the receiver does not
 * accept" and bounces. It cannot catch the reverse — "the receiver declares what
 * nobody sends" — because nothing ever arrives to judge. That reverse drift is
 * what let 11 of 15 declared kinds rot into fossils. This is where it dies.
 *
 * It also closes the checker's own blind spot: `readAgentDescriptor` reports a
 * REJECTED field (malformed JSON) and an ABSENT field identically — both come
 * back `undefined`. Every rule below treats an absent `a2a_in` as a deliberate,
 * silent policy choice (fail-open by design) and stays quiet about it. Without
 * `malformed_descriptor` telling the two apart, a typo that silently opens the
 * gate is invisible to the one tool built to catch exactly that class of drift.
 *
 * Pure: no filesystem, no DB. Callers gather the input (see `lint-scan.ts`) so
 * the rules stay testable on fixtures, which matters because `groups/` is
 * gitignored and installation-specific — the repo cannot assert on real agents.
 */
import type { AgentDescriptor, KindContract } from '../../agent-registry.js';

/** One `<message to="X" kind="Y">` found in a skill or CLAUDE.md. */
export interface A2aSend {
  from: string;
  to: string;
  kind: string;
  /** Where it was found, for the message. e.g. `payne/skills/chat-log`. */
  where: string;
}

/** One `profiles/<target>.md` reference found in a skill or CLAUDE.md. */
export interface FragmentRef {
  from: string;
  target: string;
  where: string;
}

/** A field the reader REJECTED — present in the raw JSON, gone from the descriptor. */
export interface RejectedField {
  folder: string;
  field: string;
}

export interface LintInput {
  /** folder → descriptor, null when absent or unparseable. */
  descriptors: Record<string, AgentDescriptor | null>;
  sends: A2aSend[];
  /** agent_destinations rows with target_type='agent', resolved to folders. */
  edges: Array<{ from: string; to: string }>;
  fragmentRefs: FragmentRef[];
  rejected: RejectedField[];
}

export interface LintFinding {
  severity: 'error' | 'warn';
  code: string;
  msg: string;
}

/**
 * Keys `isKindContract`/`isPublishContract` require ("has at least"). Anything
 * else surviving on the object is either a genuine typo (`replay` for `reply`)
 * or dead weight — the reader passes it through untouched (not its job to
 * whitelist), the registry publishes it verbatim, and nothing downstream ever
 * reads it. `reply: null` (as opposed to omitted) fails `isKindContract` at the
 * registry layer already and disarms the whole file — that case is caught by
 * `malformed_descriptor`, not here; this rule is for keys that squeak past the
 * shape check.
 */
const KIND_KEYS = new Set(['desc', 'from', 'fields', 'reply']);
const PUBLISH_KEYS = new Set(['desc', 'fields', 'optional']);

export function lintA2a(input: LintInput): LintFinding[] {
  const out: LintFinding[] = [];
  const folders = new Set(Object.keys(input.descriptors));
  const hasEdge = new Set(input.edges.map((e) => `${e.from}→${e.to}`));
  const sent = new Set(input.sends.map((s) => `${s.to}:${s.kind}`));
  const sentBy = new Set(input.sends.map((s) => `${s.from}→${s.to}:${s.kind}`));

  const kindsOf = (folder: string): Record<string, KindContract> => input.descriptors[folder]?.a2a_in ?? {};

  // readAgentDescriptor reports a rejected field and an absent one identically —
  // both come back undefined. For a2a_in those mean opposite things: an absent
  // one is a deliberate fail-open, a rejected one is a wire nobody chose to open.
  // Every other rule here treats a disarmed target as policy and stays silent,
  // so without this the one defect that silently opens the gate is the one thing
  // this lint cannot see.
  for (const r of input.rejected) {
    const disarmed = r.field === 'a2a_in';
    out.push({
      severity: 'error',
      code: 'malformed_descriptor',
      msg:
        `${r.folder}: agent.json объявляет «${r.field}», но ридер его отбросил как негодный` +
        (disarmed ? ' — ГЕЙТ РАЗОРУЖЁН, агент сейчас принимает что угодно.' : '.') +
        ` Причина — в warning'е agent-registry в логе хоста.`,
    });
  }

  for (const s of input.sends) {
    if (!folders.has(s.to)) {
      out.push({ severity: 'error', code: 'unknown_target', msg: `${s.where}: шлёт «${s.to}» — такого агента нет.` });
      continue;
    }
    const d = input.descriptors[s.to];
    // A null/absent a2a_in means the target DISARMED its gate (fail-open). It
    // accepts anything, so a send to it cannot be wrong — do not invent errors.
    if (!d?.a2a_in) continue;
    const c = d.a2a_in[s.kind];
    if (!c) {
      out.push({
        severity: 'error',
        code: 'unknown_kind',
        msg: `${s.where}: шлёт kind="${s.kind}" к «${s.to}», который его не принимает — отскочит в рантайме. Легальные: ${Object.keys(d.a2a_in).join(', ') || '(нет)'}.`,
      });
      continue;
    }
    if (!c.from.includes(s.from)) {
      out.push({
        severity: 'error',
        code: 'undeclared_sender',
        msg: `${s.where}: «${s.from}» шлёт kind="${s.kind}" к «${s.to}», но не назван в его from: [${c.from.join(', ')}].`,
      });
    }
  }

  for (const [folder, d] of Object.entries(input.descriptors)) {
    if (!d) continue;
    if (!d.role) out.push({ severity: 'warn', code: 'no_role', msg: `${folder}: нет role — в реестре пустая роль.` });
    if (!d.publishes) {
      out.push({
        severity: 'warn',
        code: 'no_publishes',
        msg: `${folder}: нет publishes — его фрагмент читают вслепую.`,
      });
    } else {
      const labels = new Set(Object.keys(d.publishes.fields));
      for (const o of d.publishes.optional ?? []) {
        if (!labels.has(o)) {
          out.push({
            severity: 'error',
            code: 'optional_not_in_fields',
            msg: `${folder}: publishes.optional называет «${o}», которого нет в fields.`,
          });
        }
      }
      for (const key of Object.keys(d.publishes)) {
        if (!PUBLISH_KEYS.has(key)) {
          out.push({
            severity: 'error',
            code: 'unknown_contract_key',
            msg: `${folder}: publishes содержит незнакомый ключ «${key}» — ридер пропустит его как есть, реестр опубликует его в agents.md, и его никто никогда не прочитает.`,
          });
        }
      }
    }

    for (const [kind, c] of Object.entries(kindsOf(folder))) {
      for (const key of Object.keys(c)) {
        if (!KIND_KEYS.has(key)) {
          out.push({
            severity: 'error',
            code: 'unknown_contract_key',
            msg: `${folder}.${kind}: контракт содержит незнакомый ключ «${key}» — ридер пропустит его как есть, реестр опубликует его в agents.md, и его никто никогда не прочитает. Если это опечатка в «reply» — она не сработает.`,
          });
        }
      }
      if (!sent.has(`${folder}:${kind}`)) {
        out.push({
          severity: 'error',
          code: 'phantom_kind',
          msg: `${folder}: объявил kind="${kind}", но его никто не шлёт — мёртвый контракт.`,
        });
      }
      for (const f of c.from) {
        if (!folders.has(f)) {
          out.push({
            severity: 'error',
            code: 'unknown_sender',
            msg: `${folder}.${kind}: from называет «${f}» — такого агента нет.`,
          });
          continue;
        }
        if (!hasEdge.has(`${f}→${folder}`)) {
          out.push({
            severity: 'error',
            code: 'missing_edge',
            msg: `${folder}.${kind}: from называет «${f}», но ребра ${f}→${folder} в agent_destinations нет — он физически не сможет.`,
          });
        }
      }
      if (c.reply) {
        for (const f of c.from) {
          const senderKinds = kindsOf(f);
          // The sender may have disarmed (no a2a_in at all) — then it accepts
          // everything and a reply cannot dangle.
          if (!input.descriptors[f]?.a2a_in) continue;
          if (!senderKinds[c.reply]) {
            out.push({
              severity: 'error',
              code: 'dangling_reply',
              msg: `${folder}.${kind}: обещает ответ "${c.reply}", но «${f}» такого kind не принимает.`,
            });
          } else if (!sentBy.has(`${folder}→${f}:${c.reply}`)) {
            out.push({
              severity: 'warn',
              code: 'reply_not_sent',
              msg: `${folder}.${kind}: обещает ответ "${c.reply}" к «${f}», но ни один скил «${folder}» его не шлёт.`,
            });
          }
        }
      }
    }
  }

  for (const r of input.fragmentRefs) {
    if (!folders.has(r.target)) {
      out.push({
        severity: 'error',
        code: 'unknown_fragment_ref',
        msg: `${r.where}: читает profiles/${r.target}.md — такого агента нет.`,
      });
    }
  }

  return out;
}
