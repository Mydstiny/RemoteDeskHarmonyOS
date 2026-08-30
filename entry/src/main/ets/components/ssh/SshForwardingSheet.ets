import { Palette, buildDark } from '../../common/Theme';
import {
  formatEndpointFieldsHostPort,
  formatListenerHostPort
} from '../../services/EndpointAddressPolicy';
import {
  resolveSshForwardingEditorSheetLayout,
  SshForwardingMode,
  SshForwardingProfile,
  SshForwardingSheetLayout,
  SshForwardingStartPolicy
} from '../../services/SshForwardingPolicy';
import {
  SshForwardingDraft,
  SshForwardingDraftResult,
  buildSshForwardingProfile,
  defaultSshForwardingDraft,
  makeSshForwardingProfileId,
  sshForwardingDraftFromProfile,
  sshForwardingModeLabel
} from '../../services/SshForwardingEditorPolicy';
import {
  SshForwardingRuntimeRecord,
  SshForwardingRuntimeState
} from '../../services/SshForwardingRuntimeStore';
import { SshModalCoordinator, SshModalDecision } from '../../services/SshModalCoordinator';

@Component
export struct SshForwardingSheet {
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @Prop @Watch('onProfilesChanged') profiles: SshForwardingProfile[] = [];
  @Prop runtimes: SshForwardingRuntimeRecord[] = [];
  @Prop connected: boolean = false;
  @Prop hostLabel: string = '';
  @Prop statusMessage: string = '';
  @Prop viewportWidthVp: number = 0;
  @Prop viewportHeightVp: number = 0;
  @Prop phone: boolean = true;
  onClose: () => void = (): void => {};
  onSave: (profile: SshForwardingProfile) => void = (_profile: SshForwardingProfile): void => {};
  onStart: (profileId: string) => void = (_profileId: string): void => {};
  onStop: (profileId: string) => void = (_profileId: string): void => {};
  onRemove: (profileId: string) => void = (_profileId: string): void => {};
  onRefresh: () => void = (): void => {};

  @State selectedProfileId: string = '';
  @State draft: SshForwardingDraft = defaultSshForwardingDraft('local', 'ssh-forward-new');
  @State editorMessage: string = '';
  @State dirty: boolean = false;
  @State showRuleEditorSheet: boolean = false;
  @State ruleEditorMountToken: number = 0;
  @State ruleEditorCreating: boolean = true;
  private idNonce: number = 0;
  private ruleEditorCoordinator: SshModalCoordinator = new SshModalCoordinator();
  private pendingEditorProfileId: string = '';
  private restoreProfileId: string = '';
  private restoreDraft: SshForwardingDraft = defaultSshForwardingDraft('local', 'ssh-forward-restore');
  private restoreDirty: boolean = false;

  private pal(): Palette {
    // The tunnel workspace is deliberately dark in every system color mode.
    // This keeps the terminal-adjacent workflow visually stable and prevents
    // a nested rule sheet from switching palette while its parent is open.
    return buildDark(this.accentColor);
  }

  private ruleEditorSheetLayout(): SshForwardingSheetLayout {
    return resolveSshForwardingEditorSheetLayout(
      this.viewportWidthVp, this.viewportHeightVp, this.phone);
  }

  private ruleEditorSheetWidth(): Dimension {
    const layout: SshForwardingSheetLayout = this.ruleEditorSheetLayout();
    return layout.bottomAnchored ? '100%' : layout.widthVp;
  }

  private newId(): string {
    this.idNonce++;
    return makeSshForwardingProfileId(Date.now(), this.idNonce);
  }

  private cloneDraft(value: SshForwardingDraft): SshForwardingDraft {
    return {
      id: value.id, mode: value.mode, bindHost: value.bindHost,
      bindPortText: value.bindPortText, targetHost: value.targetHost,
      targetPortText: value.targetPortText, maxConnectionsText: value.maxConnectionsText,
      maxBytesText: value.maxBytesText, enabled: value.enabled,
      startPolicy: value.startPolicy, allowPublicBind: value.allowPublicBind
    };
  }

  private fieldFocusId(title: string): string {
    if (title === '监听地址') { return 'sshForwardingBindHost'; }
    if (title === '监听端口') { return 'sshForwardingBindPort'; }
    if (title === '目标地址') { return 'sshForwardingTargetHost'; }
    if (title === '目标端口') { return 'sshForwardingTargetPort'; }
    if (title === '最大连接数') { return 'sshForwardingMaxConnections'; }
    return 'sshForwardingMaxBytes';
  }

  private mutateDraft(update: (draft: SshForwardingDraft) => void): void {
    const next: SshForwardingDraft = this.cloneDraft(this.draft);
    update(next);
    this.draft = next;
    this.dirty = true;
    this.editorMessage = '';
  }

  private selectProfile(profile: SshForwardingProfile): void {
    this.selectedProfileId = profile.id;
    this.draft = sshForwardingDraftFromProfile(profile);
    this.dirty = false;
    this.editorMessage = '';
  }

  private createProfile(mode: SshForwardingMode = 'local'): void {
    this.selectedProfileId = '';
    this.draft = defaultSshForwardingDraft(mode, this.newId());
    this.dirty = true;
    this.editorMessage = '';
  }

  private mountRuleEditor(decision: SshModalDecision): void {
    this.restoreProfileId = this.selectedProfileId;
    this.restoreDraft = this.cloneDraft(this.draft);
    this.restoreDirty = this.dirty;
    const profile: SshForwardingProfile | undefined = this.profiles.find(
      (item: SshForwardingProfile): boolean => item.id === this.pendingEditorProfileId);
    if (profile === undefined) {
      this.ruleEditorCreating = true;
      this.createProfile('local');
    } else {
      this.ruleEditorCreating = false;
      this.selectProfile(profile);
    }
    this.ruleEditorMountToken = decision.token;
    this.showRuleEditorSheet = true;
  }

  private openNewRuleEditor(): void {
    this.pendingEditorProfileId = '';
    const decision: SshModalDecision = this.ruleEditorCoordinator.requestOpen();
    if (decision.mount) { this.mountRuleEditor(decision); }
  }

  private openProfileRuleEditor(profile: SshForwardingProfile): void {
    if (this.runtimeActive(this.runtimeFor(profile.id))) {
      this.editorMessage = '运行中的规则需要先停止，再编辑。';
      return;
    }
    this.pendingEditorProfileId = profile.id;
    const decision: SshModalDecision = this.ruleEditorCoordinator.requestOpen();
    if (decision.mount) { this.mountRuleEditor(decision); }
  }

  private restoreRuleEditorSelection(): void {
    this.selectedProfileId = this.restoreProfileId;
    this.draft = this.cloneDraft(this.restoreDraft);
    this.dirty = this.restoreDirty;
    this.editorMessage = '';
  }

  private closeNewRuleEditor(restore: boolean): void {
    const decision: SshModalDecision = this.ruleEditorCoordinator.requestClose();
    if (!decision.dismiss) { return; }
    if (restore) { this.restoreRuleEditorSelection(); }
    this.showRuleEditorSheet = false;
  }

  private onRuleEditorAppear(token: number): void {
    this.ruleEditorCoordinator.noteAppeared(token);
  }

  private onRuleEditorDisappear(token: number): void {
    const decision: SshModalDecision = this.ruleEditorCoordinator.noteDisappeared(token);
    if (decision.mount) { this.mountRuleEditor(decision); }
  }

  private onProfilesChanged(): void {
    if (this.profiles.length === 0) {
      if (!this.showRuleEditorSheet) {
        this.selectedProfileId = '';
        this.dirty = false;
        this.editorMessage = '';
      }
      return;
    }
    const selected: SshForwardingProfile | undefined = this.profiles.find(
      (profile: SshForwardingProfile): boolean => profile.id === this.selectedProfileId);
    if (selected !== undefined && !this.dirty) {
      this.draft = sshForwardingDraftFromProfile(selected);
    } else if (this.selectedProfileId.length > 0 && selected === undefined) {
      this.selectProfile(this.profiles[0]);
    }
  }

  private runtimeFor(profileId: string): SshForwardingRuntimeRecord | null {
    const runtime: SshForwardingRuntimeRecord | undefined = this.runtimes.find(
      (item: SshForwardingRuntimeRecord): boolean => item.profileId === profileId);
    return runtime === undefined ? null : runtime;
  }

  private runtimeActive(runtime: SshForwardingRuntimeRecord | null): boolean {
    return runtime !== null && (runtime.state === 'starting' || runtime.state === 'listening' ||
      runtime.state === 'stopping');
  }

  private selectedRuntime(): SshForwardingRuntimeRecord | null {
    return this.runtimeFor(this.selectedProfileId);
  }

  private selectedProfile(): SshForwardingProfile | null {
    const selected: SshForwardingProfile | undefined = this.profiles.find(
      (profile: SshForwardingProfile): boolean => profile.id === this.selectedProfileId);
    return selected === undefined ? null : selected;
  }

  private selectMode(mode: SshForwardingMode): void {
    if (this.runtimeActive(this.selectedRuntime())) { return; }
    this.mutateDraft((draft: SshForwardingDraft): void => {
      draft.mode = mode;
      if (mode === 'dynamic') {
        draft.targetHost = '';
        draft.targetPortText = '';
      } else {
        if (draft.targetHost.trim().length === 0) { draft.targetHost = '127.0.0.1'; }
        if (draft.targetPortText.trim().length === 0) { draft.targetPortText = '22'; }
      }
    });
  }

  private saveDraft(closeRuleEditor: boolean = false): void {
    if (this.runtimeActive(this.selectedRuntime())) {
      this.editorMessage = '运行中的规则需要先停止，再修改或保存。';
      return;
    }
    const result: SshForwardingDraftResult = buildSshForwardingProfile(this.draft);
    if (!result.valid) {
      this.editorMessage = result.message;
      return;
    }
    this.selectedProfileId = result.profile.id;
    this.dirty = false;
    this.editorMessage = '';
    this.onSave(result.profile);
    if (closeRuleEditor) { this.closeNewRuleEditor(false); }
  }

  private stateLabel(state: SshForwardingRuntimeState): string {
    if (state === 'configured') { return '已配置'; }
    if (state === 'starting') { return '启动中'; }
    if (state === 'listening') { return '监听中'; }
    if (state === 'stopping') { return '停止中'; }
    if (state === 'failed') { return '失败'; }
    if (state === 'stale' || state === 'needsRebind') { return '等待重绑定'; }
    return '已停止';
  }

  private stateColor(state: SshForwardingRuntimeState): string {
    if (state === 'listening') { return this.pal().success; }
    if (state === 'failed' || state === 'stale') { return this.pal().danger; }
    if (state === 'starting' || state === 'stopping' || state === 'needsRebind') {
      return this.pal().editColor;
    }
    return this.pal().text3;
  }

  private formatBytes(value: number): string {
    if (value >= 1024 * 1024 * 1024) { return (value / (1024 * 1024 * 1024)).toFixed(1) + ' GB'; }
    if (value >= 1024 * 1024) { return (value / (1024 * 1024)).toFixed(1) + ' MB'; }
    if (value >= 1024) { return (value / 1024).toFixed(1) + ' KB'; }
    return Math.max(0, Math.floor(value)).toString() + ' B';
  }

  private profileSummary(profile: SshForwardingProfile): string {
    const bind: string = formatListenerHostPort(profile.bindHost, profile.bindPort);
    if (profile.mode === 'dynamic') { return bind + ' · SOCKS5'; }
    return bind + ' → ' + formatEndpointFieldsHostPort(profile.targetHost, profile.targetPort);
  }

  @Builder private field(title: string, value: string, hint: string,
    disabled: boolean, change: (value: string) => void) {
    Column({ space: 5 }) {
      Text(title).fontSize(12).fontColor(this.pal().text2)
      TextInput({ text: value, placeholder: hint })
        .id(this.fieldFocusId(title))
        .width('100%').height(44).fontSize(14).fontColor(this.pal().text)
        .placeholderColor(this.pal().text3).backgroundColor(this.pal().surface)
        .borderRadius(10).padding({ left: 12, right: 12 }).enabled(!disabled)
        // Desktop sheets do not implicitly grant touch focus to TextInput on
        // API 23/26. Keep every forwarding field keyboard-focusable so a
        // pointer click cannot fall through to the terminal surface.
        .focusable(!disabled).focusOnTouch(!disabled).enableKeyboardOnFocus(!disabled)
        .opacity(disabled ? 0.58 : 1)
        .onClick((): void => {
          if (disabled) { return; }
          const focusId: string = this.fieldFocusId(title);
          setTimeout((): void => {
            try { focusControl.requestFocus(focusId); } catch (_err) {}
          }, 32);
        })
        .onChange(change)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder private modeButton(label: string, mode: SshForwardingMode, disabled: boolean) {
    Button(label).layoutWeight(1).height(44).borderRadius(10).fontSize(13)
      .backgroundColor(this.draft.mode === mode ? this.accentColor : this.pal().surface)
      .fontColor(this.draft.mode === mode ? Color.White : this.pal().text2)
      .enabled(!disabled).opacity(disabled && this.draft.mode !== mode ? 0.5 : 1)
      .onClick((): void => { this.selectMode(mode); })
  }

  @Builder private profileList() {
    Column({ space: 8 }) {
      Row() {
        Text('转发规则').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          .layoutWeight(1)
        Button('+ 新建').height(40).borderRadius(10).fontSize(12)
          .backgroundColor(this.pal().surface).fontColor(this.accentColor)
          .onClick((): void => { this.openNewRuleEditor(); })
      }.width('100%')
      if (this.profiles.length === 0) {
        Column({ space: 6 }) {
          Text('还没有转发规则').fontSize(13).fontColor(this.pal().text2)
          Text('点击“新建”打开规则编辑弹窗。').fontSize(11).fontColor(this.pal().text3)
        }.width('100%').padding(16).backgroundColor(this.pal().surface).borderRadius(12)
      } else {
        ForEach(this.profiles, (profile: SshForwardingProfile): void => {
          Row({ space: 10 }) {
            Column().width(8).height(8).borderRadius(4)
              .backgroundColor(this.stateColor(this.runtimeFor(profile.id)?.state ?? 'stopped'))
            Column({ space: 3 }) {
              Text(sshForwardingModeLabel(profile.mode) + ' · ' + profile.bindPort.toString())
                .fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
                .maxLines(1)
              Text(this.profileSummary(profile)).fontSize(10).fontColor(this.pal().text3)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%').height(58).padding({ left: 12, right: 12 })
            .borderRadius(10)
            .backgroundColor(this.selectedProfileId === profile.id
              ? this.pal().surface : Color.Transparent)
            .onClick((): void => { this.selectProfile(profile); })
        }, (profile: SshForwardingProfile): string => 'ssh-forward-profile-' + profile.id)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder private runtimeCard() {
    Column({ space: 8 }) {
      Row() {
        Text('运行状态').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          .layoutWeight(1)
        Column().width(8).height(8).borderRadius(4)
          .backgroundColor(this.stateColor(this.selectedRuntime()?.state ?? 'stopped'))
        Text(this.selectedRuntime() === null ? '未启动' : this.stateLabel(this.selectedRuntime()!.state))
          .fontSize(11).fontColor(this.pal().text2).margin({ left: 6 })
      }.width('100%')
      if (this.selectedRuntime() !== null) {
        Text('监听 ' + formatListenerHostPort(this.selectedRuntime()!.actualBindHost,
          this.selectedRuntime()!.actualBindPort, 'runtime'))
          .fontSize(11).fontColor(this.pal().text2).width('100%')
        Row() {
          Text('连接 ' + this.selectedRuntime()!.activeConnections.toString()).fontSize(11)
            .fontColor(this.pal().text3).layoutWeight(1)
          Text('流量 ' + this.formatBytes(this.selectedRuntime()!.transferredBytes)).fontSize(11)
            .fontColor(this.pal().text3)
        }.width('100%')
        if (this.selectedRuntime()!.lastError !== 0) {
          Text('错误代码 ' + this.selectedRuntime()!.lastError.toString()).fontSize(11)
            .fontColor(this.pal().danger).width('100%')
        }
      } else {
        Text('运行时只保存在当前 SSH 会话中；重连后按启动策略恢复。')
          .fontSize(11).fontColor(this.pal().text3).width('100%')
      }
    }.width('100%').padding(12).borderRadius(12).backgroundColor(this.pal().surface)
      .alignItems(HorizontalAlign.Start)
  }

  @Builder private editor(creating: boolean = false) {
    Scroll() {
      Column({ space: 12 }) {
        Row({ space: 8 }) {
          this.modeButton('Local', 'local', this.runtimeActive(this.selectedRuntime()))
          this.modeButton('Remote', 'remote', this.runtimeActive(this.selectedRuntime()))
          this.modeButton('Dynamic', 'dynamic', this.runtimeActive(this.selectedRuntime()))
        }.width('100%')

        Text(this.draft.mode === 'local'
          ? '设备本地监听，经当前 SSH 主机连接目标地址。'
          : (this.draft.mode === 'remote'
            ? 'SSH 主机远端监听，连接回设备可访问的目标地址。'
            : '设备本地提供 SOCKS5 CONNECT 代理，经当前 SSH 会话出站。'))
          .fontSize(11).fontColor(this.pal().text3).width('100%')

        Row({ space: 12 }) {
          Column() {
            this.field('监听地址', this.draft.bindHost, '127.0.0.1',
              this.runtimeActive(this.selectedRuntime()), (value: string): void => {
                this.mutateDraft((draft: SshForwardingDraft): void => { draft.bindHost = value; });
              })
          }.layoutWeight(2)
          Column() {
            this.field('监听端口', this.draft.bindPortText,
              this.draft.mode === 'dynamic' ? '1080' : '8022',
              this.runtimeActive(this.selectedRuntime()), (value: string): void => {
                this.mutateDraft((draft: SshForwardingDraft): void => { draft.bindPortText = value; });
              })
          }.layoutWeight(1)
        }.width('100%')

        if (this.draft.mode !== 'dynamic') {
          Row({ space: 12 }) {
            Column() {
              this.field('目标地址', this.draft.targetHost, '127.0.0.1',
                this.runtimeActive(this.selectedRuntime()), (value: string): void => {
                  this.mutateDraft((draft: SshForwardingDraft): void => { draft.targetHost = value; });
                })
            }.layoutWeight(2)
            Column() {
              this.field('目标端口', this.draft.targetPortText, '22',
                this.runtimeActive(this.selectedRuntime()), (value: string): void => {
                  this.mutateDraft((draft: SshForwardingDraft): void => { draft.targetPortText = value; });
                })
            }.layoutWeight(1)
          }.width('100%')
        }

        Row({ space: 12 }) {
          Column() {
            this.field('最大连接数', this.draft.maxConnectionsText, '16',
              this.runtimeActive(this.selectedRuntime()), (value: string): void => {
                this.mutateDraft((draft: SshForwardingDraft): void => { draft.maxConnectionsText = value; });
              })
          }.layoutWeight(1)
          Column() {
            this.field('流量上限（字节）', this.draft.maxBytesText, '留空表示不限',
              this.runtimeActive(this.selectedRuntime()), (value: string): void => {
                this.mutateDraft((draft: SshForwardingDraft): void => { draft.maxBytesText = value; });
              })
          }.layoutWeight(2)
        }.width('100%')

        Row() {
          Column({ space: 3 }) {
            Text('连接后自动启动').fontSize(13).fontColor(this.pal().text)
            Text('每次建立新的 session generation 后重新创建监听。')
              .fontSize(10).fontColor(this.pal().text3)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch,
            isOn: this.draft.startPolicy === 'onSessionReady' })
            .selectedColor(this.accentColor).enabled(!this.runtimeActive(this.selectedRuntime()))
            .onChange((enabled: boolean): void => {
              this.mutateDraft((draft: SshForwardingDraft): void => {
                draft.startPolicy = enabled ? 'onSessionReady' : 'manual';
              });
            })
        }.width('100%').height(52)

        Row() {
          Column({ space: 3 }) {
            Text('允许非 loopback 监听').fontSize(13).fontColor(this.pal().text)
            Text('可能向局域网或公网暴露端口，保存时会再次确认。')
              .fontSize(10).fontColor(this.pal().danger)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.draft.allowPublicBind })
            .selectedColor(this.pal().danger).enabled(!this.runtimeActive(this.selectedRuntime()))
            .onChange((enabled: boolean): void => {
              this.mutateDraft((draft: SshForwardingDraft): void => { draft.allowPublicBind = enabled; });
            })
        }.width('100%').height(52)

        Row() {
          Text('规则已启用').fontSize(13).fontColor(this.pal().text).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.draft.enabled })
            .selectedColor(this.accentColor).enabled(!this.runtimeActive(this.selectedRuntime()))
            .onChange((enabled: boolean): void => {
              this.mutateDraft((draft: SshForwardingDraft): void => { draft.enabled = enabled; });
            })
        }.width('100%').height(48)

        if (this.editorMessage.length > 0) {
          Text(this.editorMessage).fontSize(11).fontColor(this.pal().danger).width('100%')
        }
        if (this.statusMessage.length > 0) {
          Text(this.statusMessage).fontSize(11)
            .fontColor(this.statusMessage.startsWith('失败') ? this.pal().danger : this.pal().text2)
            .width('100%')
        }

        if (!creating) { this.runtimeCard() }

        if (creating) {
          Row({ space: 8 }) {
            Button('取消').layoutWeight(1).height(44).borderRadius(10)
              .backgroundColor(this.pal().surface).fontColor(this.pal().text2)
              .onClick((): void => { this.closeNewRuleEditor(true); })
            Button(this.ruleEditorCreating ? '创建规则' : '保存修改')
              .layoutWeight(1).height(44).borderRadius(10)
              .backgroundColor(this.accentColor).fontColor(Color.White)
              .onClick((): void => { this.saveDraft(true); })
          }.width('100%')
        } else {
          Row({ space: 8 }) {
            Button('保存').layoutWeight(1).height(44).borderRadius(10)
              .backgroundColor(this.accentColor).fontColor(Color.White)
              .enabled(!this.runtimeActive(this.selectedRuntime()))
              .onClick((): void => { this.saveDraft(); })
            if (this.runtimeActive(this.selectedRuntime())) {
              Button('停止').layoutWeight(1).height(44).borderRadius(10)
                .backgroundColor(this.pal().surface).fontColor(this.pal().danger)
                .onClick((): void => { this.onStop(this.selectedProfileId); })
            } else {
              Button('启动').layoutWeight(1).height(44).borderRadius(10)
                .backgroundColor(this.pal().surface).fontColor(this.accentColor)
                .enabled(this.connected && this.selectedProfile() !== null && !this.dirty && this.draft.enabled)
                .onClick((): void => { this.onStart(this.selectedProfileId); })
            }
            Button('删除').width(64).height(44).borderRadius(10)
              .backgroundColor(this.pal().surface).fontColor(this.pal().danger)
              .enabled(this.selectedProfile() !== null)
              .onClick((): void => { this.onRemove(this.selectedProfileId); })
          }.width('100%')
        }
      }.width('100%').padding({ bottom: 20 }).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Auto)
  }

  @Builder private emptyEditor() {
    Column({ space: 10 }) {
      Text(this.profiles.length === 0 ? '还没有转发规则' : '选择或新建转发规则')
        .fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(this.pal().text)
      Text(this.profiles.length === 0
        ? '新建 Local、Remote 或 Dynamic 规则后，可在这里查看状态并启动。'
        : '已有规则可在左侧选择后编辑；点击“+ 新建”会打开独立的规则编辑弹窗。')
        .fontSize(12).fontColor(this.pal().text3).textAlign(TextAlign.Center)
        .constraintSize({ maxWidth: 360 })
      Button('+ 新建规则').height(44).borderRadius(10).fontSize(13)
        .backgroundColor(this.accentColor).fontColor(Color.White)
        .onClick((): void => { this.openNewRuleEditor(); })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }

  @Builder private overviewPanel() {
    if (this.selectedProfile() === null) {
      this.emptyEditor()
    } else {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 4 }) {
            Text(sshForwardingModeLabel(this.selectedProfile()!.mode) + ' 转发')
              .fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
            Text(this.profileSummary(this.selectedProfile()!))
              .fontSize(11).fontColor(this.pal().text3).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button('编辑').height(38).width(64).borderRadius(9).fontSize(12)
            .backgroundColor(this.pal().surface).fontColor(this.accentColor)
            .enabled(!this.runtimeActive(this.selectedRuntime()))
            .onClick((): void => { this.openProfileRuleEditor(this.selectedProfile()!); })
        }.width('100%')

        Column({ space: 8 }) {
          Row() {
            Text('监听地址').fontSize(11).fontColor(this.pal().text3).layoutWeight(1)
            Text(formatListenerHostPort(this.selectedProfile()!.bindHost,
              this.selectedProfile()!.bindPort))
              .fontSize(11).fontColor(this.pal().text)
          }.width('100%')
          Row() {
            Text('目标').fontSize(11).fontColor(this.pal().text3).layoutWeight(1)
            Text(this.selectedProfile()!.mode === 'dynamic' ? 'SOCKS5 CONNECT' :
              formatEndpointFieldsHostPort(this.selectedProfile()!.targetHost,
                this.selectedProfile()!.targetPort))
              .fontSize(11).fontColor(this.pal().text)
          }.width('100%')
          Row() {
            Text('启动策略').fontSize(11).fontColor(this.pal().text3).layoutWeight(1)
            Text(this.selectedProfile()!.startPolicy === 'onSessionReady' ? '连接后自动启动' : '手动启动')
              .fontSize(11).fontColor(this.pal().text)
          }.width('100%')
        }.width('100%').padding(12).borderRadius(12).backgroundColor(this.pal().surface)

        this.runtimeCard()

        if (this.editorMessage.length > 0) {
          Text(this.editorMessage).fontSize(11).fontColor(this.pal().danger).width('100%')
        }
        if (this.statusMessage.length > 0) {
          Text(this.statusMessage).fontSize(11)
            .fontColor(this.statusMessage.startsWith('失败') ? this.pal().danger : this.pal().text2)
            .width('100%')
        }

        Row({ space: 8 }) {
          if (this.runtimeActive(this.selectedRuntime())) {
            Button('停止').layoutWeight(1).height(42).borderRadius(10)
              .backgroundColor(this.pal().surface).fontColor(this.pal().danger)
              .onClick((): void => { this.onStop(this.selectedProfileId); })
          } else {
            Button('启动').layoutWeight(1).height(42).borderRadius(10)
              .backgroundColor(this.accentColor).fontColor(Color.White)
              .enabled(this.connected && this.selectedProfile()!.enabled)
              .onClick((): void => { this.onStart(this.selectedProfileId); })
          }
          Button('删除').width(76).height(42).borderRadius(10)
            .backgroundColor(this.pal().surface).fontColor(this.pal().danger)
            .onClick((): void => { this.onRemove(this.selectedProfileId); })
        }.width('100%')
      }.width('100%').height('100%').alignItems(HorizontalAlign.Start)
    }
  }

  @Builder private NewRuleEditorContent(token: number) {
    Column() {
      Row() {
        Column({ space: 3 }) {
          Text(this.ruleEditorCreating ? '添加转发规则' : '编辑转发规则')
            .fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          Text('选择 Local、Remote 或 Dynamic，并确认监听范围。')
            .fontSize(11).fontColor(this.pal().text3).maxLines(1)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('×').width(44).height(44).borderRadius(22).fontSize(22)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2)
          .onClick((): void => { this.closeNewRuleEditor(true); })
      }.width('100%').height(56)
      Divider().color(this.pal().divider).margin({ bottom: 12 })
      Column() { this.editor(true) }.width('100%').layoutWeight(1)
    }.width('100%').height('100%')
      .padding({ left: 20, right: 20, top: 14, bottom: 16 })
      .backgroundColor(this.pal().sheetBg)
      .onAppear((): void => { this.onRuleEditorAppear(token); })
  }

  aboutToAppear(): void {
    if (this.profiles.length > 0) {
      this.selectProfile(this.profiles[0]);
    } else {
      this.selectedProfileId = '';
      this.dirty = false;
      this.editorMessage = '';
    }
    this.onRefresh();
  }

  aboutToDisappear(): void {
    this.ruleEditorCoordinator.invalidate();
    this.showRuleEditorSheet = false;
  }

  build() {
    Column() {
      Row() {
        Column({ space: 3 }) {
          Text('SSH 隧道转发').fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.pal().text)
          Text((this.hostLabel.length > 0 ? this.hostLabel + ' · ' : '') +
            (this.connected ? '会话已连接' : '等待 SSH 会话'))
            .fontSize(11).fontColor(this.pal().text3).maxLines(1)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('×').width(44).height(44).borderRadius(22).fontSize(22)
          .backgroundColor(this.pal().surface).fontColor(this.pal().text2)
          .onClick((): void => { this.onClose(); })
      }.width('100%').height(56)

      Divider().color(this.pal().divider).margin({ bottom: 12 })

      if (this.profiles.length === 0) {
        Column() { this.emptyEditor() }.width('100%').layoutWeight(1)
      } else if (this.breakpoint === 'sm') {
        Scroll() {
          Row({ space: 8 }) {
            Button('+ 新建').height(44).borderRadius(10).fontSize(12)
              .backgroundColor(this.pal().surface).fontColor(this.accentColor)
              .onClick((): void => { this.openNewRuleEditor(); })
            ForEach(this.profiles, (profile: SshForwardingProfile): void => {
              Button(sshForwardingModeLabel(profile.mode) + ' ' + profile.bindPort.toString())
                .height(44).borderRadius(10).fontSize(12)
                .backgroundColor(this.selectedProfileId === profile.id
                  ? this.accentColor : this.pal().surface)
                .fontColor(this.selectedProfileId === profile.id ? Color.White : this.pal().text2)
                .onClick((): void => { this.selectProfile(profile); })
            }, (profile: SshForwardingProfile): string => 'ssh-forward-mobile-' + profile.id)
          }.width('100%')
        }.width('100%').height(52).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
        Column() { this.overviewPanel() }.width('100%').layoutWeight(1)
      } else {
        Row({ space: 16 }) {
          Scroll() {
            this.profileList()
          }.width(270).height('100%').scrollBar(BarState.Auto)
            .padding({ right: 4 })
          Divider().vertical(true).color(this.pal().divider).height('100%')
          Column() { this.overviewPanel() }.layoutWeight(1).height('100%')
        }.width('100%').layoutWeight(1).constraintSize({ minHeight: 0 })
          .alignItems(VerticalAlign.Top)
      }
    }.width('100%').height('100%')
      .padding({ left: 20, right: 20, top: 14, bottom: 16 })
      .backgroundColor(this.pal().sheetBg)
      .bindSheet($$this.showRuleEditorSheet,
        this.NewRuleEditorContent(this.ruleEditorMountToken), {
        height: this.ruleEditorSheetLayout().heightVp,
        preferType: this.ruleEditorSheetLayout().bottomAnchored
          ? SheetType.BOTTOM : SheetType.CENTER,
        width: this.ruleEditorSheetWidth(),
        dragBar: this.ruleEditorSheetLayout().bottomAnchored,
        backgroundColor: this.pal().sheetBg,
        blurStyle: BlurStyle.NONE,
        showClose: false,
        maskColor: 'rgba(0,0,0,0.42)',
        onWillDismiss: (action: DismissSheetAction): void => {
          this.ruleEditorCoordinator.requestClose();
          this.restoreRuleEditorSelection();
          this.showRuleEditorSheet = false;
          action.dismiss();
        },
        onDisappear: (): void => {
          this.onRuleEditorDisappear(this.ruleEditorMountToken);
        }
      })
  }
}
