import { SEARCH_CAPSULE_HEIGHT, SEARCH_CAPSULE_RADIUS, SEARCH_CAPSULE_TEXT, searchGlassSheen, searchGlassShadow } from '../../../common/SearchBarSurface';
import { KeyCode } from '@kit.InputKit';
import { appUiTint } from '../../../common/AppUiColorPolicy';
import {
  rankSshCommands,
  SshCommandDescriptor
} from '../../../services/ssh/command/SshCommandPolicy';

/**
 * Search-first SSH action surface. It consumes one parent-built registry. The parent places it as a floating card
 * above the terminal (not a native Sheet) and bounds the list by the space left above the keyboard.
 */
@Component
export struct SshCommandPalette {
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop sheetBackgroundColor: string = '#171D25';
  // > 0: the card sizes to its content and only the list scrolls past this height.
  @Prop maxBodyHeightVp: number = 0;
  private fitContent(): boolean { return this.maxBodyHeightVp > 0; }
  private bodyMaxHeight(): number { return this.fitContent() ? this.maxBodyHeightVp : 100000; }
  @Prop commands: Array<SshCommandDescriptor> = [];
  @Prop compact: boolean = false;
  onExecute: (commandId: string) => void = (_commandId: string): void => {};
  onClose: () => void = (): void => {};

  @State query: string = '';
  @State selectedIndex: number = 0;
  @State hoveredId: string = '';
  @State pressedId: string = '';
  private listScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.query = '';
    this.selectedIndex = 0;
    setTimeout((): void => {
      try { focusControl.requestFocus('sshCommandPaletteInput'); } catch (_err) {}
    }, 32);
  }

  private results(): Array<SshCommandDescriptor> {
    return rankSshCommands(this.commands, this.query, 60);
  }

  private selectedCommand(): SshCommandDescriptor | null {
    const results: Array<SshCommandDescriptor> = this.results();
    if (results.length === 0) { return null; }
    const index: number = Math.min(Math.max(0, this.selectedIndex), results.length - 1);
    return results[index];
  }

  private moveSelection(delta: number): void {
    const count: number = this.results().length;
    if (count === 0) {
      this.selectedIndex = 0;
      return;
    }
    this.selectedIndex = (this.selectedIndex + delta + count) % count;
    try { this.listScroller.scrollToIndex(this.selectedIndex, true, ScrollAlign.AUTO); } catch (_err) {}
  }

  private execute(command: SshCommandDescriptor | null): void {
    if (command === null || !command.enabled) { return; }
    this.onExecute(command.id);
  }

  private onQueryChange(value: string): void {
    this.query = value.slice(0, 256);
    this.selectedIndex = 0;
  }

  private handleKeyEvent(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) { return false; }
    if (event.keyCode === KeyCode.KEYCODE_ESCAPE) {
      try { event.stopPropagation(); } catch (_err) {}
      this.onClose();
      return true;
    }
    if (event.keyCode === KeyCode.KEYCODE_DPAD_UP) {
      try { event.stopPropagation(); } catch (_err) {}
      this.moveSelection(-1);
      return true;
    }
    if (event.keyCode === KeyCode.KEYCODE_DPAD_DOWN) {
      try { event.stopPropagation(); } catch (_err) {}
      this.moveSelection(1);
      return true;
    }
    if (event.keyCode === KeyCode.KEYCODE_ENTER ||
      event.keyCode === KeyCode.KEYCODE_NUMPAD_ENTER) {
      try { event.stopPropagation(); } catch (_err) {}
      this.execute(this.selectedCommand());
      return true;
    }
    return false;
  }

  private categoryLabel(command: SshCommandDescriptor): string {
    if (command.category === 'host') { return '主机'; }
    if (command.category === 'session') { return '会话'; }
    return '动作';
  }

  private categoryIcon(command: SshCommandDescriptor): Resource {
    if (command.category === 'host') { return $r('sys.symbol.computer_host_fill'); }
    if (command.category === 'session') { return $r('sys.symbol.code_square'); }
    return $r('sys.symbol.bolt_fill');
  }

  private rowBackground(command: SshCommandDescriptor, index: number): ResourceColor {
    if (!command.enabled) { return 'rgba(255,255,255,0.025)'; }
    if (this.pressedId === command.id) { return appUiTint(this.accentColor, '33'); }
    if (index === this.selectedIndex) { return appUiTint(this.accentColor, '1F'); }
    if (this.hoveredId === command.id) { return 'rgba(255,255,255,0.09)'; }
    return 'rgba(255,255,255,0.045)';
  }

  @Builder
  private searchField() {
    Row() {
      SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(18).fontColor(['rgba(242,244,247,0.56)'])
        .margin({ left: 14, right: 6 })
      TextInput({ text: this.query, placeholder: '搜索主机、会话或动作' })
        .id('sshCommandPaletteInput')
        .layoutWeight(1)
        .height(SEARCH_CAPSULE_HEIGHT)
        .fontSize(SEARCH_CAPSULE_TEXT)
        .placeholderFont({ size: SEARCH_CAPSULE_TEXT })
        .padding({ left: 4, right: 4 })
        .fontColor('#F2F4F7')
        .placeholderColor('rgba(242,244,247,0.42)')
        .caretColor(this.accentColor)
        .backgroundColor(Color.Transparent)
        .enableAutoFill(false)
        .enablePreviewText(true)
        .onChange((value: string): void => { this.onQueryChange(value); })
        .onSubmit((_key: EnterKeyType, event: SubmitEvent): void => {
          this.execute(this.selectedCommand());
          event.keepEditableState();
        })
        .onKeyEvent((event: KeyEvent): boolean => { return this.handleKeyEvent(event); })
        .accessibilityText('SSH 命令面板搜索')
      if (this.query.length > 0) {
        Button() {
          SymbolGlyph($r('sys.symbol.xmark_circle_fill')).fontSize(18).fontColor(['rgba(242,244,247,0.46)'])
        }
        .width(44).height(44).padding(0).backgroundColor(Color.Transparent)
        .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.6, y: 0.6 }))
          .animation({ duration: 160, curve: Curve.FastOutSlowIn }))
        .onClick((): void => {
          this.onQueryChange('');
          try { focusControl.requestFocus('sshCommandPaletteInput'); } catch (_err) {}
        })
        .accessibilityText('清除搜索')
      }
    }
    .layoutWeight(1)
    .height(SEARCH_CAPSULE_HEIGHT)
    .borderRadius(SEARCH_CAPSULE_RADIUS)
    .backgroundColor('rgba(255,255,255,0.06)')
    .linearGradient(searchGlassSheen(true))
    .backgroundBlurStyle(BlurStyle.Regular)
    .shadow(searchGlassShadow(true))
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private commandRow(command: SshCommandDescriptor, index: number) {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph(this.categoryIcon(command)).fontSize(17)
          .fontColor([command.category === 'action' ? this.accentColor : 'rgba(242,244,247,0.80)'])
      }
      .width(36).height(36).borderRadius(11)
      .backgroundColor(command.category === 'action' ? appUiTint(this.accentColor, '24') : 'rgba(255,255,255,0.08)')
      .accessibilityText(this.categoryLabel(command))
      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(command.title)
            .fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(command.enabled ? '#F2F4F7' : 'rgba(242,244,247,0.38)')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .flexShrink(1)
          if (command.danger !== 'none') {
            Text(command.danger === 'danger' ? '危险' : '需确认')
              .fontSize(11).fontColor('#FF9B9B')
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .borderRadius(6).backgroundColor('rgba(255,107,107,0.14)')
          }
        }.width('100%')
        Text(command.subtitle)
          .fontSize(12)
          .fontColor(command.enabled
            ? 'rgba(242,244,247,0.54)' : 'rgba(242,244,247,0.28)')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (command.shortcut.length > 0 && !this.compact) {
        Text(command.shortcut).fontSize(11).fontColor('rgba(242,244,247,0.50)')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(6).backgroundColor('rgba(255,255,255,0.07)')
      }
    }
    .width('100%').constraintSize({ minHeight: 60 })
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .borderRadius(14)
    .backgroundColor(this.rowBackground(command, index))
    .border({ width: 1, color: index === this.selectedIndex && command.enabled
      ? appUiTint(this.accentColor, '66') : Color.Transparent })
    .scale({ x: this.pressedId === command.id ? 0.98 : 1, y: this.pressedId === command.id ? 0.98 : 1 })
    .animation({ duration: 140, curve: Curve.FastOutSlowIn })
    .opacity(command.enabled ? 1 : 0.62)
    .onHover((hover: boolean): void => {
      this.hoveredId = hover ? command.id : '';
      if (hover && command.enabled) { this.selectedIndex = index; }
    })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down && command.enabled) { this.pressedId = command.id; }
      if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.pressedId = ''; }
    })
    .onClick((): void => { this.execute(command); })
    .accessibilityText(command.title + (command.enabled ? '' : '，当前不可用'))
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        this.searchField()
        Button() {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(17).fontColor(['rgba(242,244,247,0.82)'])
        }
        .width(44).height(44).padding(0).borderRadius(22)
        .backgroundColor('rgba(255,255,255,0.08)')
        .onClick((): void => { this.onClose(); })
        .accessibilityText('关闭 SSH 命令面板')
      }
      .width('100%')

      if (this.results().length === 0) {
        Column({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(28).fontColor(['rgba(242,244,247,0.32)'])
          Text('没有匹配项').fontSize(15).fontColor('rgba(242,244,247,0.78)')
          Text('试试主机名称、会话状态或动作关键词')
            .fontSize(12).fontColor('rgba(242,244,247,0.46)')
        }
        .width('100%').height(160).justifyContent(FlexAlign.Center)
        .transition(TransitionEffect.OPACITY.animation({ duration: 160 }))
      } else {
        List({ space: 8, scroller: this.listScroller }) {
          ForEach(this.results(), (command: SshCommandDescriptor, index: number): void => {
            ListItem() {
              this.commandRow(command, index)
            }
          }, (command: SshCommandDescriptor): string => command.id)
        }
        .width('100%').layoutWeight(this.fitContent() ? 0 : 1)
        .constraintSize({ maxHeight: this.bodyMaxHeight() })
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }

      if (!this.compact) {
        Row() {
          Text('↑↓ 选择 · Enter 执行 · Esc 关闭')
            .fontSize(11).fontColor('rgba(242,244,247,0.40)').layoutWeight(1)
          Text(this.results().length.toString() + ' 项')
            .fontSize(11).fontColor('rgba(242,244,247,0.40)')
        }.width('100%').padding({ left: 4, right: 4 })
      }
    }
    .width('100%').height(this.fitContent() ? 'auto' : '100%')
    .padding({ left: 14, right: 14, top: 14, bottom: this.compact ? 14 : 12 })
    .backgroundColor(this.sheetBackgroundColor)
  }
}
