import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { AppConfig, Palette, buildDark, buildLight } from '../../../common/Theme';
import { AccountSessionCoordinator } from '../../../services/AccountSessionCoordinator';
import {
  attestedCredential, base64UrlDecode, base64UrlEncode, bytesEqual, concatBytes, coseEc2PublicKey, p256PointFromSpki,
  PasskeyRequest, PasskeyResponse, PASSKEY_FLAG_AT, PASSKEY_FLAG_UP, PASSKEY_FLAG_UV, PASSKEY_PROTOCOL_VERSION
} from '../../../services/pro/passkey/ProPasskeyCodec';
import { ProPasskeyAuthenticator } from '../../../services/pro/passkey/ProPasskeyAuthenticator';
import { ProPasskeyChannel } from '../../../services/pro/passkey/ProPasskeyChannel';
import { ProPasskeyKeys, randomBytes, sha256, utf8, verifyEs256 } from '../../../services/pro/passkey/ProPasskeyKeys';
import { PasskeyRecord, ProPasskeyStore } from '../../../services/pro/passkey/ProPasskeyStore';

const TEST_RP_ID: string = 'remotedesk.test';
const REQUEST_TTL_MS: number = 90000;

const ERROR_TEXT: Record<string, string> = {
  'PASSKEY_USER_DENIED': '对方拒绝了请求',
  'PASSKEY_USER_CANCELLED': '验证已取消',
  'PASSKEY_USER_AUTH_FAILED': '人脸、指纹或锁屏密码验证未通过',
  'PASSKEY_USER_AUTH_UNAVAILABLE': '这台设备不能进行人脸、指纹或锁屏密码验证',
  'PASSKEY_NO_LOCK_SCREEN': '这台设备没有设置锁屏密码，不能保存通行密钥',
  'PASSKEY_NO_CREDENTIALS': '这台设备上没有该网站的通行密钥',
  'PASSKEY_CREDENTIAL_EXCLUDED': '这台设备已有该网站的通行密钥',
  'PASSKEY_KEY_MISSING': '通行密钥的私钥已不存在，记录已清理',
  'PASSKEY_REQUEST_INVALID': '请求格式无效'
};

function errorText(code: string): string {
  return ERROR_TEXT[code] ?? ('操作失败（' + code + '）');
}

function deviceLabel(): string {
  const name: string = (deviceInfo.marketName || deviceInfo.productModel || 'HarmonyOS 设备')
    .replace(/[\u0000-\u001f\u007f]/g, '');
  return name.slice(0, 40);
}

function formatDate(time: number): string {
  const date = new Date(time);
  return (date.getMonth() + 1).toString() + '月' + date.getDate().toString() + '日 ' +
    date.getHours().toString().padStart(2, '0') + ':' + date.getMinutes().toString().padStart(2, '0');
}

/**
 * Debug prototype of 手机通行密钥: this device can answer sign-in requests from the same account's other devices,
 * and can send test requests to them and verify the answer like a website would.
 */
@Component
export struct ProPhonePasskeyPanel {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @State receiving: boolean = false;
  @State status: string = '';
  @State incoming: PasskeyRequest | null = null;
  @State busy: boolean = false;
  @State records: PasskeyRecord[] = [];
  @State log: string[] = [];
  @State testCredentialId: string = '';
  private testPublicKey: Uint8Array | null = null;
  private testSignCount: number = -1;
  private context: common.UIAbilityContext | null = null;
  private alive: boolean = false;

  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }

  private owner(): string { return AccountSessionCoordinator.getInstance().currentScope().ownerScopeId; }

  aboutToAppear(): void {
    this.alive = true;
    this.context = getContext(this) as common.UIAbilityContext;
    this.refresh();
  }

  aboutToDisappear(): void {
    this.alive = false;
    const channel = ProPasskeyChannel.getInstance();
    channel.listen(null);
    const pending = this.incoming;
    if (pending !== null) { channel.respond(ProPasskeyAuthenticator.declined(pending)); }
    channel.leave();
  }

  private refresh(): void {
    if (this.context === null) { return; }
    this.records = ProPasskeyStore.list(this.context, this.owner());
  }

  private note(line: string): void {
    this.log = [line].concat(this.log).slice(0, 12);
  }

  private async ensureJoined(): Promise<boolean> {
    const context = this.context;
    const owner = this.owner();
    if (context === null) { return false; }
    if (owner === '') { this.status = '请先登录华为账号'; return false; }
    if (!ProPasskeyChannel.supported()) { this.status = '这台设备不支持跨设备数据同步'; return false; }
    const channel = ProPasskeyChannel.getInstance();
    if (channel.joined()) { return true; }
    if (!(await channel.requestPermission(context))) {
      this.status = '需要允许“多设备协同”权限才能与其他设备通信';
      return false;
    }
    const joined = await channel.join(context, owner);
    if (!joined) { this.status = '无法加入同账号设备通道，请确认两台设备登录同一华为账号并已联网'; }
    return joined && this.alive;
  }

  private async setReceiving(on: boolean): Promise<void> {
    const channel = ProPasskeyChannel.getInstance();
    if (!on) {
      channel.listen(null);
      this.receiving = false;
      this.status = '';
      return;
    }
    if (ProPasskeyKeys.preferredUnlock() === null) {
      this.receiving = false;
      this.status = '这台设备没有设置锁屏密码，不能作为通行密钥';
      return;
    }
    if (!(await this.ensureJoined())) { this.receiving = false; return; }
    channel.listen((request: PasskeyRequest): void => {
      if (!this.alive || !this.receiving) { return; }
      if (this.incoming !== null || this.busy) {
        // One request at a time: tell the newer requester right away instead of leaving it waiting.
        channel.respond(ProPasskeyAuthenticator.declined(request));
        return;
      }
      this.incoming = request;
    });
    this.receiving = true;
    this.status = '正在等待同账号设备的请求，请保持此页面打开';
  }

  private async approve(): Promise<void> {
    const request = this.incoming;
    const context = this.context;
    if (request === null || context === null || this.busy) { return; }
    this.busy = true;
    try {
      const response: PasskeyResponse = request.op === 'register'
        ? await ProPasskeyAuthenticator.register(context, this.owner(), request)
        : await ProPasskeyAuthenticator.signIn(context, this.owner(), request);
      ProPasskeyChannel.getInstance().respond(response);
      this.note((response.ok ? '已完成：' : '未完成：') + request.rpId + (request.op === 'register' ? ' 注册' : ' 登录') +
        (response.ok ? '' : '（' + errorText(response.error) + '）'));
    } catch (_error) {
      // Never leave the requester waiting for its timeout.
      ProPasskeyChannel.getInstance().respond(ProPasskeyAuthenticator.declined(request));
      this.note('未完成：' + request.rpId + '（处理失败）');
    } finally {
      this.busy = false;
      this.incoming = null;
      this.refresh();
    }
  }

  private decline(): void {
    const request = this.incoming;
    if (request === null) { return; }
    ProPasskeyChannel.getInstance().respond(ProPasskeyAuthenticator.declined(request));
    this.note('已拒绝：' + request.rpId);
    this.incoming = null;
  }

  private async remove(record: PasskeyRecord): Promise<void> {
    if (this.context === null) { return; }
    if (!(await ProPasskeyAuthenticator.remove(this.context, this.owner(), record.id))) {
      this.note('删除失败，请稍后重试');
    }
    this.refresh();
  }

  private request(op: string, credentialIds: string[]): PasskeyRequest {
    return {
      v: PASSKEY_PROTOCOL_VERSION, id: base64UrlEncode(randomBytes(16)), op, rpId: TEST_RP_ID,
      clientDataHash: base64UrlEncode(randomBytes(32)),
      user: op === 'register' ? { id: base64UrlEncode(randomBytes(16)), name: 'remotedesk-test', displayName: 'RemoteDesk 测试' } : null,
      credentialIds, from: deviceLabel(), sentAt: Date.now(), ttlMs: REQUEST_TTL_MS
    };
  }

  /** Registers a test passkey on another device and checks the answer like a relying party. */
  private async testRegister(): Promise<void> {
    if (this.busy || !(await this.ensureJoined())) { return; }
    this.busy = true;
    try {
      const request = this.request('register', []);
      const started = Date.now();
      this.note('已发送注册请求，请在另一台设备上确认…');
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
    if (this.busy || spki === null || !(await this.ensureJoined())) { return; }
    this.busy = true;
    try {
      const request = this.request('signin', [this.testCredentialId]);
      const started = Date.now();
      this.note('已发送登录请求，请在另一台设备上确认…');
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

  @Builder private receiveCard() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text('接收登录请求').fontSize(15).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily)
        Text('同一华为账号的其他设备可以请求这台设备完成注册或登录，每次都需要你确认并验证。')
          .fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily).lineHeight(17)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.receiving }).selectedColor(this.accent)
        .onChange((on: boolean): void => { void this.setReceiving(on); })
    }.width('100%')
    if (this.status.length > 0) {
      Text(this.status).fontSize(12).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily).lineHeight(17)
    }
    if (this.incoming !== null) {
      Column({ space: 8 }) {
        Text((this.incoming as PasskeyRequest).from + ' 请求' +
          ((this.incoming as PasskeyRequest).op === 'register' ? '为「' : '登录「') + (this.incoming as PasskeyRequest).rpId +
          ((this.incoming as PasskeyRequest).op === 'register' ? '」注册新的通行密钥' : '」'))
          .fontSize(14).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily).lineHeight(20)
        Text('只有确认是你本人发起的操作时才允许。允许后需要验证人脸、指纹或锁屏密码。')
          .fontSize(12).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily).lineHeight(17)
        Row({ space: 10 }) {
          this.button('拒绝', false, !this.busy, (): void => { this.decline(); })
          this.button(this.busy ? '验证中…' : '允许', true, !this.busy, (): void => { void this.approve(); })
        }.width('100%')
      }.width('100%').padding(12).borderRadius(12).backgroundColor(this.pal().surface)
    }
  }

  @Builder private recordRow(record: PasskeyRecord) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(record.rpId).fontSize(14).fontColor(this.pal().text).fontFamily(AppConfig.fontFamily)
        Text(record.userName + ' · ' + (record.unlock === 'biometric' ? '人脸/指纹' : '锁屏密码') + ' · ' +
          formatDate(record.createdAt)).fontSize(11).fontColor(this.pal().text3).fontFamily(AppConfig.fontFamily)
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Button('删除', { type: ButtonType.Capsule }).fontSize(12).height(30).fontColor(this.pal().danger)
        .backgroundColor(this.pal().surface).enabled(!this.busy).onClick((): void => { void this.remove(record); })
    }.width('100%')
  }

  build() {
    Column({ space: 12 }) {
      Text('原型（调试版）：用同一华为账号的手机作为通行密钥。私钥只保存在这台设备的系统密钥库里，每次使用都要验证人脸、指纹或锁屏密码。')
        .fontSize(12).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily).lineHeight(18).width('100%')
      Column({ space: 10 }) {
        this.receiveCard()
      }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(16).alignItems(HorizontalAlign.Start)
      Column({ space: 10 }) {
        this.heading('这台设备上的通行密钥', this.records.length === 0 ? '还没有保存通行密钥' : '')
        ForEach(this.records, (record: PasskeyRecord): void => { this.recordRow(record) },
          (record: PasskeyRecord): string => record.id + ':' + record.signCount.toString())
      }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(16).alignItems(HorizontalAlign.Start)
      Column({ space: 10 }) {
        this.heading('测试', '在另一台同账号设备上打开“接收登录请求”，再从这里发送测试注册和登录；结果会像网站一样校验签名。')
        Row({ space: 10 }) {
          this.button('测试注册', true, !this.busy, (): void => { void this.testRegister(); })
          this.button('测试登录', false, !this.busy && this.testCredentialId.length > 0,
            (): void => { void this.testSignIn(); })
        }.width('100%')
        ForEach(this.log, (line: string): void => {
          Text(line).fontSize(12).fontColor(this.pal().text2).fontFamily(AppConfig.fontFamily).lineHeight(17).width('100%')
        }, (line: string, index: number): string => index.toString() + ':' + line)
      }.width('100%').padding(16).backgroundColor(this.pal().card).borderRadius(16).alignItems(HorizontalAlign.Start)
    }.width('100%')
  }
}
