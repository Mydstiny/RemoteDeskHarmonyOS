import { KeyCode } from '@kit.InputKit';
import {
  routeSshShortcut,
  SshShortcutChord,
  SshShortcutContext,
  SshShortcutKey
} from '../../../services/ssh/shortcut/SshShortcutPolicy';

/**
 * Session-local terminal find surface. Query text is owned by the page and is
 * never routed through the SSH input buffer or any persistent settings store.
 */
@Component
export struct SshTerminalSearchBar {
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop query: string = '';
  @Prop resultLabel: string = '';
  @Prop validationMessage: string = '';
  @Prop caseSensitive: boolean = false;
  @Prop wholeWord: boolean = false;
  @Prop regex: boolean = false;
  @Prop @Watch('onFocusRequestChange') focusRequest: number = 0;
  onQueryChange: (value: string) => void = (_value: string): void => {};
  onNext: () => void = (): void => {};
  onPrevious: () => void = (): void => {};
  onToggleCaseSensitive: () => void = (): void => {};
  onToggleWholeWord: () => void = (): void => {};
  onToggleRegex: () => void = (): void => {};
  onClose: () => void = (): void => {};

  @State hoveredAction: string = '';

  aboutToAppear(): void {
    this.requestInputFocus();
  }

  private onFocusRequestChange(): void {
    this.requestInputFocus();
  }

  private requestInputFocus(): void {
    const expectedRequest: number = this.focusRequest;
    setTimeout((): void => {
      if (expectedRequest !== this.focusRequest) { return; }
      try { focusControl.requestFocus('sshTerminalSearchInput'); } catch (_err) {
        // A parent transition can briefly unmount the overlay. The next
        // focusRequest or appearance boundary will retry.
      }
    }, 32);
  }

  private modifier(event: KeyEvent, name: string): boolean {
    try {
      return event.getModifierKeyState ? event.getModifierKeyState([name]) : false;
    } catch (_err) {
      return false;
    }
  }

  private shortcutKey(keyCode: number): SshShortcutKey {
    if (keyCode === KeyCode.KEYCODE_F) { return 'F'; }
    if (keyCode === KeyCode.KEYCODE_ENTER || keyCode === KeyCode.KEYCODE_NUMPAD_ENTER) {
      return 'ENTER';
    }
    if (keyCode === KeyCode.KEYCODE_ESCAPE) { return 'ESCAPE'; }
    if (keyCode === KeyCode.KEYCODE_TAB) { return 'TAB'; }
    return 'OTHER';
  }

  private handleKeyEvent(event: KeyEvent): boolean {
    if (event.type !== KeyType.Down) { return false; }
    const chord: SshShortcutChord = {
      key: this.shortcutKey(event.keyCode),
      ctrl: this.modifier(event, 'Ctrl'),
      meta: this.modifier(event, 'Meta'),
      alt: this.modifier(event, 'Alt'),
      shift: this.modifier(event, 'Shift')
    };
    const context: SshShortcutContext = {
      modalOpen: false,
      searchOpen: true,
      textEditorFocused: true,
      terminalFocused: false,
      terminalSearchEnabled: true
    };
    const action: string = routeSshShortcut(chord, context).action;
    if (action === 'search_next') {
      // TextInput.onSubmit owns plain Enter, including software keyboards.
      return false;
    }
    if (action === 'search_previous') {
      try { event.stopPropagation(); } catch (_err) {}
      this.onPrevious();
      return true;
    }
    if (action === 'close_terminal_search') {
      try { event.stopPropagation(); } catch (_err) {}
      this.onClose();
      return true;
    }
    if (action === 'focus_terminal_search') {
      try { event.stopPropagation(); } catch (_err) {}
      this.requestInputFocus();
      return true;
    }
    return false;
  }

  private actionBackground(action: string): string {
    return this.hoveredAction === action ? 'rgba(255,255,255,0.18)' : 'rgba(255,255,255,0.08)';
  }

  private toggleBackground(active: boolean, action: string): string {
    if (active) { return this.accentColor + 'CC'; }
    return this.actionBackground(action);
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(17)
          .fontColor(['rgba(242,244,247,0.78)'])
        TextInput({ text: this.query, placeholder: '在当前终端中查找' })
          .id('sshTerminalSearchInput')
          .layoutWeight(1)
          .constraintSize({ minWidth: 88 })
          .height(34)
          .fontSize(13)
          .fontColor('#F2F4F7')
          .placeholderColor('rgba(242,244,247,0.46)')
          .caretColor(this.accentColor)
          .backgroundColor('rgba(255,255,255,0.07)')
          .borderRadius(8)
          .padding({ left: 10, right: 10 })
          .enterKeyType(EnterKeyType.Search)
          .enableAutoFill(false)
          .enablePreviewText(true)
          .onChange((value: string): void => { this.onQueryChange(value); })
          .onSubmit((_key: EnterKeyType, event: SubmitEvent): void => {
            this.onNext();
            event.keepEditableState();
          })
          .onKeyEvent((event: KeyEvent): boolean => { return this.handleKeyEvent(event); })
          .accessibilityText('终端搜索内容')
        Text(this.resultLabel)
          .width(48)
          .fontSize(11)
          .fontColor('rgba(242,244,247,0.68)')
          .textAlign(TextAlign.Center)
          .maxLines(1)
        Button('↑')
          .width(32).height(32).fontSize(16).fontColor('#F2F4F7')
          .padding(0).borderRadius(8).backgroundColor(this.actionBackground('previous'))
          .onHover((hover: boolean): void => { this.hoveredAction = hover ? 'previous' : ''; })
          .onClick((): void => { this.onPrevious(); })
          .accessibilityText('查找上一个匹配项')
        Button('↓')
          .width(32).height(32).fontSize(16).fontColor('#F2F4F7')
          .padding(0).borderRadius(8).backgroundColor(this.actionBackground('next'))
          .onHover((hover: boolean): void => { this.hoveredAction = hover ? 'next' : ''; })
          .onClick((): void => { this.onNext(); })
          .accessibilityText('查找下一个匹配项')
        Button('×')
          .width(32).height(32).fontSize(18).fontColor('#F2F4F7')
          .padding(0).borderRadius(8).backgroundColor(this.actionBackground('close'))
          .onHover((hover: boolean): void => { this.hoveredAction = hover ? 'close' : ''; })
          .onClick((): void => { this.onClose(); })
          .accessibilityText('关闭终端搜索')
      }
      .width('100%')

      Row({ space: 6 }) {
        Button('Aa')
          .height(28).fontSize(11).fontColor('#F2F4F7')
          .padding({ left: 10, right: 10 }).borderRadius(7)
          .backgroundColor(this.toggleBackground(this.caseSensitive, 'case'))
          .onHover((hover: boolean): void => { this.hoveredAction = hover ? 'case' : ''; })
          .onClick((): void => { this.onToggleCaseSensitive(); })
          .accessibilityText(this.caseSensitive ? '区分大小写，已开启' : '区分大小写，已关闭')
        Button('整词')
          .height(28).fontSize(11).fontColor('#F2F4F7')
          .padding({ left: 10, right: 10 }).borderRadius(7)
          .backgroundColor(this.toggleBackground(this.wholeWord, 'word'))
          .onHover((hover: boolean): void => { this.hoveredAction = hover ? 'word' : ''; })
          .onClick((): void => { this.onToggleWholeWord(); })
          .accessibilityText(this.wholeWord ? '全词匹配，已开启' : '全词匹配，已关闭')
        Button('.*')
          .height(28).fontSize(11).fontColor('#F2F4F7')
          .padding({ left: 10, right: 10 }).borderRadius(7)
          .backgroundColor(this.toggleBackground(this.regex, 'regex'))
          .onHover((hover: boolean): void => { this.hoveredAction = hover ? 'regex' : ''; })
          .onClick((): void => { this.onToggleRegex(); })
          .accessibilityText(this.regex ? '正则表达式，已开启' : '正则表达式，已关闭')
        Text(this.validationMessage)
          .layoutWeight(1)
          .fontSize(10)
          .fontColor('#FF8585')
          .textAlign(TextAlign.End)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 9, bottom: 9 })
    .borderRadius(12)
    .border({ width: 1, color: 'rgba(255,255,255,0.12)' })
    .backgroundColor('rgba(20,25,33,0.96)')
    .shadow({ radius: 18, color: 'rgba(0,0,0,0.42)', offsetY: 6 })
  }
}
