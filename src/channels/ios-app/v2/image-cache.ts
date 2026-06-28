import { mkdirSync, existsSync, readFileSync, writeFileSync, renameSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

/**
 * Host-side byte cache for images delivered by reference. When a
 * capability-`image_ref` device is the target, the WS handler decodes an
 * agent's `image_blob` base64 once, stores the bytes here, and enqueues a tiny
 * `image_ready { slug, sha256 }` envelope instead. The client fetches the bytes
 * over HTTP (`GET /ios/image?slug=&sha=`), so multi-MB base64 never rides the
 * realtime envelope stream and can never head-of-line-block text.
 *
 * Files live at `<baseDir>/<slug>_<sha256>`. The sha pins the cached blob to a
 * specific version (Payne re-publishing an image → new sha → new file).
 *
 * `slug` and `sha256` flow to `GET /ios/image` from the *client* query string,
 * so every key is validated against a strict charset before it touches the
 * filesystem — a path-traversal guard, not cosmetic.
 */
const KEY_RE = /^[A-Za-z0-9._-]+$/;

function validKey(slug: string, sha256: string): boolean {
  return KEY_RE.test(slug) && KEY_RE.test(sha256);
}

export class ImageCache {
  constructor(private baseDir: string) {
    mkdirSync(this.baseDir, { recursive: true });
  }

  /** Absolute path for a slug+sha. Throws on a malformed key (traversal guard). */
  path(slug: string, sha256: string): string {
    if (!validKey(slug, sha256)) {
      throw new Error(`invalid image key: ${slug}_${sha256}`);
    }
    return join(this.baseDir, `${slug}_${sha256}`);
  }

  has(slug: string, sha256: string): boolean {
    if (!validKey(slug, sha256)) return false;
    return existsSync(join(this.baseDir, `${slug}_${sha256}`));
  }

  /** Bytes for a slug+sha, or null if absent / malformed key. */
  read(slug: string, sha256: string): Buffer | null {
    if (!validKey(slug, sha256)) return null;
    const p = join(this.baseDir, `${slug}_${sha256}`);
    if (!existsSync(p)) return null;
    return readFileSync(p);
  }

  /** Persist bytes atomically. Idempotent. Throws on a malformed key. */
  write(slug: string, sha256: string, bytes: Buffer): void {
    const dest = this.path(slug, sha256);
    const tmp = `${dest}.${randomUUID()}.tmp`;
    writeFileSync(tmp, bytes);
    renameSync(tmp, dest);
  }
}
