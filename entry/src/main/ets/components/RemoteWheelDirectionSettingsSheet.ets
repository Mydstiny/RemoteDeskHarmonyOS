import { promptAction } from '@kit.ArkUI';
import { AppSheetHeader } from './AppSheetHeader';
import { settingsVisualIsModern } from '../services/SettingsVisualStylePolicy';
import { AppTheme, Palette, buildDark, buildLight } from '../common/Theme';
import { protocolIcon } from '../services/ProtocolIconPolicy';
import {
  RemoteWheelPreferencePresence,
  RemoteWheelPreferenceUpdate,
  RemoteWheelPreferences,
  RemoteWheelProtocol
} from '../services/RemoteWheelPreferencePolicy';
import { SettingsSavedBadge } from './SettingsSavedBadge';

const ALL_PROTOCOLS: RemoteWheelProtocol[] = ['rdp', 'rustdesk', 'ssh', 'vnc', 'moonlight'];

@Component
export struct RemoteWheelDirectionSettingsSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  /** 设置 → 个性化 → 全新视觉: the shared sheet header, larger rows and full-size switches. */
  @StorageProp('settingsVisualStyle') visualStyle: string = 'classic';
  @Prop initialRdp: boolean = false;
  @Prop initialRustDesk: boolean = false;
  @Prop initialSsh: boolean = false;
  @Prop initialVnc: boolean = false;
  @Prop initialMoonlight: boolean = false;
  onClose: () => void = (): void => {};
  onSave: (update: RemoteWheelPreferenceUpdate) => boolean =
    (_update: RemoteWheelPreferenceUpdate): boolean => false;

  @State draftRdp: boolean = false;
  @State draftRustDesk: boolean = false;
  @State draftSsh: boolean = false;
  @State draftVnc: boolean = false;
  @State draftMoonlight: boolean = false;
  @State savedTick: number = 0;

  aboutToAppear(): void {
    this.draftRdp = this.initialRdp;
    this.draftRustDesk = this.initialRustDesk;
    this.draftSsh = this.initialSsh;
    this.draftVnc = this.initialVnc;
    this.draftMoonlight = this.initialMoonlight;
  }

  private modern(): boolean { return settingsVisualIsModern(this.visualStyle); }

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private draft(): RemoteWheelPreferences {
    return {
      rdp: this.draftRdp,
      rustdesk: this.draftRustDesk,
      ssh: this.draftSsh,
      vnc: this.draftVnc,
      moonlight: this.draftMoonlight
    };
  }

  private value(protocol: RemoteWheelProtocol): boolean {
    if (protocol === 'rdp') { return this.draftRdp; }
    if (protocol === 'rustdesk') { return this.draftRustDesk; }
    if (protocol === 'ssh') { return this.draftSsh; }
    if (protocol === 'vnc') { return this.draftVnc; }
    return this.draftMoonlight;
  }

  private setValue(protocol: RemoteWheelProtocol, reversed: boolean): void {
    if (protocol === 'rdp') { this.draftRdp = reversed; }
    else if (protocol === 'rustdesk') { this.draftRustDesk = reversed; }
    else if (protocol === 'ssh') { this.draftSsh = reversed; }
    else if (protocol === 'vnc') { this.draftVnc = reversed; }
    else { this.draftMoonlight = reversed; }
  }

  private restore(values: RemoteWheelPreferences): void {
    this.draftRdp = values.rdp;
    this.draftRustDesk = values.rustdesk;
    this.draftSsh = values.ssh;
    this.draftVnc = values.vnc;
    this.draftMoonlight = values.moonlight;
  }

  /** Every change saves at once; if saving fails the switches go back to the saved values. */
  private commit(protocols: RemoteWheelProtocol[], reversed: boolean): void {
    const previous: RemoteWheelPreferences = this.draft();
    for (let i = 0; i < protocols.length; i++) { this.setValue(protocols[i], reversed); }
    const touched: RemoteWheelPreferencePresence = {
      rdp: protocols.indexOf('rdp') >= 0,
      rustdesk: protocols.indexOf('rustdesk') >= 0,
      ssh: protocols.indexOf('ssh') >= 0,
      vnc: protocols.indexOf('vnc') >= 0,
      moonlight: protocols.indexOf('moonlight') >= 0
    };
    if (!this.onSave({ values: this.draft(), touched: touched })) {
      this.restore(previous);
      promptAction.showToast({ message: '滚轮方向没有保存，请重试', duration: 2200 });
      return;
    }
    this.savedTick++;
  }

  @Builder private header() {
    Row() {
      Column() {
        Text('滚轮方向').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
        Text('选择需要反转滚轮方向的远程协议')
          .fontSize(11).fontColor(this.pal().text3).fontFamily(AppTheme.fontFamily)
          .margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      SettingsSavedBadge({ savedTick: this.savedTick }).margin({ right: 6 })
      SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
        .width(36).height(36).accessibilityText('关闭')
        .onClick((): void => { this.onClose(); })
    }.width('100%').padding({ left: 22, right: 16, top: 18, bottom: 12 })
  }

  @Builder private protocolRow(protocol: RemoteWheelProtocol, title: string, detail: string) {
    Row() {
      SymbolGlyph(protocolIcon(protocol)).fontSize(this.modern() ? 22 : 21)
        .fontColor([this.modern() ? this.pal().text2 : this.pal().text3]).margin({ right: 12 })
      Column() {
        Text(title).fontSize(this.modern() ? 15 : 14).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
        Text(detail).fontSize(this.modern() ? 12 : 11).fontColor(this.modern() ? this.pal().text2 : this.pal().text3)
          .fontFamily(AppTheme.fontFamily).lineHeight(16).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.value(protocol) })
        .selectedColor(this.accentColor).scale({ x: this.modern() ? 1 : 0.88, y: this.modern() ? 1 : 0.88 })
        .accessibilityText('反转 ' + title + ' 滚轮方向')
        .onChange((reversed: boolean): void => { this.commit([protocol], reversed); })
    }.width('100%').constraintSize({ minHeight: this.modern() ? 56 : 0 })
      .padding({ left: 15, right: 12, top: 11, bottom: 11 })
  }

  @Builder private divider() {
    Divider().strokeWidth(0.5).color(this.pal().divider).margin({ left: 15, right: 15 })
  }

  build() {
    Column() {
      if (this.modern()) {
        AppSheetHeader({ title: '滚轮方向', subtitle: '选择需要反转滚轮方向的远程协议，改动会立即保存', savedTick: this.savedTick, whiteOnAccent: true,
          onClose: (): void => { this.onClose(); } })
      } else {
        this.header()
      }
      Scroll() {
        Column() {
          Text('反转只作用于对应协议的远程滚轮输入。切换一个协议不会改变其他协议；' +
            'SSH 不影响 SFTP 文件列表。改动会立即保存。')
            .fontSize(12).fontColor(this.pal().text2).fontFamily(AppTheme.fontFamily)
            .lineHeight(18).width('100%').padding(13)
            .borderRadius(12).backgroundColor(this.pal().surface).margin({ bottom: 14 })

          Row() {
            Button('全部正常').layoutWeight(1).height(this.modern() ? 44 : 38).borderRadius(10)
              .backgroundColor(this.pal().surface).fontColor(this.pal().text2).fontSize(this.modern() ? 13 : 12)
              .onClick((): void => { this.commit(ALL_PROTOCOLS, false); })
            Button('全部反转').layoutWeight(1).height(this.modern() ? 44 : 38).borderRadius(10)
              .backgroundColor(this.pal().surface).fontColor(this.pal().text2).fontSize(this.modern() ? 13 : 12)
              .margin({ left: 8 }).onClick((): void => { this.commit(ALL_PROTOCOLS, true); })
          }.width('100%').margin({ bottom: 16 })

          Column() {
            this.protocolRow('rdp', 'RDP', '实体鼠标、实体触控板和虚拟触控板')
            this.divider()
            this.protocolRow('rustdesk', 'RustDesk', '实体鼠标、二维触控板和虚拟触控板')
            this.divider()
            this.protocolRow('ssh', 'SSH 终端', '滚动缓冲、全屏终端应用和鼠标跟踪')
            this.divider()
            this.protocolRow('vnc', 'VNC', '实体鼠标、实体触控板和虚拟触控板')
            this.divider()
            this.protocolRow('moonlight', 'Moonlight', '串流中的实体滚轮和虚拟触控板')
          }.width('100%').borderRadius(14).backgroundColor(this.pal().card)
            .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 24 })
        }.width('100%').padding({ left: 22, right: 22 })
      }.layoutWeight(1).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
    }.width('100%').height('100%').backgroundColor(this.pal().sheetBg).borderRadius(20)
  }
}
