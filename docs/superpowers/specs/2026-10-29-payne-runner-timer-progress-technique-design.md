# Workout runner: hold ring, screen awake, partial progress, technique block

Date: 2026-10-29. Owner's choices from the mockups the same day. iOS build 130.

## Why

Four things the owner hit in the live runner:

1. The plank / warmup stopwatch is a bare number. He wants a ring that fills
   up to the target once he presses «Старт».
2. The phone locks while a timer runs — he lies down for a plank and the
   screen goes dark.
3. The header bar cannot tell a finished exercise from one where he did one
   set of three and moved on: any logged set paints the segment copper.
4. There is no way to read how an exercise is done. The cards already hold it
   (`rules` on 136 of 143 cards, `warnings` on 112) but it never reaches the
   app.

The antitrainer media refresh (they moved to 1920×1080 30 fps renders on
2026-07-28, new style) is a separate track and not part of this spec.

## 1. Hold ring — full screen (choice B)

`«Старт»` on a timed card (plank, hold, warmup) opens `HoldTimerOverlay`, a
full-screen view built like `RestTimerOverlay`:

- label: the exercise name upper-cased, plus the set for timed sets —
  «ПЛАНКА · ПОДХОД 1»; the warmup (no sets) shows its name alone;
- a 220 pt ring in `Theme.accent` that fills `elapsed / target`;
- the elapsed time in the centre, «цель 1:00» under it;
- at the target: the ring stays full, digits and caption turn accent,
  caption becomes «цель есть · +0:07», and the count keeps going;
- no target (`target == 0`): track only, no fill, caption hidden;
- «Стоп» — the only control. It does what the card's «Стоп» does today:
  stops the watch and drops the snapped time into the wheels, the overlay
  closes and the card shows «Записать M:SS».

The overlay is shown while `holdTimer.running`; it lives in `WorkoutView`
next to the rest overlay, so a hold still survives swiping the preview.
`HoldTimer` gains `progress: Double` (`min(1, elapsed / target)`, 0 when
there is no target) and `overtimeSec: Int` (`max(0, elapsed − target)` once
reached). The card's own inline stopwatch goes away.

## 2. Screen stays on while a timer runs

`UIApplication.shared.isIdleTimerDisabled = holdTimer.running ||
restTimer.running`, recomputed on every change of either flag, and set back
to `false` when the runner disappears (close, abort, finish). Outside a
timer the phone locks as usual.

## 3. Partial progress in the header (choice A)

A segment kind `.partial(fraction)` for an exercise with sets logged but
fewer than its target, wherever it sits relative to the active one:

- fill: accent for `done / target` of the width, the rest the upcoming
  grey; plus the copper ring the skipped kind already uses;
- `.done` only when sets ≥ target (bonus sets included) — or, for an
  exercise without a set target (warmup, cardio), any logged work;
- `.active`, `.skipped`, `.upcoming` unchanged;
- the counter «1/4» counts `.done` only.

This is the same rule `hasWorkLeft` already applies to the rest hints
(«Дальше», «пропущено: …»), which stay as they are. The banner's state tag
for a previewed exercise reads «1 из 3 подходов» instead of «пройдено» when
it is partial.

## 4. Technique block (choice A)

### Data

`build-plan.js` reads the card's `rules` and `warnings` next to `name_ru`
(one card read, `loadCards` replaces `loadCardNames`) and adds to each plan
exercise:

```json
"technique": {
  "steps": [{ "title": "Исходное положение", "text": "Сядьте в тренажёр…" }],
  "warnings": ["Следите, чтобы колени не заходили внутрь…"]
}
```

`steps` from `rules[].text` / `rules[].description`, `warnings` from
`warnings[].text`; empty strings dropped; the key is omitted when both lists
are empty. The text goes as the card has it — no rewriting.

`PlanExerciseSchema` (`shared/ios-app-protocol/v2.ts`) gets the optional
`technique` object. The host only validates and forwards the plan, so no
host logic changes.

The swap tool (`container/agent-runner/src/mcp-tools/workout.ts`) reads the
same two fields from `exercises/<slug>.json` for each alternative and sends
`technique` with it (optional in the swap schema too); iOS `applySwap` takes
it, so the block follows a swapped-in exercise instead of vanishing.

### UI

- `ExercisePlan.technique: ExerciseTechnique?` (decoded, persisted with the
  active workout).
- `TechniqueStrip` sits right under the pinned header, above the image. It
  shows the **previewed** exercise. No technique → no strip.
- Collapsed: one row — book icon, «Техника · 3 шага», chevron down.
- Tap: the text drops down **over** the image and the ПЕЙН panel (an
  overlay, so the set card below keeps its place and stays usable): numbered
  steps with the title in accent, then warnings with a warning icon. Scrolls
  inside if it is taller than the image + panel. Tap the row again to
  collapse.
- Collapses whenever the previewed exercise changes. Starts collapsed every
  time.

## Testing

- `WorkoutRunnerLogic.progressSegments` — partial, done at target, bonus,
  warmup, partial ahead of the active exercise, counter.
- `HoldTimer` — `progress`, `overtimeSec`, no-target case (injected clock).
- `ExercisePlan` decode with and without `technique`; active-workout store
  round-trip.
- `applySwap` carries technique.
- Render tests in the existing style (live `WorkoutView`, PNG to the
  simulator's Documents): hold ring before / after the target, header with a
  partial segment, technique collapsed / expanded.
- `build-plan.test.js` — technique from a card, omitted when empty; swap
  tool test — technique on an alternative.

## Deploy

- `groups/payne/scripts/build-plan.js` (+ test): diff the VDS
  `agents/payne/scripts/` copy first, then scp.
- Shared schema + agent-runner swap tool: git → VDS `git pull`,
  `pnpm run build`, restart.
- iOS: build 130 (`CURRENT_PROJECT_VERSION`, `xcodegen generate`, commit
  `project.pbxproj`).

## Out of scope

- Antitrainer media refresh (new 1080p renders; whole catalogue to keep one
  style) — own track, after the catalogue dump.
- mp4 playback in the app instead of gif.
- Rewriting the card texts (some antitrainer steps end mid-sentence, e.g.
  «под углом 90»).
