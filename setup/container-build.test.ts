import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { spawnSync } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';

import { getDefaultContainerImage } from '../src/install-slug.js';

/**
 * Guards the docker invocation that `container/build.sh` produces — the one
 * build command in the tree, which `setup/container.ts` shells out to.
 *
 * Both bugs this covers were the same shape: a path resolved against the wrong
 * cwd, invisible until someone ran a real build. The Dockerfile COPYs
 * `container/` and `shared/`, so the context MUST be the project root with the
 * Dockerfile passed via -f; and the INSTALL_CJK_FONTS read must find .env at
 * the project root regardless of where the script cd's.
 *
 * Runs the real build.sh against a synthetic checkout with a stub `docker` on
 * PATH, so it asserts the actual argv without a 3-10 minute image build.
 */

const repoRoot = path.resolve(__dirname, '..');

let tmpRoot: string;
let argsFile: string;

/** Build a fake checkout containing the real build.sh + install-slug.sh. */
function makeCheckout(envContents: string | null): void {
  fs.mkdirSync(path.join(tmpRoot, 'container'), { recursive: true });
  fs.mkdirSync(path.join(tmpRoot, 'setup', 'lib'), { recursive: true });
  fs.mkdirSync(path.join(tmpRoot, 'bin'), { recursive: true });

  fs.copyFileSync(
    path.join(repoRoot, 'container', 'build.sh'),
    path.join(tmpRoot, 'container', 'build.sh'),
  );
  fs.copyFileSync(
    path.join(repoRoot, 'setup', 'lib', 'install-slug.sh'),
    path.join(tmpRoot, 'setup', 'lib', 'install-slug.sh'),
  );
  if (envContents !== null) fs.writeFileSync(path.join(tmpRoot, '.env'), envContents);

  // Stub docker: record cwd + argv instead of building.
  argsFile = path.join(tmpRoot, 'docker-args.txt');
  fs.writeFileSync(
    path.join(tmpRoot, 'bin', 'docker'),
    `#!/bin/sh\nprintf 'CWD=%s\\n' "$PWD" > "${argsFile}"\nfor a in "$@"; do printf 'ARG=%s\\n' "$a" >> "${argsFile}"; done\n`,
    { mode: 0o755 },
  );
}

function runBuild(): { cwd: string; args: string[] } {
  const res = spawnSync('bash', [path.join(tmpRoot, 'container', 'build.sh')], {
    env: {
      ...process.env,
      PATH: `${path.join(tmpRoot, 'bin')}:${process.env.PATH}`,
      // Don't let the developer's own shell env mask the .env fallback.
      INSTALL_CJK_FONTS: '',
    },
    encoding: 'utf-8',
  });
  expect(res.status, `build.sh failed: ${res.stderr}`).toBe(0);

  const lines = fs.readFileSync(argsFile, 'utf-8').trim().split('\n');
  return {
    cwd: lines[0].replace(/^CWD=/, ''),
    args: lines.slice(1).map((l) => l.replace(/^ARG=/, '')),
  };
}

beforeAll(() => {
  tmpRoot = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'nanoclaw-build-')));
});

afterAll(() => {
  fs.rmSync(tmpRoot, { recursive: true, force: true });
});

describe('container/build.sh docker invocation', () => {
  it('builds with a project-root context and an explicit -f Dockerfile', () => {
    makeCheckout(null);
    const { cwd, args } = runBuild();

    // The Dockerfile COPYs `container/...` and `shared` — both only resolve
    // from the project root. A `container/` context fails every COPY.
    expect(cwd).toBe(tmpRoot);
    expect(args[args.length - 1]).toBe('.');
    expect(args).toContain('-f');
    expect(args[args.indexOf('-f') + 1]).toBe(path.join(tmpRoot, 'container', 'Dockerfile'));
  });

  it('tags the image setup/container.ts expects to test and report', () => {
    makeCheckout(null);
    const { args } = runBuild();

    expect(args[args.indexOf('-t') + 1]).toBe(getDefaultContainerImage(tmpRoot));
  });

  it('passes INSTALL_CJK_FONTS from the project-root .env', () => {
    makeCheckout('INSTALL_CJK_FONTS=true\n');
    const { args } = runBuild();

    expect(args).toContain('--build-arg');
    expect(args[args.indexOf('--build-arg') + 1]).toBe('INSTALL_CJK_FONTS=true');
  });

  it('omits the CJK build-arg when .env does not opt in', () => {
    makeCheckout('INSTALL_CJK_FONTS=false\n');
    expect(runBuild().args).not.toContain('--build-arg');
  });
});
