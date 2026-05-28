# iOS — Media: Video Attachments, Unknown-Attachment Policy

**Date:** 2026-05-28
**Scope:** iOS app (`ios/JarvisApp/`) attachment pickers + Jarvis CLAUDE.md update; server already accepts arbitrary file mime types

## Problem

Today the iOS app supports image attachments (camera, photo picker, files picker) but not video. From [`AttachmentBar.swift:20`](../../ios/JarvisApp/Sources/JarvisApp/Components/AttachmentBar.swift#L20):

```swift
.photosPicker(isPresented: $showPhotos, selection: $photoItems,
              maxSelectionCount: 5, matching: .images)
```

The matcher is hardcoded to `.images`. The document picker accepts anything, but there is no purpose-built video flow: no thumbnail generation, no duration display, no size cap, no transcoding hint.

The server side (`ios-app.ts` `extractAttachmentFiles`) accepts any mime type — the bottleneck is on the client.

Second gap: there is no policy in `groups/jarvis/CLAUDE.md` telling the agent how to behave when it receives an attachment it cannot interpret (e.g., a raw `.heic` it has no tool for, or a large `.mp4`). The user wants Jarvis to **ask** rather than guess.

## Goals

- **Video selection** from photo library AND camera capture.
- **Thumbnail + duration** in the draft chip and the sent message row.
- **Size guard** — warn at 25 MB, block at 100 MB.
- **Server already handles** arbitrary mime types; no protocol change beyond carrying duration metadata.
- **Agent policy** in `groups/jarvis/CLAUDE.md`: when receiving an attachment whose content the agent cannot process, ask the user what to do with it instead of fabricating.

## Non-Goals

- Video editing (trim, crop, filters).
- Server-side transcoding.
- Streaming uploads — videos go up as base64 inside the WS `message.attachments` array, same as images.
- Audio attachments (voice notes) — voice already goes through STT in real time.
- Live Photos — sent as still images only.

## Architecture

### Picker Changes

```swift
// AttachmentBar.swift — replace .images matcher
.photosPicker(
    isPresented: $showPhotos,
    selection: $photoItems,
    maxSelectionCount: 5,
    matching: .any(of: [.images, .videos])
)
```

`PhotosPickerItem` is consumed in a loop. For video items, branch on `supportedContentTypes`:

```swift
.onChange(of: photoItems) { _, items in
    Task {
        for item in items {
            if let img = try? await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: img) {
                if let d = DraftAttachment.image(uiImage, name: "photo-\(Int(Date().timeIntervalSince1970)).jpg") {
                    await MainActor.run { drafts.append(d) }
                }
            } else if let movieURL = try? await item.loadTransferable(type: VideoTransferable.self) {
                // Read into Data, generate thumb + duration, build DraftAttachment
                if let d = try? await DraftAttachment.video(from: movieURL.url) {
                    await MainActor.run { drafts.append(d) }
                }
            }
        }
        photoItems = []
    }
}
```

A small `VideoTransferable` conformance loads the picker's temporary URL into our managed location.

### Camera

`CameraPicker.swift` already wraps `UIImagePickerController`. Add `mediaTypes = ["public.image", "public.movie"]` and a max video duration (60s):

```swift
imagePicker.mediaTypes = ["public.image", "public.movie"]
imagePicker.videoMaximumDuration = 60
imagePicker.videoQuality = .typeMedium  // 480p — keep payload reasonable
```

In delegate, branch on `info[.mediaType]`:

```swift
if let mediaType = info[.mediaType] as? String, mediaType == "public.movie" {
    if let url = info[.mediaURL] as? URL,
       let d = try? DraftAttachment.video(from: url) {
        drafts.append(d)
    }
} else if let img = info[.originalImage] as? UIImage {
    if let d = DraftAttachment.image(img, name: "photo-\(Int(Date().timeIntervalSince1970)).mov") {
        drafts.append(d)
    }
}
```

### DraftAttachment Extension

```swift
struct DraftAttachment: Identifiable, Equatable {
    // existing fields...
    let thumbnail: UIImage?     // NEW — non-nil for video
    let duration: TimeInterval? // NEW — non-nil for video

    enum Kind { case image, video, file }   // .video added

    static func video(from url: URL) async throws -> DraftAttachment {
        let data = try Data(contentsOf: url)
        guard data.count <= 100 * 1024 * 1024 else { throw VideoError.tooLarge }

        let asset = AVURLAsset(url: url)
        let durationCmTime = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(durationCmTime)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let cgImage = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
        let thumbnail = UIImage(cgImage: cgImage)

        let mime = url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
        let name = "video-\(Int(Date().timeIntervalSince1970)).\(url.pathExtension)"

        return DraftAttachment(
            kind: .video, name: name, mimeType: mime, data: data,
            image: thumbnail,           // re-use existing `image` slot for thumb preview
            thumbnail: thumbnail, duration: duration,
        )
    }
}

enum VideoError: Error { case tooLarge }
```

`payload` (wire shape) gains `duration` (seconds, integer) when present:

```swift
var payload: [String: Any] {
    var p: [String: Any] = [
        "name": name, "mimeType": mimeType,
        "data": data.base64EncodedString(), "size": size,
    ]
    if let duration { p["duration"] = Int(duration) }
    return p
}
```

### Size Guard

In `DraftAttachment.video(from:)`:

- **> 25 MB** → still allowed but UI surfaces a warning chip ("Большое видео — может долго грузиться") below the draft.
- **> 100 MB** → `throw VideoError.tooLarge`; UI shows toast "Видео слишком большое (>100 MB)" and skips.

A small `AttachmentSizeWarning` view appears between the draft chip row and the input bar when any draft is `> 25 MB`.

### Draft Chip + Sent Row Rendering

`AttachmentBar.chip(_:)` already handles image previews. Extend:

```swift
private func chip(_ att: DraftAttachment) -> some View {
    ZStack(alignment: .topTrailing) {
        if att.kind == .video, let thumb = att.thumbnail {
            ZStack {
                Image(uiImage: thumb).resizable().scaledToFill()
                Image(systemName: "play.fill")
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.4), in: Circle())
                if let dur = att.duration {
                    Text(formatDuration(dur))
                        .font(.system(size: 9, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let img = att.image { /* existing */ }

        Button { drafts.removeAll { $0.id == att.id } } label: { Image(systemName: "xmark.circle.fill") }
    }
}
```

`MessageRow` (sent video) renders the same thumbnail + play overlay. Tap → `fullScreenCover` with an `AVPlayer` view.

### Server Side

No protocol change. `extractAttachmentFiles` in `src/channels/ios-app.ts` already passes through `mimeType` and `name`. New optional `duration` field on each file entry is forwarded into the agent's inbound message context as a structured hint:

```ts
// ios-app.ts — when building inbound payload
const files = (msg.attachments || []).map((a: any) => ({
  name: a.name,
  mimeType: a.mimeType,
  data: Buffer.from(a.data, 'base64'),
  size: a.size,
  ...(typeof a.duration === 'number' ? { duration: a.duration } : {}),
}));
```

The agent receives video as a file; whether it can interpret it is **up to the agent and its tools** — see the policy below.

### Jarvis CLAUDE.md — Unknown-Attachment Policy

Append to `groups/jarvis/CLAUDE.md`:

```markdown
## Вложения

Когда пользователь присылает картинку, видео, аудио или файл:

1. **Если можешь обработать** (картинка через vision, текстовый файл): обрабатывай и отвечай.
2. **Если не уверен** что внутри или какой тулзой работать — **спроси**, а не выдумывай:
   - «Видео на 18 секунд, без подписи. Что мне с ним сделать — описать кадры, найти момент, сохранить?»
   - «Это PDF на 40 страниц. Прочитать всё, или нужна конкретная информация?»
3. **Никогда не выдумывай содержимое** файлов, к которым у тебя нет тула для чтения. Лучше попроси скриншот или текст.
4. Видео сейчас **нет** vision-тула. Спроси описание/намерение пользователя.
```

This is the only agent-side change.

## Data Flow

```
User taps photo button → PhotosPicker (any: images + videos)
   │
   ▼
Selection → loadTransferable
   │
   ├─ Image → DraftAttachment.image(...)
   │
   └─ Video → DraftAttachment.video(from: tempURL)
              │ AVAsset → thumbnail + duration
              │ size guard
              ▼
              drafts.append(...)
   │
   ▼
User taps send
   │
   ▼
WebSocketClient.send(attachments: drafts)
   │ payload includes base64 data + duration
   ▼
Server forwards as file with duration hint
   │
   ▼
Agent receives, applies policy:
   - has tool → process
   - no tool → ask
```

## Error Handling

| Situation | Behaviour |
|---|---|
| Video > 100 MB | Toast, drop draft, no send |
| Video 25–100 MB | Warning chip, allow send |
| Video thumb gen fails | Use generic film SF symbol as thumb, log; allow send |
| AVAsset load throws | Skip with toast "Не удалось прочитать видео" |
| Server out of memory on huge base64 | Already mitigated by 100 MB cap and existing server `MAX_PAYLOAD_SIZE` (if present — verify) |
| Agent receives video, has no tool | Per CLAUDE.md policy: asks user what to do |

## Testing

**Unit tests (`Tests/JarvisAppTests/`):**

| Test | Asserts |
|---|---|
| `DraftAttachmentVideoTest` | given a fixture .mp4 in test bundle, `DraftAttachment.video(from:)` produces non-nil thumbnail, duration > 0, mime "video/mp4" |
| `DraftAttachmentVideoSizeCapTest` | fixture > 100 MB throws `VideoError.tooLarge` |
| `DraftAttachmentVideoPayloadTest` | `payload["duration"]` is Int when video, absent when image |
| `MessageRowVideoRenderTest` | video row renders with play overlay + duration label |

**Server-side tests (`src/channels/`):**

| Test | Asserts |
|---|---|
| `ios-app.video-attachment.test.ts` | NEW — sending `{name: "v.mp4", mimeType: "video/mp4", data: base64, duration: 12}` produces inbound payload with `files[0].duration === 12` |

**Manual checks (no UI test harness for camera/picker):**

- Pick a 10s video from library → chip shows thumbnail + "0:10".
- Record from camera (60s cap enforced) → posted to chat.
- Pick a 200 MB video → toast appears, draft does not show.
- Agent receives video → response is a clarifying question.

## Migration

- `DraftAttachment` gains `thumbnail` and `duration` — both optional; image-only callers unaffected.
- `MessageCache` does not persist video bytes (only sent), so no cache schema change.
- Server `extractAttachmentFiles` change is additive — `duration` is optional in the agent-facing structure.
- `groups/jarvis/CLAUDE.md` addition is text-only.

## Open Questions

1. **Camera video quality** — `.typeMedium` (~480p) keeps payloads small but loses fidelity. Should we expose a setting? Proposal: no setting; default medium; revisit if users complain.
2. **Live Photos handling** — `.photosPicker` returns the still by default. Worth flagging Live → send as a short video? Proposal: not in v1.
3. **Max camera video duration 60s** — too restrictive? Proposal: 60s is plenty for the "show Jarvis what I see" use case; longer videos should come from library.

## Dependencies

- Depends on **reliability spec** for the outbox + retry — video uploads are bigger and more likely to hit transient WS failures.
- Independent of UI-unified-navigation; attachment chips already live in the input bar.
