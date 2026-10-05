import { common } from '@kit.AbilityKit';
import { DEBUG } from 'BuildProfile';
import rdpnapi, { RdpSecurityKeyRequest } from 'librdpnapi.so';
import { ProAccessContext } from './ProAccessPolicy';
import { ProAppRuntime } from './ProAppRuntime';
import { ProUsbFidoKeyCandidate, ProUsbFidoKeys, ProUsbFidoKeySession } from './ProUsbFidoKey';
import { CTAP2_ERR_NO_CREDENTIALS, CTAP2_ERR_OPERATION_DENIED, ctapResponseFromPasskey, ctapStatus, parseCtapCommand,
  passkeyRequestFromCtap } from './passkey/ProPasskeyCtap';
import { ProPasskeyChannel } from './passkey/ProPasskeyChannel';
import { passkeyDeviceLabel, ProPasskeyDevice } from './passkey/ProPasskeyDevice';
import { randomBytes } from './passkey/ProPasskeyKeys';
import { ProPasskeyReceiver } from './passkey/ProPasskeyReceiver';

export const PRO_SECURITY_KEY_FEATURE: string = 'pro.security.webauthnRedirect';
const USB_CAPABILITY: string = 'SystemCapability.USB.USBManager';

const KIND_CONFIRM: number = 1;
const KIND_SELECT: number = 2;
const KIND_PIN: number = 3;
const KIND_TOUCH: number = 4;
const KIND_WRITE: number = 5;
const KIND_READ: number = 6;
const KIND_RELEASE: number = 7;
const KIND_DISMISS: number = 8;
const KIND_PASSKEY: number = 9;
const AUTHENTICATOR_PHONE: number = 2;
const PASSKEY_RESPONSE: number = 1;

// CTAP2 client PIN: at least 4 characters (code points), at most 63 bytes of UTF-8.
const PIN_MIN_CHARACTERS: number = 4;
const PIN_MAX_BYTES: number = 63;

export type RdpSecurityKeyPromptKind = 'confirm' | 'select' | 'pin' | 'touch' | 'phone';

/** What the RDP session page shows; null hides the prompt. */
export interface RdpSecurityKeyPrompt {
  kind: RdpSecurityKeyPromptKind;
  requestId: number;
  /** confirm: the remote relying party, e.g. github.com */
  rpId: string;
  /** confirm: true for registration, false for sign-in */
  register: boolean;
  /** pin: remaining attempts, -1 when unknown, 0 when the key's PIN is blocked */
  retries: number;
  /** select: FIDO HID interfaces currently plugged in */
  candidates: ProUsbFidoKeyCandidate[];
  /** select: true while the system authorization dialog is open */
  busy: boolean;
  error: string;
  /** select: the paired phone's passkey may answer instead of a USB key */
  phone: boolean;
}

/** Entitlement context for this feature: RDP on this device, with the USB capability when the system has it. */
export function rdpSecurityKeyContext(): ProAccessContext {
  const context: ProAccessContext = ProAppRuntime.getInstance().context('rdp');
  try {
    if (canIUse(USB_CAPABILITY)) { context.capabilities = [USB_CAPABILITY]; }
  } catch (_error) { /* capability unavailable */ }
  return context;
}

/** Why a PIN cannot be sent to the key, or '' when it can. Checked locally so a typo never costs a key retry. */
export function rdpSecurityKeyPinProblem(pin: string): string {
  let characters: number = 0;
  let bytes: number = 0;
  for (const character of pin) {
    const code: number = character.codePointAt(0) ?? 0;
    if (code === 0) { return 'PIN 不能包含空字符'; }
    characters++;
    bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
  }
  if (characters < PIN_MIN_CHARACTERS) { return 'PIN 至少 4 位'; }
  if (bytes > PIN_MAX_BYTES) { return 'PIN 太长'; }
  return '';
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
  private watchId: number = 0;
  private stopped: boolean = true;
  private draining: boolean = false;
  private key: ProUsbFidoKeySession | null = null;
  private keys: ProUsbFidoKeys = new ProUsbFidoKeys();
  private prompt: RdpSecurityKeyPrompt | null = null;
  private onPrompt: (prompt: RdpSecurityKeyPrompt | null) => void;
  private stopRuntime: (() => void) | null = null;
  /** For the phone path: the cross-device permission is requested from this context. */
  private context: common.UIAbilityContext | null = null;

  constructor(onPrompt: (prompt: RdpSecurityKeyPrompt | null) => void) { this.onPrompt = onPrompt; }

  attachContext(context: common.UIAbilityContext): void { this.context = context; }

  /** Starts answering the broker of a connected session. False when the session has no broker. */
  start(sessionId: number): boolean {
    if (!ProRdpSecurityKey.available() || !Number.isInteger(sessionId) || sessionId <= 0) { return false; }
    this.stop();
    let watchId: number = 0;
    try { watchId = rdpnapi.rdpSecurityKeyWatch(sessionId, (): void => { this.drain(); }); }
    catch (_error) { watchId = 0; }
    if (!Number.isInteger(watchId) || watchId <= 0) { return false; }
    this.sessionId = sessionId;
    this.watchId = watchId;
    this.stopped = false;
    // Pro revocation, account change or Debug view change ends the current request; the key is released.
    this.stopRuntime = ProAppRuntime.getInstance().runtime.subscribe((): void => {
      if (!this.stopped && !ProRdpSecurityKey.available()) { this.cancel(); this.releaseKey(true); }
    });
    this.drain();
    return true;
  }

  /**
   * Stops answering. When another page has taken over the session's watch (independent-window handoff), the
   * session's request and authorization are left to that page; only this page's own key and prompt go away.
   */
  stop(): void {
    const sessionId = this.sessionId;
    const watchId = this.watchId;
    this.stopped = true;
    if (this.stopRuntime !== null) { this.stopRuntime(); this.stopRuntime = null; }
    let owner: boolean = false;
    if (sessionId > 0 && watchId > 0) {
      try { owner = rdpnapi.rdpSecurityKeyUnwatch(sessionId, watchId); } catch (_error) { owner = false; }
      if (owner) { try { rdpnapi.rdpSecurityKeyCancel(sessionId); } catch (_error) {} }
    }
    this.releaseKey(owner);
    this.sessionId = 0;
    this.watchId = 0;
    this.show(null);
  }

  /** The user dismissed the prompt or cancelled while the key was waiting for a touch. */
  cancel(): void {
    const current = this.prompt;
    if (current !== null && current.kind !== 'touch') { this.respond(current.requestId, false, null, null); }
    if (!this.stopped && this.sessionId > 0) {
      try { rdpnapi.rdpSecurityKeyCancel(this.sessionId); } catch (_error) {}
    }
    this.show(null);
  }

  answerConfirm(requestId: number, allowed: boolean): void {
    if (!this.matches(requestId, 'confirm')) { return; }
    this.respond(requestId, allowed && ProRdpSecurityKey.available(), null, null);
    this.show(null);
  }

  answerPin(requestId: number, pin: string): void {
    if (!this.matches(requestId, 'pin')) { return; }
    const accepted = rdpSecurityKeyPinProblem(pin) === '' && ProRdpSecurityKey.available();
    this.respond(requestId, accepted, null, accepted ? pin : null);
    this.show(null);
  }

  /** The user chose the paired phone instead of a USB key; it answers this session's requests from now on. */
  choosePhone(requestId: number): void {
    const current = this.prompt;
    if (current === null || current.kind !== 'select' || current.requestId !== requestId || current.busy ||
        !current.phone || this.stopped || this.sessionId <= 0) { return; }
    this.releaseKey(true);
    try { rdpnapi.rdpSecurityKeyRespondEx(this.sessionId, requestId, true, null, AUTHENTICATOR_PHONE); }
    catch (_error) { /* the request already ended; its dismissal follows */ }
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
    // A key still held from an earlier authorization would hold the same interface claimed.
    this.releaseKey(true);
    this.show(this.withBusy(current, true, ''));
    let key: ProUsbFidoKeySession;
    try {
      key = await this.keys.authorize(candidateKey, isCurrent);
    } catch (error) {
      if (isCurrent()) {
        this.show(this.selectPrompt(requestId, error instanceof Error ? error.message : '无法连接安全密钥'));
      }
      return;
    }
    if (!isCurrent()) { key.release(); return; }
    this.key = key;
    // The request may have ended while the system dialog was open; then nobody uses the claim.
    if (!this.respond(requestId, true, null, key.label)) { this.releaseKey(false); }
    this.show(null);
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
          retries: -1, candidates: [], busy: false, error: '', phone: false });
        return;
      case KIND_SELECT:
        if (!ProRdpSecurityKey.available()) { this.respond(request.id, false, null, null); return; }
        this.show(this.selectPrompt(request.id, ''));
        return;
      case KIND_PIN:
        if (!ProRdpSecurityKey.available()) { this.respond(request.id, false, null, null); return; }
        this.show({ kind: 'pin', requestId: request.id, rpId: '', register: false, retries: request.retries,
          candidates: [], busy: false, error: '', phone: false });
        return;
      case KIND_TOUCH:
        if (request.operation === 1) {
          this.show({ kind: 'touch', requestId: 0, rpId: '', register: false, retries: -1, candidates: [],
            busy: false, error: '', phone: false });
        } else if (this.prompt !== null && this.prompt.kind === 'touch') {
          this.show(null);
        }
        return;
      case KIND_WRITE:
      case KIND_READ:
        this.transfer(request);
        return;
      case KIND_RELEASE:
        this.releaseKey(false);
        return;
      case KIND_PASSKEY:
        void this.passkey(request);
        return;
      case KIND_DISMISS:
        // The broker gave up on this prompt (timeout, server cancel, disconnect): an answer would be ignored.
        if (this.prompt !== null && this.prompt.kind !== 'touch' && this.prompt.requestId === request.id) {
          this.show(null);
        }
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

  /**
   * One remote MakeCredential/GetAssertion answered by the paired phone: the CTAP command becomes a signed passkey
   * request; the phone's answer (or a timeout or refusal) goes back as the CTAP response.
   */
  private async passkey(request: RdpSecurityKeyRequest): Promise<void> {
    const sessionId = this.sessionId;
    const id = request.id;
    const command = parseCtapCommand(request.payload);
    if (command.status !== 0) { this.respondPasskey(sessionId, id, ctapStatus(command.status)); return; }
    if (command.foreignAllowList) {
      // The server only accepts credentials the phone never issued.
      this.respondPasskey(sessionId, id, ctapStatus(CTAP2_ERR_NO_CREDENTIALS));
      return;
    }
    const context = this.context;
    if (context === null || !ProPasskeyReceiver.available()) {
      this.respondPasskey(sessionId, id, ctapStatus(CTAP2_ERR_OPERATION_DENIED));
      return;
    }
    this.show({ kind: 'phone', requestId: id, rpId: command.rpId, register: command.op === 'register', retries: -1,
      candidates: [], busy: false, error: '', phone: true });
    const current = (): boolean => !this.stopped && this.sessionId === sessionId && this.prompt !== null &&
      this.prompt.kind === 'phone' && this.prompt.requestId === id;
    try {
      if (!(await ProPasskeyReceiver.getInstance().ensureChannel(context))) {
        if (current()) {
          this.respondPasskey(sessionId, id, ctapStatus(CTAP2_ERR_OPERATION_DENIED));
          this.show(null);
        }
        return;
      }
      const phoneRequest = await ProPasskeyDevice.signRequest(passkeyRequestFromCtap(command, randomBytes(16),
        passkeyDeviceLabel(), Date.now(), request.timeoutMs));
      const response = await ProPasskeyChannel.getInstance().send(phoneRequest);
      if (!current()) { return; }
      this.respondPasskey(sessionId, id, ctapResponseFromPasskey(command.op, response));
      this.show(null);
    } catch (_error) {
      if (current()) {
        this.respondPasskey(sessionId, id, ctapStatus(CTAP2_ERR_OPERATION_DENIED));
        this.show(null);
      }
    }
  }

  private respondPasskey(sessionId: number, requestId: number, payload: Uint8Array): void {
    if (this.stopped || this.sessionId !== sessionId || requestId <= 0) { return; }
    try { rdpnapi.rdpSecurityKeyRespondEx(sessionId, requestId, true, payload, PASSKEY_RESPONSE); } catch (_error) {}
  }

  private selectPrompt(requestId: number, error: string): RdpSecurityKeyPrompt {
    return { kind: 'select', requestId, rpId: '', register: false, retries: -1, candidates: this.keys.list(),
      busy: false, error, phone: ProPasskeyReceiver.available() };
  }

  private withBusy(prompt: RdpSecurityKeyPrompt, busy: boolean, error: string): RdpSecurityKeyPrompt {
    return { kind: prompt.kind, requestId: prompt.requestId, rpId: prompt.rpId, register: prompt.register,
      retries: prompt.retries, candidates: prompt.candidates, busy, error, phone: prompt.phone };
  }

  private matches(requestId: number, kind: RdpSecurityKeyPromptKind): boolean {
    return !this.stopped && this.prompt !== null && this.prompt.kind === kind && this.prompt.requestId === requestId;
  }

  /** False when the broker no longer waits for this request. */
  private respond(requestId: number, ok: boolean, report: Uint8Array | null, text: string | null): boolean {
    if (this.stopped || this.sessionId <= 0 || requestId <= 0) { return false; }
    try { return rdpnapi.rdpSecurityKeyRespond(this.sessionId, requestId, ok, report, text); }
    catch (_error) { return false; }
  }

  /** tellBroker: this side let go on its own, so the session's next request asks for a key again. */
  private releaseKey(tellBroker: boolean): void {
    const key = this.key;
    this.key = null;
    if (key !== null) { key.release(); }
    if (tellBroker && this.sessionId > 0) {
      try { rdpnapi.rdpSecurityKeyReleased(this.sessionId); } catch (_error) {}
    }
  }

  private show(prompt: RdpSecurityKeyPrompt | null): void {
    this.prompt = prompt;
    try { this.onPrompt(prompt); } catch (_error) { /* page already gone */ }
  }
}
