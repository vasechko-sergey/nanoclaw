export interface ReadReceipt {
  messageId: string;
  pid: string;
  deliveredAt: string; // ISO string
  readAt?: string;
  injected: boolean;
}

export class ReadReceiptStore {
  private entries = new Map<string, ReadReceipt>();

  private key(pid: string, messageId: string): string {
    return `${pid}\0${messageId}`;
  }

  record(pid: string, messageId: string, type: 'delivered' | 'read'): void {
    const k = this.key(pid, messageId);
    const now = new Date().toISOString();
    const existing = this.entries.get(k);
    if (type === 'delivered') {
      if (!existing) {
        this.entries.set(k, { messageId, pid, deliveredAt: now, injected: false });
      }
    } else {
      if (existing) {
        existing.readAt = now;
      } else {
        this.entries.set(k, { messageId, pid, deliveredAt: now, readAt: now, injected: false });
      }
    }
  }

  getPending(pid: string): ReadReceipt[] {
    const result: ReadReceipt[] = [];
    for (const r of this.entries.values()) {
      if (r.pid === pid && !r.injected) result.push({ ...r });
    }
    return result.slice(0, 20);
  }

  markInjected(receipts: ReadReceipt[]): void {
    for (const r of receipts) {
      const e = this.entries.get(this.key(r.pid, r.messageId));
      if (e) e.injected = true;
    }
  }

  hydrate(lines: string[]): void {
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        const r = JSON.parse(trimmed) as ReadReceipt;
        if (r.messageId && r.pid) {
          this.entries.set(this.key(r.pid, r.messageId), r);
        }
      } catch {}
    }
  }

  serialize(receipt: ReadReceipt): string {
    return JSON.stringify(receipt);
  }

  all(): ReadReceipt[] {
    return Array.from(this.entries.values());
  }
}
