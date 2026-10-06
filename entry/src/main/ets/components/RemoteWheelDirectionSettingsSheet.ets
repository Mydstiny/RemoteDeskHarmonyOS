import { promptAction } from '@kit.ArkUI';
import { AppSheetHeader } from './AppSheetHeader';
import { settingsVisualIsModern } from '../services/SettingsVisualStylePolicy';
import { AppTheme, Palette, buildDark, buildLight } from '../common/Theme';
import { appUiOnAccentText } from '../common/AppUiColorPolicy';
import { protocolIcon } from '../services/ProtocolIconPolicy';
import {
  REMOTE_WHEEL_SPEED_DEFAULT,
  REMOTE_WHEEL_SPEED_MIN,
  REMOTE_WHEEL_SPEED_STEP,
  RemoteWheelPreferencePresence,
  RemoteWheelPreferenceUpdate,
  RemoteWheelPreferences,
  RemoteWheelProtocol,
  RemoteWheelSpeeds,
  normalizeRemoteWheelSpeed,
  remoteWheelProtocolSummary,
  remoteWheelSpeed,
  remoteWheelSpeedLabel,
  remoteWheelSpeedMax,
  withRemoteWheelSpeed
} from '../services/RemoteWheelPreferencePolicy';
import { SettingsSavedBadge } from './SettingsSavedBadge';

const ALL_PROTOCOLS: RemoteWheelProtocol[] = ['rdp', 'rustdesk', 'ssh', 'vnc', 'moonlight'];
const SPEED_PRESETS: number[] = [50, 100, 150, 200];

function protocolTitle(protocol: RemoteWheelProtocol): string {
  if (protocol === 'rdp') { return 'RDP'; }
  if (protocol === 'rustdesk') { return 'RustDesk'; }
  if (protocol === 'ssh') { return 'SSH 终端'; }
  if (protocol === 'vnc') { return 'VNC'; }
  return 'Moonlight';
}

function protocolInputs(protocol: RemoteWheelProtocol): string {
  if (protocol === 'rustdesk') { return '实体鼠标、二维触控板和虚拟触控板'; }
  if (protocol === 'ssh') { return '滚动缓冲、全屏终端应用和鼠标跟踪'; }
  if (protocol === 'moonlight') { return '串流中的实体滚轮和虚拟触控板'; }
  return '实体鼠标、实体触控板和虚拟触控板';
}

/** What the speed means for each protocol (VNC servers differ the most). */
function speedNote(protocol: RemoteWheelProtocol): string {
  if (protocol === 'vnc') {
    return 'VNC 服务器每格滚动的距离差别很大：Windows 上嫌快就调低；macOS 自带的屏幕共享、UltraVNC 滚得少，可以调到 400%–1000%。';
  }
  if (protocol === 'ssh') {
    return '终端滚动缓冲每次滚动的行数；开启了鼠标的终端应用（如 tmux、vim）按应用自己的设置滚动，SFTP 文件列表不受影响。';
  }
  if (protocol === 'moonlight') { return '串流游戏或桌面里每格滚动的距离。'; }
  return '每格滚轮、每次双指滑动在远端滚动的距离。';
}

/**
 * 设置 › 显示与交互 › 远程滚轮: pick a protocol first, then set its wheel direction and speed. Every change saves at
 * once (and syncs with the account like the other remote settings); a failed save puts the control back.
 */
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
  @Prop initialSpeeds: RemoteWheelSpeeds = { rdp: 100, rustdesk: 100, ssh: 100, vnc: 100, moonlight: 100 };
  /** Open straight on one protocol's page ('' : the protocol list). */
  @Prop initialProtocol: string = '';
  onClose: () => void = (): void => {};
  onSave: (update: RemoteWheelPreferenceUpdate) => boolean =
    (_update: RemoteWheelPreferenceUpdate): boolean => false;
  onSaveSpeed: (protocol: RemoteWheelProtocol, speed: number) => boolean =
    (_protocol: RemoteWheelProtocol, _speed: number): boolean => false;

  @State draftRdp: boolean = false;
  @State draftRustDesk: boolean = false;
  @State draftSsh: boolean = false;
  @State draftVnc: boolean = false;
  @State draftMoonlight: boolean = false;
  /** The saved speeds (what a failed save goes back to). */
  @State speeds: RemoteWheelSpeeds = { rdp: 100, rustdesk: 100, ssh: 100, vnc: 100, moonlight: 100 };
  /** The speed under the finger while the slider moves (-1: none); it is saved when the finger lets go. */
  @State dragSpeed: number = -1;
  /** The protocol whose page is open ('' : the list). */
  @State selected: string = '';
  @State savedTick: number = 0;

  aboutToAppear(): void {
    this.draftRdp = this.initialRdp;
    this.draftRustDesk = this.initialRustDesk;
    this.draftSsh = this.initialSsh;
    this.draftVnc = this.initialVnc;
    this.draftMoonlight = this.initialMoonlight;
    this.speeds = {
      rdp: normalizeRemoteWheelSpeed(this.initialSpeeds.rdp, 'rdp'),
      rustdesk: normalizeRemoteWheelSpeed(this.initialSpeeds.rustdesk, 'rustdesk'),
      ssh: normalizeRemoteWheelSpeed(this.initialSpeeds.ssh, 'ssh'),
      vnc: normalizeRemoteWheelSpeed(this.initialSpeeds.vnc, 'vnc'),
      moonlight: normalizeRemoteWheelSpeed(this.initialSpeeds.moonlight, 'moonlight')
    };
    if (ALL_PROTOCOLS.indexOf(this.initialProtocol as RemoteWheelProtocol) >= 0) { this.selected = this.initialProtocol; }
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

  private speed(protocol: RemoteWheelProtocol): number { return remoteWheelSpeed(this.speeds, protocol); }

  /** What the page shows: the slider's value while it moves, else the saved speed. */
  private shownSpeed(protocol: RemoteWheelProtocol): number {
    return this.dragSpeed >= 0 ? this.dragSpeed : this.speed(protocol);
  }

  /** Every direction change saves at once; if saving fails the switches go back to the saved values. */
  private commit(protocols: RemoteWheelProtocol[], reversed: boolean): boolean {
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
      return false;
    }
    this.savedTick++;
    return true;
  }

  /** A speed saves at once too; a failed save leaves the previous speed shown. */
  private commitSpeed(protocol: RemoteWheelProtocol, value: number): boolean {
    // Compared with the saved speed, never with the slider's live value (that is only shown while dragging).
    const next: number = normalizeRemoteWheelSpeed(value, protocol);
    if (next === this.speed(protocol)) { return true; }
    const previous: RemoteWheelSpeeds = this.speeds;
    this.speeds = withRemoteWheelSpeed(this.speeds, protocol, next);
    if (!this.onSaveSpeed(protocol, next)) {
      this.speeds = previous;
      promptAction.showToast({ message: '滚轮速度没有保存，请重试', duration: 2200 });
      return false;
    }
    this.savedTick++;
    return true;
  }

  private resetProtocol(protocol: RemoteWheelProtocol): void {
    const directionOk: boolean = !this.value(protocol) || this.commit([protocol], false);
    if (directionOk) { this.commitSpeed(protocol, REMOTE_WHEEL_SPEED_DEFAULT); }
  }

  private open(protocol: string): void {
    this.dragSpeed = -1;
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => { this.selected = protocol; });
  }

  private title(): string {
    return this.selected === '' ? '远程滚轮' : protocolTitle(this.selected as RemoteWheelProtocol) + ' 滚轮';
  }

  private subtitle(): string {
    return this.selected === '' ? '先选择协议，再调整滚轮方向和速度，改动会立即保存' : '方向和速度只作用于这个协议，改动会立即保存';
  }

  @Builder private header() {
    Row() {
      Column() {
        Text(this.title()).fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
        Text(this.selected === '' ? '先选择协议，再调整方向和速度' : '方向和速度只作用于这个协议')
          .fontSize(11).fontColor(this.pal().text3).fontFamily(AppTheme.fontFamily)
          .margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      SettingsSavedBadge({ savedTick: this.savedTick }).margin({ right: 6 })
      SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2])
        .width(36).height(36).accessibilityText('关闭')
        .onClick((): void => { this.onClose(); })
    }.width('100%').padding({ left: 22, right: 16, top: 18, bottom: 12 })
  }

  @Builder private protocolRow(protocol: RemoteWheelProtocol) {
    Row() {
      SymbolGlyph(protocolIcon(protocol)).fontSize(this.modern() ? 22 : 21)
        .fontColor([this.modern() ? this.pal().text2 : this.pal().text3]).margin({ right: 12 })
      Column() {
        Text(protocolTitle(protocol)).fontSize(this.modern() ? 15 : 14).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
        Text(remoteWheelProtocolSummary(this.value(protocol), this.speed(protocol)))
          .fontSize(this.modern() ? 12 : 11).fontColor(this.modern() ? this.pal().text2 : this.pal().text3)
          .fontFamily(AppTheme.fontFamily).lineHeight(16).margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([this.pal().text3])
    }.width('100%').constraintSize({ minHeight: this.modern() ? 60 : 52 })
      .padding({ left: 15, right: 14, top: 11, bottom: 11 })
      .accessibilityText(protocolTitle(protocol) + '，' + remoteWheelProtocolSummary(this.value(protocol), this.speed(protocol)) +
        '，点按调整')
      .onClick((): void => { this.open(protocol); })
  }

  @Builder private divider() {
    Divider().strokeWidth(0.5).color(this.pal().divider).margin({ left: 15, right: 15 })
  }

  @Builder private listPage() {
    Column() {
      Text('每个协议的滚轮方向和速度分开设置，切换一个协议不会改变其他协议。速度 100% 是该协议调好的默认值。')
        .fontSize(12).fontColor(this.pal().text2).fontFamily(AppTheme.fontFamily)
        .lineHeight(18).width('100%').padding(13)
        .borderRadius(12).backgroundColor(this.pal().surface).margin({ bottom: 14 })
      Column() {
        this.protocolRow('rdp')
        this.divider()
        this.protocolRow('rustdesk')
        this.divider()
        this.protocolRow('ssh')
        this.divider()
        this.protocolRow('vnc')
        this.divider()
        this.protocolRow('moonlight')
      }.width('100%').borderRadius(14).backgroundColor(this.pal().card)
        .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 16 })
      Row() {
        Button('方向全部正常').layoutWeight(1).height(this.modern() ? 44 : 38).borderRadius(10)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2).fontSize(this.modern() ? 13 : 12)
          .onClick((): void => { this.commit(ALL_PROTOCOLS, false); })
        Button('方向全部反转').layoutWeight(1).height(this.modern() ? 44 : 38).borderRadius(10)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2).fontSize(this.modern() ? 13 : 12)
          .margin({ left: 8 }).onClick((): void => { this.commit(ALL_PROTOCOLS, true); })
      }.width('100%').margin({ bottom: 24 })
    }.width('100%')
  }

  @Builder private detailPage(protocol: RemoteWheelProtocol) {
    Column() {
      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(16).fontColor([this.pal().text2])
        Text('全部协议').fontSize(14).fontColor(this.pal().text2).fontFamily(AppTheme.fontFamily)
      }.height(44).padding({ right: 12 }).margin({ bottom: 6 })
      .accessibilityText('返回全部协议')
      .onClick((): void => { this.open(''); })

      Column() {
        Row() {
          Column() {
            Text('反转滚轮方向').fontSize(this.modern() ? 15 : 14).fontWeight(FontWeight.Medium)
              .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily)
            Text(protocolInputs(protocol)).fontSize(this.modern() ? 12 : 11)
              .fontColor(this.modern() ? this.pal().text2 : this.pal().text3).fontFamily(AppTheme.fontFamily)
              .lineHeight(16).margin({ top: 3 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.value(protocol) })
            .selectedColor(this.accentColor).scale({ x: this.modern() ? 1 : 0.88, y: this.modern() ? 1 : 0.88 })
            .accessibilityText('反转 ' + protocolTitle(protocol) + ' 滚轮方向')
            .onChange((reversed: boolean): void => { this.commit([protocol], reversed); })
        }.width('100%').constraintSize({ minHeight: this.modern() ? 56 : 0 })
        .padding({ left: 15, right: 12, top: 11, bottom: 11 })
      }.width('100%').borderRadius(14).backgroundColor(this.pal().card)
        .border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 14 })

      Column({ space: 10 }) {
        Row() {
          Text('滚轮速度').fontSize(this.modern() ? 15 : 14).fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text).fontFamily(AppTheme.fontFamily).layoutWeight(1)
          Text(remoteWheelSpeedLabel(this.shownSpeed(protocol))).fontSize(this.modern() ? 15 : 14)
            .fontWeight(FontWeight.Medium).fontColor(this.accentColor).fontFamily(AppTheme.fontFamily)
        }.width('100%')
        Slider({ value: this.shownSpeed(protocol), min: REMOTE_WHEEL_SPEED_MIN, max: remoteWheelSpeedMax(protocol),
          step: REMOTE_WHEEL_SPEED_STEP, style: SliderStyle.OutSet })
          .width('100%').selectedColor(this.accentColor).showSteps(false)
          .accessibilityText(protocolTitle(protocol) + ' 滚轮速度')
          .onChange((value: number, mode: SliderChangeMode): void => {
            // Shown as it moves; saved once the finger lets go (or a tap on the track).
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.dragSpeed = -1;
              this.commitSpeed(protocol, value);
            } else {
              this.dragSpeed = normalizeRemoteWheelSpeed(value, protocol);
            }
          })
        Row() {
          Text('25%').fontSize(11).fontColor(this.pal().text3).layoutWeight(1)
          Text(remoteWheelSpeedMax(protocol).toString() + '%').fontSize(11).fontColor(this.pal().text3)
        }.width('100%').margin({ top: -6 })
        Row({ space: 8 }) {
          ForEach(SPEED_PRESETS, (preset: number): void => {
            Text(preset === 50 ? '慢 50%' : preset === 100 ? '默认' : preset === 150 ? '快 150%' : '很快 200%')
              .fontSize(13).layoutWeight(1).height(this.modern() ? 40 : 34).textAlign(TextAlign.Center)
              .borderRadius(10)
              .fontColor(this.speed(protocol) === preset ? appUiOnAccentText(this.accentColor) : this.pal().text)
              .backgroundColor(this.speed(protocol) === preset ? this.accentColor : this.pal().surface)
              .accessibilityText('滚轮速度 ' + preset.toString() + '%' + (this.speed(protocol) === preset ? '，已选中' : ''))
              .onClick((): void => { this.commitSpeed(protocol, preset); })
          }, (preset: number): string => protocol + '-' + preset.toString() + '-' +
            (this.speed(protocol) === preset ? 'on' : 'off'))
        }.width('100%')
        Text(speedNote(protocol)).fontSize(12).lineHeight(18).fontColor(this.pal().text2)
          .fontFamily(AppTheme.fontFamily).width('100%')
      }.width('100%').padding({ left: 15, right: 15, top: 14, bottom: 14 }).borderRadius(14)
        .backgroundColor(this.pal().card).border({ width: 0.5, color: this.pal().cardBorder }).margin({ bottom: 14 })

      Button('恢复默认（方向正常、速度 100%）').width('100%').height(this.modern() ? 44 : 38).borderRadius(10)
        .backgroundColor(this.pal().surface).fontColor(this.pal().text2).fontSize(this.modern() ? 13 : 12)
        .margin({ bottom: 24 })
        .onClick((): void => { this.resetProtocol(protocol); })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      if (this.modern()) {
        AppSheetHeader({ title: this.title(), subtitle: this.subtitle(), savedTick: this.savedTick, whiteOnAccent: true,
          onClose: (): void => { this.onClose(); } })
      } else {
        this.header()
      }
      Scroll() {
        Column() {
          if (this.selected === '') {
            this.listPage()
          } else {
            this.detailPage(this.selected as RemoteWheelProtocol)
          }
        }.width('100%').padding({ left: 22, right: 22 })
      }.layoutWeight(1).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring).align(Alignment.Top)
    }.width('100%').height('100%').backgroundColor(this.pal().sheetBg).borderRadius(20)
  }
}
