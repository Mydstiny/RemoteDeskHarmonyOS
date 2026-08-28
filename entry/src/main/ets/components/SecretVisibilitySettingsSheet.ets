import { promptAction } from '@kit.ArkUI';
import { AppTheme, Palette, buildDark, buildLight } from '../common/Theme';
import {
  EditableSecretKind,
  SecretPresentationPolicy,
  SecretPresentationStore,
  allHiddenSecretPresentationPolicy,
  defaultSecretPresentationPolicy,
  parseSecretPresentationPolicy,
  secretPresentationHidden,
  serializeSecretPresentationPolicy,
  withSecretPresentationHidden
} from '../services/SecretPresentationPolicy';

@Component
export struct SecretVisibilitySettingsSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop initialPolicyJson: string = '';
  onClose: () => void = (): void => {};
  onSave: (policy: SecretPresentationPolicy) => boolean =
    (_policy: SecretPresentationPolicy): boolean => false;

  @State policyJson: string = '';
  private readonly store: SecretPresentationStore = SecretPresentationStore.getInstance();
  private storeUnsubscribe: (() => void) | null = null;

  aboutToAppear(): void {
    this.policyJson = this.store.getJson();
    if (this.storeUnsubscribe === null) {
      this.storeUnsubscribe = this.store.onChange((): void => {
        this.policyJson = this.store.getJson();
      });
    }
  }

  aboutToDisappear(): void {
    if (this.storeUnsubscribe !== null) {
      this.storeUnsubscribe();
      this.storeUnsubscribe = null;
    }
  }

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private policy(): SecretPresentationPolicy {
    return parseSecretPresentationPolicy(this.policyJson);
  }

  private persist(policy: SecretPresentationPolicy): void {
    if (!this.onSave(policy)) {
      promptAction.showToast({ message: '本机密码回显设置保存失败，已保留原设置', duration: 2400 });
      this.policyJson = this.store.getJson();
      return;
    }
    this.policyJson = serializeSecretPresentationPolicy(policy);
  }

  private toggle(kind: EditableSecretKind, hidden: boolean): void {
    this.persist(withSecretPresentationHidden(this.store.get(), kind, hidden));
  }

  @Builder private header() {
    Row() {
      Column() {
        Text('密码与秘密回显').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
        Text('选择编辑时不读取、不显示旧值的密码类型')
          .fontSize(11).fontColor(this.pal().text3).fontFamily(AppTheme.fontFamily)
          .margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('完成').fontSize(13).fontColor(this.accentColor)
        .fontFamily(AppTheme.fontFamily).onClick((): void => { this.onClose(); })
    }.width('100%').padding({ left: 22, right: 22, top: 22, bottom: 14 })
  }

  @Builder private secretRow(kind: EditableSecretKind, title: string, detail: string) {
    Row() {
      Column() {
        Text(title).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
        Text(detail).fontSize(11).fontColor(this.pal().text3)
          .fontFamily(AppTheme.fontFamily).lineHeight(16).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({
        type: ToggleType.Switch,
        isOn: secretPresentationHidden(this.policy(), kind)
      }).selectedColor(this.accentColor).scale({ x: 0.88, y: 0.88 })
        .onChange((hidden: boolean): void => { this.toggle(kind, hidden); })
    }.width('100%').padding({ left: 15, right: 12, top: 10, bottom: 10 })
  }

  @Builder private divider() {
    Divider().strokeWidth(0.5).color(this.pal().divider).margin({ left: 15, right: 15 })
  }

  @Builder private alwaysHiddenRow(title: string, detail: string) {
    Row() {
      SymbolGlyph($r('sys.symbol.lock_fill')).fontSize(17).fontColor([this.pal().text3])
        .margin({ right: 10 })
      Column() {
        Text(title).fontSize(13).fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
        Text(detail).fontSize(10).fontColor(this.pal().text3)
          .fontFamily(AppTheme.fontFamily).margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text('始终隐藏').fontSize(10).fontColor(this.pal().text3)
        .fontFamily(AppTheme.fontFamily)
    }.width('100%').padding({ left: 15, right: 15, top: 9, bottom: 9 })
  }

  build() {
    Column() {
      this.header()
      Scroll() {
        Column() {
          Column() {
            Text('隐藏后，旧密码只显示“已保存”。留空保存会保留旧值；输入新值才会覆盖。' +
              '该选择仅保存在本机，不改变密码的加密、同步或连接方式。')
              .fontSize(12).fontColor(this.pal().text2).fontFamily(AppTheme.fontFamily)
              .lineHeight(18).width('100%')
          }.width('100%').padding(13).borderRadius(12).backgroundColor(this.pal().surface)
            .margin({ bottom: 14 })

          Row() {
            Button('全部隐藏').layoutWeight(1).height(38).borderRadius(10)
              .backgroundColor(this.accentColor).fontColor(Color.White).fontSize(12)
              .onClick((): void => { this.persist(allHiddenSecretPresentationPolicy()); })
            Button('恢复兼容默认').layoutWeight(1).height(38).borderRadius(10)
              .backgroundColor(this.pal().surface).fontColor(this.pal().text2).fontSize(12)
              .margin({ left: 8 })
              .onClick((): void => { this.persist(defaultSecretPresentationPolicy()); })
          }.width('100%').margin({ bottom: 16 })

          Text('可选择隐藏').fontSize(12).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text3).fontFamily(AppTheme.fontFamily)
            .width('100%').margin({ left: 6, bottom: 7 })
          Column() {
            this.secretRow('rdp_host_password', 'RDP 主机密码', '主机记录中直接保存的 Windows 登录密码')
            this.divider()
            this.secretRow('rdp_saved_credential', 'Windows 凭据密码', 'RDP 凭据管理器中的共享账号密码')
            this.divider()
            this.secretRow('rustdesk_device_password', 'RustDesk 设备密码', '一次性或永久设备密码')
            this.divider()
            this.secretRow('ssh_host_password', 'SSH 登录密码', 'SSH 主机密码认证使用的秘密')
            this.divider()
            this.secretRow('ssh_key_passphrase', 'SSH 私钥口令', '主机绑定的加密私钥解锁口令')
            this.divider()
            this.secretRow('vnc_host_password', 'VNC 主机密码', '统一控制现有 VNC 不回显行为')
          }.width('100%').borderRadius(14).backgroundColor(this.pal().card)
            .border({ width: 0.5, color: this.pal().cardBorder })

          Text('始终隐藏').fontSize(12).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text3).fontFamily(AppTheme.fontFamily)
            .width('100%').margin({ left: 6, top: 17, bottom: 7 })
          Column() {
            this.alwaysHiddenRow('高敏感认证材料', 'NTLM Hash、TOTP 种子与访问令牌')
            this.divider()
            this.alwaysHiddenRow('密钥材料', 'SSH 私钥正文、Moonlight 客户端身份与应用主密码')
          }.width('100%').borderRadius(14).backgroundColor(this.pal().card)
            .border({ width: 0.5, color: this.pal().cardBorder })
          Blank().height(24)
        }.width('100%').padding({ left: 22, right: 22 })
      }.layoutWeight(1).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
    }.width('100%').height('100%').backgroundColor(this.pal().bg)
      .borderRadius(this.breakpointRadius())
  }

  private breakpointRadius(): number {
    return 20;
  }
}
