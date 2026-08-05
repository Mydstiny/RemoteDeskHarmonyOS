/**
 * SSH terminal tab registry.
 *
 * The router owns only the visible SSH page.  This registry owns the set of
 * SSH tabs and their native session identities so replacing the visible page
 * can detach one session and adopt another without losing the tab list.
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
  active: boolean;
}

interface SshTerminalTabRecord extends SshTerminalTabView {
  error: string;
}

export class SshTerminalTabStore {
  private static instance: SshTerminalTabStore;
  private records: Map<string, SshTerminalTabRecord> = new Map<string, SshTerminalTabRecord>();
  private activeHostId: string = '';
  private pendingNavigationHostId: string = '';
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

  beginNavigation(hostId: string): boolean {
    const normalizedHostId: string = hostId.trim();
    if (normalizedHostId.length === 0 || this.pendingNavigationHostId.length > 0) { return false; }
    this.pendingNavigationHostId = normalizedHostId;
    return true;
  }

  isNavigationPending(): boolean {
    return this.pendingNavigationHostId.length > 0;
  }

  cancelNavigation(hostId: string): void {
    const normalizedHostId: string = hostId.trim();
    if (normalizedHostId.length === 0 || this.pendingNavigationHostId === normalizedHostId) {
      this.pendingNavigationHostId = '';
    }
  }

  completeNavigation(): void {
    this.pendingNavigationHostId = '';
  }

  update(hostId: string, state: SshTerminalTabState, sessionId: number = -1,
    error: string = ''): void {
    const record: SshTerminalTabRecord | undefined = this.records.get(hostId);
    if (record === undefined) { return; }
    record.state = state;
    if (sessionId >= 0) { record.sessionId = sessionId; }
    record.error = error;
    this.notify();
  }

  sessionId(hostId: string): number {
    return this.records.get(hostId)?.sessionId ?? -1;
  }

  has(hostId: string): boolean {
    return this.records.has(hostId);
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
    this.pendingNavigationHostId = '';
    this.notify();
    return sessionIds;
  }
}
