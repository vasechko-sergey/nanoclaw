export interface SummaryPayload {
  date: string;
  count: number;
}

export type SummaryEmitter = (personKey: string, payload: SummaryPayload) => void;

let emitter: SummaryEmitter | undefined;

/** A channel adapter registers how to deliver the morning summary notification. */
export function registerSummaryEmitter(fn: SummaryEmitter): void {
  emitter = fn;
}

export function getSummaryEmitter(): SummaryEmitter | undefined {
  return emitter;
}

/** Test-only reset. */
export function __resetSummaryEmitter(): void {
  emitter = undefined;
}
