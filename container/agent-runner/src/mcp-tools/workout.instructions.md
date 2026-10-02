# workout.* tools (Payne only)

Use these tools to drive a structured workout session over the iOS app.
Default to silence — emit only the messages the user must see.

| Tool | When |
|------|------|
| `workout.start_plan` | Today's plan as a card. Pass only `workout_id` (the owner's date): the tool builds it with `scripts/build-plan.js`, applies Greg's signal, derives images. An error means no card — rest day, closed mesocycle, broken builder. The iOS plan button is answered by the runner without you. |
| `workout.coach`      | A personal record, a clear missed-set pattern, or a fatigue cue. Sparingly. |
| `workout.swap`       | Mid-workout exercise replacement. 1–3 options, each with a reason. |

Inbound side: `set_log`, `exercise_done`, `workout_complete` arrive as
`workout_event` system messages on the poll loop. React via `workout.coach`
only when meaningful.

After `workout_complete` — update `INDEX.md` (last workout, RPE trend,
weekly-volume shift).
