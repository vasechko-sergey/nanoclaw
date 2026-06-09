# workout.* tools (Payne only)

Use these tools to drive a structured workout session over the iOS app.
Default to silence — emit only the messages the user must see.

| Tool | When |
|------|------|
| `workout.start_plan` | Exactly once, at the start. Full plan + image manifest. App runs the session offline from this. |
| `workout.coach`      | A personal record, a clear missed-set pattern, or a fatigue cue. Sparingly. |
| `workout.swap`       | Mid-workout exercise replacement. 1–3 options, each with a reason. |

Inbound side: `set_log`, `exercise_done`, `workout_complete` arrive as
`workout_event` system messages on the poll loop. React via `workout.coach`
only when meaningful.

After `workout_complete` — update `INDEX.md` (last workout, RPE trend,
weekly-volume shift).
