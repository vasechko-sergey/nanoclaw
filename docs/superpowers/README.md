# Superpowers Planning Folder

This folder holds spec/brainstorm/plan documents for non-trivial changes.

## Layout

- `specs/` — active design specs (problem + architecture). Each spec eventually graduates to a plan.
- `plans/` — active implementation plans (task-by-task TDD breakdown). Each plan eventually ships to main.
- `done/` — both specs and plans that have shipped to main. Kept for historical context but not part of active planning.

## Workflow

1. Brainstorm or audit identifies work → write a spec in `specs/`.
2. Spec gets approved → write a plan in `plans/`.
3. Plan executes → merge to main.
4. After merge, move the plan + its spec to `done/`.

## Why this folder exists

It captures the "why" of changes that wouldn't survive in commit messages alone. When someone wonders "why is the iOS app structured this way?", they should be able to find the spec that drove it.

## Conventions

- Filenames are `YYYY-MM-DD-<short-topic>-{design,plan}.md`.
- Don't edit a doc after it's moved to `done/` — make a new spec/plan if the design needs revision.
