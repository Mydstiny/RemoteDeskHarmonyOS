import { promptAction } from '@kit.ArkUI';
import { AppTheme, Palette, buildDark, buildLight } from '../common/Theme';
import { protocolIcon } from '../services/ProtocolIconPolicy';
import { RemoteWheelPreferences } from '../services/RemoteWheelPreferencePolicy';

@Component
export struct RemoteWheelDirectionSettingsSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop initialRdp: boolean = false;
  @Prop initialRustDesk: boolean = false;
  @Prop initialSsh: boolean = false;
  @Prop initialVnc: boolean = false;
  @Prop initialMoonlight: boolean = false;
  onClose: () => void = (): void => {};
  onSave: (values: RemoteWheelPreferences) => boolean =
    (_values: RemoteWheelPreferences): boolean => false;

  @State draftRdp: boolean = false;
  @State draftRustDesk: boolean = false;
  @State draftSsh: boolean = false;
  @State draftVnc: boolean = false;
  @State draftMoonlight: boolean = false;

  aboutToAppear(): void {
    this.draftRdp = this.initialRdp;
    this.draftRustDesk = this.initialRustDesk;
    this.draftSsh = this.initialSsh;
    this.draftVnc = this.initialVnc;
    this.draftMoonlight = this.initialMoonlight;
  }

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

  private setAll(reversed: boolean): void {
    this.draftRdp = reversed;
    this.draftRustDesk = reversed;
    this.draftSsh = reversed;
    this.draftVnc = reversed;
    this.draftMoonlight = reversed;
  }

  private save(): void {
    if (!this.onSave(this.draft())) {
      promptAction.showToast({ message: '滚轮方向设置保存失败，原设置未改变', duration: 2200 });
      return;
    }
    this.onClose();
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
      Text('取消').fontSize(13).fontColor(this.pal().text2)
        .fontFamily(AppTheme.fontFamily).margin({ right: 18 })
        .onClick((): void => { this.onClose(); })
      Text('保存').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.accentColor)
        .fontFamily(AppTheme.fontFamily).onClick((): void => { this.save(); })
    }.width('100%').padding({ left: 22, right: 22, top: 22, bottom: 14 })
  }

  @Builder private protocolRow(icon: Resource, title: string, detail: string,
    reversed: boolean, onChange: (value: boolean) => void) {
    Row() {
      SymbolGlyph(icon).fontSize(21).fontColor([this.pal().text3]).margin({ right: 12 })
      Column() {
        Text(title).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
        Text(detail).fontSize(11).fontColor(this.pal().text3)
          .fontFamily(AppTheme.fontFamily).lineHeight(16).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: reversed })
        .selectedColor(this.accentColor).scale({ x: 0.88, y: 0.88 })
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
          Text('反转只作用于对应协议的远程滚轮输入。切换一个协议不会改变其他协议；' +
            'SSH 不影响 SFTP 文件列表。')
            .fontSize(12).fontColor(this.pal().text2).fontFamily(AppTheme.fontFamily)
            .lineHeight(18).width('100%').padding(13)
            .borderRadius(12).backgroundColor(this.pal().surface).margin({ bottom: 14 })

          Row() {
            Button('全部正常').layoutWeight(1).height(38).borderRadius(10)
              .backgroundColor(this.pal().surface).fontColor(this.pal().text2).fontSize(12)
              .onClick((): void => { this.setAll(false); })
            Button('全部反转').layoutWeight(1).height(38).borderRadius(10)
              .backgroundColor(this.pal().surface).fontColor(this.pal().text2).fontSize(12)
              .margin({ left: 8 }).onClick((): void => { this.setAll(true); })
          }.width('100%').margin({ bottom: 16 })

          Column() {
            this.protocolRow(protocolIcon('rdp'), 'RDP',
              '实体鼠标、实体触控板和虚拟触控板', this.draftRdp,
              (value: boolean): void => { this.draftRdp = value; })
            this.divider()
            this.protocolRow(protocolIcon('rustdesk'), 'RustDesk',
              '实体鼠标、二维触控板和虚拟触控板', this.draftRustDesk,
              (value: boolean): void => { this.draftRustDesk = value; })
            this.divider()
            this.protocolRow(protocolIcon('ssh'), 'SSH 终端',
              '滚动缓冲、全屏终端应用和鼠标跟踪', this.draftSsh,
              (value: boolean): void => { this.draftSsh = value; })
            this.divider()
            this.protocolRow(protocolIcon('vnc'), 'VNC',
              '实体鼠标、实体触控板和虚拟触控板', this.draftVnc,
              (value: boolean): void => { this.draftVnc = value; })
            this.divider()
            this.protocolRow(protocolIcon('moonlight'), 'Moonlight',
              '串流中的实体滚轮和虚拟触控板', this.draftMoonlight,
              (value: boolean): void => { this.draftMoonlight = value; })
          }.width('100%').borderRadius(14).backgroundColor(this.pal().card)
            .border({ width: 0.5, color: this.pal().cardBorder })

          Row() {
            Button('恢复全部正常').height(40).layoutWeight(1).borderRadius(10)
              .backgroundColor(this.pal().surface).fontColor(this.pal().text2).fontSize(13)
              .onClick((): void => { this.setAll(false); })
            Button('保存').height(40).layoutWeight(1).borderRadius(10)
              .backgroundColor(this.accentColor).fontColor(Color.White).fontSize(13)
              .margin({ left: 10 }).onClick((): void => { this.save(); })
          }.width('100%').margin({ top: 18, bottom: 24 })
        }.width('100%').padding({ left: 22, right: 22 })
      }.layoutWeight(1).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
    }.width('100%').height('100%').backgroundColor(this.pal().bg).borderRadius(20)
  }
}
