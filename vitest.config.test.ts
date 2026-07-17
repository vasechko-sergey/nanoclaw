import { resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import config, { SHARED_SOURCE_PLUGIN, resolveSharedSource } from './vitest.config.js';

const root = fileURLToPath(new URL('.', import.meta.url));
const sharedRoot = resolve(root, 'shared') + sep;
const at = (...parts: string[]) => resolve(root, ...parts);

describe('shared source resolution', () => {
  // Without this the whole suite silently binds build output again, and stays
  // green while doing it — the exact failure this plugin exists to prevent.
  it('is wired into the exported config', () => {
    const plugins = (config.plugins ?? []) as { name?: string }[];
    expect(plugins.map((p) => p.name)).toContain(SHARED_SOURCE_PLUGIN);
  });

  it('rebinds an emitted .js sibling onto its .ts source', () => {
    expect(resolveSharedSource('./kinds.js', at('shared/a2a/kinds.test.ts'), sharedRoot)).toBe(
      at('shared/a2a/kinds.ts'),
    );
  });

  it('rebinds an extensionless specifier onto its .ts source', () => {
    expect(resolveSharedSource('./v2', at('shared/ios-app-protocol/fixtures.test.ts'), sharedRoot)).toBe(
      at('shared/ios-app-protocol/v2.ts'),
    );
  });

  // Host production source reaches shared/ by relative path, so host tests bind
  // it transitively — 14 of them do.
  it('rebinds a host specifier that reaches into shared/', () => {
    expect(
      resolveSharedSource(
        '../../../../shared/ios-app-protocol/index.js',
        at('src/channels/ios-app/v2/ws-handler.ts'),
        sharedRoot,
      ),
    ).toBe(at('shared/ios-app-protocol/index.ts'));
  });

  it('leaves specifiers that resolve outside shared/ to Vite', () => {
    expect(resolveSharedSource('./router.js', at('src/index.ts'), sharedRoot)).toBeNull();
  });

  it('leaves bare specifiers to Vite', () => {
    expect(resolveSharedSource('vitest', at('shared/a2a/kinds.test.ts'), sharedRoot)).toBeNull();
  });

  it('leaves shared/ files that have no .ts source to Vite', () => {
    expect(
      resolveSharedSource('./fixtures/ping.json', at('shared/ios-app-protocol/fixtures.test.ts'), sharedRoot),
    ).toBeNull();
  });
});
