import { existsSync } from 'node:fs';
import { dirname, resolve, sep } from 'node:path';
import { defineConfig, type Plugin } from 'vitest/config';

export const SHARED_SOURCE_PLUGIN = 'nanoclaw:shared-source-resolution';

/**
 * Rebind a relative specifier that lands inside `shared/` onto its `.ts` source.
 * Returns null to leave resolution to Vite.
 *
 * The `shared/*` composite projects emit beside their sources (`outDir: "."`),
 * and that placement is load-bearing: `dist/` sits one level under the repo root
 * exactly like `src/` does, so `../../../../shared/ios-app-protocol/index.js`
 * names the same file from either tree. One specifier, both trees — moving the
 * emit would mean rewriting every host specifier to point into an emit dir that
 * Vite would then resolve to the emitted file anyway.
 *
 * The cost is that `kinds.js` sits next to `kinds.ts`, and Vite resolves a
 * fully-specified `./kinds.js` to the file that exists rather than to the source.
 * Without this plugin tests bind build output: edit the `.ts`, skip the build,
 * and the suite goes green against code that no longer exists. Nothing else
 * catches it — CI must run `build:shared` before typechecking (composite refs,
 * else TS6305), so CI binds the emitted `.js` too.
 *
 * The other two consumers are already safe and need no plugin: `tsx` prefers the
 * `.ts` on its own, and Bun in the container would prefer the `.js` but never
 * sees one — `container/Dockerfile.dockerignore` strips the emit from the build
 * context.
 */
export function resolveSharedSource(source: string, importer: string | undefined, sharedRoot: string): string | null {
  if (!sharedRoot || !importer || !source.startsWith('.')) return null;
  const target = resolve(dirname(importer.split('?')[0]), source.split('?')[0]);
  if (!target.startsWith(sharedRoot)) return null;
  // `./kinds.js` -> kinds.ts, `./v2` (extensionless) -> v2.ts. Anything with no
  // `.ts` beside it (JSON fixtures, directories) falls through to Vite.
  const candidate = target.endsWith('.js') ? `${target.slice(0, -'.js'.length)}.ts` : `${target}.ts`;
  return existsSync(candidate) ? candidate : null;
}

function sharedSourceResolution(): Plugin {
  let sharedRoot = '';
  return {
    name: SHARED_SOURCE_PLUGIN,
    enforce: 'pre',
    configResolved(config) {
      sharedRoot = resolve(config.root, 'shared') + sep;
    },
    resolveId(source, importer) {
      return resolveSharedSource(source, importer, sharedRoot);
    },
  };
}

export default defineConfig({
  plugins: [sharedSourceResolution()],
  test: {
    // container/agent-runner tests run under Bun (they depend on bun:sqlite).
    // See container/agent-runner/package.json "test" script.
    include: ['src/**/*.test.ts', 'setup/**/*.test.ts', 'scripts/**/*.test.ts', 'shared/**/*.test.ts', '*.test.ts'],
  },
});
