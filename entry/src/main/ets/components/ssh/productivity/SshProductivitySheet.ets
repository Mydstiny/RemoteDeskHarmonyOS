import {
  renderSshSnippet,
  snippetVisibleForScope,
  SshCommandHistoryV1,
  SshProductivityDocumentV1,
  SshProductivitySettingsV1,
  SshSnippetV1,
  SshSnippetVariableV1,
  SshSnippetValue
} from '../../../services/ssh/productivity/SshProductivityPolicy';

/**
 * Local-only SSH productivity surface. It emits semantic insert actions; it
 * never owns a session, writes preferences, or persists variable values.
 */
@Component
export struct SshProductivitySheet {
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @Prop sheetBackgroundColor: string = '#1C1C1F';
  @Prop document: SshProductivityDocumentV1;
  @Prop ready: boolean = false;
  @Prop hostId: string = '';
  @Prop hostLabel: string = '';
  @Prop groupId: string = '';
  @Prop query: string = '';
  @Prop sessionLogsEnabled: boolean = false;
  @Prop broadcastEnabled: boolean = false;
  onClose: () => void = (): void => {};
  onSearchChange: (value: string) => void = (_value: string): void => {};
  onInsertSnippet: (snippet: SshSnippetV1, values: Array<SshSnippetValue>) => void =
    (_snippet: SshSnippetV1, _values: Array<SshSnippetValue>): void => {};
  onInsertHistory: (command: string) => void = (_command: string): void => {};
  onToggleHistory: (enabled: boolean) => void = (_enabled: boolean): void => {};
  onToggleCompletion: (enabled: boolean) => void = (_enabled: boolean): void => {};
  onToggleCompletionNotification: (enabled: boolean) => void =
    (_enabled: boolean): void => {};
  onToggleShellIntegration: (enabled: boolean) => void = (_enabled: boolean): void => {};
  onSetStartup: (snippetId: string, enabled: boolean) => boolean =
    (_snippetId: string, _enabled: boolean): boolean => true;
  onOpenSessionLog: () => void = (): void => {};
  onOpenBroadcast: () => void = (): void => {};

  @State selectedSnippetId: string = '';
  @State variableValues: Array<SshSnippetValue> = [];
  @State startupOverrideId: string = '';
  @State startupOverrideValue: boolean = false;

  aboutToAppear(): void {
    this.selectFirstSnippet();
  }

  private selectFirstSnippet(): void {
    const snippets: Array<SshSnippetV1> = this.visibleSnippets();
    if (snippets.length > 0) {
      this.selectSnippet(snippets[0]);
    } else {
      this.selectedSnippetId = '';
      this.variableValues = [];
    }
  }

  private visibleSnippets(): Array<SshSnippetV1> {
    const token: string = this.query.trim().toLowerCase().slice(0, 256);
    const result: Array<SshSnippetV1> = [];
    for (let index: number = 0; index < this.document.snippets.length; index++) {
      const snippet: SshSnippetV1 = this.document.snippets[index];
      if (!snippetVisibleForScope(snippet, this.hostId, this.groupId)) { continue; }
      const haystack: string = (snippet.title + ' ' + snippet.description).toLowerCase();
      if (token.length === 0 || haystack.indexOf(token) >= 0) { result.push(snippet); }
    }
    return result;
  }

  private visibleHistory(): Array<SshCommandHistoryV1> {
    const token: string = this.query.trim().toLowerCase().slice(0, 256);
    const result: Array<SshCommandHistoryV1> = [];
    for (let index: number = this.document.history.length - 1; index >= 0; index--) {
      const item: SshCommandHistoryV1 = this.document.history[index];
      if (item.hostId !== this.hostId.trim()) { continue; }
      if (token.length === 0 || item.command.toLowerCase().indexOf(token) >= 0) {
        result.push(item);
      }
      if (result.length >= 100) { break; }
    }
    return result;
  }

  private selectedSnippet(): SshSnippetV1 | null {
    for (let index: number = 0; index < this.document.snippets.length; index++) {
      if (this.document.snippets[index].id === this.selectedSnippetId) {
        return this.document.snippets[index];
      }
    }
    return null;
  }

  private selectSnippet(snippet: SshSnippetV1): void {
    this.selectedSnippetId = snippet.id;
    this.variableValues = snippet.variables.map((variable): SshSnippetValue => ({
      name: variable.name,
      value: variable.defaultValue,
      secret: variable.secretRef.length > 0
    }));
  }

  private updateVariable(name: string, value: string): void {
    this.variableValues = this.variableValues.map((item: SshSnippetValue): SshSnippetValue =>
      item.name === name ? { name: item.name, value, secret: item.secret } : item);
  }

  private previewText(): string {
    const snippet: SshSnippetV1 | null = this.selectedSnippet();
    if (snippet === null) { return ''; }
    return renderSshSnippet(snippet, this.variableValues).preview;
  }

  private snippetCanInsert(): boolean {
    const snippet: SshSnippetV1 | null = this.selectedSnippet();
    return snippet !== null && renderSshSnippet(snippet, this.variableValues).ok;
  }

  private startupEnabled(snippet: SshSnippetV1): boolean {
    if (this.startupOverrideId === snippet.id) { return this.startupOverrideValue; }
    for (let index: number = 0; index < this.document.startupCommands.length; index++) {
      const item = this.document.startupCommands[index];
      if (item.hostId === this.hostId.trim() && item.snippetId === snippet.id) {
        return item.enabled;
      }
    }
    return false;
  }

  @Builder
  private SettingsRow(label: string, detail: string, enabled: boolean,
    onChange: (value: boolean) => void) {
    Row() {
      Column() {
        Text(label).fontSize(12).fontColor('#F2F4F7')
        Text(detail).fontSize(10).fontColor('rgba(242,244,247,0.48)').margin({ top: 3 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: enabled })
        .selectedColor(this.accentColor)
        .onChange(onChange)
    }
    .width('100%').constraintSize({ minHeight: 48 })
    .padding({ left: 12, right: 8, top: 6, bottom: 6 })
    .borderRadius(10).backgroundColor('rgba(255,255,255,0.055)')
  }

  @Builder
  private SnippetList() {
    Column({ space: 6 }) {
      ForEach(this.visibleSnippets(), (snippet: SshSnippetV1): void => {
        Row() {
          Column() {
            Text(snippet.title).fontSize(12).fontWeight(FontWeight.Medium)
              .fontColor('#F2F4F7').maxLines(1)
            Text(snippet.scope + (snippet.scopeId.length > 0 ? ' · ' + snippet.scopeId : ''))
              .fontSize(9).fontColor('rgba(242,244,247,0.45)').margin({ top: 3 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          if (snippet.variables.some((item): boolean => item.secretRef.length > 0)) {
            Text('secretRef').fontSize(9).fontColor('#FFCA72')
          }
        }
        .width('100%').constraintSize({ minHeight: 48 }).padding({ left: 10, right: 10 })
        .borderRadius(9)
        .backgroundColor(this.selectedSnippetId === snippet.id
          ? this.accentColor + '38' : 'rgba(255,255,255,0.045)')
        .onClick((): void => { this.selectSnippet(snippet); })
        .accessibilityText('选择片段 ' + snippet.title)
      }, (snippet: SshSnippetV1): string => snippet.id)
      if (this.visibleSnippets().length === 0) {
        Text(this.ready ? '暂无匹配的 Snippet' : '加密存储未解锁，生产力功能已禁用')
          .fontSize(11).fontColor('rgba(242,244,247,0.48)').padding(12)
      }
    }.width('100%')
  }

  @Builder
  private SnippetEditor(snippet: SshSnippetV1) {
    Column({ space: 8 }) {
      Text(snippet.description.length > 0 ? snippet.description : '变量值只保留在当前编辑状态')
        .fontSize(10).fontColor('rgba(242,244,247,0.52)').width('100%')
      ForEach(snippet.variables, (variable: SshSnippetVariableV1): void => {
        TextInput({ text: this.variableValues.find((item: SshSnippetValue): boolean =>
          item.name === variable.name)?.value ?? '', placeholder: variable.label })
          .height(42).fontSize(12).fontColor('#F2F4F7')
          .placeholderColor('rgba(242,244,247,0.40)')
          .backgroundColor('rgba(255,255,255,0.07)').borderRadius(8)
          .type(variable.secretRef.length > 0 ? InputType.Password : InputType.Normal)
          .showPasswordIcon(variable.secretRef.length > 0)
          .enableAutoFill(false)
          .onChange((value: string): void => { this.updateVariable(variable.name, value); })
      }, (variable: SshSnippetVariableV1): string => variable.name)
      Text('预览（执行前可见，点击插入不会自动发送回车）')
        .fontSize(10).fontColor('rgba(242,244,247,0.52)').width('100%')
      Text(this.previewText().length > 0 ? this.previewText() : '缺少变量值')
        .fontSize(11).fontFamily('monospace').fontColor('#F2F4F7')
        .maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%').padding(10).borderRadius(8)
        .backgroundColor('rgba(0,0,0,0.25)')
      Row({ space: 8 }) {
        Button('插入到终端').height(44).layoutWeight(1).fontSize(12)
          .backgroundColor(this.accentColor).fontColor('#FFFFFF')
          .enabled(this.snippetCanInsert() && this.ready)
          .onClick((): void => { this.onInsertSnippet(snippet, this.variableValues); })
        Row() {
          Text('连接后启动').fontSize(10).fontColor('#F2F4F7').layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.startupEnabled(snippet) })
            .selectedColor(this.accentColor)
            .onChange((value: boolean): void => {
              this.startupOverrideId = snippet.id;
              this.startupOverrideValue = value;
              if (!this.onSetStartup(snippet.id, value)) {
                this.startupOverrideId = '';
                this.startupOverrideValue = false;
              }
            })
        }.width(118).height(44).padding({ left: 8, right: 5 })
          .borderRadius(8).backgroundColor('rgba(255,255,255,0.07)')
      }.width('100%')
    }.width('100%').padding(10).borderRadius(10)
      .backgroundColor('rgba(255,255,255,0.045)')
  }

  @Builder
  private Editor() {
    if (this.selectedSnippet() === null) {
      Column() {
        Text('选择一个 Snippet 或从历史中插入命令')
          .fontSize(11).fontColor('rgba(242,244,247,0.48)')
      }.width('100%').padding(10).borderRadius(10)
        .backgroundColor('rgba(255,255,255,0.045)')
    } else {
      this.SnippetEditor(this.selectedSnippet() as SshSnippetV1)
    }
  }

  @Builder
  private HistoryList() {
    Column({ space: 6 }) {
      ForEach(this.visibleHistory().slice(0, 12), (item: SshCommandHistoryV1): void => {
        Row() {
          Text(item.command).fontSize(11).fontFamily('monospace').fontColor('#F2F4F7')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          Button('插入').height(32).fontSize(10).padding({ left: 9, right: 9 })
            .backgroundColor('rgba(255,255,255,0.08)')
            .onClick((): void => { this.onInsertHistory(item.command); })
        }.width('100%').constraintSize({ minHeight: 42 }).padding({ left: 10, right: 7 })
          .borderRadius(8).backgroundColor('rgba(255,255,255,0.035)')
      }, (item: SshCommandHistoryV1): string => item.id)
      if (this.visibleHistory().length === 0) {
        Text('当前主机还没有可用历史').fontSize(10)
          .fontColor('rgba(242,244,247,0.45)').padding(10)
      }
    }.width('100%')
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text('SSH Productivity').fontSize(18).fontWeight(FontWeight.Medium)
            .fontColor('#F2F4F7')
          Text(this.hostLabel.length > 0 ? this.hostLabel : '当前会话 · 本地加密存储')
            .fontSize(10).fontColor('rgba(242,244,247,0.50)').margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('关闭').height(36).fontSize(11).backgroundColor('rgba(255,255,255,0.08)')
          .onClick((): void => { this.onClose(); })
      }.width('100%').padding({ left: 16, right: 16, top: 14, bottom: 10 })
      TextInput({ text: this.query, placeholder: '搜索 Snippet 或当前主机历史' })
        .height(42).fontSize(12).fontColor('#F2F4F7')
        .placeholderColor('rgba(242,244,247,0.40)').backgroundColor('rgba(255,255,255,0.07)')
        .borderRadius(9).margin({ left: 16, right: 16, bottom: 10 })
        .enableAutoFill(false)
        .onChange((value: string): void => { this.onSearchChange(value.slice(0, 256)); })
      Scroll() {
        Column({ space: 10 }) {
          Text('Snippets').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#F2F4F7')
            .width('100%')
          this.SnippetList()
          this.Editor()
          Text('历史与补全').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#F2F4F7')
            .width('100%')
          this.HistoryList()
          Text('设置').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#F2F4F7')
            .width('100%')
          if (this.sessionLogsEnabled) {
            Button('打开会话日志').height(40).fontSize(11).width('100%')
              .backgroundColor('rgba(255,255,255,0.08)')
              .onClick((): void => { this.onOpenSessionLog(); })
          }
          if (this.broadcastEnabled) {
            Button('安全广播输入').height(40).fontSize(11).width('100%')
              .fontColor('#FFF3F0').backgroundColor('#7D2E2E')
              .onClick((): void => { this.onOpenBroadcast(); })
          }
          this.SettingsRow('命令历史', '默认关闭；敏感模式和禁用主机始终不记录',
            this.document.settings.historyEnabled, this.onToggleHistory)
          this.SettingsRow('本地补全', '只使用本地 Snippet/历史，不猜测密码边界',
            this.document.settings.completionEnabled, this.onToggleCompletion)
          this.SettingsRow('命令完成提醒', '默认关闭；开启时请求系统通知权限，不显示命令或网络身份',
            this.document.settings.completionNotificationEnabled,
            this.onToggleCompletionNotification)
          this.SettingsRow('Shell integration', '仅观察 OSC 133/633，不改变远端输出',
            this.document.settings.shellIntegrationEnabled, this.onToggleShellIntegration)
        }.width('100%').padding({ left: 16, right: 16, bottom: 18 })
      }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
    }
    .width('100%').height('100%').backgroundColor(this.sheetBackgroundColor)
  }
}
