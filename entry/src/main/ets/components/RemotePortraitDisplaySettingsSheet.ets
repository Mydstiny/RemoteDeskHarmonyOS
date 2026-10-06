import { promptAction } from '@kit.ArkUI';
import { AppTheme, Palette, buildDark, buildLight } from '../common/Theme';
import { appUiOnAccentText } from '../common/AppUiColorPolicy';
import { protocolIcon } from '../services/ProtocolIconPolicy';
import {
  defaultRemotePortraitDisplayPreferences,
  remotePortraitDisplayModeLabel,
  RemotePortraitDisplayPreferencePresence,
  RemotePortraitDisplayPreferences,
  RemotePortraitDisplayPreferenceUpdate,
  RemotePortraitProtocolPreference,
  RemotePortraitProtocol,
  RemotePortraitDisplayMode
} from '../services/RemotePortraitDisplayPreferencePolicy';
import {
  RemotePortraitSidebarHeightMode,
  remotePortraitSidebarHeightLabel,
  remotePortraitSidebarHeightModes,
  normalizeRemotePortraitSidebarHeightMode
} from '../services/RemotePortraitSidebarPolicy';
import { SettingsSavedBadge } from './SettingsSavedBadge';

function preferenceOf(values: RemotePortraitDisplayPreferences,
  protocol: RemotePortraitProtocol): RemotePortraitProtocolPreference {
  if (protocol === 'rdp') { return values.rdp; }
  if (protocol === 'rustdesk') { return values.rustdesk; }
  if (protocol === 'vnc') { return values.vnc; }
  return values.moonlight;
}

/** Only the changed protocol is written, so a stale copy never reverts the others. */
function touchedFor(protocol: RemotePortraitProtocol | ''): RemotePortraitDisplayPreferencePresence {
  return {
    rdpEnabled: protocol === 'rdp',
    rdpMode: protocol === 'rdp',
    rustdeskEnabled: protocol === 'rustdesk',
    rustdeskMode: protocol === 'rustdesk',
    vncEnabled: protocol === 'vnc',
    vncMode: protocol === 'vnc',
    moonlightEnabled: protocol === 'moonlight',
    moonlightMode: protocol === 'moonlight'
  };
}

@Component
export struct RemotePortraitDisplaySettingsSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop initialPreferences: RemotePortraitDisplayPreferences =
    defaultRemotePortraitDisplayPreferences();
  @Prop initialSidebarHeightMode: RemotePortraitSidebarHeightMode = 'auto';
  onClose: () => void = (): void => {};
  onSave: (update: RemotePortraitDisplayPreferenceUpdate,
    heightMode: RemotePortraitSidebarHeightMode) => boolean =
    (_update: RemotePortraitDisplayPreferenceUpdate,
      _heightMode: RemotePortraitSidebarHeightMode): boolean => false;

  @State draft: RemotePortraitDisplayPreferences =
    defaultRemotePortraitDisplayPreferences();
  @State private draftSidebarHeightMode: RemotePortraitSidebarHeightMode = 'auto';
  @State savedTick: number = 0;

  aboutToAppear(): void {
    this.draft = JSON.parse(JSON.stringify(this.initialPreferences)) as RemotePortraitDisplayPreferences;
    this.draftSidebarHeightMode = normalizeRemotePortraitSidebarHeightMode(
      this.initialSidebarHeightMode);
  }

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private preference(protocol: RemotePortraitProtocol): RemotePortraitProtocolPreference {
    return preferenceOf(this.draft, protocol);
  }

  private copy(): RemotePortraitDisplayPreferences {
    return JSON.parse(JSON.stringify(this.draft)) as RemotePortraitDisplayPreferences;
  }

  /** Every change saves at once; if saving fails the controls go back to the saved values. */
  private commit(previous: RemotePortraitDisplayPreferences,
    previousHeightMode: RemotePortraitSidebarHeightMode, protocol: RemotePortraitProtocol | ''): void {
    if (!this.onSave({ values: this.draft, touched: touchedFor(protocol) }, this.draftSidebarHeightMode)) {
      this.draft = previous;
      this.draftSidebarHeightMode = previousHeightMode;
      promptAction.showToast({ message: '竖屏显示没有保存，请重试', duration: 2200 });
      return;
    }
    this.savedTick++;
  }

  private setEnabled(protocol: RemotePortraitProtocol, enabled: boolean): void {
    const previous: RemotePortraitDisplayPreferences = this.copy();
    const next: RemotePortraitDisplayPreferences = this.copy();
    const value: RemotePortraitProtocolPreference = preferenceOf(next, protocol);
    value.enabled = enabled;
    if (!enabled) { value.mode = 'default'; }
    this.draft = next;
    this.commit(previous, this.draftSidebarHeightMode, protocol);
  }

  private setMode(protocol: RemotePortraitProtocol, mode: RemotePortraitDisplayMode): void {
    if (!this.preference(protocol).enabled || this.preference(protocol).mode === mode) { return; }
    const previous: RemotePortraitDisplayPreferences = this.copy();
    const next: RemotePortraitDisplayPreferences = this.copy();
    preferenceOf(next, protocol).mode = mode;
    this.draft = next;
    this.commit(previous, this.draftSidebarHeightMode, protocol);
  }

  private setSidebarHeightMode(mode: RemotePortraitSidebarHeightMode): void {
    const normalized: RemotePortraitSidebarHeightMode = normalizeRemotePortraitSidebarHeightMode(mode);
    if (normalized === this.draftSidebarHeightMode) { return; }
    const previousHeightMode: RemotePortraitSidebarHeightMode = this.draftSidebarHeightMode;
    this.draftSidebarHeightMode = normalized;
    this.commit(this.copy(), previousHeightMode, '');
  }

  @Builder private sidebarHeightButton(mode: RemotePortraitSidebarHeightMode) {
    Button(remotePortraitSidebarHeightLabel(mode)).height(32).fontSize(11)
      .padding({ left: 14, right: 14 })
      .backgroundColor(this.draftSidebarHeightMode === mode ? this.accentColor : this.pal().surface)
      .fontColor(this.draftSidebarHeightMode === mode ? appUiOnAccentText(this.accentColor) : this.pal().text2)
      .borderRadius(8)
      .onClick((): void => { this.setSidebarHeightMode(mode); });
  }

  @Builder private header() {
    Row() {
      Column() {
        Text('竖屏显示').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
        Text('选择允许手机竖屏显示的远程协议')
          .fontSize(11).fontColor(this.pal().text3).fontFamily(AppTheme.fontFamily)
          .margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      SettingsSavedBadge({ savedTick: this.savedTick }).margin({ right: 6 })
      SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
        .width(36).height(36).accessibilityText('关闭')
        .onClick((): void => { this.onClose(); })
    }.width('100%').padding({ left: 22, right: 16, top: 18, bottom: 12 })
  }

  @Builder private modeChooser(protocol: RemotePortraitProtocol) {
    if (this.preference(protocol).enabled) {
      Row({ space: 6 }) {
        Button('默认方向').height(28).fontSize(11).padding({ left: 8, right: 8 })
          .backgroundColor(this.preference(protocol).mode === 'default' ? this.accentColor : this.pal().surface)
          .fontColor(this.preference(protocol).mode === 'default' ?
            appUiOnAccentText(this.accentColor) : this.pal().text2)
          .borderRadius(7).onClick((): void => { this.setMode(protocol, 'default'); })
        Button('竖屏').height(28).fontSize(11).padding({ left: 8, right: 8 })
          .backgroundColor(this.preference(protocol).mode === 'portrait' ? this.accentColor : this.pal().surface)
          .fontColor(this.preference(protocol).mode === 'portrait' ?
            appUiOnAccentText(this.accentColor) : this.pal().text2)
          .borderRadius(7).onClick((): void => { this.setMode(protocol, 'portrait'); })
      }.margin({ top: 7 })
    }
  }

  @Builder private protocolRow(protocol: RemotePortraitProtocol, title: string, detail: string) {
    Row() {
      SymbolGlyph(protocolIcon(protocol)).fontSize(21).fontColor([this.pal().text3]).margin({ right: 12 })
      Column() {
        Row() {
          Text(title).fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.preference(protocol).enabled })
            .selectedColor(this.accentColor).scale({ x: 0.82, y: 0.82 })
            .accessibilityText(title + ' 竖屏显示')
            .onChange((value: boolean): void => { this.setEnabled(protocol, value); })
        }.width('100%')
        Text(detail).fontSize(11).fontColor(this.pal().text3)
          .fontFamily(AppTheme.fontFamily).lineHeight(16).margin({ top: 3 })
        this.modeChooser(protocol)
        if (this.preference(protocol).enabled) {
          Text('当前：' + remotePortraitDisplayModeLabel(this.preference(protocol).mode))
            .fontSize(10).fontColor(this.pal().text3).margin({ top: 3 })
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }.width('100%').padding({ left: 15, right: 12, top: 12, bottom: 12 })
  }

  @Builder private divider() {
    Divider().strokeWidth(0.5).color(this.pal().divider).margin({ left: 15, right: 15 })
  }

  build() {
    Column() {
      this.header()
      Scroll() {
        Column() {
          Text('竖屏时会把远端横向画面按比例缩小并完整放入手机屏幕。建议同时打开“双指缩放”，方便查看细节和移动画面。改动会立即保存。')
            .fontSize(12).fontColor(this.pal().text2).fontFamily(AppTheme.fontFamily)
            .lineHeight(18).width('100%').padding(13)
            .borderRadius(12).backgroundColor(this.pal().surface).margin({ bottom: 14 })
          Column() {
            this.protocolRow('rdp', 'RDP', '远端桌面竖屏 fit 与侧栏翻转')
            this.divider()
            this.protocolRow('rustdesk', 'RustDesk', '本机窗口竖屏；不改变被控手机方向')
            this.divider()
            this.protocolRow('vnc', 'VNC', 'VNC 画面竖屏 fit 与侧栏翻转')
            this.divider()
            this.protocolRow('moonlight', 'Moonlight', '串流画面竖屏 fit 与侧栏翻转')
          }.width('100%').borderRadius(14).backgroundColor(this.pal().card)
            .border({ width: 0.5, color: this.pal().cardBorder })
          Column() {
            Text('竖屏侧栏高度').fontSize(13).fontWeight(FontWeight.Medium)
              .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
            Text('仅在竖屏显示启用时生效；自动保持内容所需高度，其他选项限制侧栏占用的安全区域。')
              .fontSize(11).fontColor(this.pal().text3).fontFamily(AppTheme.fontFamily)
              .lineHeight(16).margin({ top: 4, bottom: 8 })
            Row({ space: 7 }) {
              this.sidebarHeightButton(remotePortraitSidebarHeightModes()[0])
              this.sidebarHeightButton(remotePortraitSidebarHeightModes()[1])
              this.sidebarHeightButton(remotePortraitSidebarHeightModes()[2])
              this.sidebarHeightButton(remotePortraitSidebarHeightModes()[3])
            }.width('100%')
          }.width('100%').padding(14).margin({ top: 14 })
            .borderRadius(14).backgroundColor(this.pal().card)
            .border({ width: 0.5, color: this.pal().cardBorder })
          Text('SSH 使用终端内的“切换横竖屏”，不会出现在这里，也不会新增本侧栏入口。')
            .fontSize(11).fontColor(this.pal().text3).fontFamily(AppTheme.fontFamily)
            .lineHeight(17).width('100%').margin({ top: 12, bottom: 24 })
        }.width('100%').padding({ left: 22, right: 22 })
      }.layoutWeight(1).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
    }.width('100%').height('100%').backgroundColor(this.pal().sheetBg).borderRadius(20)
  }
}
