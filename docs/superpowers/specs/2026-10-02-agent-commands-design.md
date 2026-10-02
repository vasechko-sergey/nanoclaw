# Per-agent quick commands — design

**Date:** 2026-10-02
**Status:** approved (owner answered the three open questions in chat)

## Problem

The iOS command list (`+` → «Команды», or typing `/`) is one global catalogue
inherited from the Telegram era: `/new /tasks /people /find /surf /status /memory`.
Every agent shows all of them, most are Jarvis-only, and the ones that do
something (`/surf`, `/people`, `/find`) are rewritten into a free-text prompt,
so the model has to work out from scratch what to run.

`/surf` is worse than that. Jarvis's CLAUDE.md routes surf requests to a `Task`
subagent that reads `/workspace/agent/agents/surf-forecast/AGENT.md`. That file
does not exist. Every surf request therefore pays for a subagent spawn that
cannot find its instructions.

## Decision

Each agent shows exactly two commands: `/new`, plus its own command.

| Agent | Command | Label | How it runs |
|---|---|---|---|
| all | `/new` | Начать новый разговор | host resets the session (unchanged) |
| jarvis | `/surf` | Прогноз серфинга | direct skill call: `surf-forecast` |
| payne | `/workout` | Начать тренировку | app-side: today's plan card (runner builds it without the model) or open/resume it |
| gordon | `/food` | Залогировать еду | `/food ` is put into the input; the user adds text or a photo; direct skill call `log-meal` |
| greg | `/health` | Состояние здоровья | runner runs `scripts/analyze.js` and attaches the JSON; the model writes the verdict in its own voice |
| scrooge | `/money` | Состояние финансов | runner runs `scripts/analyze.js` + `scripts/networth.js` and attaches the JSON; the model writes the verdict |

Owner's choices (2026-10-02):
- `/food` puts the command in the input field; it does not open the camera.
- `/surf` stays a model turn for now, going straight to the skill. A model-free
  surf script is possible later: Open-Meteo marine serves hourly tides as
  `sea_level_height_msl`, so no HTML scraping is needed.
- `/health` and `/money` are written in the agent's voice, not as a fixed template.

## Design

**Catalogue: host, `src/commands.ts`.** `AGENT_COMMANDS` holds, per command:
- the owning agent folder, the name and the label;
- `prompt(args)`: what the model receives instead of the raw `/name`;
- optionally `data`: agent scripts whose output is attached;
- optionally `input: 'compose'` or `action: 'today_plan'`, for the app.

**Advertising.** `auth_ok.commands` carries `/new` (no `agent_id`) and every
agent command with its `agent_id`, `input` and `action`.
- New app builds show only the active agent's commands. A tap sends the
  command, puts it in the input (`compose`), or runs the client action.
- Old builds ignore the new fields and still decode the list.

**Gate: `src/command-gate.ts`.** A catalogue command addressed to its own agent
becomes `{ action: 'agent_command' }`.
- `adapter-route.ts` and `router.ts` set the message `text` to `prompt(args)`
  and stamp `command: { name, data? }` onto the content.
- The content is merged, not replaced, so attachments and the iOS context survive.
- The command for a different agent passes through like any unknown slash command.
- The old `REWRITE_COMMANDS` (`/surf`, `/people`, `/find`) go away.

**Runner: `container/agent-runner/src/command-data.ts`.** Before a batch reaches
the model:
- For each chat row whose content carries `command.data`, run each script with
  bun, from `/workspace/agent`, with a 30 s timeout.
- Append its stdout, capped at 16 KB, as a `<command_data source="…">` block.
- A failing script appends an error block instead, and the prompt tells the
  model to collect the data itself.
- Script paths must match `scripts/<name>.js`. Anything else is refused, so a
  malformed row cannot run arbitrary files.
- The factuality gate already seeds its grounding set from the prompt, so
  figures taken from the attached JSON count as grounded.

Measured on live data (2026-10-02, throwaway container, read-only copies):

| Script | Output | Time |
|---|---|---|
| Greg `analyze.js` | 3.1 KB | 96 ms |
| Scrooge `analyze.js` | 3.3 KB | 76 ms |
| Scrooge `networth.js` | 5.4 KB | 50 ms |

None of them write without `--out` or `--snapshot`.

**Jarvis CLAUDE.md.** Surf routing goes to the `surf-forecast` skill, and the
`Task` table with the missing `AGENT.md` is removed. The wiki ingest/lint `Task`
note stays.

## Out of scope

- A model-free surf forecast (script plus `render.cjs`).
- The log-meal skill's two LLM subagents (vision, critique). That is where
  `/food` spends its tokens, not in the command.
- The starter chips (`AgentIdentity.suggestions`), which are unchanged.

## Testing

| Area | Tests |
|---|---|
| Host | `command-gate.test.ts` (new); `adapter-route.test.ts` checks the content merge keeps attachments and that another agent's command passes through; `router.test.ts` drops the `/surf` rewrite case |
| Runner | `command-data.test.ts` (bun:test): data attached, failure block, path refusal, untouched rows |
| iOS | command decoding with the new fields; per-agent filtering; build bump, xcodegen |
