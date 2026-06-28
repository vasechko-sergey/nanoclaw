import type { ImageCache } from './image-cache.js';

/** The slice of an outbound envelope this converter inspects. */
export interface MinimalEnvelope {
  id?: string;
  kind?: string;
  type?: string;
  payload?: unknown;
}

/**
 * Convert an outbound `image_blob` envelope into a tiny `image_ready` reference
 * for capability-`image_ref` devices, caching the decoded bytes host-side so the
 * client can fetch them over HTTP. This is the single point where multi-MB
 * base64 is kept off the realtime WS stream (see `image-cache.ts` for the why).
 *
 * Returns the SAME envelope reference (no copy, no side effect) when:
 *   - it isn't an `image_blob`,
 *   - the device doesn't support `image_ref` (old client → old blob path),
 *   - the payload is malformed or the cache write fails (fallback to blob).
 *
 * Otherwise returns a new `image_ready` envelope, preserving `id` so the
 * device's by-id dedup stays stable across a blob→ref transition.
 */
export function convertImageBlobToRef(
  envelope: MinimalEnvelope,
  deviceSupportsRef: boolean,
  imageCache: ImageCache,
  logWarn: (msg: string, ctx?: Record<string, unknown>) => void,
): MinimalEnvelope {
  if (envelope.type !== 'image_blob' || !deviceSupportsRef) return envelope;

  const p = envelope.payload as { slug?: unknown; sha256?: unknown; base64?: unknown; agent_id?: unknown } | undefined;
  if (!p || typeof p.slug !== 'string' || typeof p.sha256 !== 'string' || typeof p.base64 !== 'string') {
    logWarn('image_blob→ref: malformed payload, sending blob unchanged', { id: envelope.id });
    return envelope;
  }

  try {
    imageCache.write(p.slug, p.sha256, Buffer.from(p.base64, 'base64'));
  } catch (err) {
    logWarn('image_blob→ref: cache write failed, sending blob unchanged', {
      slug: p.slug,
      error: String(err),
    });
    return envelope;
  }

  return {
    id: envelope.id,
    kind: 'control',
    type: 'image_ready',
    payload: {
      slug: p.slug,
      sha256: p.sha256,
      ...(typeof p.agent_id === 'string' ? { agent_id: p.agent_id } : {}),
    },
  };
}
