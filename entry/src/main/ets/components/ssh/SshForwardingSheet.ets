import { Palette, buildDark, buildLight } from '../../common/Theme';
import {
  SshForwardingMode,
  SshForwardingProfile,
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

@Component
export struct SshForwardingSheet {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accentColor: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @Prop @Watch('onProfilesChanged') profiles: SshForwardingProfile[] = [];
  @Prop runtimes: SshForwardingRuntimeRecord[] = [];
  @Prop connected: boolean = false;
  @Prop hostLabel: string = '';
  @Prop statusMessage: string = '';
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
  private idNonce: number = 0;

  private pal(): Palette {
    return this.theme === 'light' ? buildLight(this.accentColor) : buildDark(this.accentColor);
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

  private onProfilesChanged(): void {
    if (this.profiles.length === 0) {
      if (!this.dirty) { this.createProfile('local'); }
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

  private saveDraft(): void {
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
    const bind: string = profile.bindHost + ':' + profile.bindPort.toString();
    if (profile.mode === 'dynamic') { return bind + ' · SOCKS5'; }
    return bind + ' → ' + profile.targetHost + ':' + profile.targetPort.toString();
  }

  @Builder private field(title: string, value: string, hint: string,
    disabled: boolean, change: (value: string) => void) {
    Column({ space: 5 }) {
      Text(title).fontSize(12).fontColor(this.pal().text2)
      TextInput({ text: value, placeholder: hint })
        .width('100%').height(44).fontSize(14).fontColor(this.pal().text)
        .placeholderColor(this.pal().text3).backgroundColor(this.pal().surface)
        .borderRadius(10).padding({ left: 12, right: 12 }).enabled(!disabled)
        .opacity(disabled ? 0.58 : 1).onChange(change)
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
          .onClick((): void => { this.createProfile('local'); })
      }.width('100%')
      if (this.profiles.length === 0) {
        Column({ space: 6 }) {
          Text('还没有转发规则').fontSize(13).fontColor(this.pal().text2)
          Text('在右侧填写并保存第一条规则。').fontSize(11).fontColor(this.pal().text3)
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

  @Builder private runtimeCard(runtime: SshForwardingRuntimeRecord | null) {
    Column({ space: 8 }) {
      Row() {
        Text('运行状态').fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.pal().text)
          .layoutWeight(1)
        Column().width(8).height(8).borderRadius(4)
          .backgroundColor(this.stateColor(runtime?.state ?? 'stopped'))
        Text(runtime === null ? '未启动' : this.stateLabel(runtime.state))
          .fontSize(11).fontColor(this.pal().text2).margin({ left: 6 })
      }.width('100%')
      if (runtime !== null) {
        Text('监听 ' + runtime.actualBindHost + ':' + runtime.actualBindPort.toString())
          .fontSize(11).fontColor(this.pal().text2).width('100%')
        Row() {
          Text('连接 ' + runtime.activeConnections.toString()).fontSize(11)
            .fontColor(this.pal().text3).layoutWeight(1)
          Text('流量 ' + this.formatBytes(runtime.transferredBytes)).fontSize(11)
            .fontColor(this.pal().text3)
        }.width('100%')
        if (runtime.lastError !== 0) {
          Text('错误代码 ' + runtime.lastError.toString()).fontSize(11)
            .fontColor(this.pal().danger).width('100%')
        }
      } else {
        Text('运行时只保存在当前 SSH 会话中；重连后按启动策略恢复。')
          .fontSize(11).fontColor(this.pal().text3).width('100%')
      }
    }.width('100%').padding(12).borderRadius(12).backgroundColor(this.pal().surface)
      .alignItems(HorizontalAlign.Start)
  }

  @Builder private editor() {
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

        this.runtimeCard(this.selectedRuntime())

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
      }.width('100%').padding({ bottom: 20 }).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').scrollBar(BarState.Auto)
  }

  aboutToAppear(): void {
    if (this.profiles.length > 0) {
      this.selectProfile(this.profiles[0]);
    } else {
      this.createProfile('local');
    }
    this.onRefresh();
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

      if (this.breakpoint === 'sm') {
        Scroll() {
          Row({ space: 8 }) {
            Button('+ 新建').height(44).borderRadius(10).fontSize(12)
              .backgroundColor(this.pal().surface).fontColor(this.accentColor)
              .onClick((): void => { this.createProfile('local'); })
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
        Column() { this.editor() }.width('100%').layoutWeight(1)
      } else {
        Row({ space: 16 }) {
          Scroll() {
            this.profileList()
          }.width(270).height('100%').scrollBar(BarState.Auto)
            .padding({ right: 4 })
          Divider().vertical(true).color(this.pal().divider).height('100%')
          Column() { this.editor() }.layoutWeight(1).height('100%')
        }.width('100%').layoutWeight(1).constraintSize({ minHeight: 0 })
          .alignItems(VerticalAlign.Top)
      }
    }.width('100%').height('100%')
      .padding({ left: 20, right: 20, top: 14, bottom: 16 })
      .backgroundColor(this.pal().sheetBg)
  }
}
