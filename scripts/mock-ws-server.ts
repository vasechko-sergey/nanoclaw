import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';

const PORT = parseInt(process.env.MOCK_WS_PORT ?? '8765', 10);
const REPLY_DELAY_MS = parseInt(process.env.MOCK_REPLY_DELAY_MS ?? '2000', 10);

const server = createServer();
const wss = new WebSocketServer({ server });

wss.on('connection', (ws: WebSocket) => {
  console.log('[mock-ws] client connected');

  ws.on('message', (data) => {
    let msg: Record<string, unknown>;
    try { msg = JSON.parse(data.toString()); } catch { return; }

    console.log(`[mock-ws] <- ${msg.type as string}`);

    if (msg.type === 'auth') {
      ws.send(JSON.stringify({ type: 'auth_ok', pid: 'ios:mock', commands: [] }));
      return;
    }

    if (msg.type === 'message') {
      if (typeof msg.clientMessageId === 'string') {
        ws.send(JSON.stringify({ type: 'message_ack', clientMessageId: msg.clientMessageId }));
      }
      const text = typeof msg.text === 'string' ? msg.text : '';
      const convId = msg.conversationId;
      setTimeout(() => {
        if (ws.readyState !== WebSocket.OPEN) return;
        ws.send(JSON.stringify({
          type: 'message',
          id: randomUUID(),
          text: `Mock: ${text}`,
          conversationId: convId,
          timestamp: new Date().toISOString(),
        }));
      }, REPLY_DELAY_MS);
      return;
    }

    if (msg.type === 'context_request') {
      ws.send(JSON.stringify({ type: 'context_response', requestId: msg.requestId, context: {} }));
      return;
    }
    // message_delivered, message_read, apns_token, feedback, new_conversation — no reply needed
  });

  ws.on('close', () => console.log('[mock-ws] client disconnected'));
  ws.on('error', (e) => console.error('[mock-ws] error:', e.message));
});

await new Promise<void>((resolve) => server.listen(PORT, '127.0.0.1', resolve));
console.log(`[mock-ws] listening on ws://127.0.0.1:${PORT}`);

for (const sig of ['SIGTERM', 'SIGINT'] as NodeJS.Signals[]) {
  process.on(sig, () => {
    wss.close();
    server.close(() => process.exit(0));
  });
}
