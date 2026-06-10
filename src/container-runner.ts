/**
 * Container Runner v2
 * Spawns agent containers with session folder + agent group folder mounts.
 * The container runs the v2 agent-runner which polls the session DB.
 */
import { ChildProcess, execSync, spawn } from 'child_process';
import fs from 'fs';
import path from 'path';

import {
  CONTAINER_IMAGE,
  CONTAINER_IMAGE_BASE,
  CONTAINER_INSTALL_LABEL,
  CREDENTIAL_PROXY_PORT,
  DATA_DIR,
  GROUPS_DIR,
  TIMEZONE,
} from './config.js';
import { materializeContainerJson } from './container-config.js';
import { getContainerConfig } from './db/container-configs.js';
import { updateContainerConfigScalars, updateContainerConfigJson } from './db/container-configs.js';
import {
  CONTAINER_HOST_GATEWAY,
  CONTAINER_RUNTIME_BIN,
  hostGatewayArgs,
  readonlyMountArgs,
  stopContainer,
} from './container-runtime.js';
import { detectAuthMode } from './credential-proxy.js';
import { getAgentGroup } from './db/agent-groups.js';
import { getDb, hasTable } from './db/connection.js';
import { initGroupFilesystem } from './group-init.js';
import { stopTypingRefresh } from './modules/typing/index.js';
import { log } from './log.js';
import { validateAdditionalMounts } from './modules/mount-security/index.js';
// Provider host-side config barrel — each provider that needs host-side
// container setup self-registers on import.
import './providers/index.js';
import {
  getProviderContainerConfig,
  type ProviderContainerContribution,
  type VolumeMount,
} from './providers/provider-container-registry.js';
import {
  heartbeatPath,
  markContainerRunning,
  markContainerStopped,
  openOutboundDbRw,
  outboundDbPath,
  sessionDir,
  writeSessionRouting,
} from './session-manager.js';
import type { AgentGroup, Session } from './types.js';

/** Active containers tracked by session ID. */
const activeContainers = new Map<string, { process: ChildProcess; containerName: string }>();

/**
 * In-flight wake promises, keyed by session id. Deduplicates concurrent
 * `wakeContainer` calls while the first spawn is still mid-setup (async
 * buildContainerArgs, OneCLI gateway apply, etc.) — otherwise a second
 * wake in that window passes the `activeContainers.has` check and spawns
 * a duplicate container against the same session directory, producing
 * racy double-replies.
 */
const wakePromises = new Map<string, Promise<boolean>>();

export function getActiveContainerCount(): number {
  return activeContainers.size;
}

export function isContainerRunning(sessionId: string): boolean {
  return activeContainers.has(sessionId);
}

/**
 * Wake up a container for a session. If already running or mid-spawn, no-op
 * (the in-flight wake promise is reused).
 *
 * The container runs the v2 agent-runner which polls the session DB.
 *
 * Contract: never throws. Returns `true` on successful spawn, `false` on
 * transient spawn failure (e.g. OneCLI gateway unreachable). Callers don't
 * need to wrap — the inbound row stays pending and host-sweep retries on
 * its next tick. Callers that care (e.g. the router's typing indicator)
 * can branch on the boolean.
 */
export function wakeContainer(session: Session): Promise<boolean> {
  if (activeContainers.has(session.id)) {
    log.debug('Container already running', { sessionId: session.id });
    return Promise.resolve(true);
  }
  const existing = wakePromises.get(session.id);
  if (existing) {
    log.debug('Container wake already in-flight — joining existing promise', { sessionId: session.id });
    return existing;
  }
  const promise = spawnContainer(session)
    .then(() => true)
    .catch((err) => {
      log.warn('wakeContainer failed — host-sweep will retry', { sessionId: session.id, err });
      return false;
    })
    .finally(() => {
      wakePromises.delete(session.id);
    });
  wakePromises.set(session.id, promise);
  return promise;
}

/** Cap a single container.log generation before rotating to .log.1. */
const CONTAINER_LOG_MAX_BYTES = 5 * 1024 * 1024;

/**
 * Open an append stream to `<sessionDir>/container.log` for the spawned
 * container's stderr. Rotates the existing file to `.log.1` if it has grown
 * past CONTAINER_LOG_MAX_BYTES, so the log survives `--rm` without growing
 * unbounded across many wakes. Returns null (and logs) if the stream can't
 * be opened — stderr still reaches the host debug log either way.
 */
export function openContainerLogStream(
  agentGroupId: string,
  sessionId: string,
  containerName: string,
): fs.WriteStream | null {
  try {
    const dir = sessionDir(agentGroupId, sessionId);
    fs.mkdirSync(dir, { recursive: true });
    const logPath = path.join(dir, 'container.log');
    try {
      if (fs.statSync(logPath).size > CONTAINER_LOG_MAX_BYTES) {
        fs.renameSync(logPath, `${logPath}.1`); // keep one prior generation
      }
    } catch {
      /* no existing file — nothing to rotate */
    }
    const stream = fs.createWriteStream(logPath, { flags: 'a' });
    stream.write(`\n--- ${new Date().toISOString()} spawn ${containerName} ---\n`);
    return stream;
  } catch (err) {
    log.warn('Failed to open container log stream', { agentGroupId, sessionId, err });
    return null;
  }
}

/**
 * Headless sessions (no messaging_group, no thread) are cron-only. They
 * exist purely to host recurring tasks (`schedule_task` rows) and should
 * NEVER accumulate SDK conversation state across fires — every wake is a
 * new, unrelated job. The session's `outbound.db` keeps a
 * `session_state.continuation:<provider>` row that the agent-runner
 * passes to the SDK to resume a prior conversation; if we don't clear
 * it, each daily fire piles onto the previous, the SDK's auto-compact
 * eventually starts eating the actual response (see Greg's
 * sess-1779443246846 which has been a single accreting conversation
 * since 22 May and stopped producing usable output once the running
 * context crossed ~130k tokens), and the agent appears silent.
 *
 * Detection: `messaging_group_id == null` (we accept undefined too as
 * a defensive measure; the FK schema only permits NULL or a valid
 * messaging_group row). Sessions tied to iOS-app, Telegram, Discord
 * etc. always have a messaging_group_id and are exempt — they're
 * interactive and the continuation IS the conversation.
 *
 * Safe to write to outbound.db here: the only writer is the container
 * we're about to spawn, and the activeContainers guard above means
 * none is currently up. The DELETE is wrapped in try/catch so a brand
 * new session (no session_state table yet — the table is created by
 * the container on first start) does not block the wake.
 */
/**
 * Delete the persisted SDK continuation row(s) from a session's outbound.db so
 * the next container start begins a brand-new conversation — fresh CLAUDE.md /
 * INSTRUCTIONS load, no replayed context. CALLER MUST ENSURE no container for
 * this session is currently up: the container is the sole writer of
 * outbound.db, so clearing while it runs both races the writer and gets
 * re-persisted by the live session. Used by headless wakes and by `/new`
 * (where it runs only after killContainer's process-exit callback fires).
 */
export function clearSessionContinuation(agentGroupId: string, sessionId: string): void {
  const dbPath = outboundDbPath(agentGroupId, sessionId);
  // First-ever wake: outbound.db may not even exist yet. The container
  // will create it on startup with a fresh (empty) session_state.
  if (!fs.existsSync(dbPath)) return;
  try {
    const db = openOutboundDbRw(agentGroupId, sessionId);
    try {
      db.exec("DELETE FROM session_state WHERE key LIKE 'continuation:%'");
    } finally {
      db.close();
    }
    log.info('Cleared SDK continuation', { sessionId });
  } catch (err) {
    // Table-missing on a freshly-initialized DB is the common case and
    // not worth a warning. Real errors (permissions, corruption) still
    // log so we can find them.
    const msg = err instanceof Error ? err.message : String(err);
    if (!/no such table/i.test(msg)) {
      log.warn('Failed to clear continuation', { sessionId, err: msg });
    }
  }
}

export function clearContinuationIfHeadless(session: Session): void {
  if (session.messaging_group_id != null) return;
  clearSessionContinuation(session.agent_group_id, session.id);
}

async function spawnContainer(session: Session): Promise<void> {
  const agentGroup = getAgentGroup(session.agent_group_id);
  if (!agentGroup) {
    log.error('Agent group not found', { agentGroupId: session.agent_group_id });
    return;
  }

  // Wipe the SDK continuation for headless cron sessions so each fire
  // is a brand-new conversation. See `clearContinuationIfHeadless`
  // docblock for the reasoning — interactive sessions are untouched.
  clearContinuationIfHeadless(session);

  // Refresh the destination map and default reply routing so any admin
  // changes take effect on wake. Destinations come from the agent-to-agent
  // module — skip when the module isn't installed (table absent).
  if (hasTable(getDb(), 'agent_destinations')) {
    const { writeDestinations } = await import('./modules/agent-to-agent/write-destinations.js');
    writeDestinations(agentGroup.id, session.id);
  }
  writeSessionRouting(agentGroup.id, session.id);

  // Materialize container.json from DB — writes fresh file and returns
  // the config object, threaded through provider resolution, buildMounts,
  // and buildContainerArgs so we don't re-read.
  const containerConfig = materializeContainerJson(agentGroup.id);

  // Resolve the effective provider + any host-side contribution it declares
  // (extra mounts, env passthrough). Computed once and threaded through both
  // buildMounts and buildContainerArgs so side effects (mkdir, etc.) fire once.
  const { provider, contribution } = resolveProviderContribution(session, agentGroup, containerConfig);

  const mounts = buildMounts(agentGroup, session, containerConfig, contribution);
  const containerName = `nanoclaw-v2-${agentGroup.folder}-${Date.now()}`;
  const args = await buildContainerArgs(mounts, containerName, agentGroup, containerConfig, provider, contribution);

  log.info('Spawning container', { sessionId: session.id, agentGroup: agentGroup.name, containerName });

  // Clear any orphan heartbeat from a previous container instance — the
  // sweep's ceiling check treats a missing file as "fresh spawn, give grace"
  // (host-sweep.ts line 87). Without this, the stale mtime can trigger an
  // immediate kill before the new container touches the file itself.
  fs.rmSync(heartbeatPath(agentGroup.id, session.id), { force: true });

  const container = spawn(CONTAINER_RUNTIME_BIN, args, { stdio: ['ignore', 'pipe', 'pipe'] });

  activeContainers.set(session.id, { process: container, containerName });
  markContainerRunning(session.id);

  // Persist container stderr to a per-session file. The container runs with
  // `--rm`, so once it exits there is otherwise NO trace of why it died — and
  // the in-process `log.debug` below is dropped at the default INFO level.
  // The file is the only durable record for diagnosing a silent container
  // failure (OOM, crash, bad config). Rotated at spawn so it can't grow
  // unbounded across many wakes; one prior generation is kept as .log.1.
  const logStream = openContainerLogStream(agentGroup.id, session.id, containerName);

  // Log stderr — both to the durable file and to the host log at debug level.
  container.stderr?.on('data', (data) => {
    const text = data.toString();
    logStream?.write(text);
    for (const line of text.trim().split('\n')) {
      if (line) log.debug(line, { container: agentGroup.folder });
    }
  });
  const closeLogStream = (): void => {
    try {
      logStream?.end();
    } catch {
      /* already closed */
    }
  };
  container.once('close', closeLogStream);
  container.once('error', closeLogStream);

  // stdout is unused in v2 (all IO is via session DB)
  container.stdout?.on('data', () => {});

  // No host-side idle timeout. Stale/stuck detection is driven by the host
  // sweep reading heartbeat mtime + processing_ack claim age + container_state
  // (see src/host-sweep.ts). This avoids killing long-running legitimate work
  // on a wall-clock timer.

  container.on('close', (code) => {
    activeContainers.delete(session.id);
    markContainerStopped(session.id);
    stopTypingRefresh(session.id);
    log.info('Container exited', { sessionId: session.id, code, containerName });
  });

  container.on('error', (err) => {
    activeContainers.delete(session.id);
    markContainerStopped(session.id);
    stopTypingRefresh(session.id);
    log.error('Container spawn error', { sessionId: session.id, err });
  });
}

/** Kill a container for a session. */
export function killContainer(sessionId: string, reason: string, onExit?: () => void): void {
  const entry = activeContainers.get(sessionId);
  if (!entry) return;

  if (onExit) {
    entry.process.once('close', onExit);
  }

  log.info('Killing container', { sessionId, reason, containerName: entry.containerName });
  try {
    stopContainer(entry.containerName);
  } catch {
    entry.process.kill('SIGKILL');
  }
}

/**
 * Resolve the provider name for a session:
 *
 *   sessions.agent_provider
 *     → container_configs.provider
 *     → 'claude'
 *
 * Pure so the precedence can be unit-tested without a DB or filesystem.
 */
export function resolveProviderName(
  sessionProvider: string | null | undefined,
  containerConfigProvider: string | null | undefined,
): string {
  return (sessionProvider || containerConfigProvider || 'claude').toLowerCase();
}

function resolveProviderContribution(
  session: Session,
  agentGroup: AgentGroup,
  containerConfig: import('./container-config.js').ContainerConfig,
): { provider: string; contribution: ProviderContainerContribution } {
  const provider = resolveProviderName(session.agent_provider, containerConfig.provider);
  const fn = getProviderContainerConfig(provider);
  const contribution = fn
    ? fn({
        sessionDir: sessionDir(agentGroup.id, session.id),
        agentGroupId: agentGroup.id,
        hostEnv: process.env,
      })
    : {};
  return { provider, contribution };
}

function buildMounts(
  agentGroup: AgentGroup,
  session: Session,
  containerConfig: import('./container-config.js').ContainerConfig,
  providerContribution: ProviderContainerContribution,
): VolumeMount[] {
  const projectRoot = process.cwd();

  // Per-group filesystem state lives forever after first creation. Init is
  // idempotent: it only writes paths that don't already exist, so this call
  // is a no-op for groups that have spawned before.
  initGroupFilesystem(agentGroup);

  // Sync skill symlinks based on container.json selection before mounting.
  const claudeDir = path.join(DATA_DIR, 'v2-sessions', agentGroup.id, '.claude-shared');
  syncSkillSymlinks(claudeDir, containerConfig, agentGroup);

  const mounts: VolumeMount[] = [];
  const sessDir = sessionDir(agentGroup.id, session.id);
  const groupDir = path.resolve(GROUPS_DIR, agentGroup.folder);

  // Session folder at /workspace (contains inbound.db, outbound.db, outbox/, .claude/)
  mounts.push({ hostPath: sessDir, containerPath: '/workspace', readonly: false });

  // Agent group folder at /workspace/agent (RW for working files + CLAUDE.local.md)
  mounts.push({ hostPath: groupDir, containerPath: '/workspace/agent', readonly: false });

  // container.json — nested RO mount on top of RW group dir so the agent
  // can read its config but cannot modify it.
  const containerJsonPath = path.join(groupDir, 'container.json');
  if (fs.existsSync(containerJsonPath)) {
    mounts.push({ hostPath: containerJsonPath, containerPath: '/workspace/agent/container.json', readonly: true });
  }

  // CLAUDE.md — static per-group persona. Nested RO mount on top of the RW
  // group dir so the agent can read but not overwrite it. Nothing composes
  // or regenerates this file; it's a plain file on disk, hand-maintained.
  // Per-group memory (CLAUDE.local.md) stays RW via the group-dir mount.
  const claudeMdPath = path.join(groupDir, 'CLAUDE.md');
  if (fs.existsSync(claudeMdPath)) {
    mounts.push({ hostPath: claudeMdPath, containerPath: '/workspace/agent/CLAUDE.md', readonly: true });
  }

  // Shared INSTRUCTIONS.md — ONE static file under GROUPS_DIR, mounted RO into
  // every container at the path each group's CLAUDE.md references via
  // `@./INSTRUCTIONS.md`. Hand-maintained: the host never generates or copies
  // it. Edit groups/INSTRUCTIONS.md directly when skills/channels change.
  const instructionsPath = path.join(GROUPS_DIR, 'INSTRUCTIONS.md');
  if (fs.existsSync(instructionsPath)) {
    mounts.push({ hostPath: instructionsPath, containerPath: '/workspace/agent/INSTRUCTIONS.md', readonly: true });
  }

  // Global memory directory — always read-only.
  const globalDir = path.join(GROUPS_DIR, 'global');
  if (fs.existsSync(globalDir)) {
    mounts.push({ hostPath: globalDir, containerPath: '/workspace/global', readonly: true });
  }

  // Per-group .claude-shared at /home/node/.claude (Claude state, settings,
  // skill symlinks)
  mounts.push({ hostPath: claudeDir, containerPath: '/home/node/.claude', readonly: false });

  // Shared agent-runner source — read-only, same code for all groups.
  const agentRunnerSrc = path.join(projectRoot, 'container', 'agent-runner', 'src');
  mounts.push({ hostPath: agentRunnerSrc, containerPath: '/app/src', readonly: true });

  // Shared skills — read-only, symlinks in .claude-shared/skills/ point here.
  const skillsSrc = path.join(projectRoot, 'container', 'skills');
  if (fs.existsSync(skillsSrc)) {
    mounts.push({ hostPath: skillsSrc, containerPath: '/app/skills', readonly: true });
  }

  // Additional mounts from container config
  if (containerConfig.additionalMounts && containerConfig.additionalMounts.length > 0) {
    const validated = validateAdditionalMounts(containerConfig.additionalMounts, agentGroup.name);
    mounts.push(...validated);
  }

  // Provider-contributed mounts (e.g. opencode-xdg)
  if (providerContribution.mounts) {
    mounts.push(...providerContribution.mounts);
  }

  return mounts;
}

/**
 * Sync skill symlinks in .claude-shared/skills/ to match the container.json
 * selection (shared skills) plus any per-group skills found under
 * `groups/<folder>/skills/`. Each symlink points to a container path
 * (`/app/skills/<name>` for shared, `/workspace/agent/skills/<name>` for
 * per-group) so it's dangling on the host but valid inside the container.
 *
 * Per-group skills take precedence over shared skills with the same name —
 * lets a group override an upstream skill without forking it.
 */
function syncSkillSymlinks(
  claudeDir: string,
  containerConfig: import('./container-config.js').ContainerConfig,
  agentGroup: AgentGroup,
): void {
  const skillsDir = path.join(claudeDir, 'skills');
  if (!fs.existsSync(skillsDir)) {
    fs.mkdirSync(skillsDir, { recursive: true });
  }

  const projectRoot = process.cwd();
  const sharedSkillsDir = path.join(projectRoot, 'container', 'skills');

  // Shared skills — selected via container.json
  let sharedDesired: string[];
  if (containerConfig.skills === 'all') {
    sharedDesired = fs.existsSync(sharedSkillsDir)
      ? fs.readdirSync(sharedSkillsDir).filter((e) => {
          try {
            return fs.statSync(path.join(sharedSkillsDir, e)).isDirectory();
          } catch {
            return false;
          }
        })
      : [];
  } else {
    sharedDesired = containerConfig.skills;
  }

  // Per-group skills — always all subdirectories in groups/<folder>/skills/
  // that contain a SKILL.md. Per-group skills are writable from inside the
  // container (groupDir is mounted RW at /workspace/agent), so the agent
  // can edit its own skills.
  const groupSkillsDir = path.join(GROUPS_DIR, agentGroup.folder, 'skills');
  const groupDesired: string[] = fs.existsSync(groupSkillsDir)
    ? fs.readdirSync(groupSkillsDir).filter((e) => {
        try {
          const entryPath = path.join(groupSkillsDir, e);
          if (!fs.statSync(entryPath).isDirectory()) return false;
          return fs.existsSync(path.join(entryPath, 'SKILL.md'));
        } catch {
          return false;
        }
      })
    : [];

  // Build target map. Per-group entries overwrite shared entries with the
  // same name on purpose — lets a group fork/override an upstream skill.
  const targets = new Map<string, string>();
  for (const skill of sharedDesired) targets.set(skill, `/app/skills/${skill}`);
  for (const skill of groupDesired) targets.set(skill, `/workspace/agent/skills/${skill}`);

  // Remove symlinks not in the desired set OR pointing to a stale target
  // (e.g. promoted from shared → group or vice versa).
  for (const entry of fs.readdirSync(skillsDir)) {
    const entryPath = path.join(skillsDir, entry);
    let isSymlink = false;
    let currentTarget: string | null = null;
    try {
      isSymlink = fs.lstatSync(entryPath).isSymbolicLink();
      if (isSymlink) currentTarget = fs.readlinkSync(entryPath);
    } catch {
      continue;
    }
    if (!isSymlink) continue;
    const wanted = targets.get(entry);
    if (!wanted || wanted !== currentTarget) {
      fs.unlinkSync(entryPath);
    }
  }

  // Create symlinks for desired skills (container path targets).
  for (const [skill, target] of targets) {
    const linkPath = path.join(skillsDir, skill);
    let exists = false;
    try {
      fs.lstatSync(linkPath);
      exists = true;
    } catch {
      /* missing */
    }
    if (!exists) {
      fs.symlinkSync(target, linkPath);
    }
  }
}

async function buildContainerArgs(
  mounts: VolumeMount[],
  containerName: string,
  agentGroup: AgentGroup,
  containerConfig: import('./container-config.js').ContainerConfig,
  provider: string,
  providerContribution: ProviderContainerContribution,
): Promise<string[]> {
  const args: string[] = ['run', '--rm', '--name', containerName, '--label', CONTAINER_INSTALL_LABEL];

  // Environment — only vars read by code we don't own.
  // Everything NanoClaw-specific is in container.json (read by runner at startup).
  args.push('-e', `TZ=${TIMEZONE}`);

  // Provider-contributed env vars (e.g. XDG_DATA_HOME, OPENCODE_*, NO_PROXY).
  if (providerContribution.env) {
    for (const [key, value] of Object.entries(providerContribution.env)) {
      args.push('-e', `${key}=${value}`);
    }
  }

  // Route Anthropic API traffic through the in-process credential proxy.
  // The container only ever sees the placeholder; the proxy injects the real
  // key/token before forwarding upstream. See src/credential-proxy.ts.
  args.push('-e', `ANTHROPIC_BASE_URL=http://${CONTAINER_HOST_GATEWAY}:${CREDENTIAL_PROXY_PORT}`);
  const authMode = detectAuthMode();
  if (authMode === 'api-key') {
    args.push('-e', 'ANTHROPIC_API_KEY=placeholder');
  } else {
    args.push('-e', 'CLAUDE_CODE_OAUTH_TOKEN=placeholder');
  }
  log.info('Credential proxy wired', { containerName, authMode });

  // Host gateway
  args.push(...hostGatewayArgs());

  // User mapping
  const hostUid = process.getuid?.();
  const hostGid = process.getgid?.();
  if (hostUid != null && hostUid !== 0 && hostUid !== 1000) {
    args.push('--user', `${hostUid}:${hostGid}`);
    args.push('-e', 'HOME=/home/node');
  }

  // Volume mounts
  for (const mount of mounts) {
    if (mount.readonly) {
      args.push(...readonlyMountArgs(mount.hostPath, mount.containerPath));
    } else {
      args.push('-v', `${mount.hostPath}:${mount.containerPath}`);
    }
  }

  // Override entrypoint: run v2 entry point directly via Bun (no tsc, no stdin).
  args.push('--entrypoint', 'bash');

  // Use per-agent-group image if one has been built, otherwise base image
  const imageTag = containerConfig.imageTag || CONTAINER_IMAGE;
  args.push(imageTag);

  args.push('-c', 'exec bun run /app/src/index.ts');

  return args;
}

/** Build a per-agent-group Docker image with custom packages. */
export async function buildAgentGroupImage(agentGroupId: string): Promise<void> {
  const agentGroup = getAgentGroup(agentGroupId);
  if (!agentGroup) throw new Error('Agent group not found');

  const configRow = getContainerConfig(agentGroup.id);
  if (!configRow) throw new Error('Container config not found');
  const aptPackages = JSON.parse(configRow.packages_apt) as string[];
  const npmPackages = JSON.parse(configRow.packages_npm) as string[];
  if (aptPackages.length === 0 && npmPackages.length === 0) {
    throw new Error('No packages to install. Use install_packages first.');
  }

  let dockerfile = `FROM ${CONTAINER_IMAGE}\nUSER root\n`;
  if (aptPackages.length > 0) {
    dockerfile += `RUN apt-get update && apt-get install -y ${aptPackages.join(' ')} && rm -rf /var/lib/apt/lists/*\n`;
  }
  if (npmPackages.length > 0) {
    // pnpm skips build scripts unless packages are allowlisted. Append each
    // to /root/.npmrc (base image sets it up for agent-browser) so packages
    // with postinstall — e.g. playwright, puppeteer, native addons — don't
    // install silently broken.
    const allowlist = npmPackages.map((p) => `echo 'only-built-dependencies[]=${p}' >> /root/.npmrc`).join(' && ');
    dockerfile += `RUN ${allowlist} && pnpm install -g ${npmPackages.join(' ')}\n`;
  }
  dockerfile += 'USER node\n';

  const imageTag = `${CONTAINER_IMAGE_BASE}:${agentGroupId}`;

  log.info('Building per-agent-group image', { agentGroupId, imageTag, apt: aptPackages, npm: npmPackages });

  // Write Dockerfile to temp file and build
  const tmpDockerfile = path.join(DATA_DIR, `Dockerfile.${agentGroupId}`);
  fs.writeFileSync(tmpDockerfile, dockerfile);
  try {
    execSync(`${CONTAINER_RUNTIME_BIN} build -t ${imageTag} -f ${tmpDockerfile} .`, {
      cwd: DATA_DIR,
      stdio: 'pipe',
      timeout: 900_000,
    });
  } finally {
    fs.unlinkSync(tmpDockerfile);
  }

  // Store the image tag in the DB
  updateContainerConfigScalars(agentGroup.id, { image_tag: imageTag });

  log.info('Per-agent-group image built', { agentGroupId, imageTag });
}
