import { curves } from '@kit.ArkUI';
import { Palette, buildDark, buildLight } from '../../common/Theme';
import { appUiOnAccentText, appUiTint } from '../../common/AppUiColorPolicy';

/**
 * The file transfer surfaces' shared pieces: one look for status, progress, notices, actions and the remote browser
 * rows, in the app's glass cards, accent and spring motion. Everything reads the theme and accent itself.
 */

export type TransferTone = 'busy' | 'done' | 'error';

/** A status line's tone: still working, finished, or stopped short (progress −1 marks a failure). */
export function transferTone(busy: boolean, progress: number): TransferTone {
  return busy ? 'busy' : progress < 0 ? 'error' : 'done';
}

/** A status sentence split at its first pause: the headline, then the detail (both may be the whole sentence). */
export function transferStatusParts(status: string): string[] {
  const match: RegExpMatchArray | null = status.match(/^(.{2,24}?)[，；：:](.+)$/);
  return match !== null ? [match[1], match[2]] : [status, ''];
}

/** Rises in from below; leaves at once (a disappearing block keeps its layout space and would shove the rest). */
export function transferRise(): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 14 }))
      .combine(TransitionEffect.scale({ x: 0.97, y: 0.97 })).animation({ curve: curves.springMotion(0.42, 0.84) }),
    TransitionEffect.OPACITY.animation({ duration: 120, curve: Curve.EaseIn }));
}

/** A floating card over the session: rises from below, sinks away. */
export function transferFloatRise(): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 24 }))
      .combine(TransitionEffect.scale({ x: 0.94, y: 0.94 })).animation({ curve: curves.springMotion(0.46, 0.8) }),
    TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 16 }))
      .animation({ duration: 200, curve: Curve.EaseIn }));
}

/** A floating card at the top of the session: drops in, lifts away. */
export function transferFloatDrop(): TransitionEffect {
  return TransitionEffect.asymmetric(
    TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -28 }))
      .combine(TransitionEffect.scale({ x: 0.94, y: 0.94 })).animation({ curve: curves.springMotion(0.46, 0.8) }),
    TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -16 }))
      .animation({ duration: 200, curve: Curve.EaseIn }));
}

function popIn(): TransitionEffect {
  return TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.4, y: 0.4 }))
    .animation({ curve: curves.springMotion(0.36, 0.62) });
}

function palette(theme: string, accent: string): Palette {
  return theme === 'light' ? buildLight(accent) : buildDark(accent);
}

/** The few symbols these surfaces use, by name ($r needs literal names). */
export function transferSymbol(name: string): Resource {
  switch (name) {
    case 'upload': return $r('sys.symbol.arrow_up_to_line');
    case 'download': return $r('sys.symbol.arrow_down_to_line');
    case 'file': return $r('sys.symbol.doc_text');
    case 'files': return $r('sys.symbol.doc_filled_on_doc');
    case 'folder': return $r('sys.symbol.folder_fill');
    case 'folderAdd': return $r('sys.symbol.folder_badge_plus');
    case 'drive': return $r('sys.symbol.externaldrive_fill');
    case 'clipboard': return $r('sys.symbol.text_clipboard_fill');
    case 'tap': return $r('sys.symbol.hand_point_up_tap_fill');
    case 'drag': return $r('sys.symbol.hand_draw');
    case 'save': return $r('sys.symbol.square_and_arrow_down');
    case 'refresh': return $r('sys.symbol.arrow_clockwise');
    case 'up': return $r('sys.symbol.arrow_up_left');
    case 'open': return $r('sys.symbol.arrow_right');
    case 'lock': return $r('sys.symbol.lock_shield_fill');
    case 'warning': return $r('sys.symbol.exclamationmark_triangle_fill');
    case 'info': return $r('sys.symbol.info_circle_fill');
    case 'done': return $r('sys.symbol.checkmark');
    case 'close': return $r('sys.symbol.xmark');
    case 'trash': return $r('sys.symbol.trash');
    case 'clock': return $r('sys.symbol.clock');
    case 'chevron': return $r('sys.symbol.chevron_right');
    default: return $r('sys.symbol.doc_text');
  }
}

/**
 * A slim progress bar: the fill glides to each new value; below zero it is indeterminate, a soft light sweeping
 * across the track.
 */
@Component
export struct TransferProgressBar {
  @StorageLink('currentTheme') theme: string = 'light';
  /** 0…1, or below zero while the total is not known. */
  @Prop value: number = -1;
  @Prop color: string = '#007DFF';
  @Prop barHeight: number = 4;
  @State private sweep: boolean = false;

  private fraction(): number { return Math.max(0.025, Math.min(1, this.value)); }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      if (this.value < 0) {
        Row()
          .width('36%').height('100%').borderRadius(this.barHeight / 2)
          .linearGradient({ direction: GradientDirection.Right, colors: [[appUiTint(this.color, '00'), 0],
            [this.color, 0.5], [appUiTint(this.color, '00'), 1]] })
          .translate({ x: this.sweep ? '290%' : '-100%' })
          .animation({ duration: 1300, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Normal })
          .onAppear((): void => { this.sweep = true; })
      } else {
        Row()
          .width((this.fraction() * 100).toFixed(2) + '%').height('100%').borderRadius(this.barHeight / 2)
          .linearGradient({ direction: GradientDirection.Right,
            colors: [[appUiTint(this.color, 'B3'), 0], [this.color, 1]] })
          .animation({ duration: 360, curve: Curve.FastOutSlowIn })
      }
    }
    .width('100%').height(this.barHeight).borderRadius(this.barHeight / 2).clip(true)
    .backgroundColor(this.theme === 'light' ? 'rgba(0,0,0,0.07)' : 'rgba(255,255,255,0.12)')
  }
}

/**
 * Where a transfer stands, in one card: an icon that turns (a ring filling, a spinner while the size is unknown),
 * then pops into a check or a warning; the headline, its detail, the percentage counting up, and the bar.
 * Floating over the session it is frosted glass; inside the panel a plain grouped card.
 */
@Component
export struct TransferStatusCapsule {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @Prop status: string = '';
  @Prop progress: number = -1;
  @Prop busy: boolean = false;
  @Prop floating: boolean = true;

  private pal(): Palette { return palette(this.theme, this.accentColor); }
  private tone(): TransferTone { return transferTone(this.busy, this.progress); }
  private known(): boolean { return this.busy && this.progress > 0 && this.progress <= 1; }
  private percent(): number { return Math.floor(Math.max(0, Math.min(1, this.progress)) * 100); }
  private toneColor(): string {
    const tone: TransferTone = this.tone();
    return tone === 'done' ? this.pal().success : tone === 'error' ? this.pal().danger : this.accentColor;
  }

  @Builder private icon() {
    Stack() {
      if (this.tone() === 'busy') {
        if (this.known()) {
          Progress({ value: this.percent(), total: 100, type: ProgressType.Ring })
            .width(34).height(34).color(this.accentColor)
            .backgroundColor(appUiTint(this.accentColor, '26'))
            .style({ strokeWidth: 3.5, enableSmoothEffect: true })
          SymbolGlyph(transferSymbol('files')).fontSize(14).fontColor([this.accentColor])
        } else {
          LoadingProgress().width(30).height(30).color(this.accentColor)
        }
      } else {
        Stack() {
          Circle().width(34).height(34).fill(appUiTint(this.toneColor(), '26'))
          SymbolGlyph(transferSymbol(this.tone() === 'done' ? 'done' : 'warning'))
            .fontSize(this.tone() === 'done' ? 18 : 16).fontWeight(FontWeight.Bold).fontColor([this.toneColor()])
        }.transition(popIn())
      }
    }.width(34).height(34)
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        this.icon()
        Column({ space: 2 }) {
          Text(transferStatusParts(this.status)[0])
            .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            .maxLines(transferStatusParts(this.status)[1].length > 0 ? 1 : 2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (transferStatusParts(this.status)[1].length > 0) {
            Text(transferStatusParts(this.status)[1])
              .fontSize(12).fontColor(this.pal().text2).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        if (this.known()) {
          Text(this.percent().toString() + '%')
            .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.accentColor)
            .fontFeature('"tnum" on')
            .contentTransition(new NumericTextTransition({ flipDirection: FlipDirection.UP }))
        }
      }.width('100%').alignItems(VerticalAlign.Center)
      if (this.busy) {
        TransferProgressBar({ value: this.known() ? this.progress : -1, color: this.accentColor, barHeight: 4 })
      }
    }
    .width('100%')
    .padding({ left: 14, right: 16, top: 12, bottom: 12 })
    .backgroundColor(this.floating ? this.pal().floatBg : this.pal().surface)
    .backdropBlur(this.floating ? 24 : 0)
    .borderRadius(this.floating ? 20 : 16)
    .border({ width: this.floating ? 1 : 0, color: this.pal().floatBorder })
    .shadow(this.floating ? { radius: 24, color: this.pal().fabShadow, offsetY: 8 } :
      { radius: 0, color: Color.Transparent })
    .animation({ duration: 240, curve: Curve.FastOutSlowIn })
  }
}

/**
 * Over an RDP session whose file offer nothing has read yet: the files wait on the remote clipboard; the user clicks
 * the target folder remotely, then 「粘贴到这里」. The hand pulses gently until then.
 */
@Component
export struct RdpPasteHereBanner {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  onPaste: () => void = (): void => {};
  onClose: () => void = (): void => {};
  @State private narrow: boolean = false;
  @State private pasting: boolean = false;
  @State private pulse: boolean = false;
  private pastingTimer: number = -1;

  private pal(): Palette { return palette(this.theme, this.accentColor); }

  aboutToDisappear(): void {
    if (this.pastingTimer >= 0) { clearTimeout(this.pastingTimer); this.pastingTimer = -1; }
  }

  private paste(): void {
    if (this.pasting) { return; }
    this.onPaste();
    this.pasting = true;
    this.pastingTimer = setTimeout((): void => { this.pastingTimer = -1; this.pasting = false; }, 2600);
  }

  @Builder private hand() {
    Stack() {
      Circle().width(44).height(44).fill(appUiTint(this.accentColor, '40'))
        .scale({ x: this.pulse ? 1.5 : 1, y: this.pulse ? 1.5 : 1 }).opacity(this.pulse ? 0 : 0.9)
        .animation({ duration: 1700, curve: Curve.EaseOut, iterations: -1, playMode: PlayMode.Normal })
      Circle().width(44).height(44).fill(appUiTint(this.accentColor, '26'))
      SymbolGlyph(transferSymbol('tap')).fontSize(22).fontColor([this.accentColor])
    }.width(44).height(44)
    .onAppear((): void => { this.pulse = true; })
  }

  @Builder private pasteButton(full: boolean) {
    Row({ space: 6 }) {
      if (this.pasting) {
        LoadingProgress().width(18).height(18).color(appUiOnAccentText(this.accentColor))
      } else {
        SymbolGlyph(transferSymbol('clipboard')).fontSize(16).fontColor([appUiOnAccentText(this.accentColor)])
      }
      Text(this.pasting ? '正在粘贴' : '粘贴到这里')
        .fontSize(14).fontWeight(FontWeight.Medium).fontColor(appUiOnAccentText(this.accentColor))
    }
    .height(40).padding({ left: 16, right: 18 }).justifyContent(FlexAlign.Center)
    .width(full ? '100%' : 'auto')
    .borderRadius(20).backgroundColor(this.accentColor)
    .shadow({ radius: 14, color: appUiTint(this.accentColor, '59'), offsetY: 4 })
    .stateStyles({ pressed: { .opacity(0.82) }, normal: { .opacity(1) } })
    .accessibilityText('粘贴到这里')
    .onClick((): void => { this.paste(); })
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        this.hand()
        Column({ space: 2 }) {
          Text('文件已在远端剪贴板').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          Text('在远端点开要放文件的文件夹，再点「粘贴到这里」')
            .fontSize(12).fontColor(this.pal().text2).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        if (!this.narrow) { this.pasteButton(false) }
        Button() {
          SymbolGlyph(transferSymbol('close')).fontSize(14).fontColor([this.pal().text2])
        }
        .width(32).height(32).padding(0).type(ButtonType.Circle)
        .backgroundColor(this.theme === 'light' ? 'rgba(0,0,0,0.06)' : 'rgba(255,255,255,0.12)')
        .accessibilityText('不用了')
        .onClick((): void => { this.onClose(); })
      }.width('100%').alignItems(VerticalAlign.Center)
      if (this.narrow) { this.pasteButton(true) }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .backgroundColor(this.pal().floatBg).backdropBlur(24)
    .borderRadius(22).border({ width: 1, color: this.pal().floatBorder })
    .shadow({ radius: 28, color: this.pal().fabShadow, offsetY: 10 })
    .onAreaChange((_old: Area, area: Area): void => { this.narrow = Number(area.width) < 440; })
  }
}

/**
 * A notice inside the panel: an icon well, a headline, the explanation, optional numbered steps and one action.
 * 'info' speaks in the accent, 'warning' in the danger colour.
 */
@Component
export struct TransferNoticeCard {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @Prop tone: string = 'info';
  @Prop iconName: string = 'info';
  @Prop title: string = '';
  @Prop message: string = '';
  @Prop steps: string[] = [];
  @Prop actionLabel: string = '';
  @Prop actionIcon: string = '';
  @Prop busy: boolean = false;
  onAction: () => void = (): void => {};

  private pal(): Palette { return palette(this.theme, this.accentColor); }
  private color(): string { return this.tone === 'warning' ? this.pal().danger : this.accentColor; }

  build() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Stack() {
          Circle().width(38).height(38).fill(appUiTint(this.color(), '26'))
          SymbolGlyph(transferSymbol(this.iconName)).fontSize(18).fontColor([this.color()])
        }.width(38).height(38)
        Column({ space: 3 }) {
          Text(this.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          if (this.message.length > 0) {
            Text(this.message).fontSize(13).lineHeight(19).fontColor(this.pal().text2)
          }
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Top)
      if (this.steps.length > 0) {
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          ForEach(this.steps, (step: string, index: number): void => {
            Row({ space: 6 }) {
              Text((index + 1).toString())
                .fontSize(11).fontWeight(FontWeight.Bold).fontColor(appUiOnAccentText(this.color()))
                .width(18).height(18).textAlign(TextAlign.Center).borderRadius(9).backgroundColor(this.color())
              Text(step).fontSize(12).fontColor(this.pal().text)
              if (index < this.steps.length - 1) {
                SymbolGlyph(transferSymbol('chevron')).fontSize(12).fontColor([this.pal().text3])
                  .margin({ left: 2, right: 6 })
              }
            }.margin({ top: 4, bottom: 4 })
          }, (step: string, index: number): string => index.toString() + step)
        }.width('100%')
      }
      if (this.actionLabel.length > 0) {
        Row({ space: 6 }) {
          if (this.busy) {
            LoadingProgress().width(18).height(18)
              .color(this.tone === 'warning' ? this.color() : appUiOnAccentText(this.color()))
          } else if (this.actionIcon.length > 0) {
            SymbolGlyph(transferSymbol(this.actionIcon)).fontSize(16)
              .fontColor([this.tone === 'warning' ? this.color() : appUiOnAccentText(this.color())])
          }
          Text(this.actionLabel).fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor(this.tone === 'warning' ? this.color() : appUiOnAccentText(this.color()))
        }
        .width('100%').height(42).justifyContent(FlexAlign.Center).borderRadius(21)
        .opacity(this.busy ? 0.7 : 1)
        .stateStyles({
          normal: { .backgroundColor(this.tone === 'warning' ? appUiTint(this.color(), '1F') : this.color()) },
          pressed: { .backgroundColor(this.tone === 'warning' ? appUiTint(this.color(), '33') : appUiTint(this.color(), 'CC')) }
        })
        .onClick((): void => { if (!this.busy) { this.onAction(); } })
      }
    }
    .width('100%').padding(14).borderRadius(18)
    .backgroundColor(appUiTint(this.color(), this.theme === 'light' ? '0F' : '1A'))
    .border({ width: 1, color: appUiTint(this.color(), '33') })
  }
}

/**
 * A direction to choose (发送 / 接收): an icon well with the accent's glow, the name, what it does, a chevron.
 * Presses sink a little; a direction that is not available fades and says why.
 */
@Component
export struct TransferDirectionCard {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @Prop iconName: string = 'upload';
  @Prop title: string = '';
  @Prop detail: string = '';
  @Prop available: boolean = true;
  /** Side by side (Pad/PC): icon over the text; stacked (phone): icon beside it. */
  @Prop tall: boolean = false;
  onTap: () => void = (): void => {};
  @State private pressed: boolean = false;

  private pal(): Palette { return palette(this.theme, this.accentColor); }

  @Builder private well() {
    Stack() {
      Circle().width(48).height(48)
        .fill(appUiTint(this.accentColor, '1F'))
      SymbolGlyph(transferSymbol(this.iconName)).fontSize(24).fontColor([this.accentColor])
    }.width(48).height(48)
  }

  build() {
    Column() {
      if (this.tall) {
        Column({ space: 12 }) {
          Row() {
            this.well()
            Blank()
            SymbolGlyph(transferSymbol('chevron')).fontSize(16).fontColor([this.pal().text3])
          }.width('100%')
          Column({ space: 4 }) {
            Text(this.title).fontSize(17).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            Text(this.detail).fontSize(12).lineHeight(17).fontColor(this.pal().text2).maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }.alignItems(HorizontalAlign.Start).width('100%')
        }.width('100%')
      } else {
        Row({ space: 14 }) {
          this.well()
          Column({ space: 3 }) {
            Text(this.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            Text(this.detail).fontSize(12).lineHeight(17).fontColor(this.pal().text2).maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          SymbolGlyph(transferSymbol('chevron')).fontSize(16).fontColor([this.pal().text3])
        }.width('100%')
      }
    }
    .width('100%').padding(16).borderRadius(20).backgroundColor(this.pal().surface)
    .opacity(this.available ? 1 : 0.5)
    .scale({ x: this.pressed ? 0.975 : 1, y: this.pressed ? 0.975 : 1 })
    .animation({ curve: curves.springMotion(0.3, 0.8) })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) { this.pressed = true; }
      else if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.pressed = false; }
    })
    .accessibilityText(this.title + '，' + this.detail)
    .onClick((): void => { this.onTap(); })
  }
}

/** One of the panel's big actions (选择文件, 选择文件夹…): an icon over its label, sinking a little when pressed. */
@Component
export struct TransferActionTile {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @Prop iconName: string = 'file';
  @Prop label: string = '';
  @Prop detail: string = '';
  @Prop available: boolean = true;
  /** The main action: filled with the accent. */
  @Prop primary: boolean = false;
  onTap: () => void = (): void => {};
  @State private pressed: boolean = false;

  private pal(): Palette { return palette(this.theme, this.accentColor); }
  private ink(): string { return this.primary ? appUiOnAccentText(this.accentColor) : this.accentColor; }

  build() {
    Column({ space: 8 }) {
      Stack() {
        Circle().width(40).height(40)
          .fill(this.primary ? 'rgba(255,255,255,0.22)' : appUiTint(this.accentColor, '1F'))
        SymbolGlyph(transferSymbol(this.iconName)).fontSize(20).fontColor([this.ink()])
      }.width(40).height(40)
      Column({ space: 2 }) {
        Text(this.label).fontSize(15).fontWeight(FontWeight.Medium)
          .fontColor(this.primary ? appUiOnAccentText(this.accentColor) : this.pal().text)
        if (this.detail.length > 0) {
          Text(this.detail).fontSize(11).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor(this.primary ? appUiOnAccentText(this.accentColor) : this.pal().text2)
            .opacity(this.primary ? 0.8 : 1)
        }
      }.alignItems(HorizontalAlign.Start)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%').padding(14).borderRadius(18)
    .backgroundColor(this.primary ? this.accentColor : this.pal().surface)
    .shadow(this.primary ? { radius: 16, color: appUiTint(this.accentColor, '4D'), offsetY: 6 } :
      { radius: 0, color: Color.Transparent })
    .opacity(this.available ? 1 : 0.45)
    .scale({ x: this.pressed ? 0.96 : 1, y: this.pressed ? 0.96 : 1 })
    .animation({ curve: curves.springMotion(0.3, 0.8) })
    .onTouch((event: TouchEvent): void => {
      if (!this.available) { return; }
      if (event.type === TouchType.Down) { this.pressed = true; }
      else if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.pressed = false; }
    })
    .accessibilityText(this.label)
    .onClick((): void => { if (this.available) { this.onTap(); } })
  }
}

/**
 * Phone/Pad RDP: the place to drop files dragged from the HarmonyOS file manager. Dashed and quiet at rest; while a
 * drag hovers it glows in the accent, swells a little and the hand lifts.
 */
@Component
export struct TransferDropZone {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @Prop active: boolean = false;

  private pal(): Palette { return palette(this.theme, this.accentColor); }

  build() {
    Row({ space: 12 }) {
      SymbolGlyph(transferSymbol('drag')).fontSize(24)
        .fontColor([this.active ? this.accentColor : this.pal().text2])
        .translate({ y: this.active ? -3 : 0 })
      Column({ space: 2 }) {
        Text(this.active ? '松手即可发送' : '从文件管理器拖到这里')
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.active ? this.accentColor : this.pal().text)
        Text('文件先进入本机暂存区，再交给远端粘贴').fontSize(12).fontColor(this.pal().text2)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }
    .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 14 }).borderRadius(18)
    .border({ width: 1.5, style: BorderStyle.Dashed,
      color: this.active ? this.accentColor : (this.theme === 'light' ? 'rgba(0,0,0,0.16)' : 'rgba(255,255,255,0.2)') })
    .backgroundColor(this.active ? appUiTint(this.accentColor, '14') : Color.Transparent)
    .scale({ x: this.active ? 1.02 : 1, y: this.active ? 1.02 : 1 })
    .animation({ curve: curves.springMotion(0.34, 0.78) })
  }
}

/** Placeholder rows while a remote folder is read the first time, breathing softly. */
@Component
export struct TransferSkeletonRows {
  @StorageLink('currentTheme') theme: string = 'light';
  @Prop rows: number = 4;
  @State private dim: boolean = false;

  private block(): string { return this.theme === 'light' ? 'rgba(0,0,0,0.07)' : 'rgba(255,255,255,0.10)'; }
  private indices(): number[] {
    const result: number[] = [];
    for (let i: number = 0; i < this.rows; i++) { result.push(i); }
    return result;
  }

  build() {
    Column({ space: 0 }) {
      ForEach(this.indices(), (index: number): void => {
        Row({ space: 12 }) {
          Row().width(32).height(32).borderRadius(9).backgroundColor(this.block())
          Column({ space: 6 }) {
            Row().width(index % 2 === 0 ? '62%' : '44%').height(11).borderRadius(5.5).backgroundColor(this.block())
            Row().width('28%').height(9).borderRadius(4.5).backgroundColor(this.block())
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }.width('100%').padding({ left: 12, right: 12, top: 11, bottom: 11 })
      }, (index: number): string => 'skeleton-' + index.toString())
    }
    .width('100%')
    .opacity(this.dim ? 0.45 : 1)
    .animation({ duration: 900, curve: Curve.EaseInOut, iterations: -1, playMode: PlayMode.Alternate })
    .onAppear((): void => { this.dim = true; })
  }
}

/** A small round icon button (上一级, 刷新, 新建…). */
@Component
export struct TransferIconButton {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @Prop iconName: string = 'refresh';
  @Prop label: string = '';
  @Prop available: boolean = true;
  @Prop spinning: boolean = false;
  onTap: () => void = (): void => {};

  build() {
    Button() {
      if (this.spinning) {
        LoadingProgress().width(20).height(20).color(this.accentColor)
      } else {
        SymbolGlyph(transferSymbol(this.iconName)).fontSize(17)
          .fontColor([this.available ? this.accentColor : (this.theme === 'light' ? 'rgba(0,0,0,0.26)' :
            'rgba(255,255,255,0.3)')])
      }
    }
    .width(40).height(40).padding(0).type(ButtonType.Circle)
    .backgroundColor(this.theme === 'light' ? 'rgba(0,0,0,0.05)' : 'rgba(255,255,255,0.10)')
    .enabled(this.available && !this.spinning)
    .accessibilityText(this.label)
    .onClick((): void => { this.onTap(); })
  }
}

/** A compact pill action on a row (接收, 另存, 提取副本…). */
@Component
export struct TransferPillButton {
  @StorageLink('currentTheme') theme: string = 'light';
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @Prop label: string = '';
  @Prop iconName: string = '';
  @Prop available: boolean = true;
  /** Filled with the accent instead of tinted. */
  @Prop strong: boolean = false;
  onTap: () => void = (): void => {};

  build() {
    Row({ space: 4 }) {
      if (this.iconName.length > 0) {
        SymbolGlyph(transferSymbol(this.iconName)).fontSize(13)
          .fontColor([this.strong ? appUiOnAccentText(this.accentColor) : this.accentColor])
      }
      Text(this.label).fontSize(13).fontWeight(FontWeight.Medium)
        .fontColor(this.strong ? appUiOnAccentText(this.accentColor) : this.accentColor)
    }
    .height(32).padding({ left: 12, right: 12 }).borderRadius(16)
    .opacity(this.available ? 1 : 0.4)
    .stateStyles({
      normal: { .backgroundColor(this.strong ? this.accentColor : appUiTint(this.accentColor, '1F')) },
      pressed: { .backgroundColor(this.strong ? appUiTint(this.accentColor, 'CC') : appUiTint(this.accentColor, '38')) }
    })
    .accessibilityText(this.label)
    .onClick((): void => { if (this.available) { this.onTap(); } })
  }
}
