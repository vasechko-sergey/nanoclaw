# Chat: image quality + reliable scroll + storage simplify

**Date:** 2026-06-21
**Scope:** iOS app (`ios/JarvisApp/`) chat view, message storage, image pipeline
**Status:** Design approved, pending implementation plan

## Problem

Two user-reported defects in the chat, plus an underlying storage inefficiency
that both touch.

1. **Image quality.** Tapping a chat image opens a blurry full-screen view. The
   expectation (matching Telegram) is: a small thumbnail in the chat list, the
   sharp original on tap.

2. **Scroll lands in the wrong place.** Opening the chat or switching agents
   sometimes leaves the view scrolled to an arbitrary mid-list position instead
   of the newest message.

3. **Storage bloat (perf).** Image bytes live base64-encoded inside the message
   row. Every timeline observation reloads and JSON-parses those megabytes for
   the whole 500-row window.

## Current behavior (as-is)

### Image pipeline

| Stage | Where | Behavior |
|-------|-------|----------|
| Send (outbound) | `Models/DraftAttachment.swift:23` | Downscale photo to 1600px longest edge, JPEG quality 0.85, base64. |
| Store | `Storage/ConversationStoreV2.swift:30,174` | base64 bytes written into `messages.attachments_json` (in the row). Same column for inbound + outbound. |
| Display | `Services/WebSocketClientV2.swift:479` (`cachedDownsampledImage`) | base64 → UIImage downsampled to **720px** longest edge, cached in an `NSCache` by row id. |
| Chat row | `Components/MessageRow.swift:91` (`imageRow`) | The 720px image, shown at `.frame(maxWidth: 240)`. |
| Full-screen tap | `Components/MessageRow.swift:102` → `Views/FullScreenImageView.swift` | The **same** 720px image, zoomed up to 6×. |

**Root cause of the quality defect:** one 720px bitmap is reused for both the
chat row (fine — 240pt needs ~480px) and the full-screen view (needs ~1290px on
a modern iPhone). Upscaling 720px → full screen is the blur. There is no
separate "original" copy.

### Storage

- `attachments_json` carries the full base64 payload. With retention at 500
  messages per the global timeline, a photo-heavy agent keeps many multi-MB
  base64 strings in the DB.
- `observeAllMessages` / `observeMessages` (`ConversationStoreV2.swift:284,318`)
  do `SELECT *` over the 500-row window on every change tick, dragging those
  base64 strings into memory and JSON-parsing them. `NSCache` saves the *image*
  re-decode but not the row/JSON load.
- The `attachments` table (`Storage/Schema.swift:32,90`) is **dead code**: it is
  created and orphan-pruned (`ConversationStoreV2.swift:362`) but never inserted
  into or read. Its columns (`kind, name, mime_type, byte_size, local_path,
  remote_id`) are exactly the shape of an on-disk file reference — it was
  designed for this and never wired up.

### Scroll

- **No persisted scroll position** anywhere. `cursors` holds seq numbers only;
  `kv` was dropped in migration v3.
- `ChatView` (`Views/ChatView.swift`) uses `.defaultScrollAnchor(.bottom)` plus
  **five** competing scroll effects, several gated behind `Task.sleep` guesses:
  - `onAppear` → scrollTo last (`:257`)
  - `onChange(ws.messages.count)` → scrollTo last (`:270`)
  - `onChange(ws.isBusy)` → 50ms sleep → scrollTo "bottom" (`:281`)
  - `onChange(active.active)` → 60ms sleep → scrollTo last (`:294`)
  - `keyboardWillShow` → 50ms sleep → scrollTo (`:309`)

**Root cause of the scroll defect:** `LazyVStack` realizes rows on demand and
row heights settle late (images decode after layout, Markdown reflows, date
separators insert). The manual `scrollTo` calls fire on a fixed sleep timer
before layout settles, so they target a row whose final position isn't known
yet and land mid-list.

## Design (to-be)

User decisions (locked):
- Scroll: **always land at the newest message**, made reliable. No
  per-agent position persistence.
- Outbound photo cap: **keep 1600px / 0.85** unchanged. Quality is fixed on the
  *view* side (show the stored original on tap, not the 720px preview).

### A. Images — Telegram model + on-disk store

Introduce a `ChatImageStore` that owns image bytes on disk, modeled on the
existing `ExerciseImageCache` (`Services/ExerciseImageCache.swift`).

**`ChatImageStore` responsibilities:**
- Store image files on disk under `Documents/chat-images/`, keyed by `sha256`
  of the bytes (content-addressed → automatic dedup).
- `write(bytes) -> sha256` — persist, return key.
- `fullImage(sha256) -> UIImage?` — decode at (downsampled to) a given max
  pixel size; used by the full-screen view at screen resolution.
- `thumbnail(sha256, maxPixel) -> UIImage?` — small decode for the chat row;
  cached in an `NSCache` keyed by `sha256` (cost-bounded, like the current
  image cache).
- `bytes(sha256) -> Data?` — raw bytes, for the outbound send path to base64
  onto the wire.
- `has(sha256) -> Bool`, and a delete/prune hook for retention.

**Attachment metadata change.** `attachments_json` stops carrying
`bytes_base64`. It carries metadata + the `sha256` reference only:
`{ kind, name, mime_type, byte_size, sha256 }`. This keeps the existing
read path (`toChatMessage` decoding `attachments_json`) but the column is now
tiny.

- Persisted shape is a local-only struct (e.g. `StoredAttachmentRef`), distinct
  from the wire type `V2.Attachment` (which keeps `bytes_base64` for transport).
  Do **not** add `local_path`/`sha256` to the wire type.

**Render split (the actual fix):**
- **Chat row** (`MessageRow.imageRow`): thumbnail at **480px** longest edge
  (240pt @2x) from `ChatImageStore.thumbnail`. Cheap, low memory.
- **Full-screen tap** (`FullScreenImageView`): full-res from
  `ChatImageStore.fullImage`, decoded on demand and downsampled to the screen's
  pixel size (≈1290px on a 430pt @3x iPhone). Sharp. The tap callback passes the
  `sha256` (not a pre-decoded UIImage) so the heavy decode happens only when the
  user actually opens the image.

**Inbound flow:** on receiving an image attachment, write bytes →
`ChatImageStore`, store the ref in `attachments_json`. (No base64 in the row.)

**Outbound flow:** keep the 1600/0.85 downscale in `DraftAttachment`. On send,
write the bytes to `ChatImageStore` at insert time and store the ref. The
dispatcher (`Services/TransportV2.swift:314`, where it currently decodes
attachments from `attachmentsJSON`) hydrates the bytes back from
`ChatImageStore` and base64-encodes them onto the wire.

**Migration (one-shot, on launch):** walk `messages` rows whose
`attachments_json` still carries legacy `bytes_base64`; for each image/file,
write the bytes to `ChatImageStore` and rewrite the JSON to the ref form. Bounded
by retention (≤500 rows). After this, old images also get sharp tap + lose the
bloat. Non-image files (PDF, etc.) move to the store the same way (they are
already shown as a `FileRow`, no decode needed).

**Alternatives considered and rejected:**
- *Minimal:* keep base64-in-DB, only the full-screen view decodes the full
  base64. Fixes quality but not perf/bloat. Rejected — the user explicitly asked
  to simplify and speed up.
- *Normalize via the `attachments` table:* wire up the existing dead table with
  a join on the read path. More code, changes `toChatMessage` / observation /
  timeline. Rejected as more complex, not simpler.

### B. Scroll — always-bottom, reliable

Lean on the SwiftUI-sanctioned anchor; delete the manual scroll storm.

- Keep `.defaultScrollAnchor(.bottom)` (it positions post-layout, unlike
  `scrollTo` on a sleep timer).
- On iOS 18+, add `.defaultScrollAnchor(.bottom, for: .sizeChanges)` so the view
  stays pinned to the bottom as content grows (new message, late image decode,
  keyboard appearance) with no manual scroll.
- **Delete** the four content-driven manual scroll effects and their
  `Task.sleep` guesses: `onAppear` scroll, `onChange(messages.count)`,
  `onChange(isBusy)`, `keyboardWillShow`.
- **Keep:**
  - The scroll-to-bottom **FAB** (`scrollToBottomAction`) — explicit,
    user-initiated.
  - **Agent switch** (`onChange(active.active)`) — the list swaps entirely, so an
    explicit reset to the bottom is still required. Drive it off the recompute,
    not a fixed sleep.
- **iOS 16/17 fallback** (no `sizeChanges` anchor): a single
  `onChange(visibleMessages.last)` → `scrollTo(last, anchor: .bottom)`, guarded
  by `!isScrolledUp` so it never yanks a user who has deliberately scrolled up.
- The "scrolled up" FAB detector (`ScrolledUpDetector`, iOS 18
  `onScrollGeometryChange`) is unchanged.

Net: far fewer scroll effects, and the remaining ones run after layout, so the
view reliably lands at the newest message.

### C. Storage simplify (the perf win)

- **Drop the dead `attachments` table** in a new migration; remove the orphan
  prune branch in `ConversationStoreV2.prune` that references it.
- With `attachments_json` reduced to metadata, `observeAllMessages` /
  `observeMessages` `SELECT *` stops dragging megabytes of base64 per tick — the
  row load and JSON parse become cheap.

## Non-goals

- No per-agent scroll-position persistence (user chose always-bottom).
- No change to the outbound resolution cap (stays 1600px / 0.85).
- Audio voice notes, file rows, action/status rows: unchanged.
- No change to the WebSocket wire protocol (`V2.Attachment` still carries
  `bytes_base64` on the wire).

## Testing

- **`ChatImageStore` unit tests:** write→read round-trip; `sha256` dedup (same
  bytes → one file); thumbnail max-pixel honored; full-res decode; `bytes()`
  round-trips for the send path; missing-key returns nil.
- **Migration test:** a row with legacy inline `bytes_base64` → after migration,
  the file exists in the store and `attachments_json` carries the ref with no
  bytes; the mapped `ChatMessage` still renders an image.
- **Mapping test:** `toChatMessage` builds an image bubble from a ref-form
  attachment (thumbnail) and the full-screen path resolves the original.
- **Scroll:** keep existing `ChatView` tests; manual device verification for the
  four cases (cold open, new inbound message, agent switch, keyboard open) — each
  must land at the newest message.

## Affected files

| File | Change |
|------|--------|
| `Services/ChatImageStore.swift` | **New** — disk store + thumbnail/full-res/bytes API. |
| `Models/DraftAttachment.swift` | Unchanged cap; bytes now flow to the store on send. |
| `Models/Message.swift` | Image content may carry a `sha256` so the tap can resolve the original. |
| `Storage/ConversationStoreV2.swift` | Insert paths write refs (no base64); drop the dead-table prune branch; one-shot migration helper. |
| `Storage/Schema.swift` | New migration: drop `attachments` table. |
| `Services/WebSocketClientV2.swift` | `toChatMessage` maps ref-form attachments via `ChatImageStore`; remove `cachedDownsampledImage` base64 path (or repoint it at the store). |
| `Services/TransportV2.swift` | Outbound send hydrates bytes from the store before base64. |
| `Components/MessageRow.swift` | `imageRow` uses 480px thumbnail; tap passes `sha256`. |
| `Views/FullScreenImageView.swift` | Resolve full-res from the store by `sha256`. |
| `Views/ChatView.swift` | Remove the manual scroll storm; rely on `defaultScrollAnchor`; keep FAB + agent-switch reset. |

Per project policy (memory `feedback_ios_version_bump`): bump
`CURRENT_PROJECT_VERSION` (+ `MARKETING_VERSION` for the feature) and run
`xcodegen generate` as part of the change.
