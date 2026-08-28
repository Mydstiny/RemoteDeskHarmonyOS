/**
 * SshKeyInstallSheet.ets — 安装 SSH 公钥到远端主机
 *
 * 流程:
 *   1. 选择目标 SSH Host (从主机列表)
 *   2. 显示认证方式 (密码/旧密钥)
 *   3. locked Host/Key → showLockGate
 *   4. 安装公钥 → 验证新密钥 → 可选切换 Host
 */
import { promptAction } from '@kit.ArkUI';
import { RemoteHost } from '../model/RemoteHost';
import { SshKey } from '../model/SshKey';
import { Palette, buildDark, buildLight, AppTheme } from '../common/Theme';
import { showLockGate, lockGateErrorMessage } from './LockGate';
import { ExtensionLoader } from '../services/ExtensionLoader';
import { DataCrypto } from '../services/DataCrypto';
import { HostSyncService } from '../services/HostSyncService';
import { KeyVaultService } from '../services/KeyVaultService';
import { SshPublicKeyInstallResult, SshAuthTestResult, GeneratedSshKeyPair } from '../types/rdpnapi';

interface SshKeyInstallHostView {
  id: string;
  label: string;
  host: string;
  port: number;
  username: string;
  locked: boolean;
  passwordConfigured: boolean;
  keyConfigured: boolean;
}

interface SshKeyInstallTargetView {
  label: string;
  locked: boolean;
}

@Component
export struct SshKeyInstallSheet {
  @Prop targetKeyId: string;
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  onComplete?: () => void;

  @State hosts: SshKeyInstallHostView[] = [];
  @State selectedHostId: string = '';
  @State installing: boolean = false;
  @State verifying: boolean = false;
  @State installResult: SshPublicKeyInstallResult | null = null;
  @State verifyResult: SshAuthTestResult | null = null;
  @State hostSwitchSaveError: string = '';
  @State step: number = 0; // 0=select host, 1=install, 2=verify, 3=done
  @State switchToNewKey: boolean = true;
  @State hostViewRevision: number = 0;

  private loader: ExtensionLoader = ExtensionLoader.getInstance();
  private hostSync: HostSyncService = HostSyncService.getInstance();
  private kvs: KeyVaultService = KeyVaultService.getInstance();
  private hostDataUnsubscribe: (() => void) | null = null;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private font(): string { return AppTheme.fontFamily; }

  aboutToAppear(): void {
    this.loadHosts();
    if (!this.hostDataUnsubscribe) {
      this.hostDataUnsubscribe = this.hostSync.onDataChange((): void => {
        this.loadHosts();
      });
    }
  }

  aboutToDisappear(): void {
    if (this.hostDataUnsubscribe) {
      this.hostDataUnsubscribe();
      this.hostDataUnsubscribe = null;
    }
  }

  private loadHosts(): void {
    const selectedId: string = this.selectedHostId;
    const allHosts: RemoteHost[] = this.hostSync.getAllHosts();
    this.hosts = allHosts.filter((host: RemoteHost): boolean => host.protocol === 'ssh')
      .map((host: RemoteHost): SshKeyInstallHostView => ({
        id: host.id,
        label: host.label,
        host: host.host,
        port: host.port,
        username: host.username,
        locked: host.locked,
        passwordConfigured: host.passwordConfigured || host.password.length > 0,
        keyConfigured: host.sshKeyId !== '' || host.sshKeyDataConfigured ||
          host.sshKeyData.length > 0
      }));
    this.hostViewRevision += 1;
    if (selectedId !== '') {
      const refreshed: SshKeyInstallHostView | undefined = this.hosts.find(
        (host: SshKeyInstallHostView): boolean => host.id === selectedId);
      this.selectedHostId = refreshed === undefined ? '' : refreshed.id;
      if (refreshed === undefined && this.step === 0 && !this.installing) {
        promptAction.showToast({ message: '所选 SSH 主机已被删除，请重新选择', duration: 2000 });
      }
    }
  }

  private targetView(): SshKeyInstallTargetView | null {
    const key: SshKey | undefined = this.kvs.getSshKey(this.targetKeyId);
    return key === undefined ? null : { label: key.label, locked: key.locked };
  }

  // ====== 安装流程 ======
  private async doInstall(): Promise<void> {
    const selectedView: SshKeyInstallHostView | undefined = this.hosts.find(
      (host: SshKeyInstallHostView): boolean => host.id === this.selectedHostId);
    if (selectedView === undefined) {
      promptAction.showToast({ message: '请选择目标主机', duration: 1500 });
      return;
    }

    // 鉴权
    if (selectedView.locked) {
      const r = await showLockGate(selectedView.label, 'biometric');
      if (!r.ok) { const m = lockGateErrorMessage(r); if (m !== '') { promptAction.showToast({ message: m, duration: 2000 }); } return; }
    }
    const targetView: SshKeyInstallTargetView | null = this.targetView();
    if (targetView === null) {
      promptAction.showToast({ message: '所选 SSH 密钥已不存在，请重新选择', duration: 2000 });
      return;
    }
    if (targetView.locked) {
      const r = await showLockGate(targetView.label, 'biometric');
      if (!r.ok) { const m = lockGateErrorMessage(r); if (m !== '') { promptAction.showToast({ message: m, duration: 2000 }); } return; }
    }

    const crypto: DataCrypto = DataCrypto.getInstance();
    if (crypto.isSetupComplete() && !crypto.isReady()) {
      promptAction.showToast({ message: '本地加密仓库已锁定，请先解锁后重试', duration: 2000 });
      return;
    }
    const host: RemoteHost | undefined = this.hostSync.getHost(this.selectedHostId);
    const targetKey: SshKey | undefined = this.kvs.getSshKey(this.targetKeyId);
    if (host === undefined || host.protocol !== 'ssh') {
      promptAction.showToast({ message: '所选 SSH 主机已变化，请重新选择', duration: 2000 });
      this.loadHosts();
      return;
    }
    if (targetKey === undefined) {
      promptAction.showToast({ message: '所选 SSH 密钥已不存在，请重新选择', duration: 2000 });
      return;
    }
    if ((host.locked && !selectedView.locked) || (targetKey.locked && !targetView.locked)) {
      promptAction.showToast({ message: '安全锁状态已变化，请重新验证后重试', duration: 2000 });
      this.loadHosts();
      return;
    }

    // 校验公钥
    if (!this.loader.validatePublicKeyForAuthorizedKeys(targetKey.publicKey)) {
      promptAction.showToast({ message: '[CC-SSHKEY-09] 公钥格式无效, 无法安装', duration: 2000 });
      return;
    }

    let authPrivateKey: string = '';
    let authPassphrase: string = '';
    if (host.sshUseKey) {
      authPassphrase = host.sshKeyPassphrase;
      if (host.sshKeyId !== '') {
        const authKey: SshKey | undefined = this.kvs.getSshKey(host.sshKeyId);
        if (authKey === undefined || authKey.privateKey === '') {
          promptAction.showToast({ message: '当前主机的认证私钥不可用，请检查密钥保险库', duration: 2000 });
          return;
        }
        authPrivateKey = authKey.privateKey;
      } else {
        authPrivateKey = host.sshKeyData;
      }
      if (authPrivateKey === '') {
        promptAction.showToast({ message: '当前主机的认证私钥不可用，请先解锁或重新配置', duration: 2000 });
        return;
      }
      if (host.sshKeyPassphraseConfigured && authPassphrase === '') {
        promptAction.showToast({ message: '当前私钥密码不可用，请先解锁后重试', duration: 2000 });
        return;
      }
    } else if (host.password === '') {
      promptAction.showToast({ message: host.passwordConfigured ?
        '服务器密码不可用，请先解锁后重试' : '当前主机未配置服务器密码', duration: 2000 });
      return;
    }
    if (targetKey.privateKey === '') {
      promptAction.showToast({ message: '所选 SSH 私钥不可用，请先解锁后重试', duration: 2000 });
      return;
    }

    this.installing = true;
    this.step = 1;
    this.installResult = null;
    this.verifyResult = null;
    this.hostSwitchSaveError = '';

    try {
      const result: SshPublicKeyInstallResult = this.loader.installSshPublicKey(
        host.host, host.port, host.username,
        host.sshUseKey ? '' : host.password, authPrivateKey, authPassphrase,
        targetKey.publicKey
      );
      this.installResult = result;

      if (result['ok']) {
        // 安装成功 → 验证新密钥
        this.step = 2;
        this.verifying = true;

        const testResult: SshAuthTestResult = await this.loader.testSshKeyAuthAsync(
          host.host, host.port, host.username,
          targetKey.privateKey, ''
        );
        this.verifyResult = testResult;
        this.verifying = false;

        if (testResult['ok'] && this.switchToNewKey) {
          // 切换 Host 使用新密钥
          const latestHost: RemoteHost | undefined = this.hostSync.getHost(host.id);
          if (latestHost === undefined) {
            this.hostSwitchSaveError = '新密钥已安装并验证成功，但主机记录已被删除；未保存认证方式。';
            this.step = 3;
            this.installing = false;
            return;
          }
          const updated: RemoteHost = latestHost.runtimeClone();
          updated.sshUseKey = true;
          updated.password = '';
          updated.passwordConfigured = false;
          updated.sshKeyId = targetKey.id;
          updated.sshKeyData = '';
          updated.sshKeyDataConfigured = false;
          updated.sshKeyPassphrase = '';
          updated.sshKeyPassphraseConfigured = false;
          updated.sshKeyPath = 'KeyVault: ' + targetKey.label;
          if (!this.hostSync.updateHost(updated)) {
            this.hostSwitchSaveError = '新密钥已安装并验证成功，但主机认证方式未能保存；请返回主机编辑页重试。';
            promptAction.showToast({ message: this.hostSwitchSaveError, duration: 3000 });
          }
        }

        this.step = 3;
      }
    } catch (err) {
      this.installResult = {
        ok: false, alreadyInstalled: false, verified: false, code: -99,
        message: '[CC-SSHKEY-10] 安装异常: ' + JSON.stringify(err)
      };
    }
    this.installing = false;
  }

  // ====== Host 列表项 ======
  @Builder hostItem(host: SshKeyInstallHostView) {
    Row() {
      Column() {
        Text(host.label).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(this.font()).maxLines(1)
        Text(host.username + '@' + host.host + ':' + host.port)
          .fontSize(11).fontColor(this.pal().text3).maxLines(1)
        // 认证方式
        Row() {
          if (host.passwordConfigured) {
            Text('密码').fontSize(10).fontColor(this.pal().success)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .borderRadius(3).backgroundColor(this.pal().success + '18')
          }
          if (host.keyConfigured) {
            Text('密钥').fontSize(10).fontColor(this.accentColor)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .borderRadius(3).backgroundColor(this.accentColor + '18')
              .margin({ left: 4 })
          }
          if (host.locked) {
            SymbolGlyph($r('sys.symbol.ohos_lock')).fontSize(10).fontColor([this.accentColor]).margin({ left: 4 })
          }
        }.margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)

      if (this.selectedHostId === host.id) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize(20).fontColor([this.accentColor])
      } else {
        Column().width(20).height(20).borderRadius(10)
          .border({ width: 2, color: this.pal().text3, style: BorderStyle.Solid })
      }
    }
    .width('100%').padding(12).borderRadius(10)
    .backgroundColor(this.selectedHostId === host.id
      ? this.accentColor + '12' : this.pal().card)
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    .onClick(() => { this.selectedHostId = host.id; })
  }

  build() {
    Column() {
      if (this.step === 0) {
        // ====== 选择主机 ======
        Text('安装公钥到主机').fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(this.font())
          .margin({ bottom: 4 }).width('100%')
        Text('选择目标 SSH 主机, 公钥将写入 ~/.ssh/authorized_keys')
          .fontSize(12).fontColor(this.pal().text3).fontFamily(this.font())
          .margin({ bottom: 14 }).width('100%')

        if (this.hosts.length === 0) {
          Column() {
            Text('没有 SSH 主机').fontSize(14).fontColor(this.pal().text2)
              .fontFamily(this.font()).margin({ bottom: 6 })
            Text('请先在主机列表中添加 SSH 主机')
              .fontSize(12).fontColor(this.pal().text3)
          }.width('100%').padding(24).justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column() {
              ForEach(this.hosts, (host: SshKeyInstallHostView) => {
                this.hostItem(host)
                Blank().height(6)
              }, (host: RemoteHost) => host.id + ':' + this.hostViewRevision.toString())
            }.width('100%')
          }.constraintSize({ maxHeight: 240 }).scrollBar(BarState.Off)
        }

        Button('安装公钥').width('100%').height(40).fontSize(14).fontWeight(FontWeight.Medium)
          .backgroundColor(this.selectedHostId !== '' ? this.accentColor : this.pal().surface)
          .fontColor(this.selectedHostId !== '' ? '#FFFFFF' : this.pal().text3)
          .borderRadius(10).margin({ top: 14 })
          .enabled(this.selectedHostId !== '' && !this.installing)
          .onClick(() => { this.doInstall(); })

        Row() {
          Text('安装成功后, 自动切换此主机使用新密钥登录')
            .fontSize(11).fontColor(this.pal().text3).fontFamily(this.font())
          Toggle({ type: ToggleType.Switch, isOn: this.switchToNewKey })
            .onChange((v: boolean) => { this.switchToNewKey = v; })
            .margin({ left: 8 })
        }.width('100%').margin({ top: 8 })
      } else {
        // ====== 安装进度 ======
        Column() {
          // Step indicators
          Row() {
            this.stepDot(1, this.step >= 1 ? (this.installResult ? (this.installResult['ok'] ? 'done' : 'fail') : 'active') : 'pending', '安装')
            this.stepLine(1)
            this.stepDot(2, this.step >= 2 ? (this.verifyResult ? (this.verifyResult['ok'] ? 'done' : 'fail') : 'active') : 'pending', '验证')
            this.stepLine(2)
            this.stepDot(3, this.step >= 3 ?
              (this.hostSwitchSaveError === '' ? 'done' : 'fail') : 'pending', '完成')
          }.width('100%').justifyContent(FlexAlign.Center).margin({ bottom: 16 })

          if (this.installResult !== null) {
            Column() {
              Row() {
                SymbolGlyph(this.installResult['ok'] ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.xmark_circle'))
                  .fontSize(18).fontColor([this.installResult['ok'] ? this.pal().success : this.pal().danger])
                Text(this.installResult['ok'] ? '安装成功' : '安装失败')
                  .fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor(this.installResult['ok'] ? this.pal().success : this.pal().danger)
                  .fontFamily(this.font()).margin({ left: 6 })
              }.margin({ bottom: 6 })
              Text(this.installResult['message'])
                .fontSize(11).fontColor(this.pal().text3).maxLines(4)
            }.width('100%').padding(12).borderRadius(10)
            .backgroundColor(this.pal().card).margin({ bottom: 8 })
          }

          if (this.verifyResult !== null) {
            Column() {
              Row() {
                SymbolGlyph(this.verifyResult['ok'] ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.xmark_circle'))
                  .fontSize(18).fontColor([this.verifyResult['ok'] ? this.pal().success : this.pal().danger])
                Text(this.verifyResult['ok'] ? '新密钥验证成功' : '验证失败')
                  .fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor(this.verifyResult['ok'] ? this.pal().success : this.pal().danger)
                  .fontFamily(this.font()).margin({ left: 6 })
              }.margin({ bottom: 4 })
              if (!this.verifyResult['ok']) {
                Text('公钥已写入但新密钥无法登录。请检查服务器配置。')
                  .fontSize(11).fontColor(this.pal().text2).maxLines(3)
              }
            }.width('100%').padding(12).borderRadius(10)
            .backgroundColor(this.pal().card).margin({ bottom: 8 })
          }

          if (this.hostSwitchSaveError !== '') {
            Text(this.hostSwitchSaveError)
              .fontSize(11).fontColor(this.pal().danger).maxLines(4)
              .width('100%').padding(12).borderRadius(10)
              .backgroundColor(this.pal().card).margin({ bottom: 8 })
          }

          if (this.installing || this.verifying) {
            LoadingProgress().width(32).height(32).color(this.accentColor)
          }

          if (this.step >= 3) {
            Button(this.hostSwitchSaveError === '' ? '完成' : '关闭（配置未保存）')
              .width('100%').height(40).fontSize(14).fontWeight(FontWeight.Medium)
              .backgroundColor(this.accentColor).fontColor('#FFFFFF').borderRadius(10)
              .margin({ top: 12 })
              .onClick(() => { if (this.onComplete) { this.onComplete(); } })
          }
        }
      }
    }
    .width('100%')
  }

  @Builder stepDot(num: number, status: string, label: string) {
    Column() {
      if (status === 'active') {
        Column().width(28).height(28).borderRadius(14)
          .backgroundColor(this.accentColor).justifyContent(FlexAlign.Center)
        Text(num.toString()).fontSize(12).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
      } else if (status === 'done') {
        SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([this.pal().success])
          .width(28).height(28)
      } else if (status === 'fail') {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor([this.pal().danger])
          .width(28).height(28)
      } else {
        Column().width(28).height(28).borderRadius(14)
          .border({ width: 2, color: this.pal().text3, style: BorderStyle.Solid })
          .justifyContent(FlexAlign.Center)
        Text(num.toString()).fontSize(12).fontColor(this.pal().text3)
      }
      Text(label).fontSize(10).fontColor(this.pal().text3).margin({ top: 4 })
    }
  }

  @Builder stepLine(idx: number) {
    Column()
      .width(32).height(2)
      .backgroundColor(this.step > idx ? this.accentColor : this.pal().text3 + '44')
      .margin({ left: 4, right: 4, bottom: 16 })
  }
}
