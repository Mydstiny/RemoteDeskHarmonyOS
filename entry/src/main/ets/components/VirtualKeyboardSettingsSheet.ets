import { common } from '@kit.AbilityKit';
import { AppSheetHeader } from './AppSheetHeader';
import { settingsVisualIsModern } from '../services/SettingsVisualStylePolicy';
import { appUiOnAccentText } from '../common/AppUiColorPolicy';
import { LengthMetrics, promptAction } from '@kit.ArkUI';
import {
  RemoteCustomShortcut,
  RemoteCustomShortcutKeyGroup,
  RemoteCustomShortcutKeyOption,
  RemoteCustomShortcutEditorLayout,
  RemoteCustomShortcutUpdate,
  remoteCustomShortcutEditorLayout,
  remoteCustomShortcutKeyGroupForKeyCode,
  remoteCustomShortcutKeyOptions,
  remoteCustomShortcutAvailableOnPlatform,
  remoteCustomShortcutKeyAvailableOnPlatform,
  remoteCustomShortcutLabelForPlatform,
  removeRemoteCustomShortcut,
  moveRemoteCustomShortcut,
  upsertRemoteCustomShortcutSteps,
  remoteCustomShortcutSteps,
  remoteCustomShortcutStepsLabel,
  remoteCustomShortcutDisplayName,
  REMOTE_CUSTOM_SHORTCUT_GROUPS,
  REMOTE_CUSTOM_SHORTCUT_MAX_STEPS,
  REMOTE_CUSTOM_SHORTCUT_NAME_MAX
} from '../services/RemoteCustomShortcutPolicy';
import { ProEntries } from '../services/pro/ProEntries';
import { PRO_PERSONALIZATION_FEATURE } from '../services/pro/ProFeatureCatalog';
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
import {
  VirtualKeyboardSettingsContentLayout,
  VirtualKeyboardSettingsSection,
  virtualKeyboardSettingsContentLayout
} from '../services/SettingsSheetRoutePolicy';
import { protocolIcon } from '../services/ProtocolIconPolicy';
import {
  defaultHarmonyShortcutBlockingPreferences,
  decodeHarmonyShortcutBlockingPreferences,
  encodeHarmonyShortcutBlockingPreferences,
  harmonyShortcutBlockingEnabled,
  harmonyShortcutDeviceClass,
  harmonyShortcutProtocolSelection,
  harmonyShortcutProtocols,
  HarmonyShortcutBlockingPreferences,
  HarmonyShortcutDeviceClass,
  HarmonyShortcutProtocol
} from '../services/HarmonyShortcutBlockingPolicy';

@Component
export struct VirtualKeyboardSettingsSheet {
  @StorageLink('accentColor') accentColor: string = '#007DFF';
  @StorageLink('currentTheme') theme: string = 'dark';
  @State private platformMode: string = 'windows';
  @State private simpleKeyboardEnabled: boolean = false;
  @State private functionKeysVisible: boolean = true;
  @State private closeAfterShortcut: boolean = false;
  @State private autoOpenOnRemoteClick: boolean = false;
  @State private systemSnapshot: RemoteSystemInputMethodSnapshot = {
    available: false, currentLabel: '', currentSubtype: '', methods: [], error: ''
  };
  @State private systemLoading: boolean = false;
  @State private customShortcuts: Array<RemoteCustomShortcut> = [];
  @State @Watch('reportEditorDirty') private editorVisible: boolean = false;
  @State private editingId: string = '';
  @State @Watch('reportEditorDirty') private modifierCodes: Array<number> = [];
  @State private actionGroup: RemoteCustomShortcutKeyGroup = 'letters';
  @State @Watch('reportEditorDirty') private actionKeyCode: number = 2017;
  // Completed steps of the sequence being edited; the modifier/key pickers edit step `activeStep`.
  @State @Watch('reportEditorDirty') private draftSteps: Array<Array<number>> = [];
  @State @Watch('reportEditorDirty') private activeStep: number = 0;
  @State @Watch('reportEditorDirty') private draftName: string = '';
  @State private recording: boolean = false;
  private recordModifiers: Array<number> = [];
  @State private viewportWidth: number = 360;
  @State private viewportHeight: number = 640;
  @State private harmonyShortcutBlocking: HarmonyShortcutBlockingPreferences =
    defaultHarmonyShortcutBlockingPreferences();
  @StorageProp('isDesktopDevice') private isDesktopDevice: boolean = false;
  @StorageProp('isPadDevice') private isPadDevice: boolean = false;
  @State private selectedHarmonyShortcutDevice: HarmonyShortcutDeviceClass = 'phone';
  @Prop requestedSection: VirtualKeyboardSettingsSection = 'system';
  private customSequence: number = 0;
  private readonly service: RemoteKeyboardSettingsService =
    RemoteKeyboardSettingsService.getInstance();
  onClose: () => void = (): void => {};
  onCustomEditorVisibleChange: (visible: boolean) => void = (_visible: boolean): void => {};
  /** 设置 → 个性化 → 全新视觉: the shared sheet header and descriptions of at least 12vp. */
  @StorageProp('settingsVisualStyle') visualStyle: string = 'modern';
  /** A new combo, or changes to the one being edited, that are not saved yet (closing the sheet asks first). */
  onCustomEditorDirtyChange: (dirty: boolean) => void = (_dirty: boolean): void => {};
  private editorStart: string = '';

  private dark(): boolean { return this.theme === 'dark'; }
  private modern(): boolean { return settingsVisualIsModern(this.visualStyle); }
  private bg(): string { return this.dark() ? '#1C1C1F' : '#F4F6F9'; }
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
    this.autoOpenOnRemoteClick = values.autoOpenOnRemoteClick;
    this.customShortcuts = this.service.loadCustomShortcuts(context);
    this.harmonyShortcutBlocking = this.service.loadHarmonyShortcutBlocking(context);
    this.selectedHarmonyShortcutDevice = harmonyShortcutDeviceClass(
      this.isDesktopDevice, this.isPadDevice);
    if (this.requestedSection === 'system') { this.refreshSystemInputMethods(); }
  }

  private pageTitle(): string {
    if (this.requestedSection === 'behavior') { return '输入行为'; }
    if (this.requestedSection === 'shortcuts') { return '快捷键平台'; }
    if (this.requestedSection === 'functions') { return '功能键与面板'; }
    if (this.requestedSection === 'custom') { return '自定义组合键'; }
    if (this.requestedSection === 'harmonyShortcuts') { return '屏蔽鸿蒙快捷键'; }
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
    if (this.requestedSection === 'harmonyShortcuts') {
      return '打开后本机屏蔽并发送远端；关闭后由鸿蒙处理';
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
      closePanelAfterShortcut: this.closeAfterShortcut,
      autoOpenOnRemoteClick: this.autoOpenOnRemoteClick
    };
    if (!this.service.savePreferences(values, getContext(this) as common.Context)) {
      promptAction.showToast({ message: '键盘设置保存失败', duration: 2000 });
    }
  }

  private selectPlatform(platform: RemoteShortcutPlatform): void {
    this.platformMode = platform;
    if (!remoteCustomShortcutKeyAvailableOnPlatform(this.actionKeyCode, platform)) {
      this.actionGroup = 'functions';
      this.actionKeyCode = 2090;
    }
    this.savePreferences();
  }

  private setHarmonyShortcutBlocking(
    deviceClass: HarmonyShortcutDeviceClass,
    protocol: HarmonyShortcutProtocol,
    enabled: boolean
  ): void {
    const before: string = encodeHarmonyShortcutBlockingPreferences(
      this.harmonyShortcutBlocking);
    const next: HarmonyShortcutBlockingPreferences | null =
      this.service.setHarmonyShortcutBlockingPreference(
        deviceClass, protocol, enabled, getContext(this) as common.Context);
    if (next === null) {
      this.harmonyShortcutBlocking = decodeHarmonyShortcutBlockingPreferences(before);
      promptAction.showToast({ message: '鸿蒙快捷键屏蔽设置保存失败', duration: 2000 });
      return;
    }
    this.harmonyShortcutBlocking = next;
  }

  private harmonyShortcutDeviceLabel(deviceClass: HarmonyShortcutDeviceClass): string {
    if (deviceClass === 'phone') { return '手机'; }
    if (deviceClass === 'pad') { return 'Pad'; }
    return 'PC';
  }

  private harmonyShortcutDeviceSubtitle(deviceClass: HarmonyShortcutDeviceClass): string {
    const selection = harmonyShortcutProtocolSelection(
      this.harmonyShortcutBlocking, deviceClass);
    let count: number = 0;
    if (selection.rdp) { count++; }
    if (selection.rustdesk) { count++; }
    if (selection.vnc) { count++; }
    if (selection.moonlight) { count++; }
    return count === 0 ? '未屏蔽任何协议' :
      (count === 4 ? '4 个协议均已屏蔽' : '已屏蔽 ' + count.toString() + ' 个协议');
  }

  private harmonyShortcutDeviceOptions(): HarmonyShortcutDeviceClass[] {
    return ['phone', 'pad', 'pc'];
  }

  private harmonyShortcutProtocolLabel(protocol: HarmonyShortcutProtocol): string {
    if (protocol === 'rdp') { return 'RDP'; }
    if (protocol === 'rustdesk') { return 'RustDesk'; }
    if (protocol === 'ssh') { return 'SSH'; }
    if (protocol === 'vnc') { return 'VNC'; }
    return 'Moonlight';
  }

  private harmonyShortcutProtocolStatus(
    deviceClass: HarmonyShortcutDeviceClass,
    protocol: HarmonyShortcutProtocol
  ): string {
    return harmonyShortcutBlockingEnabled(this.harmonyShortcutBlocking, deviceClass, protocol) ?
      '已屏蔽并发送远端' : '允许鸿蒙处理';
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
    result.push(remoteCustomShortcutKeyAvailableOnPlatform(
      this.actionKeyCode, this.platform()) ? this.actionKeyCode : 2090);
    return result;
  }

  /** All steps with the step under edit replaced by the live picker state. */
  private allDraftSteps(): Array<Array<number>> {
    const steps: Array<Array<number>> = this.draftSteps.map((step: Array<number>): Array<number> => step.slice(0));
    if (this.activeStep >= steps.length) { steps.push(this.draftKeyCodes()); } else { steps[this.activeStep] = this.draftKeyCodes(); }
    return steps;
  }

  private visibleCustomShortcuts(): Array<RemoteCustomShortcut> {
    return this.customShortcuts.filter((shortcut: RemoteCustomShortcut): boolean =>
      remoteCustomShortcutAvailableOnPlatform(shortcut, this.platform()));
  }

  private draftLabel(): string {
    return remoteCustomShortcutStepsLabel(this.allDraftSteps(), this.platform());
  }

  private stepLabel(index: number): string {
    const steps: Array<Array<number>> = this.allDraftSteps();
    return index < steps.length ? remoteCustomShortcutLabelForPlatform(steps[index], this.platform()) : '';
  }

  private stepIndexes(): Array<number> {
    const result: Array<number> = [];
    for (let index: number = 0; index < this.allDraftSteps().length; index++) { result.push(index); }
    return result;
  }

  private groupLabel(group: RemoteCustomShortcutKeyGroup): string {
    if (group === 'letters') { return '字母'; }
    if (group === 'digits') { return '数字'; }
    if (group === 'symbols') { return '符号'; }
    if (group === 'functions') { return 'F 键'; }
    if (group === 'directions') { return '方向'; }
    if (group === 'system') { return '系统键'; }
    if (group === 'numpad') { return '小键盘'; }
    return '导航';
  }

  private customEditorLayout(): RemoteCustomShortcutEditorLayout {
    return remoteCustomShortcutEditorLayout(this.viewportWidth, this.viewportHeight);
  }

  private contentLayout(): VirtualKeyboardSettingsContentLayout {
    return virtualKeyboardSettingsContentLayout(this.viewportWidth, this.viewportHeight);
  }

  /** Keep vertical gesture ownership on the outer sheet Scroll. */
  private customActionRows(): Array<Array<RemoteCustomShortcutKeyOption>> {
    const items: Array<RemoteCustomShortcutKeyOption> =
      remoteCustomShortcutKeyOptions(this.actionGroup, this.platform());
    const columns: number = this.customEditorLayout().columns;
    const rows: Array<Array<RemoteCustomShortcutKeyOption>> = [];
    for (let index: number = 0; index < items.length; index += columns) {
      rows.push(items.slice(index, Math.min(index + columns, items.length)));
    }
    return rows;
  }

  private customActionEmptyCells(itemCount: number): Array<number> {
    const result: Array<number> = [];
    const emptyCount: number = this.customEditorLayout().columns - itemCount;
    for (let index: number = 0; index < emptyCount; index++) { result.push(index); }
    return result;
  }

  private loadPicker(step: Array<number>): void {
    this.modifierCodes = step.slice(0, Math.max(0, step.length - 1));
    this.actionKeyCode = step.length === 0 ? 2017 : step[step.length - 1];
    this.actionGroup = remoteCustomShortcutKeyGroupForKeyCode(this.actionKeyCode);
  }

  private editorSnapshot(): string {
    return JSON.stringify([this.draftName, this.allDraftSteps()]);
  }

  private reportEditorDirty(): void {
    this.onCustomEditorDirtyChange(this.editorVisible && this.editorSnapshot() !== this.editorStart);
  }

  private beginEditor(shortcut: RemoteCustomShortcut | null = null): void {
    this.editorStart = '';
    this.editorVisible = true;
    this.onCustomEditorVisibleChange(true);
    this.editingId = shortcut === null ? '' : shortcut.id;
    this.draftName = shortcut === null ? '' : (shortcut.name ?? '');
    const steps: Array<Array<number>> = shortcut === null ? [[2072, 2017]] : remoteCustomShortcutSteps(shortcut);
    this.draftSteps = steps;
    this.activeStep = 0;
    this.recording = false;
    this.loadPicker(steps[0]);
    // Opening the editor changes nothing yet; only edits after this point count as unsaved.
    this.editorStart = this.editorSnapshot();
    this.reportEditorDirty();
  }

  /** Switch the picker to another step, keeping the edits of the current one. */
  private selectStep(index: number): void {
    const steps: Array<Array<number>> = this.allDraftSteps();
    this.draftSteps = steps;
    this.activeStep = Math.max(0, Math.min(index, steps.length - 1));
    this.loadPicker(steps[this.activeStep]);
  }

  private addStep(): void {
    const steps: Array<Array<number>> = this.allDraftSteps();
    if (steps.length >= REMOTE_CUSTOM_SHORTCUT_MAX_STEPS) { return; }
    steps.push([2072, 2017]);
    this.draftSteps = steps;
    this.activeStep = steps.length - 1;
    this.loadPicker(steps[this.activeStep]);
  }

  private removeStep(index: number): void {
    const steps: Array<Array<number>> = this.allDraftSteps();
    if (steps.length <= 1) { return; }
    steps.splice(index, 1);
    this.draftSteps = steps;
    this.activeStep = Math.min(this.activeStep, steps.length - 1);
    this.loadPicker(steps[this.activeStep]);
  }

  private closeEditor(): void {
    this.editorVisible = false;
    this.onCustomEditorVisibleChange(false);
    this.editingId = '';
    this.draftName = '';
    this.draftSteps = [];
    this.activeStep = 0;
    this.recording = false;
    this.modifierCodes = [];
    this.actionGroup = 'letters';
    this.actionKeyCode = 2017;
  }

  private persist(next: Array<RemoteCustomShortcut>): boolean {
    if (!this.service.saveCustomShortcuts(next, getContext(this) as common.Context)) {
      promptAction.showToast({ message: '自定义组合键保存失败', duration: 2000 });
      return false;
    }
    this.customShortcuts = next;
    return true;
  }

  private saveCustomShortcut(): void {
    const id: string = this.editingId.length > 0 ? this.editingId :
      'shortcut-settings-' + Date.now().toString() + '-' + (++this.customSequence).toString();
    const update: RemoteCustomShortcutUpdate =
      upsertRemoteCustomShortcutSteps(this.customShortcuts, id, this.draftName, this.allDraftSteps());
    if (!update.accepted) {
      promptAction.showToast({ message: update.reason, duration: 1800 });
      return;
    }
    if (this.persist(update.shortcuts)) { this.closeEditor(); }
  }

  private canAddShortcut(): boolean { return this.customShortcuts.length < 32; }

  private moveCustomShortcut(id: string, delta: number): void {
    this.persist(moveRemoteCustomShortcut(this.customShortcuts, id, delta));
  }

  /** Opens a copy in the editor as a new entry; an unchanged sequence would be rejected as a duplicate. */
  private duplicateCustomShortcut(shortcut: RemoteCustomShortcut): void {
    this.beginEditor(shortcut);
    this.editingId = '';
    const base: string = (shortcut.name ?? '').length > 0 ? (shortcut.name ?? '') : '副本';
    this.draftName = base.slice(0, REMOTE_CUSTOM_SHORTCUT_NAME_MAX - 2) + ' 2';
  }

  private deleteCustomShortcut(shortcut: RemoteCustomShortcut): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '删除组合键',
      message: '删除「' + remoteCustomShortcutDisplayName(shortcut, this.platform()) + '」？此操作不可撤销。',
      buttons: [{ text: '取消', color: this.text2() }, { text: '删除', color: this.danger() }]
    }).then((result): void => {
      if (result.index === 1) { this.persist(removeRemoteCustomShortcut(this.customShortcuts, shortcut.id)); }
    }).catch((): void => {});
  }

  /** Physical keyboard recording: modifiers are collected, the first other key completes the step. */
  private recordKey(event: KeyEvent): boolean {
    if (!this.recording) { return false; }
    const code: number = event.keyCode === 2073 ? 2072 : event.keyCode === 2046 ? 2045 :
      event.keyCode === 2048 ? 2047 : event.keyCode === 2077 ? 2076 : event.keyCode;
    const modifier: boolean = code === 2072 || code === 2045 || code === 2047 || code === 2076;
    if (event.type === KeyType.Down) {
      if (modifier) {
        if (this.recordModifiers.indexOf(code) < 0) { this.recordModifiers.push(code); }
        return true;
      }
      const group: RemoteCustomShortcutKeyGroup = remoteCustomShortcutKeyGroupForKeyCode(code);
      const known: boolean = remoteCustomShortcutKeyOptions(group, this.platform())
        .some((option: RemoteCustomShortcutKeyOption): boolean => option.keyCode === code);
      if (known) {
        this.modifierCodes = this.recordModifiers.slice(0);
        this.actionKeyCode = code;
        this.actionGroup = group;
        this.recording = false;
      }
      return true;
    }
    if (modifier) { this.recordModifiers = this.recordModifiers.filter((item: number): boolean => item !== code); }
    return true;
  }

  @Builder
  private sectionTitle(title: string, subtitle: string) {
    Column({ space: 3 }) {
      Text(title).fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.text()).width('100%')
      Text(subtitle).fontSize(this.modern() ? 12 : 10).fontColor(this.text2()).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
      .margin({ top: this.contentLayout().sectionTopMargin, bottom: 10 })
  }

  @Builder
  private switchRow(title: string, subtitle: string, enabled: boolean,
    onChange: (enabled: boolean) => void) {
    Row() {
      Column({ space: 3 }) {
        Text(title).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.text())
        Text(subtitle).fontSize(this.modern() ? 12 : 10).fontColor(this.text2()).maxLines(2)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: enabled })
        .selectedColor(this.accentColor).onChange(onChange)
    }.width('100%').padding(this.contentLayout().cardPadding)
      .borderRadius(16).backgroundColor(this.card())
      .border({ width: 0.5, color: this.cardStroke() })
  }

  @Builder
  private infoRow(title: string, value: string) {
    Row() {
      Text(title).fontSize(12).fontColor(this.text2()).layoutWeight(1)
      Text(value).fontSize(12).fontColor(this.text()).maxLines(2)
        .textAlign(TextAlign.End)
    }.width('100%').padding({
      left: this.contentLayout().cardPadding,
      right: this.contentLayout().cardPadding,
      top: 14,
      bottom: 14
    })
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
            Text('当前').fontSize(8).fontColor(appUiOnAccentText(this.accentColor))
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(5).backgroundColor(this.accentColor)
          }
          if (!method.enabled) {
            Text('未启用').fontSize(8).fontColor(this.text2())
          }
        }
        Text(method.subtypeSummary.length > 0 ? method.subtypeSummary : method.bundleName)
          .fontSize(this.modern() ? 12 : 9).fontColor(this.text2()).maxLines(2)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([this.text2()])
    }
    .width('100%').padding(this.contentLayout().cardPadding)
    .borderRadius(14).backgroundColor(this.card())
    .border({ width: 0.5, color: this.cardStroke() }).margin({ bottom: 6 })
    .onClick((): void => { this.openInputMethodDetail(method); })
    .accessibilityText('打开 ' + method.label + ' 输入法详情')
  }

  @Builder
  private modifierChoice(label: string, keyCode: number) {
    Button(label).height(34).layoutWeight(1).fontSize(10).borderRadius(8)
      .fontColor(this.modifierActive(keyCode) ? appUiOnAccentText(this.accentColor) : this.text2())
      .backgroundColor(this.modifierActive(keyCode) ? this.accentColor : this.card())
      .onClick((): void => { this.toggleModifier(keyCode); })
  }

  @Builder
  private groupChoice(group: RemoteCustomShortcutKeyGroup) {
    Text(this.groupLabel(group)).height(30).layoutWeight(1).fontSize(9)
      .textAlign(TextAlign.Center).borderRadius(8)
      .fontColor(this.actionGroup === group ? appUiOnAccentText(this.accentColor) : this.text2())
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
    Text(option.label).height(this.customEditorLayout().itemHeight).width('100%')
      .fontSize(9).textAlign(TextAlign.Center)
      .borderRadius(7)
      .fontColor(this.actionKeyCode === option.keyCode ? appUiOnAccentText(this.accentColor) : this.text2())
      .backgroundColor(this.actionKeyCode === option.keyCode ? this.accentColor : this.card())
      .onClick((): void => { this.actionKeyCode = option.keyCode; })
  }

  @Builder
  private customActionRow(options: Array<RemoteCustomShortcutKeyOption>) {
    Row({ space: this.customEditorLayout().itemGap }) {
      ForEach(options, (option: RemoteCustomShortcutKeyOption): void => {
        Column() { this.actionChoice(option) }.layoutWeight(1)
      }, (option: RemoteCustomShortcutKeyOption): string => option.keyCode.toString())
      ForEach(this.customActionEmptyCells(options.length), (index: number): void => {
        Blank().height(this.customEditorLayout().itemHeight).layoutWeight(1)
      }, (index: number): string => index.toString())
    }.width('100%')
  }

  @Builder
  private stepChip(index: number) {
    Row({ space: 4 }) {
      Text((index + 1).toString()).fontSize(9).fontWeight(FontWeight.Bold)
        .fontColor(index === this.activeStep ? this.accentColor : '#FFFFFF')
        .width(16).height(16).textAlign(TextAlign.Center).borderRadius(8)
        .backgroundColor(index === this.activeStep ? '#FFFFFF' : this.text2())
      Text(this.stepLabel(index)).fontSize(10).maxLines(1)
        .fontColor(index === this.activeStep ? '#FFFFFF' : this.text())
      if (this.allDraftSteps().length > 1) {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(10)
          .fontColor([index === this.activeStep ? '#FFFFFF' : this.text2()])
          .onClick((): void => { this.removeStep(index); })
      }
    }.height(30).padding({ left: 6, right: 8 }).borderRadius(15)
      .backgroundColor(index === this.activeStep ? this.accentColor : this.card())
      .border({ width: 0.5, color: this.cardStroke() })
      .onClick((): void => { this.selectStep(index); })
  }

  @Builder
  private customEditor() {
    Column({ space: 10 }) {
      Row() {
        Text(this.editingId.length > 0 ? '编辑组合键' : '新建组合键')
          .fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.text()).layoutWeight(1)
        Button('取消').height(32).fontSize(11).backgroundColor(Color.Transparent)
          .fontColor(this.text2()).onClick((): void => { this.closeEditor(); })
      }.width('100%')
      TextInput({ text: this.draftName, placeholder: '名称（可选，例如「全部保存」）' })
        .height(38).fontSize(12).maxLength(REMOTE_CUSTOM_SHORTCUT_NAME_MAX)
        .backgroundColor(this.card()).borderRadius(10)
        .onChange((value: string): void => { this.draftName = value; })
      if (this.contentLayout().stackPrimaryActions) {
        Column({ space: 6 }) {
          Row() { this.editorPlatformChoice('windows', 'Windows · Ctrl') }.width('100%')
          Row() { this.editorPlatformChoice('macos', 'macOS · Cmd') }.width('100%')
        }.width('100%')
      } else {
        Row({ space: 6 }) {
          this.editorPlatformChoice('windows', 'Windows · Ctrl')
          this.editorPlatformChoice('macos', 'macOS · Cmd')
        }.width('100%')
      }
      Text('按键序列 · 依次发送，最多 ' + REMOTE_CUSTOM_SHORTCUT_MAX_STEPS.toString() + ' 步')
        .fontSize(this.modern() ? 12 : 10).fontColor(this.text2()).width('100%')
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(6), cross: LengthMetrics.vp(6) } }) {
        ForEach(this.stepIndexes(), (index: number): void => { this.stepChip(index) },
          (index: number): string => index.toString() + ':' + this.stepLabel(index) + ':' + this.activeStep.toString())
        if (this.allDraftSteps().length < REMOTE_CUSTOM_SHORTCUT_MAX_STEPS) {
          Text(this.modern() ? '添加下一步' : '＋ 下一步').fontSize(this.modern() ? 12 : 10).fontColor(this.accentColor).height(30)
            .padding({ left: 10, right: 10 }).borderRadius(15)
            .border({ width: 1, color: this.accentColor, style: BorderStyle.Dashed })
            .onClick((): void => { this.addStep(); })
        }
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
        ForEach(REMOTE_CUSTOM_SHORTCUT_GROUPS.slice(0, 4), (group: RemoteCustomShortcutKeyGroup): void => {
          this.groupChoice(group)
        }, (group: RemoteCustomShortcutKeyGroup): string => group)
      }.width('100%')
      Row({ space: 4 }) {
        ForEach(REMOTE_CUSTOM_SHORTCUT_GROUPS.slice(4), (group: RemoteCustomShortcutKeyGroup): void => {
          this.groupChoice(group)
        }, (group: RemoteCustomShortcutKeyGroup): string => group)
      }.width('100%')
      Column({ space: this.customEditorLayout().itemGap }) {
        ForEach(this.customActionRows(),
          (row: Array<RemoteCustomShortcutKeyOption>): void => { this.customActionRow(row) },
          (row: Array<RemoteCustomShortcutKeyOption>): string => row[0].keyCode.toString())
      }.width('100%')
      Button(this.recording ? '请在实体键盘上按下组合…（点此取消）' : '用实体键盘录制本步')
        .width('100%').height(36).fontSize(11).borderRadius(10)
        .backgroundColor(this.recording ? this.accentSoft() : this.card())
        .fontColor(this.recording ? this.accentColor : this.text())
        .onClick((): void => { this.recordModifiers = []; this.recording = !this.recording; })
        .onKeyEvent((event: KeyEvent): void => { if (this.recordKey(event)) { event.stopPropagation(); } })
      Column({ space: 4 }) {
        Text(this.draftName.trim().length > 0 ? this.draftName.trim() : '预览').fontSize(this.modern() ? 12 : 10).fontColor(this.text2())
          .width('100%')
        Text(this.draftLabel().length > 0 ? this.draftLabel() :
          '当前步骤不完整：字母、数字和符号需要至少一个修饰键')
          .fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor(this.draftLabel().length > 0 ? this.text() : this.danger()).width('100%')
      }.width('100%').padding(10).borderRadius(10).backgroundColor(this.accentSoft())
      Button('保存').width('100%').height(40).fontSize(13).borderRadius(12)
        .backgroundColor(this.draftLabel().length > 0 ? this.accentColor : this.card())
        .fontColor(this.draftLabel().length > 0 ? appUiOnAccentText(this.accentColor) : this.text2())
        .enabled(this.draftLabel().length > 0)
        .onClick((): void => { this.saveCustomShortcut(); })
    }.width('100%').padding(this.customEditorLayout().cardPadding)
      .borderRadius(16).backgroundColor(this.card())
      .border({ width: 0.5, color: this.cardStroke() })
  }

  @Builder
  private listIcon(symbol: Resource, label: string, color: ResourceColor, enabled: boolean, action: () => void) {
    Button() { SymbolGlyph(symbol).fontSize(15).fontColor([color]) }
      .width(32).height(32).padding(0).backgroundColor(Color.Transparent)
      .enabled(enabled).opacity(enabled ? 1 : 0.3).accessibilityText(label).onClick(action)
  }

  @Builder
  private customShortcutList() {
    Column({ space: 6 }) {
      Row() {
        Text(this.customShortcuts.length.toString() + ' / 32')
          .fontSize(this.modern() ? 12 : 10).fontColor(this.text2()).layoutWeight(1)
        Button(this.modern() ? '新建组合键' : '＋ 新建').height(this.modern() ? 44 : 34).fontSize(this.modern() ? 13 : 11).borderRadius(9)
          .backgroundColor(this.accentColor).fontColor(appUiOnAccentText(this.accentColor))
          .onClick((): void => { this.beginEditor(); })
      }.width('100%')
      if (this.visibleCustomShortcuts().length === 0) {
        Text(this.customShortcuts.length === 0 ? '尚未保存自定义组合键' :
          '当前平台没有可用组合键；F21–F24 仅支持 Windows')
          .width('100%').height(58).fontSize(11).textAlign(TextAlign.Center)
          .fontColor(this.text2()).backgroundColor(this.card()).borderRadius(12)
      } else {
        ForEach(this.visibleCustomShortcuts(), (shortcut: RemoteCustomShortcut, index: number): void => {
          Row({ space: 2 }) {
            Column({ space: 2 }) {
              Text(remoteCustomShortcutDisplayName(shortcut, this.platform()))
                .fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.text()).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if ((shortcut.name ?? '').length > 0 || remoteCustomShortcutSteps(shortcut).length > 1) {
                Text(remoteCustomShortcutStepsLabel(remoteCustomShortcutSteps(shortcut), this.platform()))
                  .fontSize(this.modern() ? 12 : 10).fontColor(this.text2()).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            this.listIcon($r('sys.symbol.chevron_up'), '上移', this.text2(), index > 0,
              (): void => { this.moveCustomShortcut(shortcut.id, -1); })
            this.listIcon($r('sys.symbol.chevron_down'), '下移', this.text2(),
              index < this.visibleCustomShortcuts().length - 1,
              (): void => { this.moveCustomShortcut(shortcut.id, 1); })
            this.listIcon($r('sys.symbol.rectangle_on_rectangle'), '复制', this.text2(),
              this.canAddShortcut(), (): void => { this.duplicateCustomShortcut(shortcut); })
            this.listIcon($r('sys.symbol.square_and_pencil'), '编辑', this.accentColor, true,
              (): void => { this.beginEditor(shortcut); })
            this.listIcon($r('sys.symbol.ohos_trash'), '删除', this.danger(), true,
              (): void => { this.deleteCustomShortcut(shortcut); })
          }.width('100%').padding({ left: 14, right: 4, top: 8, bottom: 8 }).borderRadius(12)
            .backgroundColor(this.card()).border({ width: 0.5, color: this.cardStroke() })
        }, (shortcut: RemoteCustomShortcut, index: number): string =>
          shortcut.id + ':' + index.toString() + ':' + (shortcut.name ?? '') + ':' + shortcut.label)
      }
    }.width('100%')
  }

  @Builder
  private pageHero(section: VirtualKeyboardSettingsSection, eyebrow: string) {
    Row({ space: 14 }) {
      Row() {
        SymbolGlyph(section === 'harmonyShortcuts' ?
          $r('sys.symbol.lock_shield_fill') : $r('sys.symbol.keyboard'))
          .fontSize(23).fontColor([this.accentColor])
      }.width(this.contentLayout().heroIconSize).height(this.contentLayout().heroIconSize)
        .justifyContent(FlexAlign.Center)
        .borderRadius(15).backgroundColor(this.accentSoft())
      Column({ space: 4 }) {
        Text(eyebrow).fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.text())
        if (section === 'behavior') {
          Text(this.simpleKeyboardEnabled ? '精简键盘已开启' : '完整键盘已开启')
            .fontSize(this.modern() ? 12 : 10).fontColor(this.text2()).maxLines(2)
        } else if (section === 'shortcuts') {
          Text(this.platform() === 'macos' ? 'macOS · Cmd / Option' : 'Windows · Ctrl / Alt / Win')
            .fontSize(this.modern() ? 12 : 10).fontColor(this.text2()).maxLines(2)
        } else if (section === 'functions') {
          Text((this.functionKeysVisible ? '完整功能键' : '精简功能键') + ' · ' +
            (this.closeAfterShortcut ? '发送后关闭' : '连续发送'))
            .fontSize(this.modern() ? 12 : 10).fontColor(this.text2()).maxLines(2)
        } else if (section === 'custom') {
          Text(this.customShortcuts.length.toString() + ' 个已保存 · 上限 32 个')
            .fontSize(this.modern() ? 12 : 10).fontColor(this.text2()).maxLines(2)
        } else if (section === 'harmonyShortcuts') {
          Text(this.harmonyShortcutDeviceLabel(this.selectedHarmonyShortcutDevice) + ' · ' +
            this.harmonyShortcutDeviceSubtitle(this.selectedHarmonyShortcutDevice))
            .fontSize(this.modern() ? 12 : 10).fontColor(this.text2()).maxLines(2)
        } else {
          Text(this.systemLoading ? '正在读取系统输入法状态' :
            (this.systemSnapshot.available ? '当前：' + this.systemSnapshot.currentLabel : '由系统统一管理'))
            .fontSize(this.modern() ? 12 : 10).fontColor(this.text2()).maxLines(2)
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }.width('100%').padding(this.contentLayout().heroPadding)
      .borderRadius(20).backgroundColor(this.card())
      .border({ width: 0.5, color: this.cardStroke() })
  }

  @Builder
  private refreshInputMethodsButton() {
    Button(this.systemLoading ? '正在刷新…' : '刷新状态')
      .width('100%').height(this.modern() ? 44 : 42).fontSize(this.modern() ? 13 : 11).borderRadius(12)
      .backgroundColor(this.card()).fontColor(this.text())
      .enabled(!this.systemLoading).onClick((): void => { this.refreshSystemInputMethods(); })
  }

  @Builder
  private openSystemInputMethodSettingsButton() {
    Button('系统输入法设置').width('100%').height(this.modern() ? 44 : 42).fontSize(this.modern() ? 13 : 11)
      .borderRadius(12).backgroundColor(this.accentColor).fontColor(appUiOnAccentText(this.accentColor))
      .onClick((): void => { this.openSystemSettings(); })
  }

  @Builder
  private systemInputMethodContent() {
    this.pageHero('system', 'HarmonyOS 官方输入法')
    this.sectionTitle('输入法状态', '应用只读取公开状态，不会绕过系统权限切换输入法。')
    if (this.contentLayout().stackPrimaryActions) {
      Column({ space: 8 }) {
        this.refreshInputMethodsButton()
        this.openSystemInputMethodSettingsButton()
      }.width('100%').margin({ bottom: 10 })
    } else {
      Row({ space: 8 }) {
        Column() { this.refreshInputMethodsButton() }.layoutWeight(1)
        Column() { this.openSystemInputMethodSettingsButton() }.layoutWeight(2)
      }.width('100%').margin({ bottom: 10 })
    }
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
    this.sectionTitle('远端输入框', '在连接中点击远端输入框时自动唤起软键盘。')
    this.switchRow('点击远端输入框自动弹起键盘',
      '横屏使用悬浮键盘，竖屏使用正常键盘；仅在虚拟键盘模式下生效',
      this.autoOpenOnRemoteClick, (enabled: boolean): void => {
        this.autoOpenOnRemoteClick = enabled;
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
    if (this.contentLayout().stackPrimaryActions) {
      Column({ space: 8 }) {
        Row() { this.platformChoice('windows', 'Windows', '通用键：Ctrl') }.width('100%')
        Row() { this.platformChoice('macos', 'macOS', '通用键：Cmd') }.width('100%')
      }.width('100%')
    } else {
      Row({ space: 10 }) {
        this.platformChoice('windows', 'Windows', '通用键：Ctrl')
        this.platformChoice('macos', 'macOS', '通用键：Cmd')
      }.width('100%')
    }
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
      '包含 F1–F24、导航、Delete、锁定键、PrtSc、Pause 和 Menu；方向键始终独立显示',
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
      '可命名、排序，支持最多 4 步的按键序列；系统键、功能键、导航键和小键盘可单独使用。')
    this.infoRow('当前标签平台', this.platform() === 'macos' ? 'macOS' : 'Windows')
    Column().height(8)
    if (this.editorVisible) { this.customEditor() } else { this.customShortcutList() }
  }

  @Builder
  private harmonyShortcutProtocolRow(
    deviceClass: HarmonyShortcutDeviceClass,
    protocol: HarmonyShortcutProtocol
  ) {
    Row() {
      SymbolGlyph(protocolIcon(protocol)).fontSize(18).fontColor([this.text2()])
        .margin({ right: 10 })
      Column({ space: 2 }) {
        Text(this.harmonyShortcutProtocolLabel(protocol))
          .fontSize(12).fontWeight(FontWeight.Medium).fontColor(this.text())
        Text(this.harmonyShortcutProtocolStatus(deviceClass, protocol))
          .fontSize(this.modern() ? 12 : 9).fontColor(this.text2())
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({
        type: ToggleType.Switch,
        isOn: harmonyShortcutBlockingEnabled(
          this.harmonyShortcutBlocking, deviceClass, protocol)
      }).selectedColor(this.accentColor).scale({ x: 0.86, y: 0.86 })
        .onChange((enabled: boolean): void => {
          this.setHarmonyShortcutBlocking(deviceClass, protocol, enabled);
        })
        .accessibilityText(this.harmonyShortcutDeviceLabel(deviceClass) + ' ' +
          this.harmonyShortcutProtocolLabel(protocol) + '，' +
          this.harmonyShortcutProtocolStatus(deviceClass, protocol))
    }.width('100%').padding({ left: 13, right: 10, top: 9, bottom: 9 })
  }

  @Builder
  private harmonyShortcutDeviceChoice(deviceClass: HarmonyShortcutDeviceClass) {
    Button(this.harmonyShortcutDeviceLabel(deviceClass))
      .layoutWeight(1).height(40).fontSize(11).fontWeight(FontWeight.Medium)
      .fontColor(this.selectedHarmonyShortcutDevice === deviceClass ? '#FFFFFF' : this.text2())
      .backgroundColor(this.selectedHarmonyShortcutDevice === deviceClass ?
        this.accentColor : this.card())
      .borderRadius(10)
      .border({
        width: 1,
        color: this.selectedHarmonyShortcutDevice === deviceClass ?
          this.accentColor : this.cardStroke()
      })
      .onClick((): void => { this.selectedHarmonyShortcutDevice = deviceClass; })
      .accessibilityText(this.harmonyShortcutDeviceLabel(deviceClass) + '，' +
        (this.selectedHarmonyShortcutDevice === deviceClass ? '已选中' : '未选中'))
  }

  @Builder
  private harmonyShortcutDevicePicker() {
    Row({ space: 8 }) {
      ForEach(this.harmonyShortcutDeviceOptions(),
        (deviceClass: HarmonyShortcutDeviceClass): void => {
          this.harmonyShortcutDeviceChoice(deviceClass)
        }, (deviceClass: HarmonyShortcutDeviceClass): string => deviceClass)
    }.width('100%')
  }

  @Builder
  private harmonyShortcutDeviceCard() {
    Column() {
      ForEach(harmonyShortcutProtocols(), (protocol: HarmonyShortcutProtocol): void => {
        this.harmonyShortcutProtocolRow(this.selectedHarmonyShortcutDevice, protocol)
      }, (protocol: HarmonyShortcutProtocol): string =>
        this.selectedHarmonyShortcutDevice + ':' + protocol)
    }.width('100%').borderRadius(15).backgroundColor(this.card())
      .border({ width: 0.5, color: this.cardStroke() }).margin({ bottom: 10 })
  }

  @Builder
  private harmonyShortcutBlockingContent() {
    this.pageHero('harmonyShortcuts', '打开即屏蔽并发送远端')
    this.sectionTitle('设备', '默认选中当前设备；PC 默认打开，手机和 Pad 默认关闭。')
    this.harmonyShortcutDevicePicker()
    this.sectionTitle('远程协议', '打开：本机屏蔽并发送远端；关闭：由鸿蒙处理。')
    this.harmonyShortcutDeviceCard()
    Text('屏蔽仅在远程会话位于前台时生效。RustDesk 支持音量键，其他协议支持音量和媒体键；' +
      'SSH 没有通用媒体按键通道，因此不显示。')
      .fontSize(this.modern() ? 12 : 9).fontColor(this.text2()).lineHeight(this.modern() ? 18 : 14).width('100%')
      .padding({ left: 4, right: 4, top: 2 })
  }

  @Builder
  private pageContent() {
    if (this.requestedSection === 'behavior') {
      this.inputBehaviorContent()
    } else if (this.requestedSection === 'shortcuts') {
      this.shortcutPlatformContent()
    } else if (this.requestedSection === 'functions') {
      this.functionPanelContent()
    } else if (this.requestedSection === 'custom') {
      if (ProEntries.visible(PRO_PERSONALIZATION_FEATURE)) {
        this.customShortcutContent()
      } else {
        Text('自定义组合键是 Pro 个性化方案的一部分；已保存的组合键会保留，开通 Pro 后恢复。')
          .fontSize(13).fontColor(this.text2()).lineHeight(20).width('100%').padding(16)
      }
    } else if (this.requestedSection === 'harmonyShortcuts') {
      this.harmonyShortcutBlockingContent()
    } else {
      this.systemInputMethodContent()
    }
    Column().height(this.contentLayout().headerBottomPadding + 14)
  }

  build() {
    Column() {
      Row() {
        if (this.modern()) {
          AppSheetHeader({ title: this.pageTitle(), subtitle: this.pageSubtitle(), horizontalPadding: 0,
            whiteOnAccent: true, onClose: (): void => { this.onClose(); } })
            .width('100%').constraintSize({ maxWidth: this.contentLayout().maxContentWidth })
            .padding({
              left: this.contentLayout().headerHorizontalPadding,
              right: this.contentLayout().headerHorizontalPadding
            })
        } else {
        Row() {
          Column({ space: 3 }) {
            Text('键盘设置').fontSize(10).fontWeight(FontWeight.Medium)
              .fontColor(this.accentColor)
            Text(this.pageTitle()).fontSize(this.contentLayout().titleFontSize)
              .fontWeight(FontWeight.Bold).fontColor(this.text()).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.pageSubtitle()).fontSize(this.modern() ? 12 : 10).fontColor(this.text2()).maxLines(2)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button() {
            SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.text()])
          }.width(42).height(42).padding(0).borderRadius(14).backgroundColor(this.card())
            .border({ width: 0.5, color: this.cardStroke() })
            .onClick((): void => { this.onClose(); }).accessibilityText('关闭键盘设置')
        }.width('100%').constraintSize({ maxWidth: this.contentLayout().maxContentWidth })
          .padding({
            left: this.contentLayout().headerHorizontalPadding,
            right: this.contentLayout().headerHorizontalPadding,
            top: this.contentLayout().headerTopPadding,
            bottom: this.contentLayout().headerBottomPadding
          })
        }
      }.width('100%').justifyContent(FlexAlign.Center)

      Scroll() {
        if (this.requestedSection === 'system' || this.requestedSection === 'custom') {
          Column() {
            this.pageContent()
          }.width('100%')
            .padding({
              left: this.contentLayout().contentHorizontalPadding,
              right: this.contentLayout().contentHorizontalPadding
            })
        } else {
          Row() {
            Column() {
              this.pageContent()
            }.width('100%').constraintSize({ maxWidth: this.contentLayout().maxContentWidth })
              .padding({
                left: this.contentLayout().contentHorizontalPadding,
                right: this.contentLayout().contentHorizontalPadding
              })
          }.width('100%').justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Top)
        }
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
    }.width('100%').height('100%').backgroundColor(this.bg())
      .borderRadius(this.contentLayout().cornerRadius)
      .onAreaChange((_old: Area, next: Area): void => {
        const nextWidth: number = next.width as number;
        const nextHeight: number = next.height as number;
        if (Number.isFinite(nextWidth) && nextWidth > 0) { this.viewportWidth = nextWidth; }
        if (Number.isFinite(nextHeight) && nextHeight > 0) { this.viewportHeight = nextHeight; }
      })
  }
}
