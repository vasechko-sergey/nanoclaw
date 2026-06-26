# Workout Image Delivery + Animation Pipeline — Design Spec

**Date:** 2026-06-26
**Surfaces:** `container/agent-runner/` (host-mounted → no image rebuild), `ios/JarvisApp/` (build 59), `groups/payne/` (scp + rebirth). No host (`src/`) change.
**Goal:** Exercise images Payne already has must render **in the workout runner** instead of landing in the chat, and the renderer must animate GIFs — so the moment animated assets exist they play, with no further code.

## Why this is broken today (diagnosed from Payne's session DB on the VDS)

The image protocol is complete on iOS and in the host `WorkoutBridge`, but **the agent side has no way to emit `image_blob`**:

- iOS prefetches the plan's `image_manifest`, fires `image_request` per cache-miss (confirmed: inbound seq 664/666/668). `image_blob` inbound → `AppCoordinator:371` → `ExerciseImageCache.write` → resolver. `image_blob` never creates a chat row.
- The only workout MCP tools are `start_plan` / `coach` / `swap` (`container/agent-runner/src/mcp-tools/workout.ts`). There is **no image-serving tool**, and base64-ing a binary file inline in a raw `<message>` is not something the LLM can do.
- So Payne, woken by `image_request` with the files in hand, falls back to the generic chat path: `{"text":"","files":["zhim-...jpg"]}` (confirmed: Payne outbound seq 671/673/675). The runner cache stays empty → placeholders.

Image files exist + persist at `data/user-memory/owner/payne/exercises/<slug>.jpg` (~140 cards imported from **антитренер**), RW-mounted into the container at `/workspace/agent/exercises/`. All are **static** 200×200 GD-JPEGs today (verified via `file`); the source antitrainer site exposes an API for animated assets — a separate content step.

## Architecture

```
iOS runner cache-miss ─ image_request ─▶ host WorkoutBridge ─▶ Payne inbound (workout_event)
                                                                      │
                          (NEW) runner poll-loop intercepts image_request, serves blob, no LLM
                                                                      ▼
iOS cache.write ◀─ image_blob ◀─ host WorkoutBridge ◀─ outbound {type:image_blob, payload:{slug,sha256,base64}}
        │
        └─ resolver (manifest-sha path → latestPath fallback) ─▶ AnimatedExerciseImage (GIF? animate : static)
```

## Part 1 — Runner auto-serve (`container/agent-runner/`)

New `serveImageRequests(rows, opts?)` in `poll-loop.ts`, called right after `dispatchSystemReplies` in **both** the outer loop (≈line 193) and the follow-up poll (≈line 578).

- For each row where `isWorkoutEventRow(row)` and the parsed `event === 'image_request'`:
  - `slug = payload.slug`. Resolve the file: first existing of `exercises/<slug>.gif`, `.jpg`, `.png` under `EXERCISES_DIR` (default `/workspace/agent/exercises`, injectable for tests). Prefer `.gif`.
  - File found: read bytes, `sha256 = createHash('sha256').update(bytes).digest('hex')`, `base64 = bytes.toString('base64')`, then
    `writeMessageOut({ id: generateId(), kind: 'control', platform_id, channel_type, thread_id, content: JSON.stringify({ type: 'image_blob', payload: { slug, sha256, base64 } }) })`
    using routing from `getSessionRouting()` (mirrors `writeWorkoutOut` in `workout.ts`).
  - File missing or `slug` empty: serve nothing (iOS keeps the placeholder).
  - Either way **consume the row**: collect its id, `markCompleted([...ids])` at the end, and DROP it from the returned survivors — so it never reaches the LLM turn (no tokens, no chat-dump).
- Non-`image_request` rows (chat, other workout events like `set_log`) pass through unchanged.
- Wire-up: `const messages = serveImageRequests(dispatchSystemReplies(allPending)).filter(m => m.kind !== 'system' || isWorkoutEventRow(m))`. Same in the follow-up poll so a mid-workout request (e.g. after a swap) is served without interrupting Payne's turn.

`WorkoutBridge.handleAgentRequest` (`src/channels/ios-app/v2/workout-bridge.ts`) already forwards `content.type === 'image_blob'` → device. **No host change.**

### sha note (why it's robust)
iOS writes the blob under the blob's own sha; the resolver currently keys on the *manifest* sha. The runner hashes the same file Payne hashed for the manifest, so they normally match — but Part 2's `latestPath` fallback removes the dependency entirely, so a drift never blanks the image.

## Part 2 — iOS resilience + animation (`ios/JarvisApp/`, build 59)

**Resolver fallback** — `ChatView.resolveImageURL(slug:plan:)`: try `imageCache.path(forSlug:sha256:)` (manifest sha) as today; if that file doesn't exist, fall back to `imageCache.latestPath(slug:)` (newest cached blob for the slug, sha-agnostic). Decouples blob-sha from manifest-sha.

**Animated renderer** — new `AnimatedExerciseImage: UIViewRepresentable` wrapping `UIImageView`:
- Sniff the file: read the first 4 bytes; `GIF8` magic → build an animated `UIImage` from the file via ImageIO (`CGImageSourceCreateWithURL` → per-frame images + GIF frame delays → `UIImage.animatedImage(with:duration:)`), assign to the `UIImageView`. Else `UIImage(contentsOfFile:)` (static). `contentMode = .scaleAspectFill`, clipsToBounds.
- The byte-sniff + frame-extraction live in a testable helper (e.g. `ExerciseImageFormat.isAnimatedGIF(at:) -> Bool` and `animatedUIImage(at:) -> UIImage?`); the `UIViewRepresentable` is the thin wrapper.
- `ExerciseBannerView` swaps its `if let img = UIImage(contentsOfFile:url.path)` block for `AnimatedExerciseImage(url: url)`. (`SwiftUI.Image` can't animate animated `UIImage`, hence the UIKit wrap.)
- Cache filenames stay `.jpg` — irrelevant, rendering is decided by sniffed bytes, not extension.

## Part 3 — Payne skill (`groups/payne/`, scp + continuation wipe)

- `skills/workout-mode/SKILL.md`: state that **`image_request` is auto-served by the runner — never attach exercise images to chat.** Manifest step (currently line ~65): prefer `exercises/<slug>.gif` if present, else `.jpg`, and hash the chosen file.
- `skills/exercise-cards/SKILL.md`: when a reference is an animation, save `exercises/<slug>.gif` (keep `.jpg` for stills).

## Tests

- **Container (`bun:test`, `poll-loop.test.ts` or new `serve-image-requests.test.ts`):** existing file → one `image_blob` outbound row with correct slug + real sha256 + base64, row consumed (markCompleted); missing file → consumed, no outbound; non-`image_request` workout event (e.g. `set_log`) → passes through, not consumed. Inject a tmp `EXERCISES_DIR`.
- **iOS (`JarvisAppTests`):** `ExerciseImageFormat.isAnimatedGIF` true for GIF bytes / false for JPEG; resolver fallback returns `latestPath` when the manifest-sha file is absent but a blob for the slug exists. Animation playback itself is visual → device check on build 59.

## Deploy

- Container: VDS `git pull` + rebuild host TS if needed + **restart Payne** (`ncl groups restart` / kill → respawn) — agent-runner src is host-mounted, no image rebuild.
- Payne skill: scp `groups/payne/skills/...` + continuation wipe (kill container + DELETE continuation rows) so the skill is re-read.
- iOS: build 59, Сергей installs.

## Out of scope (explicit)

- **antitrainer gif download** — content step, gated on the site's API access (base URL + auth + image endpoint). Once assets land in `exercises/<slug>.gif`, Part 2 animates them with zero code change. Likely a small Payne skill or one-off script (per-slug API fetch).
- **Coach rework** — `workout.coach` → `coach_message` → `CoachBannerView` works but is underused (Payne only sees the `workout_complete` summary; per-set events accumulate silently). Live per-set coaching is a future round.
- **Layout/adaptivity redesign (#3–#8)** — the deferred other half (square image, 12-mini clipping, overall progress bar). Separate spec.
- No animated assets are sourced in this spec; it ships the pipeline only.
