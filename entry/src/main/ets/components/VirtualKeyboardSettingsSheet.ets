import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import {
  RemoteCustomShortcut,
  RemoteCustomShortcutKeyGroup,
  RemoteCustomShortcutKeyOption,
  RemoteCustomShortcutUpdate,
  remoteCustomShortcutKeyGroupForKeyCode,
  remoteCustomShortcutKeyOptions,
  remoteCustomShortcutLabelForPlatform,
  removeRemoteCustomShortcut,
  upsertRemoteCustomShortcut
} from '../services/RemoteCustomShortcutPolicy';
import {
  normalizeRemoteShortcutPlatform,
  RemoteKeyboardPreferences,
  RemoteShortcutPlatform
} from '../services/RemoteKeyboardSettingsPolicy';
import {
  RemoteKeyboardSettingsService,
  RemoteSystemInputMethodInfo,
  RemoteSystemInputMethodSnapshot
} from '../services/RemoteKeyboardSettingsService';

@Component
export struct VirtualKeyboardSettingsSheet {
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageLink('currentTheme') theme: string = 'dark';
  @State private platformMode: string = 'windows';
  @State private simpleKeyboardEnabled: boolean = false;
  @State private functionKeysVisible: boolean = true;
  @State private closeAfterShortcut: boolean = false;
  @State private systemSnapshot: RemoteSystemInputMethodSnapshot = {
    available: false, currentLabel: '', currentSubtype: '', methods: [], error: ''
  };
  @State private systemLoading: boolean = false;
  @State private customShortcuts: Array<RemoteCustomShortcut> = [];
  @State private editorVisible: boolean = false;
  @State private editingId: string = '';
  @State private modifierCodes: Array<number> = [];
  @State private actionGroup: RemoteCustomShortcutKeyGroup = 'letters';
  @State private actionKeyCode: number = 2017;
  private customSequence: number = 0;
  private readonly service: RemoteKeyboardSettingsService =
    RemoteKeyboardSettingsService.getInstance();
  onClose: () => void = (): void => {};

  private dark(): boolean { return this.theme === 'dark'; }
  private bg(): string { return this.dark() ? '#171A20' : '#F7F8FA'; }
  private card(): string { return this.dark() ? 'rgba(255,255,255,0.06)' : '#FFFFFF'; }
  private cardStroke(): string {
    return this.dark() ? 'rgba(255,255,255,0.10)' : 'rgba(18,24,36,0.08)';
  }
  private text(): string { return this.dark() ? '#F5F7FA' : '#18202B'; }
  private text2(): string { return this.dark() ? 'rgba(245,247,250,0.66)' : '#667085'; }
  private danger(): string { return '#FF6B6B'; }

  aboutToAppear(): void {
    const context: common.Context = getContext(this) as common.Context;
    const values: RemoteKeyboardPreferences = this.service.init(context);
    this.platformMode = values.shortcutPlatform;
    this.simpleKeyboardEnabled = values.simpleKeyboardEnabled;
    this.functionKeysVisible = values.functionKeysVisible;
    this.closeAfterShortcut = values.closePanelAfterShortcut;
    this.customShortcuts = this.service.loadCustomShortcuts(context);
    this.refreshSystemInputMethods();
  }

  private platform(): RemoteShortcutPlatform {
    return normalizeRemoteShortcutPlatform(this.platformMode);
  }

  private savePreferences(): void {
    const values: RemoteKeyboardPreferences = {
      shortcutPlatform: this.platform(),
      simpleKeyboardEnabled: this.simpleKeyboardEnabled,
      functionKeysVisible: this.functionKeysVisible,
      closePanelAfterShortcut: this.closeAfterShortcut
    };
    if (!this.service.savePreferences(values, getContext(this) as common.Context)) {
      promptAction.showToast({ message: '虚拟键盘设置保存失败', duration: 2000 });
    }
  }

  private selectPlatform(platform: RemoteShortcutPlatform): void {
    this.platformMode = platform;
    this.savePreferences();
  }

  private refreshSystemInputMethods(): void {
    if (this.systemLoading) { return; }
    this.systemLoading = true;
    this.service.readSystemInputMethods().then((snapshot: RemoteSystemInputMethodSnapshot): void => {
      this.systemSnapshot = snapshot;
      this.systemLoading = false;
    }).catch((_error: Error): void => {
      this.systemLoading = false;
      this.systemSnapshot = {
        available: false,
        currentLabel: '',
        currentSubtype: '',
        methods: [],
        error: '读取系统输入法失败'
      };
    });
  }

  private openSystemSettings(): void {
    const opened: boolean = this.service.openSystemInputMethodSettings(
      getContext(this) as common.UIAbilityContext);
    if (!opened) {
      promptAction.showToast({ message: '无法打开系统输入法设置', duration: 2000 });
    }
  }

  private openInputMethodDetail(method: RemoteSystemInputMethodInfo): void {
    const opened: boolean = this.service.openSystemInputMethodDetail(
      getContext(this) as common.UIAbilityContext, method);
    if (!opened) {
      promptAction.showToast({ message: '无法打开该输入法详情', duration: 2000 });
    }
  }

  private modifierActive(keyCode: number): boolean {
    return this.modifierCodes.indexOf(keyCode) >= 0;
  }

  private toggleModifier(keyCode: number): void {
    const next: Array<number> = this.modifierCodes.slice(0);
    const index: number = next.indexOf(keyCode);
    if (index >= 0) { next.splice(index, 1); } else { next.push(keyCode); }
    this.modifierCodes = next;
  }

  private draftKeyCodes(): Array<number> {
    const result: Array<number> = this.modifierCodes.slice(0);
    result.push(this.actionKeyCode);
    return result;
  }

  private draftLabel(): string {
    return remoteCustomShortcutLabelForPlatform(this.draftKeyCodes(), this.platform());
  }

  private groupLabel(group: RemoteCustomShortcutKeyGroup): string {
    if (group === 'letters') { return '字母'; }
    if (group === 'digits') { return '数字'; }
    if (group === 'symbols') { return '符号'; }
    if (group === 'functions') { return 'F 键'; }
    return '导航';
  }

  private beginEditor(shortcut: RemoteCustomShortcut | null = null): void {
    this.editorVisible = true;
    this.editingId = shortcut === null ? '' : shortcut.id;
    this.modifierCodes = shortcut === null ? [] :
      shortcut.keyCodes.slice(0, Math.max(0, shortcut.keyCodes.length - 1));
    this.actionKeyCode = shortcut === null || shortcut.keyCodes.length === 0 ?
      2017 : shortcut.keyCodes[shortcut.keyCodes.length - 1];
    this.actionGroup = remoteCustomShortcutKeyGroupForKeyCode(this.actionKeyCode);
  }

  private closeEditor(): void {
    this.editorVisible = false;
    this.editingId = '';
    this.modifierCodes = [];
    this.actionGroup = 'letters';
    this.actionKeyCode = 2017;
  }

  private saveCustomShortcut(): void {
    const id: string = this.editingId.length > 0 ? this.editingId :
      'shortcut-settings-' + Date.now().toString() + '-' + (++this.customSequence).toString();
    const update: RemoteCustomShortcutUpdate =
      upsertRemoteCustomShortcut(this.customShortcuts, id, this.draftKeyCodes());
    if (!update.accepted) {
      promptAction.showToast({ message: update.reason, duration: 1800 });
      return;
    }
    if (!this.service.saveCustomShortcuts(update.shortcuts, getContext(this) as common.Context)) {
      promptAction.showToast({ message: '自定义组合键保存失败', duration: 2000 });
      return;
    }
    this.customShortcuts = update.shortcuts;
    this.closeEditor();
  }

  private deleteCustomShortcut(id: string): void {
    const next: Array<RemoteCustomShortcut> = removeRemoteCustomShortcut(this.customShortcuts, id);
    if (this.service.saveCustomShortcuts(next, getContext(this) as common.Context)) {
      this.customShortcuts = next;
    }
  }

  @Builder
  private sectionTitle(title: string, subtitle: string) {
    Column({ space: 3 }) {
      Text(title).fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.text()).width('100%')
      Text(subtitle).fontSize(10).fontColor(this.text2()).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).margin({ top: 18, bottom: 8 })
  }

  @Builder
  private switchRow(title: string, subtitle: string, enabled: boolean,
    onChange: (enabled: boolean) => void) {
    Row() {
      Column({ space: 3 }) {
        Text(title).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.text())
        Text(subtitle).fontSize(10).fontColor(this.text2()).maxLines(2)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: enabled })
        .selectedColor(this.accentColor).onChange(onChange)
    }.width('100%').padding(14).backgroundColor(this.card())
      .border({ width: 0.5, color: this.cardStroke() })
  }

  @Builder
  private infoRow(title: string, value: string) {
    Row() {
      Text(title).fontSize(12).fontColor(this.text2()).layoutWeight(1)
      Text(value).fontSize(12).fontColor(this.text()).maxLines(2)
        .textAlign(TextAlign.End)
    }.width('100%').padding({ left: 14, right: 14, top: 12, bottom: 12 })
      .backgroundColor(this.card()).border({ width: 0.5, color: this.cardStroke() })
  }

  @Builder
  private platformChoice(platform: RemoteShortcutPlatform, label: string, subtitle: string) {
    Button() {
      Column({ space: 2 }) {
        Text(label).fontSize(13).fontWeight(FontWeight.Bold)
          .fontColor(this.platform() === platform ? '#FFFFFF' : this.text())
        Text(subtitle).fontSize(9)
          .fontColor(this.platform() === platform ? 'rgba(255,255,255,0.78)' : this.text2())
      }
    }.layoutWeight(1).height(58).borderRadius(12)
      .backgroundColor(this.platform() === platform ? this.accentColor : this.card())
      .border({ width: 1, color: this.platform() === platform ? this.accentColor : this.cardStroke() })
      .onClick((): void => { this.selectPlatform(platform); })
  }

  @Builder
  private inputMethodRow(method: RemoteSystemInputMethodInfo) {
    Row() {
      Column({ space: 3 }) {
        Row({ space: 6 }) {
          Text(method.label).fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.text())
          if (method.current) {
            Text('当前').fontSize(8).fontColor('#FFFFFF')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(5).backgroundColor(this.accentColor)
          }
          if (!method.enabled) {
            Text('未启用').fontSize(8).fontColor(this.text2())
          }
        }
        Text(method.subtypeSummary.length > 0 ? method.subtypeSummary : method.bundleName)
          .fontSize(9).fontColor(this.text2()).maxLines(2)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([this.text2()])
    }
    .width('100%').padding(14).backgroundColor(this.card())
    .border({ width: 0.5, color: this.cardStroke() })
    .onClick((): void => { this.openInputMethodDetail(method); })
    .accessibilityText('打开 ' + method.label + ' 输入法详情')
  }

  @Builder
  private modifierChoice(label: string, keyCode: number) {
    Button(label).height(34).layoutWeight(1).fontSize(10).borderRadius(8)
      .fontColor(this.modifierActive(keyCode) ? '#FFFFFF' : this.text2())
      .backgroundColor(this.modifierActive(keyCode) ? this.accentColor : this.card())
      .onClick((): void => { this.toggleModifier(keyCode); })
  }

  @Builder
  private groupChoice(group: RemoteCustomShortcutKeyGroup) {
    Text(this.groupLabel(group)).height(30).layoutWeight(1).fontSize(9)
      .textAlign(TextAlign.Center).borderRadius(8)
      .fontColor(this.actionGroup === group ? '#FFFFFF' : this.text2())
      .backgroundColor(this.actionGroup === group ? this.accentColor : this.card())
      .onClick((): void => {
        this.actionGroup = group;
        const options: Array<RemoteCustomShortcutKeyOption> = remoteCustomShortcutKeyOptions(group);
        if (options.length > 0) { this.actionKeyCode = options[0].keyCode; }
      })
  }

  @Builder
  private actionChoice(option: RemoteCustomShortcutKeyOption) {
    Text(option.label).height(30).width('100%').fontSize(9).textAlign(TextAlign.Center)
      .borderRadius(7)
      .fontColor(this.actionKeyCode === option.keyCode ? '#FFFFFF' : this.text2())
      .backgroundColor(this.actionKeyCode === option.keyCode ? this.accentColor : this.card())
      .onClick((): void => { this.actionKeyCode = option.keyCode; })
  }

  @Builder
  private customEditor() {
    Column({ space: 8 }) {
      Row() {
        Text(this.editingId.length > 0 ? '编辑组合键' : '新建组合键')
          .fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.text()).layoutWeight(1)
        Button('取消').height(32).fontSize(10).backgroundColor(Color.Transparent)
          .fontColor(this.text2()).onClick((): void => { this.closeEditor(); })
      }.width('100%')
      Row({ space: 5 }) {
        this.modifierChoice('Ctrl', 2072)
        this.modifierChoice(this.platform() === 'macos' ? 'Option' : 'Alt', 2045)
        this.modifierChoice('Shift', 2047)
        this.modifierChoice(this.platform() === 'macos' ? 'Cmd' : 'Win', 2076)
      }.width('100%')
      Row({ space: 4 }) {
        this.groupChoice('letters')
        this.groupChoice('digits')
        this.groupChoice('symbols')
        this.groupChoice('functions')
        this.groupChoice('navigation')
      }.width('100%')
      Grid() {
        ForEach(remoteCustomShortcutKeyOptions(this.actionGroup),
          (option: RemoteCustomShortcutKeyOption): void => {
            GridItem() { this.actionChoice(option) }
          }, (option: RemoteCustomShortcutKeyOption): string => option.keyCode.toString())
      }.columnsTemplate('1fr 1fr 1fr 1fr 1fr').rowsGap(4).columnsGap(4)
        .width('100%').height(132).scrollBar(BarState.Auto)
      Row() {
        Text(this.draftLabel().length > 0 ? this.draftLabel() : '请选择修饰键和主键')
          .fontSize(11).fontColor(this.draftLabel().length > 0 ? this.text() : this.danger())
          .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Button('保存').height(34).fontSize(11).borderRadius(9)
          .backgroundColor(this.draftLabel().length > 0 ? this.accentColor : this.card())
          .fontColor(this.draftLabel().length > 0 ? '#FFFFFF' : this.text2())
          .enabled(this.draftLabel().length > 0)
          .onClick((): void => { this.saveCustomShortcut(); })
      }.width('100%')
    }.width('100%').padding(14).borderRadius(14).backgroundColor(this.card())
      .border({ width: 0.5, color: this.cardStroke() })
  }

  @Builder
  private customShortcutList() {
    Column({ space: 6 }) {
      Row() {
        Text(this.customShortcuts.length.toString() + ' / 32')
          .fontSize(10).fontColor(this.text2()).layoutWeight(1)
        Button('＋ 新建').height(34).fontSize(11).borderRadius(9)
          .backgroundColor(this.accentColor).fontColor('#FFFFFF')
          .onClick((): void => { this.beginEditor(); })
      }.width('100%')
      if (this.customShortcuts.length === 0) {
        Text('尚未保存自定义组合键')
          .width('100%').height(58).fontSize(11).textAlign(TextAlign.Center)
          .fontColor(this.text2()).backgroundColor(this.card()).borderRadius(12)
      } else {
        ForEach(this.customShortcuts, (shortcut: RemoteCustomShortcut): void => {
          Row() {
            Text(remoteCustomShortcutLabelForPlatform(shortcut.keyCodes, this.platform()))
              .fontSize(12).fontColor(this.text()).layoutWeight(1)
            Button('编辑').height(32).fontSize(10).backgroundColor(Color.Transparent)
              .fontColor(this.accentColor).onClick((): void => { this.beginEditor(shortcut); })
            Button('删除').height(32).fontSize(10).backgroundColor(Color.Transparent)
              .fontColor(this.danger()).onClick((): void => { this.deleteCustomShortcut(shortcut.id); })
          }.width('100%').padding({ left: 14, right: 6, top: 6, bottom: 6 })
            .backgroundColor(this.card()).border({ width: 0.5, color: this.cardStroke() })
        }, (shortcut: RemoteCustomShortcut): string => shortcut.id)
      }
    }.width('100%')
  }

  build() {
    Column() {
      Row() {
        Column({ space: 3 }) {
          Text('虚拟键盘').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.text())
          Text('HarmonyOS 输入法、组合键、功能键与自定义')
            .fontSize(10).fontColor(this.text2())
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button() {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.text()])
        }.width(44).height(44).padding(0).borderRadius(12).backgroundColor(this.card())
          .onClick((): void => { this.onClose(); }).accessibilityText('关闭虚拟键盘设置')
      }.width('100%').padding({ left: 20, right: 14, top: 14, bottom: 8 })

      Scroll() {
        Column() {
          this.sectionTitle('HarmonyOS 官方输入法',
            'API 23 可读取输入法与语言子类型；启用、切换、词典、语音和按键反馈由系统输入法设置管理。')
          Row({ space: 8 }) {
            Button(this.systemLoading ? '正在刷新…' : '刷新状态')
              .layoutWeight(1).height(40).fontSize(11).borderRadius(10)
              .backgroundColor(this.card()).fontColor(this.text())
              .enabled(!this.systemLoading).onClick((): void => { this.refreshSystemInputMethods(); })
            Button('打开系统输入法设置').layoutWeight(2).height(40).fontSize(11)
              .borderRadius(10).backgroundColor(this.accentColor).fontColor('#FFFFFF')
              .onClick((): void => { this.openSystemSettings(); })
          }.width('100%').margin({ bottom: 8 })
          if (this.systemSnapshot.available) {
            this.infoRow('当前输入法', this.systemSnapshot.currentLabel)
            this.infoRow('当前语言/子类型', this.systemSnapshot.currentSubtype)
            ForEach(this.systemSnapshot.methods, (method: RemoteSystemInputMethodInfo): void => {
              this.inputMethodRow(method)
            }, (method: RemoteSystemInputMethodInfo): string =>
              method.bundleName + ':' + method.inputMethodId)
          } else if (!this.systemLoading) {
            this.infoRow('系统输入法状态', '当前设备未返回可用信息')
          }

          this.sectionTitle('系统键盘行为', '以下设置作用于连接中的 HarmonyOS 虚拟键盘。')
          this.switchRow('精简键盘模式', '调用 HarmonyOS API 23 setSimpleKeyboardEnabled，减少非必要扩展区域',
            this.simpleKeyboardEnabled, (enabled: boolean): void => {
              this.simpleKeyboardEnabled = enabled; this.savePreferences();
            })
          this.infoRow('输入类型', '普通文本')
          this.infoRow('回车键行为', '发送 Enter')
          this.infoRow('候选预编辑', '兼容模式：候选确认后再发送')
          this.infoRow('唤起与关闭', '由连接侧栏显式控制')

          this.sectionTitle('组合键与功能键', '连接侧栏中的面板可随时在 Windows 与 macOS 目录间切换。')
          Row({ space: 8 }) {
            this.platformChoice('windows', 'Windows', 'Ctrl / Alt / Win')
            this.platformChoice('macos', 'macOS', 'Control / Option / Cmd')
          }.width('100%').margin({ bottom: 8 })
          this.switchRow('显示完整功能键页',
            'F1–F12、方向与导航、Delete/Backspace、锁定键、PrtSc、Pause 与 Menu',
            this.functionKeysVisible, (enabled: boolean): void => {
              this.functionKeysVisible = enabled; this.savePreferences();
            })
          this.switchRow('发送后自动关闭面板', '适合一次性快捷键；关闭时可连续发送多个组合键',
            this.closeAfterShortcut, (enabled: boolean): void => {
              this.closeAfterShortcut = enabled; this.savePreferences();
            })

          this.sectionTitle('自定义组合键', '支持 Ctrl/Control、Alt/Option、Shift、Win/Cmd 与字母、数字、符号、F 键和导航键。')
          if (this.editorVisible) { this.customEditor() } else { this.customShortcutList() }
          Column().height(36)
        }.width('100%').padding({ left: 20, right: 20 })
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
    }.width('100%').height('100%').backgroundColor(this.bg())
  }
}
