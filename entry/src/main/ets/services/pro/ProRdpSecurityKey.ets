import { DEBUG } from 'BuildProfile';
import rdpnapi, { RdpSecurityKeyRequest } from 'librdpnapi.so';
import { ProAccessContext } from './ProAccessPolicy';
import { ProAppRuntime } from './ProAppRuntime';
import { ProUsbFidoKeyCandidate, ProUsbFidoKeys, ProUsbFidoKeySession } from './ProUsbFidoKey';

export const PRO_SECURITY_KEY_FEATURE: string = 'pro.security.webauthnRedirect';
const USB_CAPABILITY: string = 'SystemCapability.USB.USBManager';

const KIND_CONFIRM: number = 1;
const KIND_SELECT: number = 2;
const KIND_PIN: number = 3;
const KIND_TOUCH: number = 4;
const KIND_WRITE: number = 5;
const KIND_READ: number = 6;
const KIND_RELEASE: number = 7;

export type RdpSecurityKeyPromptKind = 'confirm' | 'select' | 'pin' | 'touch';

/** What the RDP session page shows; null hides the prompt. */
export interface RdpSecurityKeyPrompt {
  kind: RdpSecurityKeyPromptKind;
  requestId: number;
  /** confirm: the remote relying party, e.g. github.com */
  rpId: string;
  /** confirm: true for registration, false for sign-in */
  register: boolean;
  /** pin: remaining attempts, -1 when unknown */
  retries: number;
  /** select: FIDO HID interfaces currently plugged in */
  candidates: ProUsbFidoKeyCandidate[];
  /** select: true while the system authorization dialog is open */
  busy: boolean;
  error: string;
}

/** Entitlement context for this feature: RDP on this device, with the USB capability when the system has it. */
export function rdpSecurityKeyContext(): ProAccessContext {
  const context: ProAccessContext = ProAppRuntime.getInstance().context('rdp');
  try {
    if (canIUse(USB_CAPABILITY)) { context.capabilities = [USB_CAPABILITY]; }
  } catch (_error) { /* capability unavailable */ }
  return context;
}

/**
 * Bridges one RDP session's MS-RDPEWA broker to the local user and the USB key. The native broker drives the
 * protocol; this side only answers its requests: confirmations, key selection, PIN entry and 64-byte reports.
 */
export class ProRdpSecurityKey {
  /** Debug only, and only for an entitled account on a supported device. Release always returns false. */
  static available(): boolean {
    if (DEBUG) {
      try {
        return rdpnapi.rdpSecurityKeyAvailable() &&
          ProAppRuntime.getInstance().runtime.decision(PRO_SECURITY_KEY_FEATURE, rdpSecurityKeyContext()).executable;
      } catch (_error) {
        return false;
      }
    }
    return false;
  }

  private sessionId: number = 0;
  private stopped: boolean = true;
  private draining: boolean = false;
  private key: ProUsbFidoKeySession | null = null;
  private keys: ProUsbFidoKeys = new ProUsbFidoKeys();
  private prompt: RdpSecurityKeyPrompt | null = null;
  private onPrompt: (prompt: RdpSecurityKeyPrompt | null) => void;
  private stopRuntime: (() => void) | null = null;

  constructor(onPrompt: (prompt: RdpSecurityKeyPrompt | null) => void) { this.onPrompt = onPrompt; }

  /** Starts answering the broker of a connected session. False when the session has no broker. */
  start(sessionId: number): boolean {
    if (!ProRdpSecurityKey.available() || !Number.isInteger(sessionId) || sessionId <= 0) { return false; }
    this.stop();
    this.sessionId = sessionId;
    this.stopped = false;
    let watching: boolean = false;
    try { watching = rdpnapi.rdpSecurityKeyWatch(sessionId, (): void => { this.drain(); }); }
    catch (_error) { watching = false; }
    if (!watching) { this.stopped = true; this.sessionId = 0; return false; }
    // Pro revocation, account change or Debug view change ends the current request; the key is released.
    this.stopRuntime = ProAppRuntime.getInstance().runtime.subscribe((): void => {
      if (!this.stopped && !ProRdpSecurityKey.available()) { this.cancel(); this.releaseKey(); }
    });
    this.drain();
    return true;
  }

  stop(): void {
    const sessionId = this.sessionId;
    this.stopped = true;
    if (this.stopRuntime !== null) { this.stopRuntime(); this.stopRuntime = null; }
    if (sessionId > 0) {
      try { rdpnapi.rdpSecurityKeyCancel(sessionId); } catch (_error) {}
      try { rdpnapi.rdpSecurityKeyUnwatch(sessionId); } catch (_error) {}
    }
    this.sessionId = 0;
    this.releaseKey();
    this.show(null);
  }

  /** The user dismissed the prompt or cancelled while the key was waiting for a touch. */
  cancel(): void {
    const current = this.prompt;
    if (current !== null && current.kind !== 'touch') { this.respond(current.requestId, false, null, null); }
    if (this.sessionId > 0) { try { rdpnapi.rdpSecurityKeyCancel(this.sessionId); } catch (_error) {} }
    this.show(null);
  }

  answerConfirm(requestId: number, allowed: boolean): void {
    if (!this.matches(requestId, 'confirm')) { return; }
    this.respond(requestId, allowed && ProRdpSecurityKey.available(), null, null);
    this.show(null);
  }

  answerPin(requestId: number, pin: string): void {
    if (!this.matches(requestId, 'pin')) { return; }
    const accepted = pin.length > 0 && pin.length <= 63 && ProRdpSecurityKey.available();
    this.respond(requestId, accepted, null, accepted ? pin : null);
    this.show(null);
  }

  refreshKeys(): void {
    const current = this.prompt;
    if (current === null || current.kind !== 'select' || current.busy) { return; }
    this.show(this.selectPrompt(current.requestId, ''));
  }

  async chooseKey(requestId: number, candidateKey: string): Promise<void> {
    const current = this.prompt;
    if (current === null || current.kind !== 'select' || current.requestId !== requestId || current.busy) { return; }
    const sessionId = this.sessionId;
    const isCurrent = (): boolean => !this.stopped && this.sessionId === sessionId &&
      this.prompt !== null && this.prompt.requestId === requestId && ProRdpSecurityKey.available();
    this.show(this.withBusy(current, true, ''));
    try {
      const key = await this.keys.authorize(candidateKey, isCurrent);
      if (!isCurrent()) { key.release(); return; }
      this.releaseKey();
      this.key = key;
      this.respond(requestId, true, null, key.label);
      this.show(null);
    } catch (error) {
      if (isCurrent()) {
        this.show(this.selectPrompt(requestId, error instanceof Error ? error.message : '无法连接安全密钥'));
      }
    }
  }

  private drain(): void {
    if (this.draining || this.stopped) { return; }
    this.draining = true;
    try {
      for (let guard: number = 0; guard < 64 && !this.stopped; guard++) {
        let request: RdpSecurityKeyRequest | null = null;
        try { request = rdpnapi.rdpSecurityKeyPoll(this.sessionId); } catch (_error) { request = null; }
        if (request === null) { break; }
        this.handle(request);
      }
    } finally {
      this.draining = false;
    }
  }

  private handle(request: RdpSecurityKeyRequest): void {
    switch (request.kind) {
      case KIND_CONFIRM:
        if (!ProRdpSecurityKey.available()) { this.respond(request.id, false, null, null); return; }
        this.show({ kind: 'confirm', requestId: request.id, rpId: request.text, register: request.operation === 1,
          retries: -1, candidates: [], busy: false, error: '' });
        return;
      case KIND_SELECT:
        if (!ProRdpSecurityKey.available()) { this.respond(request.id, false, null, null); return; }
        this.show(this.selectPrompt(request.id, ''));
        return;
      case KIND_PIN:
        if (!ProRdpSecurityKey.available()) { this.respond(request.id, false, null, null); return; }
        this.show({ kind: 'pin', requestId: request.id, rpId: '', register: false, retries: request.retries,
          candidates: [], busy: false, error: '' });
        return;
      case KIND_TOUCH:
        if (request.operation === 1) {
          this.show({ kind: 'touch', requestId: 0, rpId: '', register: false, retries: -1, candidates: [],
            busy: false, error: '' });
        } else if (this.prompt !== null && this.prompt.kind === 'touch') {
          this.show(null);
        }
        return;
      case KIND_WRITE:
      case KIND_READ:
        this.transfer(request);
        return;
      case KIND_RELEASE:
        this.releaseKey();
        return;
      default:
        return;
    }
  }

  private transfer(request: RdpSecurityKeyRequest): void {
    const key = this.key;
    const sessionId = this.sessionId;
    if (key === null || !key.open) { this.respond(request.id, false, null, null); return; }
    const write = request.kind === KIND_WRITE;
    key.transfer(write, write ? request.report : new Uint8Array(64), write ? 1500 : request.timeoutMs)
      .then((data: Uint8Array | null): void => {
        if (this.stopped || this.sessionId !== sessionId) { return; }
        this.respond(request.id, data !== null, write || data === null ? null : data, null);
      });
  }

  private selectPrompt(requestId: number, error: string): RdpSecurityKeyPrompt {
    return { kind: 'select', requestId, rpId: '', register: false, retries: -1, candidates: this.keys.list(),
      busy: false, error };
  }

  private withBusy(prompt: RdpSecurityKeyPrompt, busy: boolean, error: string): RdpSecurityKeyPrompt {
    return { kind: prompt.kind, requestId: prompt.requestId, rpId: prompt.rpId, register: prompt.register,
      retries: prompt.retries, candidates: prompt.candidates, busy, error };
  }

  private matches(requestId: number, kind: RdpSecurityKeyPromptKind): boolean {
    return !this.stopped && this.prompt !== null && this.prompt.kind === kind && this.prompt.requestId === requestId;
  }

  private respond(requestId: number, ok: boolean, report: Uint8Array | null, text: string | null): void {
    if (this.sessionId <= 0 || requestId <= 0) { return; }
    try { rdpnapi.rdpSecurityKeyRespond(this.sessionId, requestId, ok, report, text); } catch (_error) {}
  }

  private releaseKey(): void {
    const key = this.key;
    this.key = null;
    if (key !== null) { key.release(); }
  }

  private show(prompt: RdpSecurityKeyPrompt | null): void {
    this.prompt = prompt;
    try { this.onPrompt(prompt); } catch (_error) { /* page already gone */ }
  }
}
