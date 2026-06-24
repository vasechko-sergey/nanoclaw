/**
 * Runner config — reads /workspace/agent/container.json at startup.
 *
 * This file is mounted read-only inside the container. The host writes it;
 * the runner only reads. All NanoClaw-specific configuration lives here
 * instead of environment variables.
 */
import fs from 'fs';

const CONFIG_PATH = '/workspace/agent/container.json';

/** Factuality verification level (see docs/superpowers/specs/2026-06-24-factuality-phase3-design.md).
 *  0=off, 1=numbers, 2=tool-prose, 3=all-prose. Cumulative. */
export type FactualityLevel = 0 | 1 | 2 | 3;

/**
 * Coerce container.json's value to a level 0..3. Prefer the integer
 * `factualityLevel`; if absent, map the legacy `factualityGate` string
 * (off→0, deterministic→1, full→2) for one-release back-compat.
 */
export function parseFactualityLevel(raw: unknown, legacy?: unknown): FactualityLevel {
  if (typeof raw === 'number' && Number.isFinite(raw)) {
    const n = Math.max(0, Math.min(3, Math.trunc(raw)));
    return n as FactualityLevel;
  }
  if (legacy === 'deterministic') return 1;
  if (legacy === 'full') return 2;
  return 0;
}

export interface RunnerConfig {
  provider: string;
  assistantName: string;
  groupName: string;
  agentGroupId: string;
  maxMessagesPerPrompt: number;
  mcpServers: Record<string, { command: string; args: string[]; env: Record<string, string> }>;
  model?: string;
  effort?: string;
  factualityLevel: FactualityLevel;
}

const DEFAULT_MAX_MESSAGES = 10;

let _config: RunnerConfig | null = null;

/**
 * Load config from container.json. Called once at startup.
 * Falls back to sensible defaults for any missing field.
 */
export function loadConfig(): RunnerConfig {
  if (_config) return _config;

  let raw: Record<string, unknown> = {};
  try {
    raw = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
  } catch {
    console.error(`[config] Failed to read ${CONFIG_PATH}, using defaults`);
  }

  _config = {
    provider: (raw.provider as string) || 'claude',
    assistantName: (raw.assistantName as string) || '',
    groupName: (raw.groupName as string) || '',
    agentGroupId: (raw.agentGroupId as string) || '',
    maxMessagesPerPrompt: (raw.maxMessagesPerPrompt as number) || DEFAULT_MAX_MESSAGES,
    mcpServers: (raw.mcpServers as RunnerConfig['mcpServers']) || {},
    model: (raw.model as string) || undefined,
    effort: (raw.effort as string) || undefined,
    factualityLevel: parseFactualityLevel(raw.factualityLevel, raw.factualityGate),
  };

  return _config;
}

/** Get the loaded config. Throws if loadConfig() hasn't been called. */
export function getConfig(): RunnerConfig {
  if (!_config) throw new Error('Config not loaded — call loadConfig() first');
  return _config;
}
