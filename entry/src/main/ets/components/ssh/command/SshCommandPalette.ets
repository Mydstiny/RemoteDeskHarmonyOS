import { KeyCode } from '@kit.InputKit';
import {
  rankSshCommands,
  SshCommandDescriptor
} from '../../../services/ssh/command/SshCommandPolicy';

/** Search-first SSH action surface. It consumes one parent-built registry. */
@Component
export struct SshCommandPalette {
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop commands: Array<SshCommandDescriptor> = [];
  @Prop compact: boolean = false;
  onExecute: (commandId: string) => void = (_commandId: string): void => {};
  onClose: () => void = (): void => {};

  @State query: string = '';
  @State selectedIndex: number = 0;
  @State hoveredId: string = '';

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

  private rowBackground(command: SshCommandDescriptor, index: number): string {
    if (!command.enabled) { return 'rgba(255,255,255,0.025)'; }
    if (index === this.selectedIndex) { return this.accentColor + '30'; }
    if (this.hoveredId === command.id) { return 'rgba(255,255,255,0.10)'; }
    return 'rgba(255,255,255,0.055)';
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Text('⌕').fontSize(20).fontColor('rgba(242,244,247,0.72)')
        TextInput({ text: this.query, placeholder: '搜索主机、会话或动作' })
          .id('sshCommandPaletteInput')
          .layoutWeight(1)
          .height(42)
          .fontSize(14)
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
        Button('×')
          .width(34).height(34).padding(0).fontSize(18).fontColor('#F2F4F7')
          .borderRadius(9).backgroundColor('rgba(255,255,255,0.08)')
          .onClick((): void => { this.onClose(); })
          .accessibilityText('关闭 SSH 命令面板')
      }
      .width('100%')
      .height(48)
      .padding({ left: 12, right: 8 })
      .borderRadius(12)
      .backgroundColor('rgba(255,255,255,0.07)')

      if (this.results().length === 0) {
        Column({ space: 6 }) {
          Text('没有匹配项').fontSize(14).fontColor('rgba(242,244,247,0.72)')
          Text('尝试输入主机名称、会话状态或动作关键词')
            .fontSize(11).fontColor('rgba(242,244,247,0.44)')
        }
        .width('100%').height(180).justifyContent(FlexAlign.Center)
      } else {
        List({ space: 6 }) {
          ForEach(this.results(), (command: SshCommandDescriptor, index: number): void => {
            ListItem() {
              Row({ space: 10 }) {
                Text(this.categoryLabel(command))
                  .width(38).height(22).fontSize(9)
                  .fontColor(command.enabled ? '#F2F4F7' : 'rgba(242,244,247,0.38)')
                  .textAlign(TextAlign.Center)
                  .borderRadius(6)
                  .backgroundColor(command.category === 'action'
                    ? 'rgba(0,125,255,0.30)' : 'rgba(255,255,255,0.09)')
                Column({ space: 3 }) {
                  Row({ space: 6 }) {
                    Text(command.title)
                      .fontSize(13).fontWeight(FontWeight.Medium)
                      .fontColor(command.enabled ? '#F2F4F7' : 'rgba(242,244,247,0.38)')
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    if (command.danger !== 'none') {
                      Text(command.danger === 'danger' ? '危险' : '需确认')
                        .fontSize(9).fontColor('#FF9B9B')
                    }
                  }.width('100%')
                  Text(command.subtitle)
                    .fontSize(10)
                    .fontColor(command.enabled
                      ? 'rgba(242,244,247,0.52)' : 'rgba(242,244,247,0.28)')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                if (command.shortcut.length > 0 && !this.compact) {
                  Text(command.shortcut).fontSize(9).fontColor('rgba(242,244,247,0.46)')
                    .padding({ left: 7, right: 7, top: 4, bottom: 4 })
                    .borderRadius(5).backgroundColor('rgba(255,255,255,0.07)')
                }
              }
              .width('100%').height(54)
              .padding({ left: 10, right: 10 })
              .borderRadius(10)
              .backgroundColor(this.rowBackground(command, index))
              .opacity(command.enabled ? 1 : 0.62)
              .onHover((hover: boolean): void => {
                this.hoveredId = hover ? command.id : '';
                if (hover && command.enabled) { this.selectedIndex = index; }
              })
              .onClick((): void => { this.execute(command); })
              .accessibilityText(command.title + (command.enabled ? '' : '，当前不可用'))
            }
          }, (command: SshCommandDescriptor): string => command.id)
        }
        .width('100%').layoutWeight(1).scrollBar(BarState.Auto)
      }

      Row() {
        Text('↑↓ 选择 · Enter 执行 · Esc 关闭')
          .fontSize(9).fontColor('rgba(242,244,247,0.38)').layoutWeight(1)
        Text(this.results().length.toString() + ' 项')
          .fontSize(9).fontColor('rgba(242,244,247,0.38)')
      }.width('100%')
    }
    .width('100%').height('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 12 })
    .backgroundColor('#171D25')
  }
}
