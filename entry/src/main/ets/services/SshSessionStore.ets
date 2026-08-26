/**
 * ArkTS-side SSH session registry.
 *
 * Tabs are views; this store owns the identity that outlives a view.  It never
 * stores passwords, key material, terminal payloads, or adapter references.
 * Every mutation is fenced by sessionId + channelId + generation so a late
 * callback cannot update a newly adopted session.
 */

import { SshSessionSnapshot } from '../types/rdpnapi';
import { DiagnosticOutcome } from './DiagnosticCapturePolicy';
import { recordDiagnosticEvent } from './DiagnosticCaptureRuntime';

export type SshSessionLifecycleState =
  | 'Created'
  | 'Connecting'
  | 'Authenticating'
  | 'Ready'
  | 'NetworkLost'
  | 'ReconnectScheduled'
  | 'Reconnecting'
  | 'NeedsAuthentication'
  | 'Failed'
  | 'Closing'
  | 'Closed';

export interface SshSessionHandle {
  sessionId: number;
  channelId: string;
  generation: number;
}

export interface SshSessionContext {
  schemaVersion: number;
  sessionId: number;
  channelId: string;
  generation: number;
  hostId: string;
  label: string;
  address: string;
  state: SshSessionLifecycleState;
  eventSequence: number;
  backgroundLimited: boolean;
  detached: boolean;
  unreadOutput: number;
  lastEventType: string;
  error: string;
}

export interface SshSessionStoreEvent {
  schemaVersion: number;
  sessionId: number;
  channelId: string;
  generation: number;
  sequence: number;
  timestampMs: number;
  priority: number;
  type: string;
  payloadJson: string;
}

export interface SshSessionStoreChange {
  kind: 'created' | 'changed' | 'removed';
  context: SshSessionContext;
  event: SshSessionStoreEvent | null;
}

interface SshSessionRecord {
  context: SshSessionContext;
  events: SshSessionStoreEvent[];
}

export const SSH_SESSION_SCHEMA_VERSION: number = 1;
export const SSH_SESSION_DEFAULT_CHANNEL: string = 'shell';
export const SSH_SESSION_MAX_SESSIONS: number = 32;
export const SSH_SESSION_MAX_EVENTS: number = 128;
const SSH_SESSION_MAX_EVENT_PAYLOAD: number = 2048;

function diagnosticSshLifecycleCode(state: SshSessionLifecycleState): number {
  switch (state) {
    case 'Created': return 1;
    case 'Connecting': return 2;
    case 'Authenticating': return 3;
    case 'Ready': return 4;
    case 'NetworkLost': return 5;
    case 'ReconnectScheduled': return 6;
    case 'Reconnecting': return 7;
    case 'NeedsAuthentication': return 8;
    case 'Failed': return 9;
    case 'Closing': return 10;
    case 'Closed': return 11;
  }
}

function diagnosticSshLifecycleOutcome(state: SshSessionLifecycleState): DiagnosticOutcome {
  if (state === 'Failed') { return 'failed'; }
  if (state === 'NetworkLost' || state === 'ReconnectScheduled' || state === 'Reconnecting') {
    return 'retry';
  }
  if (state === 'Created' || state === 'Connecting') { return 'started'; }
  if (state === 'Closed') { return 'succeeded'; }
  return 'state';
}

export function isValidSshSessionHandle(handle: SshSessionHandle): boolean {
  return Number.isFinite(handle.sessionId) && handle.sessionId > 0 &&
    Number.isInteger(handle.sessionId) && handle.channelId.trim().length > 0 &&
    Number.isFinite(handle.generation) && handle.generation > 0 &&
    Number.isInteger(handle.generation);
}

export function sameSshSessionHandle(left: SshSessionHandle, right: SshSessionHandle): boolean {
  return left.sessionId === right.sessionId && left.generation === right.generation &&
    left.channelId === right.channelId;
}

export function sshSessionStateFromNative(value: number | string): SshSessionLifecycleState {
  if (typeof value === 'string') {
    switch (value) {
      case 'Created':
      case 'Connecting':
      case 'Authenticating':
      case 'Ready':
      case 'NetworkLost':
      case 'ReconnectScheduled':
      case 'Reconnecting':
      case 'NeedsAuthentication':
      case 'Failed':
      case 'Closing':
      case 'Closed':
        return value;
      default:
        return 'Failed';
    }
  }
  switch (Math.floor(value)) {
    case 0: return 'Created';
    case 1: return 'Connecting';
    case 2: return 'Authenticating';
    case 3: return 'Ready';
    case 4: return 'NetworkLost';
    case 5: return 'ReconnectScheduled';
    case 6: return 'Reconnecting';
    case 7: return 'NeedsAuthentication';
    case 8: return 'Failed';
    case 9: return 'Closing';
    case 10: return 'Closed';
    default: return 'Failed';
  }
}

function normalizeHostId(hostId: string): string {
  return hostId.trim();
}

function cloneHandle(context: SshSessionContext): SshSessionHandle {
  return {
    sessionId: context.sessionId,
    channelId: context.channelId,
    generation: context.generation
  };
}

function cloneContext(context: SshSessionContext): SshSessionContext {
  return {
    schemaVersion: context.schemaVersion,
    sessionId: context.sessionId,
    channelId: context.channelId,
    generation: context.generation,
    hostId: context.hostId,
    label: context.label,
    address: context.address,
    state: context.state,
    eventSequence: context.eventSequence,
    backgroundLimited: context.backgroundLimited,
    detached: context.detached,
    unreadOutput: context.unreadOutput,
    lastEventType: context.lastEventType,
    error: context.error
  };
}

function cloneEvent(event: SshSessionStoreEvent): SshSessionStoreEvent {
  return {
    schemaVersion: event.schemaVersion,
    sessionId: event.sessionId,
    channelId: event.channelId,
    generation: event.generation,
    sequence: event.sequence,
    timestampMs: event.timestampMs,
    priority: event.priority,
    type: event.type,
    payloadJson: event.payloadJson
  };
}

function canTransition(from: SshSessionLifecycleState, to: SshSessionLifecycleState): boolean {
  if (from === to) { return true; }
  if (to === 'Closing' || to === 'Closed') {
    return from !== 'Closed';
  }
  switch (from) {
    case 'Created': return to === 'Connecting' || to === 'Failed';
    case 'Connecting': return to === 'Authenticating' || to === 'Ready' ||
      to === 'NetworkLost' || to === 'ReconnectScheduled' || to === 'Failed';
    case 'Authenticating': return to === 'Ready' || to === 'NeedsAuthentication' ||
      to === 'NetworkLost' || to === 'Failed';
    case 'Ready': return to === 'NetworkLost' || to === 'Reconnecting' || to === 'Failed';
    case 'NetworkLost': return to === 'ReconnectScheduled' || to === 'Reconnecting' || to === 'Failed';
    case 'ReconnectScheduled': return to === 'Reconnecting' || to === 'Failed';
    case 'Reconnecting': return to === 'Authenticating' || to === 'Ready' ||
      to === 'NeedsAuthentication' || to === 'NetworkLost' || to === 'Failed';
    case 'NeedsAuthentication': return to === 'Authenticating' || to === 'Ready' || to === 'Failed';
    case 'Failed': return to === 'Connecting' || to === 'Reconnecting';
    case 'Closing': return false;
    case 'Closed': return false;
  }
}

/**
 * Session registry shared by terminal views, background work and SFTP.
 * Constructing a second instance is supported for policy tests; production
 * code should use getInstance().
 */
export class SshSessionStore {
  private static instance: SshSessionStore | null = null;
  private readonly records: Map<number, SshSessionRecord> = new Map<number, SshSessionRecord>();
  private readonly hostToSession: Map<string, number> = new Map<string, number>();
  private readonly listeners: Array<(change: SshSessionStoreChange) => void> = [];
  private readonly maxSessions: number;
  private readonly maxEvents: number;

  constructor(maxSessions: number = SSH_SESSION_MAX_SESSIONS,
    maxEvents: number = SSH_SESSION_MAX_EVENTS) {
    this.maxSessions = Math.max(1, Math.floor(maxSessions));
    this.maxEvents = Math.max(1, Math.floor(maxEvents));
  }

  static getInstance(): SshSessionStore {
    if (SshSessionStore.instance === null) {
      SshSessionStore.instance = new SshSessionStore();
    }
    return SshSessionStore.instance;
  }

  subscribe(listener: (change: SshSessionStoreChange) => void): () => void {
    this.listeners.push(listener);
    let active: boolean = true;
    return (): void => {
      if (!active) { return; }
      active = false;
      const index: number = this.listeners.indexOf(listener);
      if (index >= 0) { this.listeners.splice(index, 1); }
    };
  }

  private notify(change: SshSessionStoreChange): void {
    const listeners: Array<(change: SshSessionStoreChange) => void> = this.listeners.slice();
    for (let index = 0; index < listeners.length; index++) {
      try { listeners[index](change); } catch (_err) { /* stale views cannot break the store */ }
    }
  }

  private appendEvent(record: SshSessionRecord, type: string, payloadJson: string = '',
    priority: number = 0,
    diagnosticState: SshSessionLifecycleState | null = null): SshSessionStoreEvent {
    const boundedPayload: string = payloadJson.substring(0, SSH_SESSION_MAX_EVENT_PAYLOAD);
    const context: SshSessionContext = record.context;
    context.eventSequence++;
    context.lastEventType = type.substring(0, 96);
    const event: SshSessionStoreEvent = {
      schemaVersion: SSH_SESSION_SCHEMA_VERSION,
      sessionId: context.sessionId,
      channelId: context.channelId,
      generation: context.generation,
      sequence: context.eventSequence,
      timestampMs: Date.now(),
      priority: Math.max(0, Math.min(255, Math.floor(priority))),
      type: context.lastEventType,
      payloadJson: boundedPayload
    };
    record.events.push(event);
    while (record.events.length > this.maxEvents) { record.events.shift(); }
    if (!type.startsWith('terminal.output.')) {
      const stateForDiagnostics: SshSessionLifecycleState = diagnosticState ?? context.state;
      recordDiagnosticEvent('connection.ssh_sftp', 'ssh_session_event',
        diagnosticSshLifecycleOutcome(stateForDiagnostics), context.sessionId,
        context.generation, diagnosticSshLifecycleCode(stateForDiagnostics));
    }
    return event;
  }

  private removeRecord(sessionId: number): SshSessionContext | null {
    const record: SshSessionRecord | undefined = this.records.get(sessionId);
    if (record === undefined) { return null; }
    this.records.delete(sessionId);
    if (this.hostToSession.get(record.context.hostId) === sessionId) {
      this.hostToSession.delete(record.context.hostId);
    }
    const context: SshSessionContext = cloneContext(record.context);
    this.notify({ kind: 'removed', context, event: null });
    return context;
  }

  /** Reserve a new native identity before its asynchronous connect settles. */
  reserve(hostId: string, label: string, address: string, handle: SshSessionHandle): boolean {
    const owner: string = normalizeHostId(hostId);
    if (owner.length === 0 || !isValidSshSessionHandle(handle)) {
      return false;
    }
    const oldSessionId: number | undefined = this.hostToSession.get(owner);
    if (oldSessionId !== undefined && oldSessionId !== handle.sessionId) {
      const old: SshSessionRecord | undefined = this.records.get(oldSessionId);
      if (old !== undefined && old.context.state !== 'Closed' && old.context.state !== 'Failed') {
        return false;
      }
      this.removeRecord(oldSessionId);
    }
    // Reclaiming a terminal owner above can free the only slot. Enforce the
    // global bound only after that host-local stale record has been removed;
    // otherwise a full registry permanently blocks reconnecting that host.
    if (this.records.size >= this.maxSessions || this.records.has(handle.sessionId)) { return false; }
    const context: SshSessionContext = {
      schemaVersion: SSH_SESSION_SCHEMA_VERSION,
      sessionId: handle.sessionId,
      channelId: handle.channelId.trim(),
      generation: handle.generation,
      hostId: owner,
      label,
      address,
      state: 'Created',
      eventSequence: 0,
      backgroundLimited: false,
      detached: false,
      unreadOutput: 0,
      lastEventType: '',
      error: ''
    };
    const record: SshSessionRecord = { context, events: [] };
    const event: SshSessionStoreEvent = this.appendEvent(record, 'session.created');
    this.records.set(handle.sessionId, record);
    this.hostToSession.set(owner, handle.sessionId);
    this.notify({ kind: 'created', context: cloneContext(context), event: cloneEvent(event) });
    return true;
  }

  /** Register a session which was adopted from the background/detached set. */
  registerExisting(hostId: string, label: string, address: string,
    handle: SshSessionHandle, state: SshSessionLifecycleState = 'Ready'): boolean {
    if (!isValidSshSessionHandle(handle)) { return false; }
    const owner: string = normalizeHostId(hostId);
    if (owner.length === 0) { return false; }
    const existing: SshSessionRecord | undefined = this.records.get(handle.sessionId);
    if (existing !== undefined) {
      if (existing.context.channelId !== handle.channelId ||
        existing.context.generation !== handle.generation ||
        existing.context.hostId !== owner) {
        // A native session identity is not a host identity.  A late adoption
        // callback for another host must not relabel the live owner or create
        // a second host-to-session mapping around the existing record.
        return false;
      }
      existing.context.label = label;
      existing.context.address = address;
      existing.context.detached = false;
      this.hostToSession.set(owner, handle.sessionId);
      return this.transition(handle, state, 'session.adopted');
    }
    if (!this.reserve(owner, label, address, handle)) { return false; }
    const record: SshSessionRecord | undefined = this.records.get(handle.sessionId);
    if (record === undefined) { return false; }
    if (state !== 'Created') {
      // registerExisting adopts a native session whose transport/auth work
      // happened before this registry observed it. Ready is therefore a
      // deliberate adoption edge, not a normal Created lifecycle shortcut.
      const adoptedReady: boolean = record.context.state === 'Created' && state === 'Ready';
      if (!canTransition(record.context.state, state) && !adoptedReady) {
        this.removeRecord(handle.sessionId);
        return false;
      }
      const event: SshSessionStoreEvent = this.appendEvent(
        record, 'session.adopted', '', 0, state);
      record.context.state = state;
      this.notify({ kind: 'changed', context: cloneContext(record.context), event: cloneEvent(event) });
    }
    return true;
  }

  /** Advance a reconnect generation without accepting the old callback identity. */
  rebindGeneration(sessionId: number, channelId: string, expectedGeneration: number,
    nextGeneration: number): SshSessionHandle | null {
    const record: SshSessionRecord | undefined = this.records.get(sessionId);
    if (record === undefined || record.context.channelId !== channelId ||
      record.context.generation !== expectedGeneration || !Number.isInteger(nextGeneration) ||
      nextGeneration <= expectedGeneration) { return null; }
    record.context.generation = nextGeneration;
    const event: SshSessionStoreEvent = this.appendEvent(record, 'session.generation.changed');
    this.notify({ kind: 'changed', context: cloneContext(record.context), event: cloneEvent(event) });
    return cloneHandle(record.context);
  }

  accepts(handle: SshSessionHandle): boolean {
    if (!isValidSshSessionHandle(handle)) { return false; }
    const record: SshSessionRecord | undefined = this.records.get(handle.sessionId);
    return record !== undefined && sameSshSessionHandle(cloneHandle(record.context), handle) &&
      record.context.state !== 'Closed';
  }

  transition(handle: SshSessionHandle, state: SshSessionLifecycleState, type: string,
    payloadJson: string = '', priority: number = 0): boolean {
    if (!this.accepts(handle) || type.trim().length === 0) { return false; }
    const record: SshSessionRecord | undefined = this.records.get(handle.sessionId);
    if (record === undefined || !canTransition(record.context.state, state)) { return false; }
    record.context.state = state;
    if (state === 'Failed') { record.context.error = payloadJson.substring(0, 512); }
    if (state !== 'Failed' && state !== 'Closing') { record.context.error = ''; }
    const event: SshSessionStoreEvent = this.appendEvent(record, type, payloadJson, priority);
    this.notify({ kind: 'changed', context: cloneContext(record.context), event: cloneEvent(event) });
    return true;
  }

  setBackgroundLimited(handle: SshSessionHandle, limited: boolean, reason: string = ''): boolean {
    if (!this.accepts(handle)) { return false; }
    const record: SshSessionRecord | undefined = this.records.get(handle.sessionId);
    if (record === undefined) { return false; }
    record.context.backgroundLimited = limited;
    const event: SshSessionStoreEvent = this.appendEvent(record,
      limited ? 'background.limited' : 'background.available', reason);
    this.notify({ kind: 'changed', context: cloneContext(record.context), event: cloneEvent(event) });
    return true;
  }

  markDetached(handle: SshSessionHandle, detached: boolean): boolean {
    if (!this.accepts(handle)) { return false; }
    const record: SshSessionRecord | undefined = this.records.get(handle.sessionId);
    if (record === undefined) { return false; }
    record.context.detached = detached;
    const event: SshSessionStoreEvent = this.appendEvent(record,
      detached ? 'view.detached' : 'view.attached');
    this.notify({ kind: 'changed', context: cloneContext(record.context), event: cloneEvent(event) });
    return true;
  }

  noteOutput(handle: SshSessionHandle, bytes: number, consumed: boolean = false): boolean {
    if (!this.accepts(handle) || !Number.isFinite(bytes) || bytes < 0) { return false; }
    const record: SshSessionRecord | undefined = this.records.get(handle.sessionId);
    if (record === undefined) { return false; }
    record.context.unreadOutput = consumed ? 0 : record.context.unreadOutput + Math.floor(bytes);
    const event: SshSessionStoreEvent = this.appendEvent(record,
      consumed ? 'terminal.output.consumed' : 'terminal.output.received');
    this.notify({ kind: 'changed', context: cloneContext(record.context), event: cloneEvent(event) });
    return true;
  }

  close(handle: SshSessionHandle, reason: string = 'session.close'): boolean {
    if (!this.accepts(handle)) { return false; }
    const closing: boolean = this.transition(handle, 'Closing', reason);
    if (!closing) { return false; }
    return this.transition(handle, 'Closed', 'session.closed');
  }

  handleForHost(hostId: string): SshSessionHandle | null {
    const sessionId: number | undefined = this.hostToSession.get(normalizeHostId(hostId));
    if (sessionId === undefined) { return null; }
    const record: SshSessionRecord | undefined = this.records.get(sessionId);
    return record === undefined ? null : cloneHandle(record.context);
  }

  context(handle: SshSessionHandle): SshSessionContext | null {
    if (!isValidSshSessionHandle(handle)) { return null; }
    const record: SshSessionRecord | undefined = this.records.get(handle.sessionId);
    if (record === undefined || !sameSshSessionHandle(cloneHandle(record.context), handle)) { return null; }
    return cloneContext(record.context);
  }

  contexts(): SshSessionContext[] {
    const result: SshSessionContext[] = [];
    this.records.forEach((record: SshSessionRecord): void => {
      result.push(cloneContext(record.context));
    });
    return result;
  }

  events(handle: SshSessionHandle, afterSequence: number = 0): SshSessionStoreEvent[] {
    if (!isValidSshSessionHandle(handle)) { return []; }
    const record: SshSessionRecord | undefined = this.records.get(handle.sessionId);
    if (record === undefined || !sameSshSessionHandle(cloneHandle(record.context), handle)) { return []; }
    const after: number = Number.isFinite(afterSequence) && afterSequence >= 0
      ? Math.floor(afterSequence) : 0;
    return record.events.filter((event: SshSessionStoreEvent): boolean => event.sequence > after)
      .map((event: SshSessionStoreEvent): SshSessionStoreEvent => cloneEvent(event));
  }

  applyNativeSnapshot(hostId: string, label: string, address: string,
    handle: SshSessionHandle, snapshot: SshSessionSnapshot): boolean {
    const state: SshSessionLifecycleState = sshSessionStateFromNative(snapshot.stateName || snapshot.state);
    if (!this.registerExisting(hostId, label, address, handle, state)) { return false; }
    if (snapshot.backgroundLimited) { this.setBackgroundLimited(handle, true, 'native.snapshot'); }
    return true;
  }

  removeClosed(handle: SshSessionHandle): boolean {
    const context: SshSessionContext | null = this.context(handle);
    if (context === null || context.state !== 'Closed') { return false; }
    return this.removeRecord(handle.sessionId) !== null;
  }
}
