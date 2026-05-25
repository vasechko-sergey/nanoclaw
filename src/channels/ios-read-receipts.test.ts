import { describe, it, expect, beforeEach } from 'vitest';
import { ReadReceiptStore } from './ios-read-receipts.js';

describe('ReadReceiptStore', () => {
  let store: ReadReceiptStore;
  beforeEach(() => {
    store = new ReadReceiptStore();
  });

  it('records delivered event', () => {
    store.record('ios:abc', 'msg1', 'delivered');
    const pending = store.getPending('ios:abc');
    expect(pending).toHaveLength(1);
    expect(pending[0].messageId).toBe('msg1');
    expect(pending[0].deliveredAt).toBeTruthy();
    expect(pending[0].readAt).toBeUndefined();
    expect(pending[0].injected).toBe(false);
  });

  it('records read event on existing entry', () => {
    store.record('ios:abc', 'msg1', 'delivered');
    store.record('ios:abc', 'msg1', 'read');
    const pending = store.getPending('ios:abc');
    expect(pending[0].readAt).toBeTruthy();
  });

  it('creates entry for read without prior delivered', () => {
    store.record('ios:abc', 'msg1', 'read');
    const pending = store.getPending('ios:abc');
    expect(pending).toHaveLength(1);
    expect(pending[0].readAt).toBeTruthy();
  });

  it('getPending returns only uninjected entries for given pid', () => {
    store.record('ios:abc', 'msg1', 'delivered');
    store.record('ios:xyz', 'msg2', 'delivered');
    expect(store.getPending('ios:abc')).toHaveLength(1);
    expect(store.getPending('ios:xyz')).toHaveLength(1);
  });

  it('markInjected prevents entries from appearing in getPending', () => {
    store.record('ios:abc', 'msg1', 'delivered');
    const pending = store.getPending('ios:abc');
    store.markInjected(pending);
    expect(store.getPending('ios:abc')).toHaveLength(0);
  });

  it('getPending returns at most 20 entries', () => {
    for (let i = 0; i < 25; i++) store.record('ios:abc', `msg${i}`, 'delivered');
    expect(store.getPending('ios:abc')).toHaveLength(20);
  });

  it('hydrate restores state from serialized lines', () => {
    const r = { messageId: 'msg1', pid: 'ios:abc', deliveredAt: '2026-01-01T00:00:00Z', injected: false };
    store.hydrate([JSON.stringify(r)]);
    expect(store.getPending('ios:abc')).toHaveLength(1);
  });

  it('serialize returns a JSON string', () => {
    const line = store.serialize({
      messageId: 'msg1',
      pid: 'ios:abc',
      deliveredAt: '2026-01-01T00:00:00Z',
      injected: false,
    });
    expect(() => JSON.parse(line)).not.toThrow();
  });
});
