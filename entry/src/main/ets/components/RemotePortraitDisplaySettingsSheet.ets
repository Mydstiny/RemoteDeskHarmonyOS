import { promptAction } from '@kit.ArkUI';
import { AppTheme, Palette, buildDark, buildLight } from '../common/Theme';
import { protocolIcon } from '../services/ProtocolIconPolicy';
import {
  defaultRemotePortraitDisplayPreferences,
  remotePortraitDisplayModeLabel,
  RemotePortraitDisplayPreferences,
  RemotePortraitDisplayPreferenceUpdate,
  RemotePortraitProtocolPreference,
  RemotePortraitProtocol,
  RemotePortraitDisplayMode
} from '../services/RemotePortraitDisplayPreferencePolicy';

@Component
export struct RemotePortraitDisplaySettingsSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop initialPreferences: RemotePortraitDisplayPreferences =
    defaultRemotePortraitDisplayPreferences();
  onClose: () => void = (): void => {};
  onSave: (update: RemotePortraitDisplayPreferenceUpdate) => boolean =
    (_update: RemotePortraitDisplayPreferenceUpdate): boolean => false;

  @State draft: RemotePortraitDisplayPreferences =
    defaultRemotePortraitDisplayPreferences();
  private touchedEnabled: Record<string, boolean> = {};
  private touchedMode: Record<string, boolean> = {};

  aboutToAppear(): void {
    this.draft = JSON.parse(JSON.stringify(this.initialPreferences)) as RemotePortraitDisplayPreferences;
    this.touchedEnabled = {};
    this.touchedMode = {};
  }

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private preference(protocol: RemotePortraitProtocol): RemotePortraitProtocolPreference {
    if (protocol === 'rdp') { return this.draft.rdp; }
    if (protocol === 'rustdesk') { return this.draft.rustdesk; }
    if (protocol === 'vnc') { return this.draft.vnc; }
    return this.draft.moonlight;
  }

  private setEnabled(protocol: RemotePortraitProtocol, enabled: boolean): void {
    const value = this.preference(protocol);
    value.enabled = enabled;
    if (!enabled) { value.mode = 'default'; }
    this.touchedEnabled[protocol] = true;
    this.touchedMode[protocol] = true;
    this.draft = JSON.parse(JSON.stringify(this.draft)) as RemotePortraitDisplayPreferences;
  }

  private setMode(protocol: RemotePortraitProtocol, mode: RemotePortraitDisplayMode): void {
    if (!this.preference(protocol).enabled) { return; }
    this.preference(protocol).mode = mode;
    this.touchedMode[protocol] = true;
    this.draft = JSON.parse(JSON.stringify(this.draft)) as RemotePortraitDisplayPreferences;
  }

  private update(): RemotePortraitDisplayPreferenceUpdate {
    return {
      values: this.draft,
      touched: {
        rdpEnabled: this.touchedEnabled.rdp === true,
        rdpMode: this.touchedMode.rdp === true,
        rustdeskEnabled: this.touchedEnabled.rustdesk === true,
        rustdeskMode: this.touchedMode.rustdesk === true,
        vncEnabled: this.touchedEnabled.vnc === true,
        vncMode: this.touchedMode.vnc === true,
        moonlightEnabled: this.touchedEnabled.moonlight === true,
        moonlightMode: this.touchedMode.moonlight === true
      }
    };
  }

  private save(): void {
    if (!this.onSave(this.update())) {
      promptAction.showToast({ message: '竖屏显示设置保存失败，请重试', duration: 2200 });
      return;
    }
    this.onClose();
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
      Text('取消').fontSize(13).fontColor(this.pal().text2)
        .fontFamily(AppTheme.fontFamily).margin({ right: 18 })
        .onClick((): void => { this.onClose(); })
      Text('保存').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.accentColor)
        .fontFamily(AppTheme.fontFamily).onClick((): void => { this.save(); })
    }.width('100%').padding({ left: 22, right: 22, top: 22, bottom: 14 })
  }

  @Builder private modeChooser(protocol: RemotePortraitProtocol) {
    if (this.preference(protocol).enabled) {
      Row({ space: 6 }) {
        Button('默认方向').height(28).fontSize(11).padding({ left: 8, right: 8 })
          .backgroundColor(this.preference(protocol).mode === 'default' ? this.accentColor : this.pal().surface)
          .fontColor(this.preference(protocol).mode === 'default' ? Color.White : this.pal().text2)
          .borderRadius(7).onClick((): void => { this.setMode(protocol, 'default'); })
        Button('竖屏').height(28).fontSize(11).padding({ left: 8, right: 8 })
          .backgroundColor(this.preference(protocol).mode === 'portrait' ? this.accentColor : this.pal().surface)
          .fontColor(this.preference(protocol).mode === 'portrait' ? Color.White : this.pal().text2)
          .borderRadius(7).onClick((): void => { this.setMode(protocol, 'portrait'); })
      }.margin({ top: 7 })
    }
  }

  @Builder private protocolRow(protocol: RemotePortraitProtocol, title: string,
    detail: string, icon: Resource) {
    Row() {
      SymbolGlyph(icon).fontSize(21).fontColor([this.pal().text3]).margin({ right: 12 })
      Column() {
        Row() {
          Text(title).fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.preference(protocol).enabled })
            .selectedColor(this.accentColor).scale({ x: 0.82, y: 0.82 })
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
          Text('竖屏时会把远端横向画面按比例缩小并完整放入手机屏幕。建议同时打开“双指缩放”，方便查看细节和移动画面。')
            .fontSize(12).fontColor(this.pal().text2).fontFamily(AppTheme.fontFamily)
            .lineHeight(18).width('100%').padding(13)
            .borderRadius(12).backgroundColor(this.pal().surface).margin({ bottom: 14 })
          Column() {
            this.protocolRow('rdp', 'RDP', '远端桌面竖屏 fit 与侧栏翻转', protocolIcon('rdp'))
            this.divider()
            this.protocolRow('rustdesk', 'RustDesk', '本机窗口竖屏；不改变被控手机方向', protocolIcon('rustdesk'))
            this.divider()
            this.protocolRow('vnc', 'VNC', 'VNC 画面竖屏 fit 与侧栏翻转', protocolIcon('vnc'))
            this.divider()
            this.protocolRow('moonlight', 'Moonlight', '串流画面竖屏 fit 与侧栏翻转', protocolIcon('moonlight'))
          }.width('100%').borderRadius(14).backgroundColor(this.pal().card)
            .border({ width: 0.5, color: this.pal().cardBorder })
          Text('SSH 使用终端内的“切换横竖屏”，不会出现在这里，也不会新增本侧栏入口。')
            .fontSize(11).fontColor(this.pal().text3).fontFamily(AppTheme.fontFamily)
            .lineHeight(17).width('100%').margin({ top: 12 })
          Row() {
            Button('取消').height(40).layoutWeight(1).borderRadius(10)
              .backgroundColor(this.pal().surface).fontColor(this.pal().text2).fontSize(13)
              .onClick((): void => { this.onClose(); })
            Button('保存').height(40).layoutWeight(1).borderRadius(10)
              .backgroundColor(this.accentColor).fontColor(Color.White).fontSize(13)
              .margin({ left: 10 }).onClick((): void => { this.save(); })
          }.width('100%').margin({ top: 18, bottom: 24 })
        }.width('100%').padding({ left: 22, right: 22 })
      }.layoutWeight(1).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
    }.width('100%').height('100%').backgroundColor(this.pal().sheetBg).borderRadius(20)
  }
}
