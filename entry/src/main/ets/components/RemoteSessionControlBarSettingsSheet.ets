import { promptAction } from '@kit.ArkUI';
import { AppTheme, Palette, buildDark, buildLight } from '../common/Theme';
import { protocolIcon } from '../services/ProtocolIconPolicy';
import {
  protectRemoteSessionControlBarVisibility,
  RemoteSessionControlBarPreferenceUpdate,
  RemoteSessionControlBarVisibility
} from '../services/RemoteSessionTopBarPolicy';

@Component
export struct RemoteSessionControlBarSettingsSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
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
  private touchedRdp: boolean = false;
  private touchedRustDesk: boolean = false;
  private touchedVnc: boolean = false;
  private touchedMoonlight: boolean = false;

  aboutToAppear(): void {
    const initial: RemoteSessionControlBarVisibility =
      protectRemoteSessionControlBarVisibility({
        rdpHidden: this.initialRdpHidden,
        rustDeskHidden: this.initialRustDeskHidden,
        vncHidden: this.initialVncHidden,
        moonlightHidden: this.initialMoonlightHidden
      }, this.quickExitDisabled);
    this.draftRdpHidden = initial.rdpHidden;
    this.draftRustDeskHidden = initial.rustDeskHidden;
    this.draftVncHidden = initial.vncHidden;
    this.draftMoonlightHidden = initial.moonlightHidden;
    this.touchedRdp = false;
    this.touchedRustDesk = false;
    this.touchedVnc = false;
    this.touchedMoonlight = false;
  }

  private onQuickExitDisabledChange(): void {
    if (!this.quickExitDisabled) { return; }
    this.setAll(false);
  }

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

  private setAll(hidden: boolean): void {
    if (hidden && this.quickExitDisabled) { return; }
    this.draftRdpHidden = hidden;
    this.draftRustDeskHidden = hidden;
    this.draftVncHidden = hidden;
    this.draftMoonlightHidden = hidden;
    this.touchedRdp = true;
    this.touchedRustDesk = true;
    this.touchedVnc = true;
    this.touchedMoonlight = true;
  }

  private save(): void {
    const update: RemoteSessionControlBarPreferenceUpdate = {
      values: this.draft(),
      touched: {
        rdpHidden: this.touchedRdp,
        rustDeskHidden: this.touchedRustDesk,
        vncHidden: this.touchedVnc,
        moonlightHidden: this.touchedMoonlight
      }
    };
    if (!this.onSave(update)) {
      promptAction.showToast({ message: '会话控制栏设置保存失败，请重试', duration: 2200 });
      return;
    }
    this.onClose();
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
      Text('取消').fontSize(13).fontColor(this.pal().text2)
        .fontFamily(AppTheme.fontFamily).margin({ right: 18 })
        .onClick((): void => { this.onClose(); })
      Text('保存').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.accentColor)
        .fontFamily(AppTheme.fontFamily).onClick((): void => { this.save(); })
    }.width('100%').padding({ left: 22, right: 22, top: 22, bottom: 14 })
  }

  @Builder private protocolRow(icon: Resource, title: string, hidden: boolean,
    onChange: (value: boolean) => void) {
    Row() {
      SymbolGlyph(icon).fontSize(21).fontColor([this.pal().text3]).margin({ right: 12 })
      Column() {
        Text(title).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
        Text(this.quickExitDisabled ? '关闭快捷退出时必须显示' :
          (hidden ? '侧栏和顶栏均已隐藏' : '显示会话侧栏与顶栏'))
          .fontSize(11).fontColor(this.pal().text3)
          .fontFamily(AppTheme.fontFamily).lineHeight(16).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: hidden })
        .selectedColor(this.accentColor).scale({ x: 0.88, y: 0.88 })
        .enabled(!this.quickExitDisabled).opacity(this.quickExitDisabled ? 0.45 : 1)
        .accessibilityText((hidden ? '显示 ' : '隐藏 ') + title + ' 会话控制栏')
        .onChange(onChange)
    }.width('100%').padding({ left: 15, right: 12, top: 11, bottom: 11 })
  }

  @Builder private divider() {
    Divider().strokeWidth(0.5).color(this.pal().divider).margin({ left: 15, right: 15 })
  }

  build() {
    Column() {
      this.header()
      Scroll() {
        Column() {
          Text(this.quickExitDisabled ?
            '“关闭快捷退出”已开启。为确保始终存在退出按钮，所有协议的会话控制栏必须显示。' :
            '开关开启表示隐藏对应协议的手机/平板侧栏和 PC 顶栏；' +
              '隐藏后可返回“显示与交互”设置恢复，不影响远程输入。')
            .fontSize(12).fontColor(this.pal().text2).fontFamily(AppTheme.fontFamily)
            .lineHeight(18).width('100%').padding(13)
            .borderRadius(12).backgroundColor(this.pal().surface).margin({ bottom: 14 })

          Row() {
            Button('全部显示').layoutWeight(1).height(38).borderRadius(10)
              .backgroundColor(this.pal().surface).fontColor(this.pal().text2).fontSize(12)
              .onClick((): void => { this.setAll(false); })
            Button('全部隐藏').layoutWeight(1).height(38).borderRadius(10)
              .backgroundColor(this.pal().surface).fontColor(this.pal().text2).fontSize(12)
              .margin({ left: 8 }).onClick((): void => { this.setAll(true); })
              .enabled(!this.quickExitDisabled).opacity(this.quickExitDisabled ? 0.45 : 1)
          }.width('100%').margin({ bottom: 16 })

          Column() {
            this.protocolRow(protocolIcon('rdp'), 'RDP', this.draftRdpHidden,
              (value: boolean): void => {
                this.draftRdpHidden = value; this.touchedRdp = true;
              })
            this.divider()
            this.protocolRow(protocolIcon('rustdesk'), 'RustDesk', this.draftRustDeskHidden,
              (value: boolean): void => {
                this.draftRustDeskHidden = value; this.touchedRustDesk = true;
              })
            this.divider()
            this.protocolRow(protocolIcon('vnc'), 'VNC', this.draftVncHidden,
              (value: boolean): void => {
                this.draftVncHidden = value; this.touchedVnc = true;
              })
            this.divider()
            this.protocolRow(protocolIcon('moonlight'), 'Moonlight', this.draftMoonlightHidden,
              (value: boolean): void => {
                this.draftMoonlightHidden = value; this.touchedMoonlight = true;
              })
          }.width('100%').borderRadius(14).backgroundColor(this.pal().card)
            .border({ width: 0.5, color: this.pal().cardBorder })

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
