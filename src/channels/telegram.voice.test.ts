import { describe, it, expect, vi } from 'vitest';
import { sendVoice } from './telegram.js';

describe('sendVoice', () => {
  it('POSTs multipart to sendVoice with chat_id + voice', async () => {
    const calls: any[] = [];
    const fetchMock = vi.fn(async (url: string, init: any) => {
      calls.push({ url, init });
      return new Response('{"ok":true,"result":{"message_id":5}}', { status: 200 });
    });
    const id = await sendVoice('TOKEN', '123', Buffer.from('OggS'), { fetchImpl: fetchMock as any });
    expect(calls[0].url).toContain('/botTOKEN/sendVoice');
    expect(id).toBe('5');
  });
});
