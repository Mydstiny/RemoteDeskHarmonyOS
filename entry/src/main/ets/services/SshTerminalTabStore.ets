/**
 * SSH terminal tab registry.
 *
 * The SSH page owns one persistent workspace. This registry owns the set of
 * SSH tabs and their native session identities while the page switches the
 * visible binding in place.
 * It deliberately stores no credentials or terminal payload.
 */

export type SshTerminalTabState =
  'disconnected' | 'connecting' | 'connected' | 'reconnecting' | 'error';

export interface SshTerminalTabView {
  tabId: string;
  hostId: string;
  label: string;
  address: string;
  state: SshTerminalTabState;
  sessionId: number;
  generation: number;
  pinned: boolean;
  active: boolean;
}

/** Page exit tears down every tab, so a background tab must protect the page
 * from shortcut exit even when the currently selected tab is disconnected. */
export function sshTerminalTabsHaveLiveSession(tabs: SshTerminalTabView[]): boolean {
  for (let index: number = 0; index < tabs.length; index++) {
    const tab: SshTerminalTabView = tabs[index];
    if (tab.sessionId > 0 || tab.state === 'connecting' ||
      tab.state === 'connected' || tab.state === 'reconnecting') {
      return true;
    }
  }
  return false;
}

/**
 * ArkUI ForEach preserves an item while its key is stable. Tab chrome must be
 * rebuilt when any visible tab metadata changes, while terminal surfaces keep
 * using the stable tabId so a connection-state update cannot remount xterm.
 */
export function sshTerminalTabChromeRenderKey(tab: SshTerminalTabView): string {
  return tab.tabId + '|' + tab.state + '|' + tab.sessionId.toString() + '|' +
    tab.generation.toString() + '|' + (tab.active ? '1' : '0') + '|' +
    (tab.pinned ? '1' : '0') + '|' + tab.label.length.toString() + ':' + tab.label + '|' +
    tab.address.length.toString() + ':' + tab.address;
}

export interface SshTerminalTabCloseResult {
  closed: boolean;
  hostId: string;
  sessionId: number;
  generation: number;
  wasActive: boolean;
  nextActiveHostId: string;
}

interface SshTerminalTabRecord extends SshTerminalTabView {
  error: string;
  customLabel: boolean;
}

export class SshTerminalTabStore {
  private static instance: SshTerminalTabStore;
  private records: Map<string, SshTerminalTabRecord> = new Map<string, SshTerminalTabRecord>();
  /** Session-scoped one-shot markers survive page recreation but never leave the tab store. */
  private startupExecutionKeys: Set<string> = new Set<string>();
  /** UI order only. Native session ownership remains in the records/session facade. */
  private order: Array<string> = [];
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

  private ensureOrdered(hostId: string): void {
    if (this.order.indexOf(hostId) < 0) { this.order.push(hostId); }
  }

  private removeFromOrder(hostId: string): number {
    const index: number = this.order.indexOf(hostId);
    if (index >= 0) { this.order.splice(index, 1); }
    return index;
  }

  private firstUnpinnedIndex(): number {
    for (let index: number = 0; index < this.order.length; index++) {
      const record: SshTerminalTabRecord | undefined = this.records.get(this.order[index]);
      if (record !== undefined && !record.pinned) { return index; }
    }
    return this.order.length;
  }

  private orderedHostIds(): Array<string> {
    const result: Array<string> = [];
    for (let index: number = 0; index < this.order.length; index++) {
      const hostId: string = this.order[index];
      if (this.records.has(hostId) && result.indexOf(hostId) < 0) { result.push(hostId); }
    }
    this.records.forEach((_record: SshTerminalTabRecord, hostId: string): void => {
      if (result.indexOf(hostId) < 0) { result.push(hostId); }
    });
    return result;
  }

  open(hostId: string, label: string, address: string): void {
    const normalizedHostId: string = hostId.trim();
    if (normalizedHostId.length === 0) { return; }
    const existing: SshTerminalTabRecord | undefined = this.records.get(normalizedHostId);
    if (existing !== undefined) {
      if (!existing.customLabel) { existing.label = label; }
      existing.address = address;
      this.ensureOrdered(normalizedHostId);
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
      pinned: false,
      active: false,
      error: '',
      customLabel: false
    });
    this.order.push(normalizedHostId);
    this.notify();
  }

  /** Publish a newly selected tab as active in one registry transaction. */
  openAndActivate(hostId: string, label: string, address: string): void {
    const normalizedHostId: string = hostId.trim();
    if (normalizedHostId.length === 0) { return; }
    const existing: SshTerminalTabRecord | undefined = this.records.get(normalizedHostId);
    if (existing !== undefined) {
      if (!existing.customLabel) { existing.label = label; }
      existing.address = address;
      this.ensureOrdered(normalizedHostId);
    } else {
      this.records.set(normalizedHostId, {
        tabId: normalizedHostId,
        hostId: normalizedHostId,
        label,
        address,
        state: 'connecting',
        sessionId: -1,
        generation: 0,
        pinned: false,
        active: false,
        error: '',
        customLabel: false
      });
      this.order.push(normalizedHostId);
    }
    this.activeHostId = normalizedHostId;
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
    const sessionReplaced: boolean = sessionId >= 0 && record.sessionId > 0 &&
      record.sessionId !== sessionId;
    const generationReplaced: boolean = generation >= 0 && record.generation > 0 &&
      record.generation !== generation;
    if (sessionReplaced || generationReplaced) {
      this.clearStartupExecutionKeysForHost(hostId);
    }
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
    this.clearStartupExecutionKeysForHost(hostId);
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
    this.clearStartupExecutionKeysForHost(hostId);
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

  hasStartupExecutionKey(key: string): boolean {
    return key.trim().length > 0 && this.startupExecutionKeys.has(key);
  }

  markStartupExecutionKey(key: string): void {
    const normalizedKey: string = key.trim();
    if (normalizedKey.length > 0) { this.startupExecutionKeys.add(normalizedKey); }
  }

  clearStartupExecutionKeysForHost(hostId: string, keepKey: string = ''): void {
    const normalizedHostId: string = hostId.trim();
    if (normalizedHostId.length === 0) { return; }
    const prefix: string = normalizedHostId + ':';
    const keys: Array<string> = [];
    this.startupExecutionKeys.forEach((key: string): void => {
      if (key.startsWith(prefix) && key !== keepKey) { keys.push(key); }
    });
    for (let index: number = 0; index < keys.length; index++) {
      this.startupExecutionKeys.delete(keys[index]);
    }
  }

  has(hostId: string): boolean {
    return this.records.has(hostId.trim());
  }

  activeHost(): string {
    return this.activeHostId;
  }

  renameDisplayTitle(hostId: string, title: string): boolean {
    const record: SshTerminalTabRecord | undefined = this.records.get(hostId.trim());
    const normalizedTitle: string = title.trim().slice(0, 96);
    if (record === undefined || normalizedTitle.length === 0) { return false; }
    record.label = normalizedTitle;
    record.customLabel = true;
    this.notify();
    return true;
  }

  setPinned(hostId: string, pinned: boolean): boolean {
    const normalizedHostId: string = hostId.trim();
    const record: SshTerminalTabRecord | undefined = this.records.get(normalizedHostId);
    if (record === undefined) { return false; }
    this.ensureOrdered(normalizedHostId);
    if (record.pinned === pinned) { return true; }
    this.removeFromOrder(normalizedHostId);
    record.pinned = pinned;
    const insertionIndex: number = this.firstUnpinnedIndex();
    this.order.splice(insertionIndex, 0, normalizedHostId);
    this.notify();
    return true;
  }

  /** Move one tab inside its pinned/unpinned group without touching session identity. */
  move(hostId: string, delta: number): boolean {
    const normalizedHostId: string = hostId.trim();
    const record: SshTerminalTabRecord | undefined = this.records.get(normalizedHostId);
    if (record === undefined || !Number.isFinite(delta) || delta === 0) { return false; }
    this.ensureOrdered(normalizedHostId);
    const currentIndex: number = this.order.indexOf(normalizedHostId);
    const targetIndex: number = currentIndex + (delta < 0 ? -1 : 1);
    if (currentIndex < 0 || targetIndex < 0 || targetIndex >= this.order.length) { return false; }
    const target: SshTerminalTabRecord | undefined = this.records.get(this.order[targetIndex]);
    if (target === undefined || target.pinned !== record.pinned) { return false; }
    const targetHostId: string = this.order[targetIndex];
    this.order[targetIndex] = normalizedHostId;
    this.order[currentIndex] = targetHostId;
    this.notify();
    return true;
  }

  /** Drop before another tab in the same group; drag state never enters the store. */
  moveBefore(hostId: string, beforeHostId: string): boolean {
    const normalizedHostId: string = hostId.trim();
    const normalizedBeforeHostId: string = beforeHostId.trim();
    if (normalizedHostId.length === 0 || normalizedBeforeHostId.length === 0 ||
      normalizedHostId === normalizedBeforeHostId) { return false; }
    const record: SshTerminalTabRecord | undefined = this.records.get(normalizedHostId);
    const before: SshTerminalTabRecord | undefined = this.records.get(normalizedBeforeHostId);
    if (record === undefined || before === undefined || record.pinned !== before.pinned) { return false; }
    this.ensureOrdered(normalizedHostId);
    this.ensureOrdered(normalizedBeforeHostId);
    this.removeFromOrder(normalizedHostId);
    const targetIndex: number = this.order.indexOf(normalizedBeforeHostId);
    if (targetIndex < 0) {
      this.order.push(normalizedHostId);
      return false;
    }
    this.order.splice(targetIndex, 0, normalizedHostId);
    this.notify();
    return true;
  }

  close(hostId: string): SshTerminalTabCloseResult {
    const normalizedHostId: string = hostId.trim();
    const record: SshTerminalTabRecord | undefined = this.records.get(normalizedHostId);
    if (record === undefined) {
      return {
        closed: false, hostId: normalizedHostId, sessionId: -1, generation: 0,
        wasActive: false, nextActiveHostId: this.activeHostId
      };
    }
    this.clearStartupExecutionKeysForHost(normalizedHostId);
    this.ensureOrdered(normalizedHostId);
    const removedIndex: number = this.removeFromOrder(normalizedHostId);
    const wasActive: boolean = normalizedHostId === this.activeHostId;
    this.records.delete(normalizedHostId);
    if (wasActive) {
      if (this.order.length === 0) {
        this.activeHostId = '';
      } else {
        const nextIndex: number = Math.min(Math.max(0, removedIndex), this.order.length - 1);
        this.activeHostId = this.order[nextIndex];
      }
    }
    this.notify();
    return {
      closed: true,
      hostId: normalizedHostId,
      sessionId: record.sessionId,
      generation: record.generation,
      wasActive,
      nextActiveHostId: this.activeHostId
    };
  }

  views(): SshTerminalTabView[] {
    const result: SshTerminalTabView[] = [];
    const orderedHostIds: Array<string> = this.orderedHostIds();
    for (let index: number = 0; index < orderedHostIds.length; index++) {
      const record: SshTerminalTabRecord | undefined = this.records.get(orderedHostIds[index]);
      if (record === undefined) { continue; }
      result.push({
        tabId: record.tabId,
        hostId: record.hostId,
        label: record.label,
        address: record.address,
        state: record.state,
        sessionId: record.sessionId,
        generation: record.generation,
        pinned: record.pinned,
        active: record.hostId === this.activeHostId
      });
    }
    return result;
  }

  sessionIds(): number[] {
    const result: number[] = [];
    const orderedHostIds: Array<string> = this.orderedHostIds();
    for (let index: number = 0; index < orderedHostIds.length; index++) {
      const record: SshTerminalTabRecord | undefined = this.records.get(orderedHostIds[index]);
      if (record === undefined) { continue; }
      if (record.sessionId > 0) { result.push(record.sessionId); }
    }
    return result;
  }

  closeAll(): number[] {
    const sessionIds: number[] = this.sessionIds();
    this.records.clear();
    this.startupExecutionKeys.clear();
    this.order = [];
    this.activeHostId = '';
    this.notify();
    return sessionIds;
  }
}
