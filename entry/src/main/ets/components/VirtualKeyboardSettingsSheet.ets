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
import { VirtualKeyboardSettingsSection } from '../services/SettingsSheetRoutePolicy';

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
  @Prop requestedSection: VirtualKeyboardSettingsSection = 'system';
  private customSequence: number = 0;
  private readonly service: RemoteKeyboardSettingsService =
    RemoteKeyboardSettingsService.getInstance();
  onClose: () => void = (): void => {};

  private dark(): boolean { return this.theme === 'dark'; }
  private bg(): string { return this.dark() ? '#11141A' : '#F4F6F9'; }
  private card(): string { return this.dark() ? 'rgba(255,255,255,0.075)' : '#FFFFFF'; }
  private cardStroke(): string {
    return this.dark() ? 'rgba(255,255,255,0.10)' : 'rgba(18,24,36,0.08)';
  }
  private text(): string { return this.dark() ? '#F5F7FA' : '#18202B'; }
  private text2(): string { return this.dark() ? 'rgba(245,247,250,0.66)' : '#667085'; }
  private accentSoft(): string {
    return this.dark() ? 'rgba(0,125,255,0.18)' : 'rgba(0,125,255,0.09)';
  }
  private danger(): string { return '#FF6B6B'; }

  aboutToAppear(): void {
    const context: common.Context = getContext(this) as common.Context;
    const values: RemoteKeyboardPreferences = this.service.init(context);
    this.platformMode = values.shortcutPlatform;
    this.simpleKeyboardEnabled = values.simpleKeyboardEnabled;
    this.functionKeysVisible = values.functionKeysVisible;
    this.closeAfterShortcut = values.closePanelAfterShortcut;
    this.customShortcuts = this.service.loadCustomShortcuts(context);
    if (this.requestedSection === 'system') { this.refreshSystemInputMethods(); }
  }

  private pageTitle(): string {
    if (this.requestedSection === 'behavior') { return '输入行为'; }
    if (this.requestedSection === 'shortcuts') { return '快捷键平台'; }
    if (this.requestedSection === 'functions') { return '功能键与面板'; }
    if (this.requestedSection === 'custom') { return '自定义组合键'; }
    return '系统输入法';
  }

  private pageSubtitle(): string {
    if (this.requestedSection === 'behavior') {
      return '控制连接中 HarmonyOS 软键盘的文本输入方式';
    }
    if (this.requestedSection === 'shortcuts') {
      return '设置组合键目录与修饰键的默认显示语义';
    }
    if (this.requestedSection === 'functions') {
      return '分别管理功能键入口与组合键面板的发送行为';
    }
    if (this.requestedSection === 'custom') {
      return '创建可在所有远程连接中复用的快捷组合';
    }
    return '查看当前输入法，并进入 HarmonyOS 官方设置';
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
    }.width('100%').alignItems(HorizontalAlign.Start).margin({ top: 20, bottom: 10 })
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
    }.width('100%').padding(16).borderRadius(16).backgroundColor(this.card())
      .border({ width: 0.5, color: this.cardStroke() })
  }

  @Builder
  private infoRow(title: string, value: string) {
    Row() {
      Text(title).fontSize(12).fontColor(this.text2()).layoutWeight(1)
      Text(value).fontSize(12).fontColor(this.text()).maxLines(2)
        .textAlign(TextAlign.End)
    }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .borderRadius(14).backgroundColor(this.card())
      .border({ width: 0.5, color: this.cardStroke() })
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
  private editorPlatformChoice(platform: RemoteShortcutPlatform, label: string) {
    Button() {
      Row({ space: 6 }) {
        Text(label).fontSize(11).fontWeight(FontWeight.Medium)
          .fontColor(this.platform() === platform ? '#FFFFFF' : this.text2())
        if (this.platform() === platform) {
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(12).fontColor(['#FFFFFF'])
        }
      }.justifyContent(FlexAlign.Center)
    }
    .layoutWeight(1).height(38).borderRadius(10)
    .backgroundColor(this.platform() === platform ? this.accentColor : this.card())
    .border({ width: 1, color: this.platform() === platform ? this.accentColor : this.cardStroke() })
    .onClick((): void => { this.selectPlatform(platform); })
    .accessibilityText('切换到' + label + '组合键')
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
    .width('100%').padding(14).borderRadius(14).backgroundColor(this.card())
    .border({ width: 0.5, color: this.cardStroke() }).margin({ bottom: 6 })
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
        const options: Array<RemoteCustomShortcutKeyOption> =
          remoteCustomShortcutKeyOptions(group, this.platform());
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
      Row({ space: 6 }) {
        this.editorPlatformChoice('windows', 'Windows · Ctrl')
        this.editorPlatformChoice('macos', 'macOS · Cmd')
      }.width('100%')
      Row({ space: 5 }) {
        if (this.platform() === 'macos') {
          this.modifierChoice('Cmd', 2076)
          this.modifierChoice('Option', 2045)
          this.modifierChoice('Shift', 2047)
          this.modifierChoice('Control', 2072)
        } else {
          this.modifierChoice('Ctrl', 2072)
          this.modifierChoice('Alt', 2045)
          this.modifierChoice('Shift', 2047)
          this.modifierChoice('Win', 2076)
        }
      }.width('100%')
      Row({ space: 4 }) {
        this.groupChoice('letters')
        this.groupChoice('digits')
        this.groupChoice('symbols')
        this.groupChoice('functions')
        this.groupChoice('navigation')
      }.width('100%')
      Grid() {
        ForEach(remoteCustomShortcutKeyOptions(this.actionGroup, this.platform()),
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

  @Builder
  private pageHero(section: VirtualKeyboardSettingsSection, eyebrow: string) {
    Row({ space: 14 }) {
      Row() {
        SymbolGlyph($r('sys.symbol.keyboard')).fontSize(23).fontColor([this.accentColor])
      }.width(48).height(48).justifyContent(FlexAlign.Center)
        .borderRadius(15).backgroundColor(this.accentSoft())
      Column({ space: 4 }) {
        Text(eyebrow).fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.text())
        if (section === 'behavior') {
          Text(this.simpleKeyboardEnabled ? '精简键盘已开启' : '完整键盘已开启')
            .fontSize(10).fontColor(this.text2()).maxLines(2)
        } else if (section === 'shortcuts') {
          Text(this.platform() === 'macos' ? 'macOS · Cmd / Option' : 'Windows · Ctrl / Alt / Win')
            .fontSize(10).fontColor(this.text2()).maxLines(2)
        } else if (section === 'functions') {
          Text((this.functionKeysVisible ? '完整功能键' : '精简功能键') + ' · ' +
            (this.closeAfterShortcut ? '发送后关闭' : '连续发送'))
            .fontSize(10).fontColor(this.text2()).maxLines(2)
        } else if (section === 'custom') {
          Text(this.customShortcuts.length.toString() + ' 个已保存 · 上限 32 个')
            .fontSize(10).fontColor(this.text2()).maxLines(2)
        } else {
          Text(this.systemLoading ? '正在读取系统输入法状态' :
            (this.systemSnapshot.available ? '当前：' + this.systemSnapshot.currentLabel : '由系统统一管理'))
            .fontSize(10).fontColor(this.text2()).maxLines(2)
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }.width('100%').padding(16).borderRadius(20).backgroundColor(this.card())
      .border({ width: 0.5, color: this.cardStroke() })
  }

  @Builder
  private systemInputMethodContent() {
    this.pageHero('system', 'HarmonyOS 官方输入法')
    this.sectionTitle('输入法状态', '应用只读取公开状态，不会绕过系统权限切换输入法。')
    Row({ space: 8 }) {
      Button(this.systemLoading ? '正在刷新…' : '刷新状态')
        .layoutWeight(1).height(42).fontSize(11).borderRadius(12)
        .backgroundColor(this.card()).fontColor(this.text())
        .enabled(!this.systemLoading).onClick((): void => { this.refreshSystemInputMethods(); })
      Button('系统输入法设置').layoutWeight(2).height(42).fontSize(11)
        .borderRadius(12).backgroundColor(this.accentColor).fontColor('#FFFFFF')
        .onClick((): void => { this.openSystemSettings(); })
    }.width('100%').margin({ bottom: 10 })
    if (this.systemSnapshot.available) {
      Column({ space: 6 }) {
        this.infoRow('当前输入法', this.systemSnapshot.currentLabel)
        this.infoRow('语言 / 子类型', this.systemSnapshot.currentSubtype)
      }.width('100%')
      this.sectionTitle('已安装输入法', '点按任一输入法可打开对应的系统详情页。')
      ForEach(this.systemSnapshot.methods, (method: RemoteSystemInputMethodInfo): void => {
        this.inputMethodRow(method)
      }, (method: RemoteSystemInputMethodInfo): string =>
        method.bundleName + ':' + method.inputMethodId)
    } else if (!this.systemLoading) {
      this.infoRow('系统输入法状态',
        this.systemSnapshot.error.length > 0 ? this.systemSnapshot.error : '当前设备未返回可用信息')
    }
  }

  @Builder
  private inputBehaviorContent() {
    this.pageHero('behavior', '连接输入约定')
    this.sectionTitle('键盘布局', '此行为仅影响连接中唤起的 HarmonyOS 软键盘。')
    this.switchRow('精简键盘模式',
      '使用 HarmonyOS API 23 减少软键盘中的非必要扩展区域',
      this.simpleKeyboardEnabled, (enabled: boolean): void => {
        this.simpleKeyboardEnabled = enabled;
        this.savePreferences();
      })
    this.sectionTitle('文本发送规则', '这些兼容规则用于避免预编辑文字和远端按键重复。')
    Column({ space: 6 }) {
      this.infoRow('输入类型', '普通文本')
      this.infoRow('回车键', '发送 Enter')
      this.infoRow('候选预编辑', '确认候选后发送')
      this.infoRow('键盘唤起 / 收起', '由连接侧栏显式控制')
    }.width('100%')
  }

  @Builder
  private shortcutPlatformContent() {
    this.pageHero('shortcuts', '默认快捷键目录')
    this.sectionTitle('平台语义', '设置默认目录；连接中的组合键面板仍可随时切换。')
    Row({ space: 10 }) {
      this.platformChoice('windows', 'Windows', '通用键：Ctrl')
      this.platformChoice('macos', 'macOS', '通用键：Cmd')
    }.width('100%')
    this.sectionTitle('映射说明', '切换平台只改变快捷键名称与组合目录，不会修改远端系统。')
    Column({ space: 6 }) {
      this.infoRow('Windows 通用组合', 'Ctrl+C / Ctrl+V / Ctrl+Z')
      this.infoRow('macOS 通用组合', 'Cmd+C / Cmd+V / Cmd+Z')
      this.infoRow('macOS Control', '仅保留调度中心、空间切换等系统键')
      this.infoRow('会话内切换', '即时生效，可自由往返')
    }.width('100%')
  }

  @Builder
  private functionPanelContent() {
    this.pageHero('functions', '功能键与面板行为')
    this.sectionTitle('功能键目录', '单独控制扩展功能键是否出现在连接面板。')
    this.switchRow('显示完整功能键页',
      '包含 F1–F12、方向与导航、Delete、锁定键、PrtSc、Pause 和 Menu',
      this.functionKeysVisible, (enabled: boolean): void => {
        this.functionKeysVisible = enabled;
        this.savePreferences();
      })
    this.sectionTitle('面板发送行为', '面板关闭行为与功能键可见性互不影响。')
    this.switchRow('发送后自动关闭面板',
      '适合一次性快捷键；关闭此项后可连续发送多个组合键',
      this.closeAfterShortcut, (enabled: boolean): void => {
        this.closeAfterShortcut = enabled;
        this.savePreferences();
      })
    this.sectionTitle('触控约定', '连接中的浮层只拦截自身覆盖区域。')
    Column({ space: 6 }) {
      this.infoRow('面板覆盖区域', '阻止触控透传')
      this.infoRow('面板以外区域', '连接仍可正常触控')
      this.infoRow('位置调整', '拖动面板标题栏')
    }.width('100%')
  }

  @Builder
  private customShortcutContent() {
    this.pageHero('custom', '可复用组合键')
    this.sectionTitle('自定义组合键',
      '支持修饰键与字母、数字、符号、F 键、方向键及导航键。')
    this.infoRow('当前标签平台', this.platform() === 'macos' ? 'macOS' : 'Windows')
    Column().height(8)
    if (this.editorVisible) { this.customEditor() } else { this.customShortcutList() }
  }

  build() {
    Column() {
      Row() {
        Column({ space: 3 }) {
          Text('虚拟键盘设置').fontSize(10).fontWeight(FontWeight.Medium)
            .fontColor(this.accentColor)
          Text(this.pageTitle()).fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.text())
          Text(this.pageSubtitle()).fontSize(10).fontColor(this.text2()).maxLines(2)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button() {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.text()])
        }.width(42).height(42).padding(0).borderRadius(14).backgroundColor(this.card())
          .border({ width: 0.5, color: this.cardStroke() })
          .onClick((): void => { this.onClose(); }).accessibilityText('关闭虚拟键盘设置')
      }.width('100%').padding({ left: 20, right: 16, top: 16, bottom: 14 })

      Scroll() {
        Column() {
          if (this.requestedSection === 'behavior') {
            this.inputBehaviorContent()
          } else if (this.requestedSection === 'shortcuts') {
            this.shortcutPlatformContent()
          } else if (this.requestedSection === 'functions') {
            this.functionPanelContent()
          } else if (this.requestedSection === 'custom') {
            this.customShortcutContent()
          } else {
            this.systemInputMethodContent()
          }
          Column().height(28)
        }.width('100%').padding({ left: 20, right: 20 })
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
    }.width('100%').height('100%').backgroundColor(this.bg())
      .borderRadius({ topLeft: 28, topRight: 28 })
  }
}
