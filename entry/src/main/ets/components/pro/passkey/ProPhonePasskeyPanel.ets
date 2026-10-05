import { common } from '@kit.AbilityKit';
import { AppConfig, Palette, buildDark, buildLight } from '../../../common/Theme';
import { AccountSessionCoordinator } from '../../../services/AccountSessionCoordinator';
import {
  attestedCredential, base64UrlDecode, base64UrlEncode, bytesEqual, concatBytes, coseEc2PublicKey, p256PointFromSpki,
  PasskeyRequest, PASSKEY_FLAG_AT, PASSKEY_FLAG_UP, PASSKEY_FLAG_UV, PASSKEY_PROTOCOL_VERSION
} from '../../../services/pro/passkey/ProPasskeyCodec';
import { ProPasskeyAuthenticator } from '../../../services/pro/passkey/ProPasskeyAuthenticator';
import { ProPasskeyChannel } from '../../../services/pro/passkey/ProPasskeyChannel';
import { passkeyDeviceLabel, passkeyPairingCodeOf, ProPasskeyDevice } from '../../../services/pro/passkey/ProPasskeyDevice';
import { randomBytes, sha256, utf8, verifyEs256 } from '../../../services/pro/passkey/ProPasskeyKeys';
import { PasskeyPeer, ProPasskeyPeers } from '../../../services/pro/passkey/ProPasskeyPeers';
import { PasskeyReceiverState, ProPasskeyReceiver } from '../../../services/pro/passkey/ProPasskeyReceiver';
import { PasskeyRecord, ProPasskeyStore } from '../../../services/pro/passkey/ProPasskeyStore';

const TEST_RP_ID: string = 'remotedesk.test';
const REQUEST_TTL_MS: number = 90000;

const ERROR_TEXT: Record<string, string> = {
  'PASSKEY_USER_DENIED': '对方拒绝了请求',
  'PASSKEY_USER_CANCELLED': '验证已取消',
  'PASSKEY_USER_AUTH_FAILED': '人脸、指纹或锁屏密码验证未通过',
  'PASSKEY_USER_AUTH_UNAVAILABLE': '那台设备不能进行人脸、指纹或锁屏密码验证',
  'PASSKEY_NO_LOCK_SCREEN': '那台设备没有设置锁屏密码，不能保存通行密钥',
  'PASSKEY_NO_CREDENTIALS': '那台设备上没有该网站的通行密钥',
  'PASSKEY_CREDENTIAL_EXCLUDED': '那台设备已有该网站的通行密钥',
  'PASSKEY_KEY_MISSING': '通行密钥的私钥已不存在，记录已清理',
  'PASSKEY_REQUEST_INVALID': '请求格式无效',
  'PASSKEY_DEVICE_NOT_PAIRED': '手机还没有与这台设备配对，请先点「与手机配对」',
  'PASSKEY_SIGNATURE_INVALID': '请求签名无效，请重新配对',
  'PASSKEY_PAIRING_DECLINED': '手机上拒绝了配对（或配对码不一致）',
  'PASSKEY_BUSY': '那台设备正在处理另一个请求，请稍后再试',
  'PASSKEY_STORE_UNAVAILABLE': '那台设备保存失败，请稍后再试'
};

function errorText(code: string): string {
  return ERROR_TEXT[code] ?? ('操作失败（' + code + '）');
}

function formatDate(time: number): string {
  const date = new Date(time);
  return (date.getMonth() + 1).toString() + '月' + date.getDate().toString() + '日 ' +
    date.getHours().toString().padStart(2, '0') + ':' + date.getMinutes().toString().padStart(2, '0');
}

/**
 * 手机通行密钥 (Debug prototype). On the phone: receive requests from paired devices on any page, manage paired
 * devices and saved passkeys. On another device: pair with the phone and run test registrations and sign-ins that
 * are checked like a website would check them.
 */
@Component
export struct ProPhonePasskeyPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @State receiving: boolean = false;
  @State listening: boolean = false;
  @State receiverStatus: string = '';
  @State receiverLog: string[] = [];
  @State peers: PasskeyPeer[] = [];
  @State records: PasskeyRecord[] = [];
  @State busy: boolean = false;
  @State pairingCode: string = '';
  @State log: string[] = [];
  @State testCredentialId: string = '';
  private testPublicKey: Uint8Array | null = null;
  private testSignCount: number = -1;
  private context: common.UIAbilityContext | null = null;
  private alive: boolean = false;
  private stopReceiver: () => void = (): void => {};

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  private owner(): string { return AccountSessionCoordinator.getInstance().currentScope().ownerScopeId; }

  aboutToAppear(): void {
    this.alive = true;
    this.context = getContext(this) as common.UIAbilityContext;
    this.refresh();
    this.stopReceiver = ProPasskeyReceiver.getInstance().subscribe((state: PasskeyReceiverState): void => {
      if (!this.alive) { return; }
      this.receiving = state.enabled;
      this.listening = state.listening;
      this.receiverStatus = state.status;
      this.receiverLog = state.log;
      this.refresh();
    });
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.stopReceiver();
    ProPasskeyReceiver.getInstance().releaseChannel();
  }

  private refresh(): void {
    if (this.context === null) { return; }
    this.records = ProPasskeyStore.list(this.context, this.owner());
    this.peers = ProPasskeyPeers.list(this.context, this.owner());
  }

  private note(line: string): void {
    this.log = [line].concat(this.log).slice(0, 12);
  }

  private async setReceiving(on: boolean): Promise<void> {
    const context = this.context;
    if (context === null) { return; }
    this.receiving = on;
    const saved = await ProPasskeyReceiver.getInstance().setEnabled(on, context);
    if (!saved && this.alive) {
      // The switch already moved; move it back in a later frame so the change is visible.
      setTimeout((): void => { this.receiving = ProPasskeyReceiver.getInstance().enabled(); }, 0);
    }
  }

  private removePeer(peer: PasskeyPeer): void {
    if (this.context === null) { return; }
    try {
      ProPasskeyPeers.remove(this.context, this.owner(), peer.id);
    } catch (_error) {
      this.note('解除配对失败，请稍后重试');
    }
    this.refresh();
  }

  private async removeRecord(record: PasskeyRecord): Promise<void> {
    if (this.context === null) { return; }
    if (!(await ProPasskeyAuthenticator.remove(this.context, this.owner(), record.id))) {
      this.note('删除失败，请稍后重试');
    }
    this.refresh();
  }

  private async ensureChannel(): Promise<boolean> {
    const context = this.context;
    if (context === null) { return false; }
    if (this.owner() === '') { this.note('请先登录华为账号'); return false; }
    if (await ProPasskeyReceiver.getInstance().ensureChannel(context)) { return this.alive; }
    this.note('无法加入同账号设备通道：请允许“多设备协同”权限，并确认两台设备登录同一华为账号、已联网');
    return false;
  }

  private async signedRequest(op: string, credentialIds: string[]): Promise<PasskeyRequest> {
    const request: PasskeyRequest = {
      v: PASSKEY_PROTOCOL_VERSION, id: base64UrlEncode(randomBytes(16)), op,
      rpId: op === 'pair' ? '' : TEST_RP_ID,
      clientDataHash: op === 'pair' ? '' : base64UrlEncode(randomBytes(32)),
      user: op === 'register' ? { id: base64UrlEncode(randomBytes(16)), name: 'remotedesk-test', displayName: 'RemoteDesk 测试' } : null,
      credentialIds, from: passkeyDeviceLabel(), sentAt: Date.now(), ttlMs: REQUEST_TTL_MS, device: '', devicePub: '', sig: ''
    };
    return ProPasskeyDevice.signRequest(request);
  }

  /** Asks the phone to trust this device; both screens show the same six-digit code. */
  private async pairWithPhone(): Promise<void> {
    if (this.busy || !(await this.ensureChannel())) { return; }
    this.busy = true;
    try {
      const request = await this.signedRequest('pair', []);
      this.pairingCode = passkeyPairingCodeOf(request);
      this.note('已发送配对请求，请在手机上核对配对码 ' + this.pairingCode + ' 并确认…');
      const response = await ProPasskeyChannel.getInstance().send(request);
      if (response === null) { this.note('配对：手机没有在 90 秒内回应（手机需在前台并开启“接收登录请求”）'); }
      else if (!response.ok) { this.note('配对失败：' + errorText(response.error)); }
      else { this.note('配对成功：手机现在会接受这台设备的请求'); }
    } catch (_error) {
      this.note('配对出错，请重试');
    } finally {
      this.pairingCode = '';
      this.busy = false;
    }
  }

  /** Registers a test passkey on the phone and checks the answer like a relying party. */
  private async testRegister(): Promise<void> {
    if (this.busy || !(await this.ensureChannel())) { return; }
    this.busy = true;
    try {
      const request = await this.signedRequest('register', []);
      const started = Date.now();
      this.note('已发送注册请求，请在手机上确认…');
      const response = await ProPasskeyChannel.getInstance().send(request);
      if (response === null) { this.note('注册：没有设备在 90 秒内回应'); return; }
      if (!response.ok) { this.note('注册失败：' + errorText(response.error)); return; }
      const authData = base64UrlDecode(response.authData);
      const spki = base64UrlDecode(response.publicKey);
      const credentialId = base64UrlDecode(response.credentialId);
      const point = spki === null ? null : p256PointFromSpki(spki);
      const attested = authData === null ? null : attestedCredential(authData);
      const checks: boolean[] = [
        authData !== null && bytesEqual(authData.slice(0, 32), sha256(utf8(TEST_RP_ID))),
        authData !== null && (authData[32] & (PASSKEY_FLAG_UP | PASSKEY_FLAG_UV | PASSKEY_FLAG_AT)) ===
          (PASSKEY_FLAG_UP | PASSKEY_FLAG_UV | PASSKEY_FLAG_AT),
        attested !== null && credentialId !== null && bytesEqual(attested[0], credentialId),
        attested !== null && point !== null && bytesEqual(attested[1], coseEc2PublicKey(point[0], point[1]))
      ];
      if (checks.some((ok: boolean): boolean => !ok) || spki === null) {
        this.note('注册应答未通过校验（' + checks.map((ok: boolean): string => ok ? '✓' : '✗').join('') + '）');
        return;
      }
      this.testPublicKey = spki;
      this.testSignCount = 0;
      this.testCredentialId = response.credentialId;
      this.note('注册成功，用时 ' + ((Date.now() - started) / 1000).toFixed(1) + ' 秒；网站摘要、标志位、凭据和公钥均校验通过');
    } catch (_error) {
      this.note('注册测试出错，请重试');
    } finally {
      this.busy = false;
    }
  }

  /** Signs in with the test passkey and verifies the signature with its public key. */
  private async testSignIn(): Promise<void> {
    const spki = this.testPublicKey;
    if (this.busy || spki === null || !(await this.ensureChannel())) { return; }
    this.busy = true;
    try {
      const request = await this.signedRequest('signin', [this.testCredentialId]);
      const started = Date.now();
      this.note('已发送登录请求，请在手机上确认…');
      const response = await ProPasskeyChannel.getInstance().send(request);
      if (response === null) { this.note('登录：没有设备在 90 秒内回应'); return; }
      if (!response.ok) { this.note('登录失败：' + errorText(response.error)); return; }
      const authData = base64UrlDecode(response.authData);
      const signature = base64UrlDecode(response.signature);
      const clientDataHash = base64UrlDecode(request.clientDataHash);
      if (authData === null || signature === null || clientDataHash === null || authData.length !== 37) {
        this.note('登录应答格式无效');
        return;
      }
      const signCount = (authData[33] << 24 | authData[34] << 16 | authData[35] << 8 | authData[36]) >>> 0;
      const checks: boolean[] = [
        bytesEqual(authData.slice(0, 32), sha256(utf8(TEST_RP_ID))),
        (authData[32] & (PASSKEY_FLAG_UP | PASSKEY_FLAG_UV)) === (PASSKEY_FLAG_UP | PASSKEY_FLAG_UV),
        response.credentialId === this.testCredentialId,
        signCount > this.testSignCount,
        await verifyEs256(spki, concatBytes([authData, clientDataHash]), signature)
      ];
      if (checks.some((ok: boolean): boolean => !ok)) {
        this.note('登录应答未通过校验（' + checks.map((ok: boolean): string => ok ? '✓' : '✗').join('') + '）');
        return;
      }
      this.testSignCount = signCount;
      this.note('登录成功，用时 ' + ((Date.now() - started) / 1000).toFixed(1) + ' 秒；签名用注册时的公钥校验通过（计数 ' +
        signCount.toString() + '）');
    } catch (_error) {
      this.note('登录测试出错，请重试');
    } finally {
      this.busy = false;
    }
  }

  @Builder private heading(title: string, detail: string) {
    Column({ space: 2 }) {
      Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily)
      if (detail.length > 0) {
        Text(detail).fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily).lineHeight(17)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder private button(label: string, primary: boolean, enabled: boolean, action: () => void) {
    Button(label, { type: ButtonType.Capsule }).fontSize(14).height(38).layoutWeight(1)
      .fontColor(primary ? Color.White : this.pal().text)
      .backgroundColor(primary ? this.accent : this.pal().surface)
      .enabled(enabled).opacity(enabled ? 1 : 0.5).onClick(action)
  }

  @Builder private logLines(lines: string[]) {
    ForEach(lines, (line: string): void => {
      Text(line).fontSize(12).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily).lineHeight(17).width('100%')
    }, (line: string, index: number): string => index.toString() + ':' + line)
  }

  @Builder private receiveCard() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text('接收登录请求').fontSize(15).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily)
        Text('这台设备作为通行密钥：应用在前台时，已配对设备的请求会在任何页面弹出确认，允许后验证人脸、指纹或锁屏密码。')
          .fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily).lineHeight(17)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.receiving }).selectedColor(this.accent)
        .onChange((on: boolean): void => { if (on !== this.receiving) { void this.setReceiving(on); } })
    }.width('100%')
    if (this.receiverStatus.length > 0) {
      Text(this.receiverStatus).fontSize(12).fontColor(this.listening ? this.accent : this.pal().text2)
        .fontFamily(AppConfig.fontFamily).lineHeight(17)
    }
    this.logLines(this.receiverLog)
    Divider().color(this.pal().divider)
    this.heading('已配对的设备', this.peers.length === 0 ?
      '还没有。在另一台同账号设备上打开本页，点「与手机配对」，核对两边的配对码后在这里确认。' : '只有这些设备的请求会弹出确认。')
    ForEach(this.peers, (peer: PasskeyPeer): void => {
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text(peer.name).fontSize(14).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily)
          Text('配对于 ' + formatDate(peer.pairedAt) + (peer.lastUsedAt > peer.pairedAt ? ' · 最近使用 ' +
            formatDate(peer.lastUsedAt) : '')).fontSize(11).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button('解除', { type: ButtonType.Capsule }).fontSize(12).height(30).fontColor(this.pal().danger)
          .backgroundColor(this.pal().surface).enabled(!this.busy).onClick((): void => { this.removePeer(peer); })
      }.width('100%')
    }, (peer: PasskeyPeer): string => peer.id + ':' + peer.lastUsedAt.toString())
  }

  @Builder private pairCard() {
    this.heading('让这台设备使用手机通行密钥', '先与开启了“接收登录请求”的手机配对。之后这台设备上的测试（以及后续的远程桌面）可以请求手机完成注册和登录。')
    if (this.pairingCode.length > 0) {
      Column({ space: 4 }) {
        Text('配对码').fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily)
        Text(this.pairingCode).fontSize(28).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          .fontFamily(AppConfig.fontFamily).letterSpacing(4)
        Text('在手机上核对相同的数字后点「一致，配对」').fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily)
      }.width('100%').padding(12).borderRadius(12).backgroundColor(this.pal().surface)
    }
    Row({ space: 10 }) {
      this.button(this.pairingCode.length > 0 ? '等待手机确认…' : '与手机配对', true, !this.busy,
        (): void => { void this.pairWithPhone(); })
    }.width('100%')
  }

  @Builder private recordRow(record: PasskeyRecord) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(record.rpId).fontSize(14).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily)
        Text(record.userName + ' · ' + (record.unlock === 'biometric' ? '人脸/指纹' : '锁屏密码') + ' · 创建于 ' +
          formatDate(record.createdAt) + (record.signCount > 0 ? ' · 已用 ' + record.signCount.toString() + ' 次' : ''))
          .fontSize(11).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Button('删除', { type: ButtonType.Capsule }).fontSize(12).height(30).fontColor(this.pal().danger)
        .backgroundColor(this.pal().surface).enabled(!this.busy).onClick((): void => { void this.removeRecord(record); })
    }.width('100%')
  }

  build() {
    Column({ space: 12 }) {
      Text('原型（调试版）：用同一华为账号的手机作为通行密钥。私钥只保存在手机的系统密钥库里，每次使用都要你在手机上确认并验证人脸、指纹或锁屏密码。')
        .fontSize(12).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily).lineHeight(18).width('100%')
      Column({ space: 10 }) {
        this.receiveCard()
      }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(16).alignItems(HorizontalAlign.Start)
      Column({ space: 10 }) {
        this.pairCard()
      }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(16).alignItems(HorizontalAlign.Start)
      Column({ space: 10 }) {
        this.heading('这台设备上的通行密钥', this.records.length === 0 ? '还没有保存通行密钥' : '删除记录会同时删除系统密钥库里的私钥。')
        ForEach(this.records, (record: PasskeyRecord): void => { this.recordRow(record) },
          (record: PasskeyRecord): string => record.id + ':' + record.signCount.toString())
      }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(16).alignItems(HorizontalAlign.Start)
      Column({ space: 10 }) {
        this.heading('测试', '配对后从这里发送测试注册和登录；手机确认后，结果会像网站一样校验签名。')
        Row({ space: 10 }) {
          this.button('测试注册', true, !this.busy, (): void => { void this.testRegister(); })
          this.button('测试登录', false, !this.busy && this.testCredentialId.length > 0,
            (): void => { void this.testSignIn(); })
        }.width('100%')
        this.logLines(this.log)
      }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(16).alignItems(HorizontalAlign.Start)
    }.width('100%')
  }
}
