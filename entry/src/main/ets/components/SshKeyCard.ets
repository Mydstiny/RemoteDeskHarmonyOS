/**
 * SshKeyCard.ets — SSH 密钥卡片 (v5: 复制公钥需锁验证)
 */
import { SshKey, SshKeyType } from '../model/SshKey';
import { Palette, buildDark, buildLight, AppTheme } from '../common/Theme';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { showLockGate, lockGateErrorMessage } from './LockGate';

@Component
export struct SshKeyCard {
  @Prop sshKey: SshKey;
  @Prop showCheckbox: boolean = false;
  @Prop checkboxSelected: boolean = false;
  onCheckChange?: (checked: boolean) => void;
  onEdit?: () => void;
  onToggleLock?: () => void;
  onSelect?: () => void;
  onDelete?: () => void;
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @State menuVisible: boolean = false;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private typeLabel(kt: SshKeyType): string {
    if (kt === SshKeyType.RSA) { return 'RSA'; }
    if (kt === SshKeyType.ED25519) { return 'ED'; }
    if (kt === SshKeyType.ECDSA) { return 'EC'; }
    return 'KEY';
  }

  /** 缩略指纹: 前8字符 + ... + 后8字符 */
  private shortFingerprint(): string {
    const fp: string = this.sshKey.fingerprint;
    if (fp.length <= 24) { return fp; }
    const prefix: string = fp.substring(0, 10);
    const suffix: string = fp.substring(fp.length - 8);
    return prefix + '…' + suffix;
  }

  private async copyPublicKey(): Promise<void> {
    // 锁定状态需先验证身份
    if (this.sshKey.locked) {
      const r = await showLockGate(this.sshKey.label, 'biometric');
      if (!r.ok) {
        const msg: string = lockGateErrorMessage(r);
        if (msg !== '') { promptAction.showToast({ message: msg, duration: 2000 }); }
        return;
      }
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.sshKey.publicKey);
      pasteboard.getSystemPasteboard().setDataSync(data);
      promptAction.showToast({ message: '公钥已复制', duration: 1500 });
    } catch (err) {
      promptAction.showToast({ message: '复制失败', duration: 1500 });
    }
  }

  @Builder sshKeyMenuBuilder() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(16).fontColor([this.pal().text])
        Text('管理').fontSize(13).fontColor(this.pal().text).margin({ left: 8 })
      }
      .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .onClick(() => { animateTo({ duration: 150 }, () => { this.menuVisible = false; }); if (this.onEdit) { this.onEdit(); } })

      Divider().strokeWidth(0.5).color(this.pal().cardBorder).width('100%')

      Row() {
        SymbolGlyph(this.sshKey.locked ? $r('sys.symbol.lock_open') : $r('sys.symbol.ohos_lock'))
          .fontSize(16).fontColor([this.pal().text])
        Text(this.sshKey.locked ? '解锁' : '上锁').fontSize(13).fontColor(this.pal().text).margin({ left: 8 })
      }
      .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .onClick(() => { animateTo({ duration: 150 }, () => { this.menuVisible = false; }); if (this.onToggleLock) { this.onToggleLock(); } })

      Divider().strokeWidth(0.5).color(this.pal().cardBorder).width('100%')

      Row() {
        SymbolGlyph($r('sys.symbol.list_bullet')).fontSize(16).fontColor([this.pal().text])
        Text('多选').fontSize(13).fontColor(this.pal().text).margin({ left: 8 })
      }
      .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .onClick(() => { animateTo({ duration: 150 }, () => { this.menuVisible = false; }); if (this.onSelect) { this.onSelect(); } })

      Divider().strokeWidth(0.5).color(this.pal().cardBorder).width('100%')

      Row() {
        SymbolGlyph($r('sys.symbol.ohos_trash')).fontSize(16).fontColor([this.pal().danger])
        Text('删除').fontSize(13).fontColor(this.pal().danger).margin({ left: 8 })
      }
      .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .onClick(() => { animateTo({ duration: 150 }, () => { this.menuVisible = false; }); if (this.onDelete) { this.onDelete(); } })
    }
    .width(148).padding({ top: 2, bottom: 2 }).borderRadius(12)
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.scale({ x: 0.85, y: 0.85 }).combine(TransitionEffect.OPACITY)
        .animation({ duration: 200, curve: Curve.FastOutSlowIn }),
      TransitionEffect.scale({ x: 0.85, y: 0.85 }).combine(TransitionEffect.OPACITY)
        .animation({ duration: 150, curve: Curve.FastOutSlowIn })
    ))
  }

  build() {
    Row() {
      if (this.showCheckbox) {
        Checkbox()
          .select(this.checkboxSelected)
          .selectedColor('#007DFF')
          .margin({ right: 8 })
          .onChange((v: boolean) => { if (this.onCheckChange) { this.onCheckChange(v); } })
      }
      // 密钥类型图标 (sm: 42, md+: 44)
      Text(this.typeLabel(this.sshKey.keyType))
        .fontSize(this.breakpoint === 'sm' ? 16 : 18).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
        .width(this.breakpoint === 'sm' ? 42 : 44)
        .height(this.breakpoint === 'sm' ? 42 : 44)
        .borderRadius(this.breakpoint === 'sm' ? 21 : 22).backgroundColor(this.accentColor)
        .textAlign(TextAlign.Center)
        .margin({ right: this.breakpoint === 'sm' ? 10 : 12 })

      // 信息区
      Column() {
        // 第一行: 名称 + 标签
        Row() {
          Text(this.sshKey.label)
            .fontSize(this.breakpoint === 'sm' ? 14 : 15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text).maxLines(1).layoutWeight(1)
          if (this.sshKey.isLegacyFormat()) {
            Text('旧格式')
              .fontSize(9).fontColor('#FFFFFF')
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .borderRadius(4).backgroundColor('#FF9500')
              .margin({ left: 4 })
          }
          if (this.sshKey.locked) {
            SymbolGlyph($r('sys.symbol.ohos_lock'))
              .fontSize(14).fontColor([this.accentColor]).margin({ left: 4 })
          }
        }.width('100%')

        // 第二行: 指纹 (始终显示, 用于识别密钥)
        if (this.sshKey.fingerprint !== '') {
          Text(this.shortFingerprint())
            .fontSize(this.breakpoint === 'sm' ? 10 : 11)
            .fontColor(this.pal().text3).maxLines(1)
            .fontFamily('monospace')
        }

        // 第三行: 附加信息
        Row() {
          Text(SshKey.typeLabel(this.sshKey.keyType))
            .fontSize(10).fontWeight(FontWeight.Medium)
            .fontColor(this.accentColor)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .borderRadius(3).backgroundColor(this.accentColor + '18')
          if (this.sshKey.privateKeyEncrypted) {
            Text('加密')
              .fontSize(10).fontColor(this.pal().text2)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .borderRadius(3).backgroundColor(this.pal().text2 + '12')
              .margin({ left: 4 })
          }
          if (this.sshKey.locked) {
            Text('已锁定')
              .fontSize(10).fontColor('#FF9500')
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .borderRadius(3).backgroundColor('#FF9500' + '15')
              .margin({ left: 4 })
          }
          if (this.sshKey.comment !== '' && !this.sshKey.locked) {
            Text(this.sshKey.comment)
              .fontSize(10).fontColor(this.pal().text3).maxLines(1).margin({ left: 4 })
          }
        }.width('100%').margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)
      .onClick(() => { this.copyPublicKey(); })

      // PC/2in1: 省略号按钮 → 弹出操作菜单
      if (this.isDesktopDevice && !this.showCheckbox) {
        Button() {
          Text('⋯').fontSize(18).fontColor(this.pal().text)
        }
        .width(36).height(36).borderRadius(18)
        .backgroundColor(this.pal().surface)
        .margin({ left: 4 })
        .bindPopup(this.menuVisible, {
          builder: this.sshKeyMenuBuilder(),
          placement: Placement.BottomRight,
          enableArrow: true,
          popupColor: this.pal().card,
          onStateChange: (e: Object) => {
            const ev: Record<string, boolean> = e as Record<string, boolean>;
            if (!ev['isVisible']) { this.menuVisible = false; }
          }
        })
        .onClick(() => { animateTo({ duration: 200, curve: Curve.FastOutSlowIn }, () => { this.menuVisible = !this.menuVisible; }); })
      }
    }
    .width('100%')
    .constraintSize({ minHeight: this.breakpoint === 'sm' ? 66 : 80 })
    .padding(this.breakpoint === 'sm' ? { left: 12, right: 14, top: 12, bottom: 12 } : 14)
    .borderRadius(14).backgroundColor(this.pal().card)
    .backgroundBlurStyle(BlurStyle.Regular)
    .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
  }
}
