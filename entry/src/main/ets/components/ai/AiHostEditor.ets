import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppConfig, Palette, buildDark, buildLight } from '../../common/Theme';
import { appUiButtonText } from '../../common/AppUiColorPolicy';
import { AppUiMetrics } from '../../common/AppUiMetrics';
import { AiActionButton } from './AiActionButton';
import { AiBackendChoiceCard } from './AiBackendChoiceCard';
import { AiFormField } from './AiFormField';
import { ProBadge } from '../ProBadge';
import { AiHost, AiBackend, AI_BACKENDS, emptyAiHost, aiHostError, aiBackendDefaultPort, aiBackendName, aiBackendSubtitle } from '../../services/ai/AiModels';
import { AiAccess, AiAccountLease } from '../../services/ai/AiAccess';
import { AiLocalStore } from '../../services/ai/AiLocalStore';
import { AiBridgeClient } from '../../services/ai/AiBridgeClient';
import { aiRandomId } from '../../services/ai/AiTransport';
import { aiErrorText, parseAiInvite } from '../../services/ai/AiWirePolicy';
import { HostSyncService } from '../../services/HostSyncService';
import { RustDeskRelayConfig } from '../../model/RustDeskRelayConfig';
import { AiConnectionPathCard } from './AiConnectionPathCard';
import { AiLanDiscoveryService, AiLanScanStatus, DiscoveredAiAgent } from '../../services/ai/AiLanDiscoveryService';

@Component
export struct AiHostEditor {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @Prop host: AiHost | null = null;
  @Prop modern: boolean = true;
  @Prop canReturnToProtocols: boolean = false;
  /** Live window height from the hosting page; the form scrolls instead of pushing its buttons off screen. */
  @Prop viewportHeight: number = 0;
  onBackToProtocols: () => void = (): void => {};
  @StorageProp('remoteDesktopBgFlag') @Watch('onBackgroundChanged') inBackground: boolean = false;
  @State step: number = 1;
  onClose: () => void = (): void => {};
  /** Whether anything differs from how the flow opened (the page asks before throwing it away). */
  onDirtyChange: (dirty: boolean) => void = (_dirty: boolean): void => {};
  /** The fields as the editor opened (the port follows the backend, so it is not compared). */
  private draftBaseline: string = '';
  private draftDirty: boolean = false;
  onSaved: (id: string, connect: boolean) => void = (_id: string, _connect: boolean): void => {};
  @State @Watch('reportDirty') label: string = '';
  @State @Watch('reportDirty') address: string = '';
  @State @Watch('reportDirty') groupId: string = '';
  @State port: string = '9443';
  @State @Watch('reportDirty') serverName: string = '';
  @State backend: AiBackend = 'codex';
  @State transport: 'lan' | 'rustdesk' = 'lan';
  @State relayHostId: string = '';
  @State relays: RustDeskRelayConfig[] = [];
  @State lanScanning: boolean = false;
  @State lanAgents: DiscoveredAiAgent[] = [];
  @State lanStatus: AiLanScanStatus = 'idle';
  @State @Watch('reportDirty') invite: string = '';
  @State inviteStatus: string = '';
  @State paired: boolean = false;
  @State error: string = '';
  @State busy: boolean = false;
  @State defaultsPending: boolean = false;
  @State allowed: boolean = false;
  private draft: AiHost | null = null;
  private account: AiAccountLease | null = null;
  private alive: boolean = false;
  private editGeneration: number = 0;
  private unsubscribe: () => void = (): void => {};
  private lanDiscovery: AiLanDiscoveryService = new AiLanDiscoveryService();
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  aboutToAppear(): void {
    this.alive = true; this.editGeneration++; this.step = 1;
    try {
      this.account = AiAccess.getInstance().capture();
      this.draft = this.host === null ? emptyAiHost(this.account.owner, aiRandomId()) :
        JSON.parse(JSON.stringify(this.host)) as AiHost;
      this.groupId = this.draft.groupId; this.label = this.draft.label; this.address = this.draft.address; this.port = this.draft.port.toString();
      this.serverName = this.draft.serverName; this.backend = this.draft.backend;
      this.transport = this.draft.transport === 'rustdesk' ? 'rustdesk' : 'lan';
      this.relayHostId = this.draft.relayHostId || '';
      this.relays = HostSyncService.getInstance().getAllRelays();
      this.draftBaseline = this.draftSnapshot();
      void this.loadPairingState();
    } catch (error) { this.error = aiErrorText((error as Error).message); }
    this.unsubscribe = AiAccess.getInstance().subscribe((): void => {
      this.allowed = AiAccess.getInstance().executable(this.backend);
      if (!this.allowed) { this.editGeneration++; this.invite = ''; this.inviteStatus = ''; this.stopLanScan(); }
      if (this.account !== null && !AiAccess.getInstance().current(this.account)) {
        this.editGeneration++; this.invite = ''; this.inviteStatus = ''; this.paired = false; this.stopLanScan(); this.label = ''; this.address = ''; this.groupId = '';
        this.serverName = ''; this.draft = null; this.error = '账号已变化，请关闭后重新打开';
      }
    });
    if (this.host === null && this.account !== null) { void this.loadDefaults(); }
  }
  aboutToDisappear(): void {
    this.alive = false; this.editGeneration++; this.invite = ''; this.inviteStatus = ''; this.stopLanScan(); this.unsubscribe();
  }
  private onBackgroundChanged(): void {
    if (this.inBackground) {
      this.editGeneration++; this.invite = ''; this.inviteStatus = ''; this.stopLanScan();
    }
  }
  private async loadDefaults(): Promise<void> {
    const account = this.account, generation = this.editGeneration;
    if (account === null) { return; }
    this.defaultsPending = true;
    try {
      await AiLocalStore.getInstance().initialize(getContext(this) as common.UIAbilityContext);
      const settings = await AiLocalStore.getInstance().settings(account);
      if (!this.alive || this.inBackground || generation !== this.editGeneration ||
        !AiAccess.getInstance().current(account)) { return; }
      this.backend = settings.defaultBackend;
      this.port = aiBackendDefaultPort(this.backend).toString();
      this.allowed = AiAccess.getInstance().executable(this.backend);
    } catch (error) {
      if (this.alive && generation === this.editGeneration) { this.error = aiErrorText((error as Error).message); }
    } finally { this.defaultsPending = false; }
  }
  private async loadPairingState(): Promise<void> {
    const account = this.account, draft = this.draft, generation = this.editGeneration;
    if (account === null || draft === null || this.host === null) { this.paired = false; return; }
    try {
      await AiLocalStore.getInstance().initialize(getContext(this) as common.UIAbilityContext);
      const record = await AiLocalStore.getInstance().connection(account, draft.id);
      if (this.alive && generation === this.editGeneration && AiAccess.getInstance().current(account)) {
        this.paired = record !== null && record.identity !== null;
      }
    } catch (_error) { if (this.alive && generation === this.editGeneration) { this.paired = false; } }
  }
  private wizard(): boolean { return this.modern && this.host === null; }
  private draftHost(): AiHost | null {
    if (this.draft === null) { return null; }
    const next = JSON.parse(JSON.stringify(this.draft)) as AiHost;
    next.groupId = this.groupId.trim(); next.label = this.label.trim(); next.address = this.address.trim();
    next.port = Number(this.port); next.serverName = this.serverName.trim(); next.backend = this.backend;
    next.transport = this.transport; next.relayHostId = this.transport === 'rustdesk' ? this.relayHostId : '';
    return next;
  }
  private draftSnapshot(): string {
    return JSON.stringify([this.label, this.address, this.groupId, this.serverName, this.invite]);
  }

  private reportDirty(): void {
    if (this.draftBaseline === '') { return; }
    const dirty: boolean = this.draftSnapshot() !== this.draftBaseline;
    if (dirty !== this.draftDirty) {
      this.draftDirty = dirty;
      this.onDirtyChange(dirty);
    }
  }

  private nextStep(): void {
    if (this.busy || this.defaultsPending || this.inBackground) { return; }
    if (!this.allowed || !AiAccess.getInstance().proVisible()) {
      this.error = '远程 AI 需要有效 Pro 权益'; return;
    }
    const next = this.draftHost(); if (next === null) { return; }
    this.error = this.hostError(next); if (this.error === '') { this.step = 2; }
  }
  private previousStep(): void {
    if (this.busy) { return; } this.error = '';
    if (this.step === 2) { this.step = 1; }
    else if (this.canReturnToProtocols) { this.invite = ''; this.inviteStatus = ''; this.editGeneration++; this.onBackToProtocols(); }
  }
  private selectBackend(backend: AiBackend): void {
    if (this.busy || this.defaultsPending || !AiAccess.getInstance().proVisible() || this.backend === backend) { return; }
    this.backend = backend; this.port = aiBackendDefaultPort(backend).toString(); this.invite = ''; this.inviteStatus = ''; this.paired = false;
    this.stopLanScan();
    this.allowed = AiAccess.getInstance().executable(backend);
  }
  // Existing relay bindings stay stored and valid; they only cannot be saved again until the relay opens.
  private relayClosedError(host: AiHost): string {
    return host.transport === 'rustdesk' && !AiAccess.getInstance().relayTransportAvailable() ?
      'RustDesk 中继暂未开放，请改用局域网连接' : '';
  }
  private hostError(host: AiHost): string {
    const closed = this.relayClosedError(host);
    return closed !== '' ? closed : aiHostError(host);
  }
  private selectTransport(transport: 'lan' | 'rustdesk'): void {
    if (this.busy || this.defaultsPending || !AiAccess.getInstance().proVisible() || this.transport === transport) { return; }
    if (transport === 'rustdesk' && !AiAccess.getInstance().relayTransportAvailable()) { return; }
    this.transport = transport;
    if (transport !== 'lan') { this.stopLanScan(); }
    this.relayHostId = transport === 'lan' ? '' : this.relayHostId; this.paired = false;
    this.relays = HostSyncService.getInstance().getAllRelays();
    this.invite = ''; this.inviteStatus = '';
    this.error = '';
  }
  private selectRelay(relayId: string): void {
    if (this.busy || this.defaultsPending || !this.allowed) { return; }
    this.relayHostId = relayId;
    this.error = '';
  }
  private selectedRelayName(): string {
    const relay = this.relays.find((item: RustDeskRelayConfig): boolean => item.id === this.relayHostId);
    return relay === undefined ? '未选择中继' : relay.displayName();
  }
  private routeSummary(): string {
    return this.transport === 'lan' ? '局域网直连' : 'RustDesk 中继 · ' + this.selectedRelayName();
  }
  private stopLanScan(): void {
    this.lanDiscovery.stopScan(); this.lanScanning = false; this.lanAgents = [];
    this.lanStatus = 'idle';
  }
  private lanStatusText(): string {
    if (this.lanStatus === 'scanning') { return '正在搜索当前局域网…'; }
    if (this.lanStatus === 'completed') { return '已发现 ' + this.lanAgents.length.toString() + ' 个可用端口'; }
    if (this.lanStatus === 'no_private_network') { return '未找到可扫描的私有局域网地址'; }
    if (this.lanStatus === 'no_open_port') { return '没有发现开放的 AI Agent 端口'; }
    if (this.lanStatus === 'network_error') { return '读取局域网地址失败，请手动填写'; }
    if (this.lanStatus === 'cancelled') { return '搜索已取消'; }
    return '';
  }
  private startLanScan(): void {
    if (this.lanScanning || this.transport !== 'lan' || this.inBackground || this.busy || !this.allowed) { return; }
    const port: number = Number(this.port);
    if (!Number.isInteger(port) || port < 1 || port > 65535) { this.error = '请先填写有效的 Agent 端口'; return; }
    this.lanAgents = []; this.lanScanning = true; this.lanStatus = 'scanning'; this.error = '';
    const generation: number = this.editGeneration;
    void this.lanDiscovery.startScan(port, this.backend, (agent: DiscoveredAiAgent): void => {
      if (this.alive && generation === this.editGeneration && this.transport === 'lan') {
        this.lanAgents = this.lanAgents.concat([agent]);
      }
    }).then((agents: DiscoveredAiAgent[]): void => {
      if (this.alive && generation === this.editGeneration) {
        this.lanAgents = agents; this.lanStatus = this.lanDiscovery.getStatus(); this.lanScanning = false;
      }
    }).catch((_error: Error): void => {
      if (this.alive && generation === this.editGeneration) { this.lanScanning = false; this.lanStatus = 'network_error'; }
    });
  }
  private selectLanAgent(agent: DiscoveredAiAgent): void {
    if (this.busy || this.lanScanning || !this.allowed || !AiAccess.getInstance().proVisible()) { return; }
    this.address = agent.host; this.port = agent.port.toString(); this.paired = false;
    if (this.label.trim() === '') { this.label = agent.displayName; }
    this.error = '';
  }
  private async pasteInvite(): Promise<void> {
    if (this.busy || this.defaultsPending || !this.allowed || this.inBackground || !this.alive) { return; }
    try {
      const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      if (!board.hasDataSync()) { this.inviteStatus = '本机剪贴板没有配对邀请'; return; }
      const data: pasteboard.PasteData = await board.getData();
      const records: number = data.getRecordCount();
      for (let index = 0; index < records; index++) {
        const record: pasteboard.PasteDataRecord = data.getRecord(index);
        const types: string[] = record.getValidTypes([pasteboard.MIMETYPE_TEXT_PLAIN]);
        if (types.length === 0) { continue; }
        const value: pasteboard.ValueType = await record.getData(types[0]);
        if (typeof value === 'string' && value.trim() !== '') {
          try {
            parseAiInvite(value);
            this.invite = value; this.inviteStatus = '已读取有效邀请，请核对后保存或配对';
          } catch (error) {
            this.invite = ''; this.inviteStatus = aiErrorText((error as Error).message);
          }
          return;
        }
      }
      this.inviteStatus = '剪贴板中没有可读取的文本邀请';
    } catch (_error) { this.inviteStatus = '读取剪贴板失败，请长按输入框选择粘贴或手动输入'; }
  }
  private async save(connect: boolean): Promise<void> {
    if (!this.allowed || !AiAccess.getInstance().proVisible()) {
      this.error = '远程 AI 需要有效 Pro 权益'; return;
    }
    if (this.busy || this.defaultsPending || !this.alive || this.inBackground || this.draft === null || this.account === null) { return; }
    const next = this.draftHost(); if (next === null) { return; }
    const invitation = this.invite.trim(), account = this.account, generation = this.editGeneration;
    this.error = this.hostError(next); if (this.error !== '') { return; }
    if (invitation !== '' && next.transport !== 'lan') {
      this.error = 'RustDesk 中继暂不支持 AI 配对，请先保存绑定'; return;
    }
    let connectRequested: boolean = false;
    this.busy = true;
    try {
      AiAccess.getInstance().assertCurrent(account);
      await AiLocalStore.getInstance().initialize(getContext(this) as common.UIAbilityContext);
      if (!this.alive || this.inBackground || generation !== this.editGeneration ||
        !AiAccess.getInstance().proVisible() || !AiAccess.getInstance().executable(next.backend)) {
        throw new Error('AI_PRO_ACCESS_REQUIRED');
      }
      AiAccess.getInstance().assertCurrent(account);
      if (invitation !== '') {
        await AiBridgeClient.pair(next, invitation, 'HarmonyOS'); this.paired = true;
        if (!AiAccess.getInstance().proVisible() || !AiAccess.getInstance().executable(next.backend)) {
          throw new Error('AI_PRO_ACCESS_REQUIRED');
        }
        connectRequested = connect && next.transport === 'lan';
      } else {
        await AiLocalStore.getInstance().saveHost(account, next);
        if (!AiAccess.getInstance().proVisible() || !AiAccess.getInstance().executable(next.backend)) {
          throw new Error('AI_PRO_ACCESS_REQUIRED');
        }
        const stored = await AiLocalStore.getInstance().connection(account, next.id);
        if (!AiAccess.getInstance().proVisible() || !AiAccess.getInstance().executable(next.backend)) {
          throw new Error('AI_PRO_ACCESS_REQUIRED');
        }
        this.paired = stored !== null && stored.identity !== null;
        connectRequested = connect && next.transport === 'lan' && this.paired;
      }
      this.invite = '';
      if (this.alive && !this.inBackground && generation === this.editGeneration &&
        AiAccess.getInstance().proVisible() && AiAccess.getInstance().executable(next.backend) &&
        AiAccess.getInstance().current(account)) {
        this.onSaved(next.id, connectRequested);
      }
    } catch (error) { if (this.alive && generation === this.editGeneration) { this.error = aiErrorText((error as Error).message); } }
    finally { this.busy = false; }
  }
  @Builder private hostFields() {
    Text('选择电脑端 AI').fontSize(14).fontFamily(AppConfig.fontFamily).fontWeight(FontWeight.Medium)
      .fontColor(this.pal().text).width('100%')
    Column({ space: 10 }) {
      ForEach(AI_BACKENDS, (backend: AiBackend): void => {
        AiBackendChoiceCard({ backend, title: aiBackendName(backend), subtitle: aiBackendSubtitle(backend),
          isSelected: this.backend === backend, onSelect: (): void => { this.selectBackend(backend); } })
          .width('100%').enabled(!this.busy && !this.defaultsPending && AiAccess.getInstance().executable(backend))
      }, (backend: AiBackend): string => backend)
    }.width('100%')
    Text('连接路径').fontSize(14).fontFamily(AppConfig.fontFamily).fontWeight(FontWeight.Medium)
      .fontColor(this.pal().text).width('100%')
    Column({ space: 10 }) {
      AiConnectionPathCard({ path: 'lan', title: '局域网', subtitle: '直接连接电脑端 AI Agent', status: '可用',
        isSelected: this.transport === 'lan', isEnabled: !this.busy && !this.defaultsPending && this.allowed,
        onSelect: (): void => { this.selectTransport('lan'); } }).width('100%')
      AiConnectionPathCard({ path: 'rustdesk', title: 'RustDesk 中继', subtitle: '通过已配置的 RustDesk 中继转发',
        status: AiAccess.getInstance().relayTransportAvailable() ? '绑定' : '即将支持',
        isSelected: this.transport === 'rustdesk', isEnabled: !this.busy && !this.defaultsPending && this.allowed &&
          AiAccess.getInstance().relayTransportAvailable(),
        onSelect: (): void => { this.selectTransport('rustdesk'); } }).width('100%')
    }.width('100%')
    if (this.transport === 'lan') {
      Column({ space: 8 }) {
        Text('局域网搜索').fontSize(14).fontFamily(AppConfig.fontFamily).fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text).width('100%')
        Text('只扫描当前私有网段的 ' + this.port + ' 端口；搜索结果仍需通过邀请完成 mTLS 配对。')
          .fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
        AiActionButton({ label: this.lanScanning ? '正在搜索…' : '搜索局域网 Agent',
          isEnabled: !this.busy && !this.defaultsPending && !this.lanScanning && this.allowed,
          onAction: (): void => { this.startLanScan(); } })
        if (this.lanStatusText() !== '') {
          Text(this.lanStatusText()).fontSize(12).fontFamily(AppConfig.fontFamily)
            .fontColor(this.pal().text3).width('100%')
        }
        ForEach(this.lanAgents, (agent: DiscoveredAiAgent): void => {
          Row({ space: 10 }) {
            Column({ space: 3 }) {
              Text(agent.displayName).fontSize(15).fontWeight(FontWeight.Medium)
                .fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
              Text(agent.host + ':' + agent.port.toString()).fontSize(12).fontFamily(AppConfig.fontFamily)
                .fontColor(this.pal().text3)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            if (this.address === agent.host && Number(this.port) === agent.port) {
              Text('已选').fontSize(11).fontFamily(AppConfig.fontFamily)
                .fontColor(appUiButtonText(this.accent)).padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .borderRadius(8).backgroundColor(this.accent)
            }
          }.width('100%').height(58).padding({ left: 16, right: 16 })
            .borderRadius(14).backgroundColor(this.pal().surface)
            .border({ width: this.address === agent.host && Number(this.port) === agent.port ? 1.5 : 0.5,
              color: this.address === agent.host && Number(this.port) === agent.port ? this.accent : this.pal().cardBorder,
              style: BorderStyle.Solid })
            .focusable(true).accessibilityText('选择局域网 Agent ' + agent.displayName)
            .accessibilitySelected(this.address === agent.host && Number(this.port) === agent.port)
            .enabled(this.allowed)
            .onClick((): void => { this.selectLanAgent(agent); })
        }, (agent: DiscoveredAiAgent): string => agent.stableId)
      }.width('100%').padding(14).backgroundColor(this.pal().card).borderRadius(16)
        .border({ width: 0.5, color: this.pal().cardBorder, style: BorderStyle.Solid })
    }
    if (this.transport === 'rustdesk') {
      Text('选择 RustDesk 中继').fontSize(14).fontFamily(AppConfig.fontFamily).fontWeight(FontWeight.Medium)
        .fontColor(this.pal().text).width('100%')
      if (this.relays.length === 0) {
        Text('暂无已配置的 RustDesk 中继，请先在 RustDesk 中继设置中完成服务器和密钥绑定。')
          .fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
      } else {
        ForEach(this.relays, (relay: RustDeskRelayConfig): void => {
          Row({ space: 10 }) {
            Column({ space: 3 }) {
              Text(relay.displayName()).fontSize(15).fontWeight(FontWeight.Medium)
                .fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
              Text(relay.relayServer + ':' + relay.relayPort.toString())
                .fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            if (this.relayHostId === relay.id) {
              Text('已选').fontSize(11).fontFamily(AppConfig.fontFamily)
                .fontColor(appUiButtonText(this.accent)).padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .borderRadius(8).backgroundColor(this.accent)
            }
          }.width('100%').height(60).padding({ left: 16, right: 16 })
            .borderRadius(14).backgroundColor(this.pal().surface)
            .border({ width: this.relayHostId === relay.id ? 1.5 : 0.5,
              color: this.relayHostId === relay.id ? this.accent : this.pal().cardBorder, style: BorderStyle.Solid })
            .opacity(this.allowed ? 1 : 0.55)
            .focusable(true).accessibilityText('选择中继 ' + relay.displayName())
            .accessibilitySelected(this.relayHostId === relay.id)
            .onClick((): void => { this.selectRelay(relay.id); })
        }, (relay: RustDeskRelayConfig): string => relay.id)
      }
      Text('绑定只保存中继关系；当前 AI 数据通道仍需后续 RustDesk 转发实现。')
        .fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
    }
    AiFormField({ title: '名称', value: this.label, hint: '办公室 AI 工作区', limit: 100, isEnabled: !this.busy && !this.defaultsPending && this.allowed,
      onChange: (v: string): void => { this.label = v; } })
    AiFormField({ title: '分组（可选）', value: this.groupId, hint: '工作或个人', limit: 100, isEnabled: !this.busy && !this.defaultsPending && this.allowed,
      onChange: (v: string): void => { this.groupId = v; } })
    AiFormField({ title: this.transport === 'lan' ? '电脑地址' : '电脑地址（中继目标）', value: this.address,
      hint: this.transport === 'lan' ? '局域网 IP 或域名' : 'Agent 地址或已绑定目标地址', isEnabled: !this.busy && !this.defaultsPending && this.allowed,
      onChange: (v: string): void => { this.address = v; } })
    AiFormField({ title: '端口', value: this.port, hint: aiBackendDefaultPort(this.backend).toString(),
      limit: 5, inputType: InputType.Number, isEnabled: !this.busy && !this.defaultsPending && this.allowed, onChange: (v: string): void => { this.port = v; } })
    AiFormField({ title: '证书服务器名称（可选）', value: this.serverName, hint: '默认使用电脑地址', isEnabled: !this.busy && !this.defaultsPending && this.allowed,
      onChange: (v: string): void => { this.serverName = v; } })
  }
  @Builder private pairingFields() {
    if (this.wizard()) {
      Column({ space: 6 }) {
        Text(this.label).fontSize(16).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
        Text(aiBackendName(this.backend) + ' · ' + this.address + ':' + this.port + ' · ' + this.routeSummary())
          .fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2)
      }.width('100%').alignItems(HorizontalAlign.Start).padding(16).borderRadius(16).backgroundColor(this.pal().card)
    }
    Text('配对邀请').fontSize(14).fontFamily(AppConfig.fontFamily).fontWeight(FontWeight.Medium)
      .fontColor(this.pal().text).width('100%')
    TextArea({ text: this.invite, placeholder: '粘贴电脑生成的 JSON、二维码扫描结果或配对链接；留空可先保存主机' })
      .constraintSize({ minHeight: 112, maxHeight: 180 }).fontSize(13).fontFamily(AppConfig.fontFamily)
      .fontColor(this.pal().text).backgroundColor(this.pal().surface).borderRadius(12)
      .enabled(!this.busy && !this.defaultsPending && this.allowed && !this.inBackground).accessibilityText('配对邀请')
      .onChange((v: string): void => { if (this.alive && !this.inBackground && !this.busy && !this.defaultsPending && this.allowed) { this.invite = v; } }).maxLength(70000)
    AiActionButton({ label: '从剪贴板粘贴邀请（二维码/链接）', isEnabled: !this.busy && !this.defaultsPending && this.allowed && !this.inBackground,
      onAction: (): void => { void this.pasteInvite(); } })
    if (this.inviteStatus !== '') {
      Text(this.inviteStatus).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
    }
    Text('电脑端生成方式').fontSize(13).fontFamily(AppConfig.fontFamily).fontWeight(FontWeight.Medium)
      .fontColor(this.pal().text).width('100%')
    Text(aiBackendName(this.backend) + '：在插件目录运行 node bin/remotedesk-' + this.backend +
      '.mjs invite --state "$STATE" --projects <项目ID> --role operator --out "$STATE/invite.json"')
      .fontSize(11).fontFamily('monospace').fontColor(this.pal().text2).width('100%')
    Text('电脑端设置页默认显示二维码；扫描结果可以直接粘贴，二维码不可用时切换到链接配对并复制链接。邀请由电脑端本地签发，有效 120 秒且只能使用一次；完成配对后删除传输副本。')
      .fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
    Text('已配对主机可直接保存并连接。未配对主机请填写邀请，或先保存、稍后配对。')
      .fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
    Text('配对凭据仅保存在本机。更换连接地址需要重新配对；配对邀请在退出或进入后台时清除。')
      .fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
  }
  @Builder private actions() {
    if (this.wizard() && this.step === 1) {
      AiActionButton({ label: '下一步：配对与保存', primary: true, isEnabled: !this.busy && !this.defaultsPending && this.allowed,
        onAction: (): void => { this.nextStep(); } })
    } else {
      Row({ space: 10 }) {
        AiActionButton({ label: '保存', isEnabled: !this.busy && !this.defaultsPending && this.allowed, onAction: (): void => { void this.save(false); } }).layoutWeight(1)
        AiActionButton({ label: this.transport === 'rustdesk' ? '保存绑定' :
          (this.busy ? '处理中…' : (this.invite.trim() === '' && !this.paired ? '保存主机' : '保存并连接')), primary: true,
          isEnabled: !this.busy && !this.defaultsPending && this.allowed,
          onAction: (): void => { void this.save(true); } }).layoutWeight(1)
      }.width('100%')
    }
  }
  /** Room for the form between the title and the buttons (about 220vp together) in the live window. */
  private formMaxHeight(): number {
    const preferred: number = this.breakpoint === 'sm' ? 520 : 560;
    if (!Number.isFinite(this.viewportHeight) || this.viewportHeight <= 0) { return preferred; }
    return Math.max(160, Math.min(preferred, this.viewportHeight - 220));
  }

  build() {
    Column() {
      Row() {
        if (this.wizard() && (this.step === 2 || this.canReturnToProtocols)) {
          Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor([this.pal().text2]) }
            .width(36).height(36)
            .borderRadius(18).padding(0).backgroundColor(this.pal().surface)
            .enabled(!this.busy && !this.defaultsPending).accessibilityText(this.step === 2 ? '返回主机信息' : '返回协议选择')
            .onClick((): void => { this.previousStep(); })
        }
        Column({ space: 3 }) {
          Text(this.host === null ? '添加远程 AI' : '编辑远程 AI').fontSize(20).fontWeight(FontWeight.Bold)
            .fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
          Text(this.wizard() ? (this.step === 1 ? '1/2  基础信息' : '2/2  配对与保存') : '主机信息与配对')
            .fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          .margin({ left: this.wizard() && (this.step === 2 || this.canReturnToProtocols) ? 12 : 0 })
        ProBadge().alignSelf(ItemAlign.Center).margin({ right: 8 })
        Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text2]) }
          .width(AppUiMetrics.minTouchTarget).height(AppUiMetrics.minTouchTarget)
          .borderRadius(AppUiMetrics.minTouchTarget / 2).padding(0).backgroundColor(this.pal().surface)
          .accessibilityText('关闭远程 AI 编辑').onClick(this.onClose)
      }.width('100%').margin({ bottom: 18 })
      // Keep the editor adaptive on phone, Pad and PC: the sheet grows to the
      // content when it fits, while longer forms scroll inside the viewport.
      Scroll() {
        Column({ space: AppUiMetrics.sectionGap }) {
          if (!this.wizard() || this.step === 1) { this.hostFields() }
          if (!this.wizard() || this.step === 2) { this.pairingFields() }
          Text(this.transport === 'lan' ? '局域网直连 · TLS/mTLS 配对' : 'RustDesk 中继 · 需绑定 RustDesk 中继服务器')
            .fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
          if (!this.allowed) {
            Text('远程 AI 需要有效 Pro 权益。可先保存配置，配对与控制仍受设备、网络和电脑端授权保护。')
              .fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
          }
          if (this.error !== '') {
            Text(this.error).fontSize(13).fontFamily(AppConfig.fontFamily)
              .fontColor(this.pal().danger).width('100%')
          }
        }.width('100%')
      }.width('100%')
        .constraintSize({ maxHeight: this.formMaxHeight() })
        .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
      this.actions()
    }.width('100%').padding({ left: AppUiMetrics.sheetPadding, right: AppUiMetrics.sheetPadding,
      top: 20, bottom: AppUiMetrics.sheetPadding }).backgroundColor(this.pal().sheetBg)
  }
}
