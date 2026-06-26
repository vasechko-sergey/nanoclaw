# Workout Image Delivery + Animation Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the exercise images Payne already has render in the workout runner (not the chat), and animate GIFs — so animated assets play the moment they exist, with no further code.

**Architecture:** The runner's poll-loop auto-serves an `image_blob` for every iOS `image_request` (reads `/workspace/agent/exercises/<slug>.{gif,jpg}`, no LLM). iOS gains a `latestPath` resolver fallback (kills sha-fragility) and a `UIImageView`-backed animated renderer that sniffs GIF bytes. Payne's skill stops chat-dumping. No host (`src/`) change.

**Tech Stack:** Bun + `bun:test` (container, `container/agent-runner/`), SwiftUI/UIKit/ImageIO + XCTest (iOS), Payne skill markdown (VDS scp).

**Spec:** `docs/superpowers/specs/2026-06-26-workout-image-delivery-design.md`

---

## Conventions

- **Container tests:** `cd container/agent-runner && bun test src/poll-loop.test.ts` (bun 1.3.14 is on the host). Typecheck from repo root: `pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit`.
- **iOS:** XcodeBuildMCP, scheme `JarvisApp`, sim `iPhone 17` (`A8612AF0-85B1-4CE1-B0FF-62B4340CC4DA`). After any new `.swift` file: `cd ios/JarvisApp && xcodegen generate`. Test module is `Jarvis` (`@testable import Jarvis`).
- **Commits** end with the trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Use `--no-verify` (the pre-commit prettier hook only touches `src/**/*.ts`, irrelevant here).
- Work on branch `workout-image-delivery`; do NOT push — merge to main at the end.

## File structure

| File | Responsibility | Action |
|------|----------------|--------|
| `container/agent-runner/src/poll-loop.ts` | `serveImageRequests` + wire-in | Modify |
| `container/agent-runner/src/poll-loop.test.ts` | container tests | Modify |
| `ios/.../Views/Workout/AnimatedExerciseImage.swift` | GIF-sniff + animated renderer | **Create** |
| `ios/.../Views/Workout/ExerciseBannerView.swift` | use the animated renderer | Modify |
| `ios/.../Views/ChatView.swift` | resolver `latestPath` fallback | Modify |
| `ios/.../JarvisAppTests/ExerciseImageFormatTests.swift` | GIF-sniff tests | **Create** |
| `ios/.../JarvisAppTests/ExerciseImageCacheTests.swift` | latestPath test | Modify |
| `ios/JarvisApp/project.yml` | build 58→59 | Modify |
| `groups/payne/skills/workout-mode/SKILL.md` (VDS) | no chat-dump + prefer gif | Modify (scp) |
| `groups/payne/skills/exercise-cards/SKILL.md` (VDS) | save gif | Modify (scp) |

---

### Task 0: Branch

- [ ] **Step 1**

```bash
cd /Users/serg/git/nanoclaw && git checkout -b workout-image-delivery && git branch --show-current
```

---

### Task 1: Runner auto-serve `serveImageRequests`

**Files:**
- Modify: `container/agent-runner/src/poll-loop.ts`
- Test: `container/agent-runner/src/poll-loop.test.ts`

- [ ] **Step 1: Write the failing tests**

Append to `poll-loop.test.ts` (the file already has `insertMessage`, `initTestSessionDb`/`closeSessionDb` in `beforeEach`/`afterEach`, and imports `getPendingMessages`, `getUndeliveredMessages`):

```ts
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { serveImageRequests } from './poll-loop.js';

describe('serveImageRequests', () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'ex-')); });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  it('serves an image_blob for an existing file and consumes the request', () => {
    const bytes = Buffer.from([0x47, 0x49, 0x46, 0x38, 1, 2, 3]);
    writeFileSync(join(dir, 'zhim.gif'), bytes);
    insertMessage('ir1', 'system', { subtype: 'workout_event', event: 'image_request', payload: { slug: 'zhim' } });
    const survivors = serveImageRequests(getPendingMessages(), dir);
    expect(survivors.length).toBe(0);
    const out = getUndeliveredMessages();
    expect(out.length).toBe(1);
    const c = JSON.parse(out[0].content);
    expect(c.type).toBe('image_blob');
    expect(c.payload.slug).toBe('zhim');
    expect(c.payload.sha256).toBe(createHash('sha256').update(bytes).digest('hex'));
    expect(Buffer.from(c.payload.base64, 'base64')).toEqual(bytes);
  });

  it('prefers .gif over .jpg', () => {
    writeFileSync(join(dir, 'ex.jpg'), Buffer.from('JPGDATA'));
    writeFileSync(join(dir, 'ex.gif'), Buffer.from('GIF8DATA'));
    insertMessage('ir1', 'system', { subtype: 'workout_event', event: 'image_request', payload: { slug: 'ex' } });
    serveImageRequests(getPendingMessages(), dir);
    const c = JSON.parse(getUndeliveredMessages()[0].content);
    expect(Buffer.from(c.payload.base64, 'base64').toString()).toBe('GIF8DATA');
  });

  it('consumes but serves nothing when the file is missing', () => {
    insertMessage('ir1', 'system', { subtype: 'workout_event', event: 'image_request', payload: { slug: 'nope' } });
    const survivors = serveImageRequests(getPendingMessages(), dir);
    expect(survivors.length).toBe(0);
    expect(getUndeliveredMessages().length).toBe(0);
  });

  it('passes non-image_request workout events through untouched', () => {
    insertMessage('sl1', 'system', { subtype: 'workout_event', event: 'set_log', payload: {} });
    const survivors = serveImageRequests(getPendingMessages(), dir);
    expect(survivors.length).toBe(1);
    expect(getUndeliveredMessages().length).toBe(0);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd container/agent-runner && bun test src/poll-loop.test.ts`
Expected: FAIL — `serveImageRequests` is not exported.

- [ ] **Step 3: Implement**

In `poll-loop.ts`, add imports at the top (after the existing imports):
```ts
import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { getSessionRouting } from './db/session-routing.js';
```

Add the constant + function (place after `dispatchSystemReplies`, near line 137):
```ts
const DEFAULT_EXERCISES_DIR = '/workspace/agent/exercises';
const IMAGE_EXTS = ['.gif', '.jpg', '.png'] as const;

/**
 * Auto-serve iOS `image_request` workout events: read the exercise image from
 * the agent's workspace, emit an `image_blob` outbound row (kind 'control', so
 * the host WorkoutBridge forwards it and it never counts as user-facing), and
 * CONSUME the request so it never reaches the LLM — no tokens, no chat-dump.
 *
 * `.gif` is preferred over `.jpg`/`.png` so an animated asset wins automatically.
 * A missing file (or absent slug) is still consumed: iOS keeps its placeholder.
 * Non-image_request rows (chat, set_log, …) pass through untouched.
 *
 * `exercisesDir` is injectable for tests; production is `/workspace/agent/exercises`.
 */
export function serveImageRequests(
  rows: MessageInRow[],
  exercisesDir: string = DEFAULT_EXERCISES_DIR,
): MessageInRow[] {
  const consumed: string[] = [];
  const survivors: MessageInRow[] = [];
  for (const row of rows) {
    if (!isWorkoutEventRow(row)) {
      survivors.push(row);
      continue;
    }
    let ev: { event?: string; payload?: { slug?: string } };
    try {
      ev = JSON.parse(row.content);
    } catch {
      survivors.push(row);
      continue;
    }
    if (ev.event !== 'image_request') {
      survivors.push(row);
      continue;
    }
    const slug = ev.payload?.slug;
    if (slug) {
      const path = IMAGE_EXTS.map((ext) => join(exercisesDir, `${slug}${ext}`)).find((p) => existsSync(p));
      if (path) {
        try {
          const bytes = readFileSync(path);
          const sha256 = createHash('sha256').update(bytes).digest('hex');
          const routing = getSessionRouting();
          writeMessageOut({
            id: generateId(),
            kind: 'control',
            platform_id: routing.platform_id,
            channel_type: routing.channel_type,
            thread_id: routing.thread_id,
            content: JSON.stringify({ type: 'image_blob', payload: { slug, sha256, base64: bytes.toString('base64') } }),
          });
          log(`Served image_blob for ${slug} (${bytes.length}b, sha ${sha256.slice(0, 8)})`);
        } catch (err) {
          log(`serveImageRequests failed for ${slug}: ${err instanceof Error ? err.message : String(err)}`);
        }
      } else {
        log(`No exercise image for ${slug} — iOS keeps placeholder`);
      }
    }
    consumed.push(row.id);
  }
  if (consumed.length > 0) markCompleted(consumed);
  return survivors;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd container/agent-runner && bun test src/poll-loop.test.ts`
Expected: PASS (the 4 new cases + the existing suite).

- [ ] **Step 5: Wire into the loops**

In `poll-loop.ts` outer loop, replace (≈line 193):
```ts
    const messages = dispatchSystemReplies(allPending).filter(
      (m) => m.kind !== 'system' || isWorkoutEventRow(m),
    );
```
with:
```ts
    const messages = serveImageRequests(dispatchSystemReplies(allPending)).filter(
      (m) => m.kind !== 'system' || isWorkoutEventRow(m),
    );
```

In the follow-up poll inside `processQuery`, replace (≈line 578):
```ts
        const newMessages = dispatchSystemReplies(pending).filter(
          (m) => m.kind !== 'system' || isWorkoutEventRow(m),
        );
```
with:
```ts
        const newMessages = serveImageRequests(dispatchSystemReplies(pending)).filter(
          (m) => m.kind !== 'system' || isWorkoutEventRow(m),
        );
```

- [ ] **Step 6: Typecheck + full container test**

Run: `pnpm exec tsc -p container/agent-runner/tsconfig.json --noEmit` (root) → no errors.
Run: `cd container/agent-runner && bun test` → all pass.

- [ ] **Step 7: Commit**

```bash
git add container/agent-runner/src/poll-loop.ts container/agent-runner/src/poll-loop.test.ts
git commit --no-verify   # "feat(workout): runner auto-serves image_blob on image_request" + co-author
```

---

### Task 2: iOS `AnimatedExerciseImage` + GIF sniff

**Files:**
- Create: `ios/JarvisApp/Sources/JarvisApp/Views/Workout/AnimatedExerciseImage.swift`
- Create test: `ios/JarvisApp/Sources/JarvisAppTests/ExerciseImageFormatTests.swift`

- [ ] **Step 1: Write the failing test**

Create `ExerciseImageFormatTests.swift`:

```swift
import XCTest
@testable import Jarvis

final class ExerciseImageFormatTests: XCTestCase {
    private func tmpFile(_ bytes: [UInt8], _ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        return url
    }

    func test_isAnimatedGIF_trueForGIFMagic() throws {
        let url = try tmpFile([0x47, 0x49, 0x46, 0x38, 0x39, 0x61], "g.gif")  // GIF89a
        XCTAssertTrue(ExerciseImageFormat.isAnimatedGIF(at: url))
    }

    func test_isAnimatedGIF_falseForJPEG() throws {
        let url = try tmpFile([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10], "j.jpg")  // JPEG SOI
        XCTAssertFalse(ExerciseImageFormat.isAnimatedGIF(at: url))
    }

    func test_isAnimatedGIF_falseForShortFile() throws {
        let url = try tmpFile([0x47, 0x49], "s.bin")
        XCTAssertFalse(ExerciseImageFormat.isAnimatedGIF(at: url))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

`cd ios/JarvisApp && xcodegen generate`, then `test_sim` only-testing `JarvisAppTests/ExerciseImageFormatTests`.
Expected: compile failure — `ExerciseImageFormat` undefined.

- [ ] **Step 3: Implement**

Create `AnimatedExerciseImage.swift`:

```swift
import SwiftUI
import UIKit
import ImageIO

/// Pure format/animation helpers for exercise images — unit-tested without a view.
enum ExerciseImageFormat {
    /// GIF magic ("GIF8") detected by bytes, NOT extension — the cache always
    /// names files `.jpg` regardless of the real format served by the runner.
    static func isAnimatedGIF(at url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = h.readData(ofLength: 4)
        return head.elementsEqual([0x47, 0x49, 0x46, 0x38])  // G I F 8
    }

    /// Build an animated UIImage (frames + per-frame delays) from a GIF file.
    /// Returns nil if it isn't a decodable multi-frame GIF.
    static func animatedUIImage(at url: URL) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 1 else { return nil }
        var frames: [UIImage] = []
        var total = 0.0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            total += gifDelay(src, i)
            frames.append(UIImage(cgImage: cg))
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: total > 0 ? total : Double(frames.count) / 20)
    }

    private static func gifDelay(_ src: CGImageSource, _ i: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        let d = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        return d < 0.02 ? 0.1 : d
    }
}

/// Renders an exercise image file, animating it when the bytes are a GIF.
/// SwiftUI.Image can't play an animated UIImage, so wrap UIImageView.
struct AnimatedExerciseImage: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateUIView(_ v: UIImageView, context: Context) {
        if ExerciseImageFormat.isAnimatedGIF(at: url), let animated = ExerciseImageFormat.animatedUIImage(at: url) {
            v.image = animated
        } else {
            v.image = UIImage(contentsOfFile: url.path)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

`cd ios/JarvisApp && xcodegen generate`, then `test_sim` only-testing `JarvisAppTests/ExerciseImageFormatTests`.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/Workout/AnimatedExerciseImage.swift ios/JarvisApp/Sources/JarvisAppTests/ExerciseImageFormatTests.swift ios/JarvisApp/JarvisApp.xcodeproj/project.pbxproj
git commit --no-verify   # "feat(ios/workout): animated GIF exercise renderer + byte-sniff" + co-author
```

---

### Task 3: `ExerciseBannerView` uses the animated renderer

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/Workout/ExerciseBannerView.swift`

- [ ] **Step 1: Swap the static image block**

In `ExerciseBannerView.swift`, replace:
```swift
            if let url = imageURL, let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Theme.surface
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 70)).foregroundStyle(Theme.accent.opacity(0.5))
            }
```
with:
```swift
            if let url = imageURL, FileManager.default.fileExists(atPath: url.path) {
                AnimatedExerciseImage(url: url)
            } else {
                Theme.surface
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 70)).foregroundStyle(Theme.accent.opacity(0.5))
            }
```

- [ ] **Step 2: Build**

`build_sim`. Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/Workout/ExerciseBannerView.swift
git commit --no-verify   # "feat(ios/workout): banner uses AnimatedExerciseImage" + co-author
```

---

### Task 4: Resolver `latestPath` fallback

**Files:**
- Modify: `ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift`
- Test: `ios/JarvisApp/Sources/JarvisAppTests/ExerciseImageCacheTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `ExerciseImageCacheTests.swift` (it already constructs an `ExerciseImageCache` over a temp dir — mirror its existing setup for `cache`):

```swift
func test_latestPath_returnsNewestWrittenBlobForSlug() throws {
    _ = try cache.write(slug: "ex", sha256: "aaa", base64: Data("one".utf8).base64EncodedString())
    let second = try cache.write(slug: "ex", sha256: "bbb", base64: Data("two".utf8).base64EncodedString())
    XCTAssertEqual(cache.latestPath(slug: "ex")?.lastPathComponent, second.lastPathComponent)
    XCTAssertNil(cache.latestPath(slug: "absent"))
}
```

(If `ExerciseImageCacheTests` builds `cache` inside each test rather than as a property, inline the same `ExerciseImageCache(baseURL:imageRequestSender:)` construction used by the neighbouring tests before these asserts.)

- [ ] **Step 2: Run to verify it fails or passes**

`test_sim` only-testing `JarvisAppTests/ExerciseImageCacheTests`.
Expected: PASS if `latestPath` already behaves (it exists in `ExerciseImageCache`); this test pins it as the fallback's dependency. If the cache writes need an explicit sha-named file the test will surface it.

- [ ] **Step 3: Implement the resolver fallback**

In `ChatView.swift`, replace `resolveImageURL`:
```swift
    private func resolveImageURL(slug: String, plan: WorkoutPlan) -> URL? {
        guard let entry = plan.imageManifest.first(where: { $0.slug == slug }) else { return nil }
        return coordinator.imageCache.has(slug: entry.slug, sha256: entry.sha256)
            ? coordinator.imageCache.path(forSlug: entry.slug, sha256: entry.sha256)
            : nil
    }
```
with:
```swift
    private func resolveImageURL(slug: String, plan: WorkoutPlan) -> URL? {
        if let entry = plan.imageManifest.first(where: { $0.slug == slug }),
           coordinator.imageCache.has(slug: entry.slug, sha256: entry.sha256) {
            return coordinator.imageCache.path(forSlug: entry.slug, sha256: entry.sha256)
        }
        // Fallback: newest cached blob for this slug regardless of sha — covers a
        // manifest-sha vs served-blob-sha drift so a delivered image still resolves.
        return coordinator.imageCache.latestPath(slug: slug)
    }
```

- [ ] **Step 4: Run + build**

`test_sim` only-testing `JarvisAppTests/ExerciseImageCacheTests` → PASS. `build_sim` → BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add ios/JarvisApp/Sources/JarvisApp/Views/ChatView.swift ios/JarvisApp/Sources/JarvisAppTests/ExerciseImageCacheTests.swift
git commit --no-verify   # "feat(ios/workout): resolver latestPath fallback (sha-drift resilient)" + co-author
```

---

### Task 5: iOS version bump + full verify

**Files:**
- Modify: `ios/JarvisApp/project.yml`

- [ ] **Step 1: Bump**

In `project.yml`, `JarvisApp.settings.base`: `CURRENT_PROJECT_VERSION: "58"` → `"59"` (leave `MARKETING_VERSION: "1.13.0"` — same feature line).

- [ ] **Step 2: Regenerate + full suite + build**

```bash
cd ios/JarvisApp && xcodegen generate
```
`test_sim` only-testing `JarvisAppTests` (whole bundle) → all pass (esp. `ExerciseImageFormatTests`, `ExerciseImageCacheTests`, the pre-existing workout suite).
`build_sim` → BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add ios/JarvisApp/project.yml ios/JarvisApp/JarvisApp.xcodeproj/project.pbxproj
git commit --no-verify   # "chore(ios): bump to build 59 — animated exercise images" + co-author
```

---

### Task 6: Payne skill — stop chat-dump + prefer gif (VDS)

Payne's skills live only on the VDS (`groups/payne/`, not in git). Edit on the host, scp back, then rebirth so the next workout re-reads cleanly. Skills are read on demand by the `Skill` tool, so this is belt-and-suspenders, but cheap.

- [ ] **Step 1: Pull both skill files**

```bash
ssh root@148.253.211.164 'sudo -iu nanoclaw -- bash -c "cat /home/nanoclaw/nanoclaw/groups/payne/skills/workout-mode/SKILL.md"' > /tmp/workout-mode.SKILL.md
ssh root@148.253.211.164 'sudo -iu nanoclaw -- bash -c "cat /home/nanoclaw/nanoclaw/groups/payne/skills/exercise-cards/SKILL.md"' > /tmp/exercise-cards.SKILL.md
```

- [ ] **Step 2: Edit `workout-mode` manifest step**

In `/tmp/workout-mode.SKILL.md`, replace the line:
```
4. Собери `image_manifest` (slug + sha256 для каждого упражнения дня — sha256 файла `exercises/<slug>.jpg`).
```
with:
```
4. Собери `image_manifest` (slug + sha256 для каждого упражнения дня). Предпочитай `exercises/<slug>.gif`, иначе `.jpg`; sha256 считай от ВЫБРАННОГО файла. **Картинки в чат НЕ шли** — iOS сам запрашивает их (`image_request`), раннер отдаёт автоматически из `exercises/`. Твоя задача — только манифест.
```

- [ ] **Step 3: Edit `exercise-cards` image rule**

In `/tmp/exercise-cards.SKILL.md`, replace:
```
3. **Картинка** — если боец прислал, сохраняй в `exercises/<slug>.jpg`. Если нет — попроси: «Кинь референс одной картинкой / гифкой, я запомню.»
```
with:
```
3. **Картинка** — статичную сохраняй `exercises/<slug>.jpg`; анимацию (gif) сохраняй `exercises/<slug>.gif` (раннер отдаёт и анимирует её в тренировке). Если нет — попроси: «Кинь референс одной картинкой / гифкой, я запомню.»
```

- [ ] **Step 4: Push back + rebirth**

```bash
scp /tmp/workout-mode.SKILL.md root@148.253.211.164:/tmp/wm.md
scp /tmp/exercise-cards.SKILL.md root@148.253.211.164:/tmp/ec.md
ssh root@148.253.211.164 'sudo -iu nanoclaw -- bash' <<'REMOTE'
cd /home/nanoclaw/nanoclaw
cp /tmp/wm.md groups/payne/skills/workout-mode/SKILL.md
cp /tmp/ec.md groups/payne/skills/exercise-cards/SKILL.md
rm -f /tmp/wm.md /tmp/ec.md
echo "--- verify ---"; grep -n "Картинки в чат НЕ шли" groups/payne/skills/workout-mode/SKILL.md
REMOTE
rm -f /tmp/workout-mode.SKILL.md /tmp/exercise-cards.SKILL.md
```

(Rebirth happens in Task 7's restart.)

---

### Task 7: Deploy container to VDS + e2e verify

agent-runner src is host-mounted on the VDS → `git pull` + restart Payne, no image rebuild.

- [ ] **Step 1: Merge to main first** (see finishing skill — do Task 7 after the branch is merged), then on the VDS:

```bash
ssh root@148.253.211.164 'sudo -iu nanoclaw -- bash' <<'REMOTE'
cd /home/nanoclaw/nanoclaw
git pull --ff-only
# wipe Payne continuation so the fresh container re-reads the edited skill,
# then restart (kill → respawn on next workout). find, not glob.
find data/v2-sessions/payne -name outbound.db -exec pnpm exec tsx scripts/q.ts {} "DELETE FROM session_state WHERE key LIKE 'continuation%';" \;
ncl groups restart --id payne 2>/dev/null || echo "restart via ncl unavailable — container respawns on next workout message"
REMOTE
```

- [ ] **Step 2: e2e verify (Сергей, build 59 on device)**

Start a workout in the app. Expected: exercise images render IN the runner (no longer in chat). Confirm on the VDS that Payne emitted `image_blob` (not chat files):

```bash
ssh root@148.253.211.164 'sudo -iu nanoclaw -- bash' <<'REMOTE'
cd /home/nanoclaw/nanoclaw
s=$(ls -1t data/v2-sessions/payne | head -1)
pnpm exec tsx scripts/q.ts "data/v2-sessions/payne/$s/outbound.db" "SELECT seq, substr(content,1,80) FROM messages_out WHERE content LIKE '%image_blob%' ORDER BY seq DESC LIMIT 5;"
REMOTE
```

Expected: rows with `{"type":"image_blob","payload":{"slug":...}}` and NO `{"text":"","files":[...]}` for exercise slugs.

---

## Self-review

**Spec coverage:**
- Part 1 runner auto-serve → Task 1 ✓ (+ wire-in both loops, tests)
- Part 2 iOS resolver fallback → Task 4 ✓; animated renderer → Tasks 2–3 ✓
- Part 3 Payne skill (no chat-dump, prefer gif, save gif) → Task 6 ✓
- Deploy (container host-mounted, skill scp+rebirth, iOS build 59) → Tasks 5, 7 ✓
- Out-of-scope (antitrainer, coach, layout) → untouched ✓

**Type/signature consistency:** `serveImageRequests(rows, exercisesDir?)` defined Task 1, called in both loops (Task 1 Step 5) + tests (Task 1 Step 1). `getSessionRouting()` returns `{channel_type, platform_id, thread_id}` (all nullable) — matches `writeMessageOut` optional fields; `kind:'control'` is non-user-facing (no dedup, no count). `ExerciseImageFormat.isAnimatedGIF/animatedUIImage` defined Task 2, used by `AnimatedExerciseImage` (Task 2) + tests (Task 2). `imageCache.latestPath(slug:)` exists in `ExerciseImageCache`; used Task 4, pinned by its test.

**Placeholder scan:** no TBD/TODO; every code step shows full code; commands concrete (`bun test`, `test_sim`, scp/ssh heredocs).

**Risk:** the Payne-skill rebirth (Task 7) wipes `continuation` for ALL Payne sessions — same pattern used safely before. If `ncl groups restart` isn't socket-available on the VDS, the container respawns on the next workout message anyway (skills are read on demand). The e2e image check is gated on Сергей running build 59.
```
