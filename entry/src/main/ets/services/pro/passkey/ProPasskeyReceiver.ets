import { common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import { DEBUG } from 'BuildProfile';
import { PasskeyConfirmation, PasskeyDialogParams } from '../../../components/pro/passkey/ProPasskeyConfirmDialog';
import { AccountSessionCoordinator } from '../../AccountSessionCoordinator';
import { ProAppRuntime } from '../ProAppRuntime';
import { base64UrlDecode, passkeyCleanText, PasskeyRequest, PasskeyResponse } from './ProPasskeyCodec';
import { ProPasskeyAuthenticator } from './ProPasskeyAuthenticator';
import { ProPasskeyChannel } from './ProPasskeyChannel';
import { passkeyPairingCodeOf, passkeyRequestSignedBy } from './ProPasskeyDevice';
import { ProPasskeyKeys } from './ProPasskeyKeys';
import { PasskeyPeer, ProPasskeyPeers } from './ProPasskeyPeers';

export const PHONE_PASSKEY_FEATURE: string = 'pro.security.phonePasskey';
const MAX_LOG: number = 12;

export interface PasskeyReceiverState {
  /** The user's choice for this account (kept across launches). */
  enabled: boolean;
  /** Answering right now: enabled, entitled, in the foreground and joined. */
  listening: boolean;
  status: string;
  log: string[];
}

function rpLabel(request: PasskeyRequest): string { return '「' + request.rpId + '」'; }

/** The request being confirmed or answered; it ends when it expires, is withdrawn or the receiver stops. */
class ActiveRequest {
  id: string;
  deadline: number;
  ended: boolean = false;
  /** The user answered the dialog (the unlock that follows may move the app to the background). */
  answered: boolean = false;
  confirmation: PasskeyConfirmation | null = null;

  constructor(id: string, deadline: number) { this.id = id; this.deadline = deadline; }

  end(): void {
    this.ended = true;
    const confirmation = this.confirmation;
    this.confirmation = null;
    if (confirmation !== null) { confirmation.close(); }
  }
}

/**
 * The phone side of 手机通行密钥 for the whole app: while the app is in the foreground and receiving is on,
 * requests from paired devices of the same account are confirmed in a dialog on whatever page is open. Requests
 * must be signed by a paired device's key; pairing itself is confirmed by comparing a six-digit code.
 */
export class ProPasskeyReceiver {
  private static instance: ProPasskeyReceiver = new ProPasskeyReceiver();
  static getInstance(): ProPasskeyReceiver { return ProPasskeyReceiver.instance; }

  /** Debug only, and only while the account may use this experimental feature. */
  static available(): boolean {
    if (DEBUG) {
      try {
        return ProAppRuntime.getInstance().runtime.decision(PHONE_PASSKEY_FEATURE,
          ProAppRuntime.getInstance().context()).executable;
      } catch (_error) {
        return false;
      }
    }
    return false;
  }

  private context: common.UIAbilityContext | null = null;
  private ui: () => UIContext | null = (): UIContext | null => null;
  private inForeground: boolean = false;
  private listening: boolean = false;
  private busy: boolean = false;
  private status: string = '';
  private log: string[] = [];
  private generation: number = 0;
  private observers: ((state: PasskeyReceiverState) => void)[] = [];
  private watching: boolean = false;
  private active: ActiveRequest | null = null;
  private activeRequest: PasskeyRequest | null = null;

  private owner(): string { return AccountSessionCoordinator.getInstance().currentScope().ownerScopeId; }

  /** EntryAbility: the app came to the foreground. `ui` supplies the main window's UI context for dialogs. */
  foreground(context: common.UIAbilityContext, ui: () => UIContext | null): void {
    this.context = context;
    this.ui = ui;
    this.inForeground = true;
    if (!this.watching) {
      this.watching = true;
      ProAppRuntime.getInstance().runtime.subscribe((): void => { void this.evaluate(); });
      AccountSessionCoordinator.getInstance().onChange((): void => { void this.evaluate(); });
    }
    void this.evaluate();
  }

  /**
   * EntryAbility: the app went to the background; nothing is answered until it returns. A request still waiting
   * for the user is cancelled: while away this device stops hearing withdrawals, so an answer given on return could
   * create a passkey nobody waits for. A request already being unlocked carries on.
   */
  background(): void {
    this.inForeground = false;
    const active = this.active;
    if (active !== null && !active.answered && !active.ended) {
      const request = this.activeRequest;
      active.end();
      if (request !== null && request.id === active.id) {
        this.respond(ProPasskeyAuthenticator.failed(request, 'PASSKEY_USER_CANCELLED'));
        this.note('应用切到后台，未确认的请求已取消');
        // The answer needs a moment to sync before this device leaves the channel.
        setTimeout((): void => { if (!this.inForeground) { void this.evaluate(); } }, 500);
        return;
      }
    }
    void this.evaluate();
  }

  enabled(): boolean {
    const context = this.context;
    return context !== null && ProPasskeyPeers.receiving(context, this.owner());
  }

  state(): PasskeyReceiverState {
    return { enabled: this.enabled(), listening: this.listening, status: this.status, log: this.log.slice() };
  }

  subscribe(observer: (state: PasskeyReceiverState) => void): () => void {
    this.observers.push(observer);
    try { observer(this.state()); } catch (_error) { /* isolate observers */ }
    return (): void => {
      this.observers = this.observers.filter((item: (state: PasskeyReceiverState) => void): boolean => item !== observer);
    };
  }

  /** Turns receiving on or off for this account; turning it on asks for the cross-device permission. */
  async setEnabled(on: boolean, context: common.UIAbilityContext): Promise<boolean> {
    this.context = context;
    const owner = this.owner();
    if (owner === '') { this.setStatus('请先登录华为账号'); return false; }
    if (on && !ProPasskeyReceiver.available()) { this.setStatus('手机通行密钥当前不可用'); return false; }
    if (on) {
      if (ProPasskeyKeys.preferredUnlock() === null) { this.setStatus('这台设备没有设置锁屏密码，不能作为通行密钥'); return false; }
      if (!ProPasskeyChannel.supported()) { this.setStatus('这台设备不支持跨设备数据同步'); return false; }
      if (!(await ProPasskeyChannel.getInstance().requestPermission(context))) {
        this.setStatus('需要允许“多设备协同”权限才能与其他设备通信');
        return false;
      }
    }
    if (!ProPasskeyPeers.setReceiving(context, owner, on)) { this.setStatus('设置未保存，请稍后再试'); return false; }
    await this.evaluate();
    return true;
  }

  /** For a device that sends requests (tests, pairing, the RDP path): joins the channel without receiving. */
  async ensureChannel(context: common.UIAbilityContext): Promise<boolean> {
    this.context = context;
    const owner = this.owner();
    if (owner === '' || !ProPasskeyReceiver.available() || !ProPasskeyChannel.supported()) { return false; }
    const channel = ProPasskeyChannel.getInstance();
    if (channel.joined()) { return true; }
    if (!(await channel.requestPermission(context))) { return false; }
    return channel.join(context, owner);
  }

  /** A sender is done; the channel stays while this device receives or still waits for an answer. */
  releaseChannel(): void {
    if (!this.listening) { ProPasskeyChannel.getInstance().release(); }
  }

  private setStatus(status: string): void {
    this.status = status;
    this.publish();
  }

  private note(line: string): void {
    this.log = [line].concat(this.log).slice(0, MAX_LOG);
    this.publish();
  }

  private publish(): void {
    const state = this.state();
    this.observers.slice().forEach((observer: (state: PasskeyReceiverState) => void): void => {
      try { observer(state); } catch (_error) { /* isolate observers */ }
    });
  }

  private async evaluate(): Promise<void> {
    const generation = ++this.generation;
    const context = this.context;
    const owner = this.owner();
    const channel = ProPasskeyChannel.getInstance();
    const receiving = context !== null && owner !== '' && ProPasskeyReceiver.available() &&
      ProPasskeyPeers.receiving(context, owner);
    const wanted = this.inForeground && receiving;
    if (!receiving && this.active !== null) {
      // Receiving was turned off, the account changed or the feature went away: nothing more is answered.
      this.active.end();
    }
    if (!wanted || context === null) {
      if (this.listening) {
        channel.listen(null);
        channel.release();
        this.listening = false;
      }
      this.setStatus(this.enabled() && !this.inForeground ? '应用在后台时暂停接收' : '');
      return;
    }
    const joined = await channel.join(context, owner);
    if (generation !== this.generation) { return; }
    if (!joined) {
      this.listening = false;
      this.setStatus('无法加入同账号设备通道，请确认设备登录同一华为账号并已联网');
      return;
    }
    channel.listen((request: PasskeyRequest): void => { void this.onRequest(request); },
      (id: string): void => { this.onWithdraw(id); });
    this.listening = true;
    this.setStatus('正在接收：已配对设备的请求会在任何页面弹出确认');
  }

  private respond(response: PasskeyResponse): void { ProPasskeyChannel.getInstance().respond(response); }

  /** The requester gave up on `id` (its user cancelled, its remote request ended): the dialog comes down. */
  private onWithdraw(id: string): void {
    const active = this.active;
    if (active !== null && active.id === id) {
      active.end();
      this.note('请求已取消');
    }
  }

  private async onRequest(request: PasskeyRequest): Promise<void> {
    const context = this.context;
    const owner = this.owner();
    if (context === null || owner === '' || !this.listening || !this.inForeground) { return; }
    if (this.busy) {
      // One request at a time: the newer requester hears it right away instead of waiting out its timeout.
      this.respond(ProPasskeyAuthenticator.failed(request, 'PASSKEY_BUSY'));
      return;
    }
    this.busy = true;
    // The requester's own wait began before the request reached this device; ending 3 s earlier than its time to
    // live leaves room for the transfer, so this device never answers after the requester stopped waiting.
    const active = new ActiveRequest(request.id, Date.now() + Math.max(1000, request.ttlMs - 3000));
    this.active = active;
    this.activeRequest = request;
    const current = (): boolean => !active.ended && Date.now() < active.deadline && this.owner() === owner;
    try {
      if (request.op === 'pair') {
        await this.pair(context, owner, request, active, current);
        return;
      }
      const from = passkeyCleanText(request.from, 40);
      const peer: PasskeyPeer | null = ProPasskeyPeers.find(context, owner, request.device);
      if (peer === null) {
        this.respond(ProPasskeyAuthenticator.failed(request, 'PASSKEY_DEVICE_NOT_PAIRED'));
        this.note('已拒绝未配对设备「' + from + '」的请求');
        return;
      }
      const name = passkeyCleanText(peer.name, 40);
      const key = base64UrlDecode(peer.publicKey);
      if (key === null || !(await passkeyRequestSignedBy(request, key))) {
        this.respond(ProPasskeyAuthenticator.failed(request, 'PASSKEY_SIGNATURE_INVALID'));
        this.note('已拒绝签名无效的请求（' + name + '）');
        return;
      }
      const register = request.op === 'register';
      const allowed = await this.ask(active, register ? '注册通行密钥' : '使用通行密钥登录',
        '「' + name + '」请求' + (register ? '为' + rpLabel(request) + '注册新的通行密钥' : '登录' + rpLabel(request)) +
        (request.user !== null ? '（账号 ' + passkeyCleanText(request.user.name, 64) + '）' : '') +
        '。\n\n只有确认是你本人发起的操作时才允许。允许后需要验证人脸、指纹或锁屏密码。', '', '拒绝', '允许');
      if (!current()) {
        // Expired or withdrawn while the dialog was open: the requester no longer listens.
        this.note('请求已结束：' + request.rpId + (register ? ' 注册' : ' 登录') + '（' + name + '）');
        return;
      }
      if (!allowed) {
        this.respond(ProPasskeyAuthenticator.declined(request));
        this.note('已拒绝：' + request.rpId + (register ? ' 注册' : ' 登录') + '（' + name + '）');
        return;
      }
      const response: PasskeyResponse = register ?
        await ProPasskeyAuthenticator.register(context, owner, request, current) :
        await ProPasskeyAuthenticator.signIn(context, owner, request, current);
      if (!current()) {
        this.note('请求已结束：' + request.rpId + (register ? ' 注册' : ' 登录') + '（' + name + '）');
        return;
      }
      this.respond(response);
      peer.lastUsedAt = Date.now();
      try { ProPasskeyPeers.save(context, peer); } catch (_error) { /* the answer already went out */ }
      this.note((response.ok ? '已完成：' : '未完成：') + request.rpId + (register ? ' 注册' : ' 登录') + '（' + name +
        (response.ok ? '）' : '，' + response.error + '）'));
    } catch (_error) {
      // Never leave a requester that still waits running into its timeout.
      if (current()) { this.respond(ProPasskeyAuthenticator.declined(request)); }
      this.note('未完成：处理请求时出错');
    } finally {
      active.end();
      if (this.active === active) { this.active = null; this.activeRequest = null; }
      this.busy = false;
    }
  }

  private async pair(context: common.UIAbilityContext, owner: string, request: PasskeyRequest, active: ActiveRequest,
    current: () => boolean): Promise<void> {
    const key = base64UrlDecode(request.devicePub);
    if (key === null || !(await passkeyRequestSignedBy(request, key))) {
      this.respond(ProPasskeyAuthenticator.failed(request, 'PASSKEY_SIGNATURE_INVALID'));
      return;
    }
    const from = passkeyCleanText(request.from, 40);
    const confirmed = await this.ask(active, '配对新设备',
      '「' + from + '」请求与这台设备配对。配对后，它可以请求你用这台设备上的通行密钥注册和登录，每次仍需你确认。' +
      '\n\n请确认两台设备显示的配对码一致：', passkeyPairingCodeOf(request), '不一致', '一致，配对');
    if (!current()) { this.note('配对请求已结束：' + from); return; }
    if (!confirmed) {
      this.respond(ProPasskeyAuthenticator.failed(request, 'PASSKEY_PAIRING_DECLINED'));
      this.note('已拒绝配对：' + from);
      return;
    }
    const now = Date.now();
    try {
      ProPasskeyPeers.save(context, { owner, id: request.device, name: from, publicKey: request.devicePub,
        pairedAt: now, lastUsedAt: now });
    } catch (_error) {
      this.respond(ProPasskeyAuthenticator.failed(request, 'PASSKEY_STORE_UNAVAILABLE'));
      return;
    }
    this.respond(ProPasskeyAuthenticator.done(request));
    this.note('已配对：' + from);
  }

  /** Shows the confirmation for `active`; false when refused, expired, withdrawn or no window can show it. */
  private ask(active: ActiveRequest, title: string, message: string, code: string, cancel: string,
    confirm: string): Promise<boolean> {
    const ui = this.ui();
    if (ui === null || active.ended) { return Promise.resolve(false); }
    const params = new PasskeyDialogParams();
    params.title = title;
    params.message = message;
    params.code = code;
    params.cancel = cancel;
    params.confirm = confirm;
    params.deadline = active.deadline;
    const confirmation = new PasskeyConfirmation(ui, params);
    active.confirmation = confirmation;
    return confirmation.answer.then((allowed: boolean): boolean => {
      active.answered = true;
      return allowed;
    });
  }
}
