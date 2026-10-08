import { appUiOnAccentText, appUiTint } from '../../../common/AppUiColorPolicy';

/** The SSH page's colours (its skin), handed to the SFTP pieces. */
export class SftpColors {
  text: string = '#F2F4F7';
  text2: string = 'rgba(242,244,247,0.72)';
  text3: string = 'rgba(242,244,247,0.46)';
  card: string = '#232A33';
  surface: string = '#1B2129';
  divider: string = 'rgba(255,255,255,0.08)';
  accent: string = '#007DFF';
  danger: string = '#FF5A5F';
}

/** Press feedback shared by the SFTP buttons and rows. */
const PRESS_SCALE: number = 0.95;
const MOTION_MS: number = 160;

/**
 * A round icon button (上级、刷新、根目录、新建目录…): the label is for screen readers; the tone tints it for the
 * primary (accent) or a destructive (danger) action.
 */
@Component
export struct SftpIconButton {
  @Prop icon: Resource = $r('sys.symbol.circle');
  @Prop label: string = '';
  @Prop usable: boolean = true;
  @Prop tone: string = 'plain';
  @Prop diameter: number = 40;
  @Prop colors: SftpColors = new SftpColors();
  @State pressed: boolean = false;
  onTap: () => void = (): void => {};

  private foreground(): string {
    if (this.tone === 'accent') { return appUiOnAccentText(this.colors.accent); }
    if (this.tone === 'danger') { return this.colors.danger; }
    return this.colors.text2;
  }

  private fill(): string {
    if (this.tone === 'accent') { return this.colors.accent; }
    if (this.tone === 'danger') { return appUiTint(this.colors.danger.startsWith('#') ? this.colors.danger : '#FF5A5F', '24'); }
    return this.colors.card;
  }

  build() {
    Stack() {
      SymbolGlyph(this.icon).fontSize(Math.round(this.diameter * 0.45)).fontColor([this.foreground()])
    }
    .width(this.diameter).height(this.diameter).borderRadius(this.diameter / 2)
    .backgroundColor(this.fill())
    .opacity(this.usable ? 1 : 0.38)
    .scale({ x: this.pressed ? PRESS_SCALE : 1, y: this.pressed ? PRESS_SCALE : 1 })
    .animation({ duration: MOTION_MS, curve: Curve.FastOutSlowIn })
    .onTouch((event: TouchEvent): void => {
      if (!this.usable) { return; }
      if (event.type === TouchType.Down) { this.pressed = true; }
      if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.pressed = false; }
    })
    .onClick((): void => { if (this.usable) { this.onTap(); } })
    .accessibilityText(this.label)
    .accessibilityLevel('yes')
  }
}

/** A labelled action (上传、下载、传输到…): filled for the main action, tonal otherwise, red for deleting. */
@Component
export struct SftpActionButton {
  @Prop icon: Resource = $r('sys.symbol.circle');
  @Prop label: string = '';
  @Prop usable: boolean = true;
  @Prop tone: string = 'tonal';
  @Prop barHeight: number = 46;
  @Prop colors: SftpColors = new SftpColors();
  @State pressed: boolean = false;
  onTap: () => void = (): void => {};

  private foreground(): string {
    if (this.tone === 'primary') { return appUiOnAccentText(this.colors.accent); }
    if (this.tone === 'danger') { return this.colors.danger; }
    return this.colors.text;
  }

  private fill(): string {
    if (this.tone === 'primary') { return this.colors.accent; }
    if (this.tone === 'danger') { return appUiTint(this.colors.danger.startsWith('#') ? this.colors.danger : '#FF5A5F', '22'); }
    return this.colors.card;
  }

  build() {
    Row({ space: 8 }) {
      SymbolGlyph(this.icon).fontSize(17).fontColor([this.foreground()])
      Text(this.label).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.foreground())
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).flexShrink(1)
    }
    .width('100%').height(this.barHeight).justifyContent(FlexAlign.Center)
    .padding({ left: 14, right: 14 })
    .borderRadius(this.barHeight / 2)
    .backgroundColor(this.fill())
    .shadow(this.tone === 'primary' && this.usable
      ? { radius: 14, color: appUiTint(this.colors.accent, '40'), offsetY: 5 } : { radius: 0, color: Color.Transparent })
    .opacity(this.usable ? 1 : 0.4)
    .scale({ x: this.pressed ? 0.97 : 1, y: this.pressed ? 0.97 : 1 })
    .animation({ duration: MOTION_MS, curve: Curve.FastOutSlowIn })
    .onTouch((event: TouchEvent): void => {
      if (!this.usable) { return; }
      if (event.type === TouchType.Down) { this.pressed = true; }
      if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.pressed = false; }
    })
    .onClick((): void => { if (this.usable) { this.onTap(); } })
    .accessibilityText(this.label)
  }
}

/**
 * One file or folder. Tapping selects it; tapping a selected folder (or its chevron) opens it. The selection is a
 * tinted card with a check, animated in and out.
 */
@Component
export struct SftpFileRow {
  @Prop name: string = '';
  @Prop meta: string = '';
  @Prop isDirectory: boolean = false;
  @Prop selected: boolean = false;
  @Prop compact: boolean = false;
  @Prop usable: boolean = true;
  @Prop colors: SftpColors = new SftpColors();
  @State pressed: boolean = false;
  onSelect: () => void = (): void => {};
  /** Empty for a file; a folder opens through it. */
  onOpen: () => void = (): void => {};

  build() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph(this.isDirectory ? $r('sys.symbol.folder_fill') : $r('sys.symbol.doc_text'))
          .fontSize(this.compact ? 17 : 19)
          .fontColor([this.isDirectory ? this.colors.accent : this.colors.text2])
      }
      .width(this.compact ? 32 : 36).height(this.compact ? 32 : 36).borderRadius(10)
      .backgroundColor(this.isDirectory ? appUiTint(this.colors.accent, '1F') : this.colors.card)
      Column({ space: 2 }) {
        Text(this.name).fontSize(this.compact ? 13 : 14).fontColor(this.colors.text)
          .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Normal)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.meta).fontSize(11).fontColor(this.colors.text3)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (this.selected) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(18).fontColor([this.colors.accent])
          .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.5, y: 0.5 }))
            .animation({ duration: MOTION_MS, curve: Curve.FastOutSlowIn }))
      }
      if (this.isDirectory) {
        Stack() {
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([this.colors.text3])
        }
        .width(36).height(36).borderRadius(18)
        .onClick((): void => { if (this.usable) { this.onOpen(); } })
        .accessibilityText('打开 ' + this.name)
      }
    }
    .width('100%').height(this.compact ? 46 : 54)
    .padding({ left: 8, right: this.isDirectory ? 2 : 12 })
    .borderRadius(14)
    .backgroundColor(this.selected ? appUiTint(this.colors.accent, '1A') :
      (this.pressed ? this.colors.card : Color.Transparent))
    .border({ width: 1, color: this.selected ? appUiTint(this.colors.accent, '59') : Color.Transparent })
    .scale({ x: this.pressed ? 0.985 : 1, y: this.pressed ? 0.985 : 1 })
    .animation({ duration: MOTION_MS, curve: Curve.FastOutSlowIn })
    .opacity(this.usable ? 1 : 0.5)
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) { this.pressed = true; }
      if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.pressed = false; }
    })
    .onClick((): void => {
      if (!this.usable) { return; }
      if (this.isDirectory && this.selected) { this.onOpen(); return; }
      this.onSelect();
    })
    .accessibilityText((this.isDirectory ? '文件夹 ' : '文件 ') + this.name + (this.selected ? '，已选择' : ''))
  }
}

/** An empty, loading or not-yet-connected list: an icon, one line and a hint. */
@Component
export struct SftpEmptyState {
  @Prop icon: Resource = $r('sys.symbol.folder');
  @Prop title: string = '';
  @Prop detail: string = '';
  @Prop loading: boolean = false;
  @Prop colors: SftpColors = new SftpColors();

  build() {
    Column({ space: 8 }) {
      if (this.loading) {
        LoadingProgress().width(28).height(28).color(this.colors.accent)
      } else {
        Stack() {
          SymbolGlyph(this.icon).fontSize(24).fontColor([this.colors.text3])
        }.width(52).height(52).borderRadius(26).backgroundColor(this.colors.card)
      }
      Text(this.title).fontSize(14).fontColor(this.colors.text2).textAlign(TextAlign.Center)
      if (this.detail.length > 0) {
        Text(this.detail).fontSize(12).fontColor(this.colors.text3).textAlign(TextAlign.Center)
      }
    }
    .width('100%').height('100%').justifyContent(FlexAlign.Center).padding(16)
    .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
  }
}
