import { randomUUID } from 'node:crypto';
import type { TransportDb } from './transport-db.js';
import type { ContextField } from '../../../../shared/ios-app-protocol/index.js';

export interface ContextBridgeDeps {
  db: TransportDb;
  resolvePlatformForSession: (session_id: string) => string | null;
  sendEnvelopeToDevice: (platform_id: string, envelope: unknown) => void;
  writeInboundContextResponse: (input: {
    session_id: string;
    request_id: string;
    data: Record<string, unknown>;
    errors?: Record<string, string>;
  }) => void;
}

export interface AgentRequest {
  session_id: string;
  request_id: string;
  fields: ContextField[];
  params: Record<string, unknown>;
  expires_at_ms: number;
}

export class ContextBridge {
  constructor(private deps: ContextBridgeDeps) {}

  handleAgentRequest(req: AgentRequest): void {
    const platform_id = this.deps.resolvePlatformForSession(req.session_id);
    if (!platform_id) {
      this.deps.writeInboundContextResponse({
        session_id: req.session_id,
        request_id: req.request_id,
        data: {},
        errors: { scope: 'no ios-app device wired' },
      });
      return;
    }
    this.deps.db.raw
      .prepare(
        `
      INSERT OR REPLACE INTO pending_context_requests
        (request_id, platform_id, session_id, fields_json, created_at, expires_at)
      VALUES (?, ?, ?, ?, ?, ?)
    `,
      )
      .run(req.request_id, platform_id, req.session_id, JSON.stringify(req.fields), Date.now(), req.expires_at_ms);

    this.deps.sendEnvelopeToDevice(platform_id, {
      v: 2,
      kind: 'control',
      type: 'context_request',
      id: randomUUID(),
      seq: 0, // ws-handler may replace at send time
      ts: new Date().toISOString(),
      payload: { request_id: req.request_id, fields: req.fields, params: req.params },
    });
  }

  resolveDeviceResponse(request_id: string): { session_id: string } | null {
    const row = this.deps.db.raw
      .prepare(`SELECT session_id FROM pending_context_requests WHERE request_id = ?`)
      .get(request_id) as { session_id: string } | undefined;
    if (!row) return null;
    this.deps.db.raw.prepare(`DELETE FROM pending_context_requests WHERE request_id = ?`).run(request_id);
    return { session_id: row.session_id };
  }

  sweepExpired(): void {
    const now = Date.now();
    const rows = this.deps.db.raw
      .prepare(`SELECT request_id, session_id FROM pending_context_requests WHERE expires_at < ?`)
      .all(now) as { request_id: string; session_id: string }[];
    for (const r of rows) {
      this.deps.writeInboundContextResponse({
        session_id: r.session_id,
        request_id: r.request_id,
        data: {},
        errors: { timeout: 'device offline / timeout' },
      });
    }
    this.deps.db.raw.prepare(`DELETE FROM pending_context_requests WHERE expires_at < ?`).run(now);
  }
}
