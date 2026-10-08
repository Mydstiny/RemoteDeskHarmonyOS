import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { DEBUG } from 'BuildProfile';
import rdpnapi, { RdpSecurityKeyRequest } from 'librdpnapi.so';
import { ProAccessContext } from './ProAccessPolicy';
import { ProAppRuntime } from './ProAppRuntime';
import { ProUsbFidoKeyCandidate, ProUsbFidoKeys, ProUsbFidoKeySession } from './ProUsbFidoKey';
import { CTAP1_ERR_INVALID_PARAMETER, CTAP2_ERR_NO_CREDENTIALS, CTAP2_ERR_USER_ACTION_TIMEOUT, ctapResponseFromPasskey,
  ctapStatus, parseCtapCommand, passkeyRequestFromCtap } from './passkey/ProPasskeyCtap';
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

// Below this much time left a request is not worth sending to the phone (read, decide, unlock).
const PHONE_MIN_REQUEST_MS: number = 8000;

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
  /** select: the paired phone's passkey may answer instead of a USB key; phone: the user may still switch to one */
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
  /** The phone request this session waits for ('' when none); withdrawn when the wait ends here first. */
  private phoneRequestId: string = '';
  /** Why the phone was set aside; shown with the next key selection. */
  private selectNotice: string = '';

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
    this.withdrawPhone();
    this.sessionId = 0;
    this.watchId = 0;
    this.selectNotice = '';
    this.show(null);
  }

  /** The user dismissed the prompt or cancelled while the key was waiting for a touch. */
  cancel(): void {
    const current = this.prompt;
    if (current !== null && current.kind === 'phone' && current.error !== '') {
      // Only a note about a request that already ended: closing it must not cancel a newer one.
      this.show(null);
      return;
    }
    if (current !== null && current.kind === 'phone') { this.withdrawPhone(); }
    if (current !== null && current.kind !== 'touch') { this.respond(current.requestId, false, null, null); }
    if (!this.stopped && this.sessionId > 0) {
      try { rdpnapi.rdpSecurityKeyCancel(this.sessionId); } catch (_error) {}
    }
    this.show(null);
  }

  answerConfirm(requestId: number, allowed: boolean): void {
    if (!this.matches(requestId, 'confirm')) {
      hilog.warn(0x0014, 'RemoteDesktop', 'security-key confirm ignored request=' + requestId.toString() +
        ' current=' + (this.prompt === null ? 'none' : this.prompt.kind + ':' + this.prompt.requestId.toString()));
      return;
    }
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
    this.selectNotice = '';
    try { rdpnapi.rdpSecurityKeyRespondEx(this.sessionId, requestId, true, null, AUTHENTICATOR_PHONE); }
    catch (_error) { /* the request already ended; its dismissal follows */ }
    this.show(null);
  }

  /** While the phone is asked: use a USB key instead. The phone's request is withdrawn and the selection returns. */
  useSecurityKey(requestId: number): void {
    const current = this.prompt;
    if (current === null || current.kind !== 'phone' || current.requestId !== requestId || !current.phone ||
        this.stopped || this.sessionId <= 0) { return; }
    this.withdrawPhone();
    this.dropPhone(this.sessionId, requestId, '');
  }

  refreshKeys(): void {
    const current = this.prompt;
    if (current === null || current.kind !== 'select' || current.busy) { return; }
    this.show(this.selectPrompt(current.requestId, current.error));
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
        this.show(this.selectPrompt(request.id, this.selectNotice));
        this.selectNotice = '';
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
          if (this.prompt.kind === 'phone') { this.withdrawPhone(); }
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
    const handledAt = Date.now();
    const command = parseCtapCommand(request.payload);
    if (command.status !== 0) { this.respondPasskey(sessionId, id, ctapStatus(command.status)); return; }
    // The phone signs only for the relying party the user confirmed here (the native reading of the same command).
    if (command.rpId !== request.text) {
      this.respondPasskey(sessionId, id, ctapStatus(CTAP1_ERR_INVALID_PARAMETER));
      return;
    }
    if (command.foreignAllowList) {
      // The server only accepts credentials the phone never issued.
      this.respondPasskey(sessionId, id, ctapStatus(CTAP2_ERR_NO_CREDENTIALS));
      return;
    }
    // Whether this request can still go back to key selection (native allows it once per request).
    const switchable = request.operation === 1;
    const drop = (notice: string): void => {
      this.dropPhone(sessionId, id, switchable ? notice : '');
      // No selection follows: the reason stays on screen until the user closes it.
      if (!switchable && notice !== '' && !this.stopped && this.sessionId === sessionId) {
        this.show({ kind: 'phone', requestId: id, rpId: command.rpId, register: command.op === 'register', retries: -1,
          candidates: [], busy: false, error: notice, phone: false });
      }
    };
    const context = this.context;
    if (context === null || !ProPasskeyReceiver.available()) {
      drop('手机通行密钥当前不可用，请改用 USB 安全密钥');
      return;
    }
    this.show({ kind: 'phone', requestId: id, rpId: command.rpId, register: command.op === 'register', retries: -1,
      candidates: [], busy: false, error: '', phone: switchable });
    // Every await may outlive the request: the user cancelled, the remote request ended or the page stopped.
    const current = (): boolean => !this.stopped && this.sessionId === sessionId && this.prompt !== null &&
      this.prompt.kind === 'phone' && this.prompt.requestId === id;
    try {
      if (!(await ProPasskeyReceiver.getInstance().ensureChannel(context))) {
        if (current()) { drop('无法连接同账号设备：请确认手机登录同一华为账号并已联网'); }
        return;
      }
      if (!current()) { return; }
      // The phone gets the time actually left (joining may have waited for a permission dialog).
      const remaining = request.timeoutMs - (Date.now() - handledAt);
      if (remaining < PHONE_MIN_REQUEST_MS) {
        this.respondPasskey(sessionId, id, ctapStatus(CTAP2_ERR_USER_ACTION_TIMEOUT));
        this.show(null);
        return;
      }
      const phoneRequest = await ProPasskeyDevice.signRequest(passkeyRequestFromCtap(command, randomBytes(16),
        passkeyDeviceLabel(), Date.now(), remaining));
      if (!current()) { return; }
      this.phoneRequestId = phoneRequest.id;
      const response = await ProPasskeyChannel.getInstance().send(phoneRequest);
      if (this.phoneRequestId === phoneRequest.id) { this.phoneRequestId = ''; }
      if (!current()) { return; }
      const problem = response === null ? '手机没有回应：请确认手机已打开 RemoteDesk 并开启「接收登录请求」' :
        response.ok ? '' :
        response.error === 'PASSKEY_DEVICE_NOT_PAIRED' || response.error === 'PASSKEY_SIGNATURE_INVALID' ?
          '手机还没有与这台设备配对：请在 设置 → 安全与数据 → 手机通行密钥 中配对' :
        response.error === 'PASSKEY_BUSY' ? '手机正在处理另一个请求，请稍后重试' : '';
      if (problem !== '') { drop(problem); return; }
      this.respondPasskey(sessionId, id, ctapResponseFromPasskey(command.op, response));
      this.show(null);
    } catch (_error) {
      if (current()) { drop('手机通行密钥出错，请重试或改用 USB 安全密钥'); }
    }
  }

  /**
   * The phone cannot answer for this session (unavailable, unreachable, unpaired, busy) or the user wants a USB key:
   * the phone stops being the session's choice and the request goes back to key selection, which the native side
   * shows again while the remote request lasts.
   */
  private dropPhone(sessionId: number, requestId: number, notice: string): void {
    if (this.stopped || this.sessionId !== sessionId || requestId <= 0) { return; }
    this.selectNotice = notice;
    try { rdpnapi.rdpSecurityKeyReleased(sessionId); } catch (_error) {}
    try { rdpnapi.rdpSecurityKeyRespondEx(sessionId, requestId, false, null, PASSKEY_RESPONSE); } catch (_error) {}
    if (this.prompt !== null && this.prompt.requestId === requestId) { this.show(null); }
  }

  /** The wait for the phone ended here first: the phone is told, so its dialog comes down. */
  private withdrawPhone(): void {
    const id = this.phoneRequestId;
    this.phoneRequestId = '';
    if (id !== '') {
      try { ProPasskeyChannel.getInstance().withdraw(id); } catch (_error) { /* the request still expires */ }
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
