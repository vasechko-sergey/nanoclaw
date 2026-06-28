# iOS image delivery — by-reference (kill image_blob head-of-line blocking)

Date: 2026-06-28

## Problem (root cause, confirmed)

Large `image_blob` envelopes head-of-line-block all text on the ios-app v2
outbound queue. The *cause* is architectural, not the queue ordering:

Image bytes ride **inline (base64) on the realtime WS envelope stream**, are
**drained all-at-once with no backpressure**, and are **fully materialized 2–3×
in memory** on the client, with the final decode + disk write **on the main
thread**.

Trace:
1. Host drain (`ws-handler.ts` `attachAuthed`) pushes every queued row in one
   synchronous `for` loop on connect. 5 blobs (~5 MB) hit the wire ahead of the
   text behind them.
2. Client recv loop (`URLSessionWebSocket`) re-arms `task.receive` the instant
   `onMessage` returns; `onMessage` only spawns a `Task`. No backpressure — all
   5 raw frames buffered as concurrent pending actor tasks.
3. Per blob: raw `Data` (~2.3 MB) + `JSONDecoder` → base64 `String` (~2.3 MB) +
   `Data(base64Encoded:)` (~1.7 MB) + synchronous `data.write(to:)`. The last two
   run on `@MainActor` (`AppCoordinator.handleWorkoutEnvelope` →
   `ExerciseImageCache.write`).
4. Main-thread stall + memory spike on connect → app OOM-killed (jetsam) or the
   saturated main RunLoop starves the ping timer → socket drops — **mid-drain,
   before the text rows behind the blobs are processed.** Relaunch → same queue,
   same order → same death. `lastSeenInbound` frozen → agent reply never lands.

"Text stuck behind blobs" is the symptom. (Same inline-base64 pattern exists for
chat-image attachments via `ChatImageStore`.)

## Fix — deliver image bytes out-of-band by reference

Bytes never travel on the realtime stream. WS carries only small refs; the
client fetches bytes over HTTP, streaming to disk off-main.

### Contract (frozen)

- **Envelope** `image_ready` (kind `control`): `{ slug, sha256, agent_id? }` —
  same shape as `image_blob` minus `base64`. A few hundred bytes.
- **HTTP** `GET /ios/image?slug=<slug>&sha=<sha256>` — Bearer-auth (same
  `authIdentity` as other `/ios/*` routes), streams cached bytes, 404 if absent,
  400 on malformed slug/sha (path-traversal guard), 401 if no/invalid token.
- **Capability** `"image_ref"` in the client's auth payload `capabilities`.
  Host converts `image_blob` → `image_ready` ONLY for devices that advertise it;
  absent/unknown caps → unchanged `image_blob` (old path). Safe in every rollout
  combination (old/new client × old/new host).

### Host changes (no container / agent-runner change)

- `shared/ios-app-protocol/v2.ts`: add `Envelopes.ImageReady` to the
  `AnyEnvelope` discriminated union. Recompile (`pnpm build:protocol`).
- New `src/channels/ios-app/v2/image-cache.ts`: `ImageCache(baseDir)` with
  `write(slug,sha,bytes)`, `has`, `path`, `read`/stream. Base dir
  `data/ios-app/image-cache/`. Filename `<slug>_<sha256>`. **Sanitize** slug+sha
  (`^[A-Za-z0-9._-]+$`) — the GET endpoint takes them from the client.
- New `src/channels/ios-app/v2/image-ref.ts`: pure `convertImageBlobToRef(env,
  deviceSupportsRef, imageCache, logWarn)` → on `image_blob` + ref-capable +
  valid payload, caches bytes and returns an `image_ready` envelope; otherwise
  returns the original envelope (fallback to blob).
- `ws-handler.ts`: call the converter at the top of `sendEnvelopeToDevice`
  (the single outbound choke point). Device caps read from the persisted
  `devices.capabilities_json`. `imageCache` is a new optional dep (absent → no
  conversion, so existing tests are unaffected).
- `http-handler.ts`: add the `GET /ios/image` route. `imageCache` new dep.
- `index.ts`: instantiate `ImageCache`, inject into WsHandler + http-handler.

### Client changes (iOS — rebuild required)

- `Protocol/V2.swift`: add `.imageReady` type tag + `ImageReady` payload +
  decode/encode.
- New `Services/ImageFetcher.swift`: on a slug/sha, if not cached, URLSession
  **download task** → atomic move into `ExerciseImageCache.path(forSlug:sha256:)`
  → fire `imageReceived`. HTTP base derived from `ServerConfig.url` (ws→http,
  wss→https) + `Authorization: Bearer <token>` (mirrors `HealthUpload`).
  In-flight dedup; bounded concurrency (max 2); 1–2 retries.
- `Services/TransportV2.swift`: route `.imageReady` through the workout-family
  case (forward via `onWorkoutEnvelope`, per-id `delivered` ack on receipt —
  the ref is tiny; bytes fetched separately with own retry). Advertise
  `capabilities: ["image_ref"]` in `connect()`'s auth payload.
- `Services/AppCoordinator.swift`: `handleWorkoutEnvelope` gains `.imageReady` →
  `imageFetcher.fetch`. Keep `.imageBlob` (backward compat during rollout).
- `project.yml`: bump `CURRENT_PROJECT_VERSION` (+ `MARKETING_VERSION` per
  feature); `xcodegen generate`.

The existing `prefetch(manifest)` → `image_request` → agent → `image_blob`
loop is unchanged; only the heavy `image_blob` transport leg becomes
`image_ready` + an HTTP GET. (Manifest-driven direct HTTP prefetch is a future
optimization — skipped to avoid 404 races before the agent emits the bytes.)

## Tests

Host (vitest): `image-cache` roundtrip + sanitization; `image-ref` conversion
(ref-capable → image_ready + bytes cached; non-capable → unchanged; bad base64 →
fallback); **regression** — enqueue several MB of image_blob ahead of a message
for a ref-capable device via `sendEnvelopeToDevice`, assert queue holds tiny
`image_ready` rows (no base64) and the message drains/acks independently;
`GET /ios/image` 200/404/400/401.

Client (Swift): `image_ready` decode fixture; `ImageFetcher` writes bytes to the
cache + dedupes (injected mock session); `TransportV2` routes `image_ready`.

## Deploy

Host: git push → VDS pull + `pnpm run build` + restart. iOS: build install by
Sergei. Backward-compatible, so order doesn't matter.
