import { promptAction } from '@kit.ArkUI';
import { AppSheetHeader } from './AppSheetHeader';
import { settingsVisualIsModern } from '../services/SettingsVisualStylePolicy';
import { AppTheme, Palette, buildDark, buildLight } from '../common/Theme';
import { protocolIcon } from '../services/ProtocolIconPolicy';
import {
  protectRemoteSessionControlBarVisibility,
  RemoteSessionControlBarPreferenceUpdate,
  RemoteSessionControlBarVisibility
} from '../services/RemoteSessionTopBarPolicy';
import { SettingsSavedBadge } from './SettingsSavedBadge';

type ControlBarProtocol = 'rdp' | 'rustdesk' | 'vnc' | 'moonlight';
const ALL_PROTOCOLS: ControlBarProtocol[] = ['rdp', 'rustdesk', 'vnc', 'moonlight'];

@Component
export struct RemoteSessionControlBarSettingsSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  /** 设置 → 个性化 → 全新视觉: the shared sheet header, larger rows and full-size switches. */
  @StorageProp('settingsVisualStyle') visualStyle: string = 'classic';
  @Prop initialRdpHidden: boolean = false;
  @Prop initialRustDeskHidden: boolean = false;
  @Prop initialVncHidden: boolean = false;
  @Prop initialMoonlightHidden: boolean = false;
  @Prop @Watch('onQuickExitDisabledChange') quickExitDisabled: boolean = false;
  onClose: () => void = (): void => {};
  onSave: (update: RemoteSessionControlBarPreferenceUpdate) => boolean =
    (_update: RemoteSessionControlBarPreferenceUpdate): boolean => false;

  @State draftRdpHidden: boolean = false;
  @State draftRustDeskHidden: boolean = false;
  @State draftVncHidden: boolean = false;
  @State draftMoonlightHidden: boolean = false;
  @State savedTick: number = 0;

  aboutToAppear(): void {
    this.restore(protectRemoteSessionControlBarVisibility({
      rdpHidden: this.initialRdpHidden,
      rustDeskHidden: this.initialRustDeskHidden,
      vncHidden: this.initialVncHidden,
      moonlightHidden: this.initialMoonlightHidden
    }, this.quickExitDisabled));
  }

  /** 关闭快捷退出 already saved every bar as shown; mirror that here without saving again. */
  private onQuickExitDisabledChange(): void {
    if (!this.quickExitDisabled) { return; }
    this.restore({ rdpHidden: false, rustDeskHidden: false, vncHidden: false, moonlightHidden: false });
  }

  private modern(): boolean { return settingsVisualIsModern(this.visualStyle); }

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
  }

  private draft(): RemoteSessionControlBarVisibility {
    return protectRemoteSessionControlBarVisibility({
      rdpHidden: this.draftRdpHidden,
      rustDeskHidden: this.draftRustDeskHidden,
      vncHidden: this.draftVncHidden,
      moonlightHidden: this.draftMoonlightHidden
    }, this.quickExitDisabled);
  }

  private restore(values: RemoteSessionControlBarVisibility): void {
    this.draftRdpHidden = values.rdpHidden;
    this.draftRustDeskHidden = values.rustDeskHidden;
    this.draftVncHidden = values.vncHidden;
    this.draftMoonlightHidden = values.moonlightHidden;
  }

  private hidden(protocol: ControlBarProtocol): boolean {
    if (protocol === 'rdp') { return this.draftRdpHidden; }
    if (protocol === 'rustdesk') { return this.draftRustDeskHidden; }
    if (protocol === 'vnc') { return this.draftVncHidden; }
    return this.draftMoonlightHidden;
  }

  private setHidden(protocol: ControlBarProtocol, hidden: boolean): void {
    if (protocol === 'rdp') { this.draftRdpHidden = hidden; }
    else if (protocol === 'rustdesk') { this.draftRustDeskHidden = hidden; }
    else if (protocol === 'vnc') { this.draftVncHidden = hidden; }
    else { this.draftMoonlightHidden = hidden; }
  }

  /** Every change saves at once; if saving fails the switches go back to the saved values. */
  private commit(protocols: ControlBarProtocol[], shown: boolean): void {
    if (!shown && this.quickExitDisabled) { return; }
    const previous: RemoteSessionControlBarVisibility = this.draft();
    for (let i = 0; i < protocols.length; i++) { this.setHidden(protocols[i], !shown); }
    const update: RemoteSessionControlBarPreferenceUpdate = {
      values: this.draft(),
      touched: {
        rdpHidden: protocols.indexOf('rdp') >= 0,
        rustDeskHidden: protocols.indexOf('rustdesk') >= 0,
        vncHidden: protocols.indexOf('vnc') >= 0,
        moonlightHidden: protocols.indexOf('moonlight') >= 0
      }
    };
    if (!this.onSave(update)) {
      this.restore(previous);
      promptAction.showToast({ message: '会话控制栏设置没有保存，请重试', duration: 2200 });
      return;
    }
    this.savedTick++;
  }

  @Builder private header() {
    Row() {
      Column() {
        Text('会话侧栏与顶栏').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
        Text('按协议选择是否显示会话控制栏')
          .fontSize(11).fontColor(this.pal().text3).fontFamily(AppTheme.fontFamily)
          .margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      SettingsSavedBadge({ savedTick: this.savedTick }).margin({ right: 6 })
      SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
        .width(36).height(36).accessibilityText('关闭')
        .onClick((): void => { this.onClose(); })
    }.width('100%').padding({ left: 22, right: 16, top: 18, bottom: 12 })
  }

  @Builder private protocolRow(protocol: ControlBarProtocol, title: string) {
    Row() {
      SymbolGlyph(protocolIcon(protocol)).fontSize(this.modern() ? 22 : 21)
        .fontColor([this.modern() ? this.pal().text2 : this.pal().text3]).margin({ right: 12 })
      Column() {
        Text(title).fontSize(this.modern() ? 15 : 14).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
        Text(this.quickExitDisabled ? '关闭快捷退出时必须显示' :
          (this.hidden(protocol) ? '侧栏和顶栏均已隐藏' : '显示会话侧栏与顶栏'))
          .fontSize(this.modern() ? 12 : 11).fontColor(this.modern() ? this.pal().text2 : this.pal().text3)
          .fontFamily(AppTheme.fontFamily).lineHeight(16).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      // On = shown. The stored preference still records "hidden".
      Toggle({ type: ToggleType.Switch, isOn: !this.hidden(protocol) })
        .selectedColor(this.accentColor).scale({ x: this.modern() ? 1 : 0.88, y: this.modern() ? 1 : 0.88 })
        .enabled(!this.quickExitDisabled).opacity(this.quickExitDisabled ? 0.45 : 1)
        .accessibilityText('显示 ' + title + ' 会话控制栏')
        .onChange((shown: boolean): void => { this.commit([protocol], shown); })
    }.width('100%').constraintSize({ minHeight: this.modern() ? 56 : 0 })
      .padding({ left: 15, right: 12, top: 11, bottom: 11 })
  }

  @Builder private divider() {
    Divider().strokeWidth(0.5).color(this.pal().divider).margin({ left: 15, right: 15 })
  }

  build() {
    Column() {
      if (this.modern()) {
        AppSheetHeader({ title: '会话侧栏与顶栏', subtitle: '按协议选择是否显示会话控制栏，改动会立即保存', savedTick: this.savedTick, whiteOnAccent: true,
          onClose: (): void => { this.onClose(); } })
      } else {
        this.header()
      }
      Scroll() {
        Column() {
          Text(this.quickExitDisabled ?
            '“关闭快捷退出”已开启。为确保始终存在退出按钮，所有协议的会话控制栏必须显示。' :
            '开关打开表示显示对应协议的手机/平板侧栏和 PC 顶栏；关闭后隐藏，' +
              '可回到“显示与交互”设置重新打开，不影响远程输入。改动会立即保存。')
            .fontSize(12).fontColor(this.pal().text2).fontFamily(AppTheme.fontFamily)
            .lineHeight(18).width('100%').padding(13)
            .borderRadius(12).backgroundColor(this.pal().surface).margin({ bottom: 14 })

          Row() {
            Button('全部显示').layoutWeight(1).height(this.modern() ? 44 : 38).borderRadius(10)
              .backgroundColor(this.pal().surface).fontColor(this.pal().text2).fontSize(this.modern() ? 13 : 12)
              .onClick((): void => { this.commit(ALL_PROTOCOLS, true); })
            Button('全部隐藏').layoutWeight(1).height(this.modern() ? 44 : 38).borderRadius(10)
              .backgroundColor(this.pal().surface).fontColor(this.pal().text2).fontSize(this.modern() ? 13 : 12)
              .margin({ left: 8 }).onClick((): void => { this.commit(ALL_PROTOCOLS, false); })
              .enabled(!this.quickExitDisabled).opacity(this.quickExitDisabled ? 0.45 : 1)
          }.width('100%').margin({ bottom: 16 })

          Column() {
            this.protocolRow('rdp', 'RDP')
            this.divider()
            this.protocolRow('rustdesk', 'RustDesk')
            this.divider()
            this.protocolRow('vnc', 'VNC')
            this.divider()
            this.protocolRow('moonlight', 'Moonlight')
          }.width('100%').borderRadius(14).backgroundColor(this.pal().card)
            .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 24 })
        }.width('100%').padding({ left: 22, right: 22 })
      }.layoutWeight(1).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
    }.width('100%').height('100%').backgroundColor(this.pal().sheetBg).borderRadius(20)
  }
}
