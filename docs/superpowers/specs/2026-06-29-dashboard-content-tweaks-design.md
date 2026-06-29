# Dashboard Content Tweaks — Design Spec

**Date:** 2026-06-29
**Status:** Approved
**Scope:** 2 agent publish/brief skills (gitignored `groups/`, scp-deployed). NO iOS build, NO host change.

Post-ship feedback on the agent dashboard (build 68). The dashboard renders each agent's
`summary` / metric chips / `action` / expandable `detail` from its `public.md` (via
`/ios/state`). Two content changes; the iOS rendering is unchanged.

## 1. Jarvis morning brief → into the Сводка card

The 09:00 morning brief is currently only a chat `<message>`. Surface it in the owner's
dashboard: Jarvis's card detail (tap-to-expand) becomes the full brief.

- **`morning-brief` skill** additionally writes `memories/public.md` every run (host projects
  to `profiles/jarvis.md` → `/ios/state` → card):
  - frontmatter `metrics` = `события N · почта M · погода°`, `action` = next event as a
    to-do, `summary` = one-line (`N событий · M писем · погода`).
  - body (= card `detail`) = the brief sections (Погода / Сегодня / Почта / На сегодня /
    Новости), as gists (not raw mail), **without the health line**.
  - Written **every run, even during quiet hours** (the card is status, not a ping); only the
    chat `<message>` stays quiet-hours-gated.
- **Remove the routine health line** from the brief (chat + card). Greg's card already shows
  готовность/восст/сон — it was a duplicate. (This is the "убрать то что дублируется другими
  агентами" — health is the only such duplicate; nutrition/training/finance aren't in the brief.)
- **Keep the critical health-finding escalation** (Greg `severity: critical` → Jarvis surfaces
  it urgently). That is a real-time alert, not a routine duplicate of Greg's card.
- The 08:45 `publish` skill stays as the thin pre-09:00 card (location/focus/events); the
  09:00 brief overwrites it with the rich version. Left unchanged.

**Privacy note (accepted):** `public.md` body is read by the owner's other agents too. The brief
body carries mail gists/calendar — a relaxation of the publish "no sensitive data" discipline.
Accepted because these are the owner's own same-person agents and the body is gists, not raw
mail. (A truly owner-only card detail would need a host/iOS change — out of scope.)

## 2. Gordon card → yesterday-report, action becomes an attention-flag

Currently Gordon's `action` is a forward recommendation ("Добери 30г белка к ужину"). In the
morning the owner wants a **report of yesterday** + a flag only when something needs watching,
not a daily to-do.

- **`publish` skill:**
  - `summary` reframed to a yesterday report: "Вчера: калории N% цели, белок <добор|недобор Nг>".
  - `action` becomes a **conditional attention-flag**, not a task: `"—"` when on track (hidden
    by the card's `showsAction`); a short watch/adjust flag when yesterday/the trend is off
    ("Белок недобор Nг — последи", "Калории N% — притормози"). NOT "do X today".
  - metric chips (ккал% · белок±г · дефицит) unchanged — already a yesterday report.
- Forward "what to eat today" advice stays available in chat on request (`daily`/`recomp`
  skills), just not pushed into the morning Сводка card.

Payne / Greg / Scrooge cards unchanged (owner: "остальные норм").

## Deploy

Edit `groups/jarvis/skills/morning-brief/SKILL.md` + `groups/gordon/skills/publish/SKILL.md`
locally → scp to VDS (groups/ gitignored). No rebirth: skills load fresh per invocation; the
new templates take effect at the next 08:45 publish / 09:00 brief. No iOS build, no host restart.

## Non-goals

No iOS/host code. No change to Payne/Greg/Scrooge. The brief's chat delivery, quiet-hours gate,
and all non-health sources stay. No multi-day trend engine for Gordon's flag — single-day
off-target is enough to flag (a trend note is a future nicety).
