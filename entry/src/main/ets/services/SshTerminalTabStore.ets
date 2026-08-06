/**
 * SSH terminal tab registry.
 *
 * The SSH page owns one persistent workspace. This registry owns the set of
 * SSH tabs and their native session identities while the page switches the
 * visible binding in place.
 * It deliberately stores no credentials or terminal payload.
 */

export type SshTerminalTabState = 'connecting' | 'connected' | 'reconnecting' | 'error';

export interface SshTerminalTabView {
  tabId: string;
  hostId: string;
  label: string;
  address: string;
  state: SshTerminalTabState;
  sessionId: number;
  generation: number;
  active: boolean;
}

interface SshTerminalTabRecord extends SshTerminalTabView {
  error: string;
}

export class SshTerminalTabStore {
  private static instance: SshTerminalTabStore;
  private records: Map<string, SshTerminalTabRecord> = new Map<string, SshTerminalTabRecord>();
  private activeHostId: string = '';
  private listeners: Array<() => void> = [];

  static getInstance(): SshTerminalTabStore {
    if (!SshTerminalTabStore.instance) {
      SshTerminalTabStore.instance = new SshTerminalTabStore();
    }
    return SshTerminalTabStore.instance;
  }

  subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      const index: number = this.listeners.indexOf(listener);
      if (index >= 0) {
        this.listeners.splice(index, 1);
      }
    };
  }

  private notify(): void {
    const listeners: Array<() => void> = this.listeners.slice();
    for (let index = 0; index < listeners.length; index++) {
      try { listeners[index](); } catch (_err) { /* a stale page must not break the registry */ }
    }
  }

  open(hostId: string, label: string, address: string): void {
    const normalizedHostId: string = hostId.trim();
    if (normalizedHostId.length === 0) { return; }
    const existing: SshTerminalTabRecord | undefined = this.records.get(normalizedHostId);
    if (existing !== undefined) {
      existing.label = label;
      existing.address = address;
      this.notify();
      return;
    }
    this.records.set(normalizedHostId, {
      tabId: normalizedHostId,
      hostId: normalizedHostId,
      label,
      address,
      state: 'connecting',
      sessionId: -1,
      generation: 0,
      active: false,
      error: ''
    });
    this.notify();
  }

  activate(hostId: string): void {
    const normalizedHostId: string = hostId.trim();
    if (normalizedHostId.length === 0 || !this.records.has(normalizedHostId)) { return; }
    this.activeHostId = normalizedHostId;
    this.notify();
  }

  update(hostId: string, state: SshTerminalTabState, sessionId: number = -1,
    error: string = '', generation: number = -1): void {
    const record: SshTerminalTabRecord | undefined = this.records.get(hostId.trim());
    if (record === undefined) { return; }
    record.state = state;
    if (sessionId >= 0) { record.sessionId = sessionId; }
    if (generation >= 0) { record.generation = generation; }
    record.error = error;
    this.notify();
  }

  /** Start a new connection attempt without reusing the old surface identity. */
  beginConnection(hostId: string): void {
    const record: SshTerminalTabRecord | undefined = this.records.get(hostId.trim());
    if (record === undefined) { return; }
    record.state = 'connecting';
    record.sessionId = -1;
    record.generation = 0;
    record.error = '';
    this.notify();
  }

  /** Clear a dead native session while retaining the tab and its xterm page. */
  invalidateSession(hostId: string, state: SshTerminalTabState = 'error',
    error: string = ''): void {
    const record: SshTerminalTabRecord | undefined = this.records.get(hostId.trim());
    if (record === undefined) { return; }
    record.state = state;
    record.sessionId = -1;
    record.generation = 0;
    record.error = error;
    this.notify();
  }

  sessionId(hostId: string): number {
    return this.records.get(hostId.trim())?.sessionId ?? -1;
  }

  sessionGeneration(hostId: string): number {
    return this.records.get(hostId.trim())?.generation ?? 0;
  }

  has(hostId: string): boolean {
    return this.records.has(hostId.trim());
  }

  views(): SshTerminalTabView[] {
    const result: SshTerminalTabView[] = [];
    this.records.forEach((record: SshTerminalTabRecord): void => {
      result.push({
        tabId: record.tabId,
        hostId: record.hostId,
        label: record.label,
        address: record.address,
        state: record.state,
        sessionId: record.sessionId,
        generation: record.generation,
        active: record.hostId === this.activeHostId
      });
    });
    return result;
  }

  sessionIds(): number[] {
    const result: number[] = [];
    this.records.forEach((record: SshTerminalTabRecord): void => {
      if (record.sessionId > 0) { result.push(record.sessionId); }
    });
    return result;
  }

  closeAll(): number[] {
    const sessionIds: number[] = this.sessionIds();
    this.records.clear();
    this.activeHostId = '';
    this.notify();
    return sessionIds;
  }
}
