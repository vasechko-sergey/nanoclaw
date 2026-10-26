#!/usr/bin/env node
// Payne's /progress, answered by the runner without a model turn
// (src/commands.ts `serve` → container/agent-runner/src/command-serve.ts).
// The work lives in Payne's own scripts; this runs progress.js with --png and
// passes its last JSON line on: { photo, summary } normally, { summary } alone
// when there is too little data — then the runner hands the command to the
// model, which says so in Payne's voice.
// No SKILL.md here on purpose: container/skills is mounted for every agent, and
// this is no skill for them — only the runner calls it.
const { execFileSync } = require('node:child_process');

const photo = `/tmp/progress-${Date.now()}.png`;
const out = execFileSync('bun', ['/workspace/agent/scripts/progress.js', '--png', photo], {
  cwd: '/workspace/agent',
  encoding: 'utf8',
  timeout: 100_000,
});
const lines = out.trim().split('\n');
console.log(lines[lines.length - 1]);
