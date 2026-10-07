import { AppUiMetrics } from '../common/AppUiMetrics';
import { AiActionButton } from '../components/ai/AiActionButton';
import { AiFormField } from '../components/ai/AiFormField';
import { aiStatusLabel, aiRequestTitle, aiApprovalDetails, aiModeLabel, aiModeDetail, aiOperationSummary, aiShortTime, aiRelativeTime, aiEffortLabel, aiTokens, aiElapsed } from '../services/ai/AiPresentation';
import { aiParams } from '../services/ai/AiWirePolicy';
import { KeyboardAvoidMode, router, promptAction } from '@kit.ArkUI';
import { common, ApplicationStateChangeCallback } from '@kit.AbilityKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { util } from '@kit.ArkTS';
import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import { AppSheetHeader } from '../components/AppSheetHeader';
import { AiAccess, AiAccountLease } from '../services/ai/AiAccess';
import { AiHostService } from '../services/ai/AiHostService';
import { AiHost, AiProject, AiSession, AiTranscriptItem, AiApproval, AiPendingOperation, aiAgentEvents, aiBackendName } from '../services/ai/AiModels';
import { AiWorkspaceController } from '../services/ai/AiWorkspaceController';
import { AiLocalStore } from '../services/ai/AiLocalStore';
import { aiArray, aiRecord, aiString, aiErrorText } from '../services/ai/AiWirePolicy';
import { AiStylePalette, aiStylePalette } from '../services/ai/AiStylePalette';
import { AiStepEntry, aiStepEntries, aiStepSummary, aiStepGroupIcon } from '../services/ai/AiTimeline';
import { AiDiffFile, AiToolView, aiConversationItem, aiDiffFiles, aiDiffSignature, aiDiffStats, aiItemDiff, aiStepState, aiToolView } from '../services/ai/AiTimeline';
import { AiRemoteMarkdown } from '../components/ai/AiRemoteMarkdown';
import { AiDiffView } from '../components/ai/AiDiffView';

interface AiWsButton { label: string; primary: boolean; enabled: boolean; action: () => void; }
interface AiWsIconButton { symbol: Resource; label: string; enabled: boolean; action: () => void; }
interface AiWsTab { label: string; selected: boolean; enabled: boolean; action: () => void; }
interface AiHomeRow { key: string; session: AiSession | null; project: string; title: string; count: number; more: number; }
interface AiWsSheetHead { title: string; close: () => void; }
interface AiWsChoice { label: string; detail: string; selected: boolean; enabled: boolean; action: () => void; }
interface AiWsModes { values: string[]; selected: string; choose: (value: string) => void; }
interface AiWsChip { label: string; enabled: boolean; action: () => void; }
interface AiWsRoundAction { symbol: Resource; label: string; primary: boolean; enabled: boolean; action: () => void; }
interface AiQuestionValue { id: string; title: string; options: string[]; descriptions: string[]; multiple: boolean; selected: string[]; text: string; }
@Entry
@Component
export struct RemoteAiWorkspace {
  @StorageProp('currentTheme') theme: string = 'light';
  @StorageProp('accentColor') accent: string = '#007DFF';
  @StorageProp('topRectHeight') topInset: number = 0;
  @StorageProp('currentBreakpoint') breakpoint: string = 'sm';
  @State title: string = '远程 AI';
  @State status: string = '未连接';
  @State error: string = '';
  @State projects: AiProject[] = [];
  @State sessions: AiSession[] = [];
  @State items: AiTranscriptItem[] = [];
  @State approvals: AiApproval[] = [];
  @State operations: AiPendingOperation[] = [];
  @State terminals: Record<string, Object>[] = [];
  @State models: Record<string, Object>[] = [];
  @State questions: AiQuestionValue[] = [];
  @State draft: string = '';
  @State newTitle: string = '';
  @State busy: boolean = false;
  @State control: boolean = false;
  @State allowed: boolean = false;
  @State archived: boolean = false;
  @State sessionId: string = '';
  @State projectId: string = '';
  @State historyCursor: string = '';
  @State showDetails: boolean = false;
  @State showApproval: boolean = false;
  @State showApprovalDetails: boolean = false;
  @State detailTab: number = 0;
  /** The paired role: an operator sends and approves (control is taken on the first action); a viewer only reads. */
  @State role: string = '';
  /** Conversation list filter: '' for every project. */
  @State listFilter: string = '';
  @State listRefreshing: boolean = false;
  @State composerFocused: boolean = false;
  @State searching: boolean = false;
  @State query: string = '';
  @State showAddSheet: boolean = false;
  @State showModelList: boolean = false;
  @State showEffortList: boolean = false;
  @State showPermissionList: boolean = false;
  /** Drive the breathing 正在思考 and the turning ✳ (set once on appear; the animations repeat). */
  @State pulse: boolean = false;
  @State spin: number = 0;
  /** When the running turn started and the clock it is measured against (the Codex app's 已运行). */
  @State workingSince: number = 0;
  @State nowTick: number = 0;
  private elapsedTimer: number = -1;
  /** Projects whose whole conversation list is open on the home list (five show otherwise). */
  @State expandedProjects: string[] = [];
  /** Where the home composer starts a new conversation ('' picks the most recently used project). */
  @State homeProject: string = '';
  @State showModelPicker: boolean = false;
  @State currentModel: string = '';
  @State currentEffort: string = '';
  @State currentPermission: string = '';
  /** The engine's permission and collaboration modes (from the handshake), as state so the composer redraws. */
  @State permissionModes: string[] = [];
  @State collaborationModes: string[] = [];
  @State currentCollaboration: string = '';
  @State contextUsed: number = 0;
  @State contextWindow: number = 0;
  /** When each row was first drawn: a row animates in only then, not when a streamed change redraws it. */
  private firstSeen: Map<string, number> = new Map();
  private enterEffectValue: TransitionEffect | null = null;
  @State pageWidth: number = 320;
  @State pageHeight: number = 800;
  /** Measured header/tabs above and approval/composer below the transcript: the list takes exactly what is left. */
  @State topChrome: number = 56;
  @State bottomChrome: number = 0;
  private oldKeyboardAvoidMode: KeyboardAvoidMode | null = null;
  @State approval: AiApproval | null = null;
  @State diff: string = '';
  @State model: string = '';
  @State efforts: string[] = [];
  @State provider: string = '';
  @State effort: string = '';
  @State permission: string = '';
  @State collaboration: string = '';
  @State attachments: string[] = [];
  @State textSize: number = 15;
  @State showExecution: boolean = true;
  /** 'claude' | 'codex': the look chosen in 远程 AI 设置 → 界面风格. */
  @State uiStyle: string = 'claude';
  /** The controller's raw status ('running', 'idle', …); `status` holds its label. */
  @State rawStatus: string = '';
  @State expandedIds: string[] = [];
  /** Codex style: 0 对话 · 1 日志 · 2 差异 */
  @State codexTab: number = 0;
  /** Pro access lets this page (re)connect to its host, whether or not it is connected right now. */
  @State canReconnect: boolean = false;
  private controller: AiWorkspaceController = new AiWorkspaceController();
  private host: AiHost | null = null;
  private pageAccount: AiAccountLease | null = null;
  private stopPageAccess: () => void = (): void => {};
  private pendingForeground: boolean = false;
  private leaving: boolean = false;
  private alive: boolean = false;
  private mountGeneration: number = 0;
  private appStateCallback: ApplicationStateChangeCallback | null = null;
  private inBackground: boolean = false;
  private resumeSession: string = '';
  private resumeProject: string = '';
  private resumeAccount: AiAccountLease | null = null;
  private reconnectForeground: boolean = false;
  private preferencesReady: boolean = false;
  private pausedDuringSetup: boolean = false;
  private pal(): Palette { return this.theme === 'light' ? buildLight(this.accent) : buildDark(this.accent); }
  private sync(): void {
    if (!this.alive) { return; }
    const c = this.controller;
    if (this.pageAccount !== null && !AiAccess.getInstance().current(this.pageAccount)) {
      this.host = null; this.resumeAccount = null; this.resumeSession = ''; this.resumeProject = '';
      this.resetDrafts(); this.showDetails = false;
    } else if (!c.allowed) {
      this.resetDrafts(); this.showDetails = false;
    }
    this.title = c.title || this.host?.label || '远程 AI'; this.status = aiStatusLabel(c.status); this.error = c.error;
    this.rawStatus = c.status;
    this.projects = c.projects.slice(); this.sessions = c.sessions.slice();
    this.items = c.transcript.items.length > 0 || c.previewItems.length === 0 ? c.transcript.items.slice() : c.previewItems.slice();
    this.currentModel = c.currentModel; this.currentEffort = c.currentEffort;
    this.currentPermission = c.currentPermission; this.currentCollaboration = c.currentCollaboration;
    this.contextUsed = c.contextUsed; this.contextWindow = c.contextWindow;
    this.approvals = c.approvals.slice(); this.operations = c.operations.slice(); this.terminals = c.terminals.slice();
    this.models = c.models.slice(); this.allowed = c.allowed; this.archived = c.archived;
    this.sessionId = c.sessionId; this.projectId = c.projectId; this.historyCursor = c.historyCursor;
    this.control = c.lease !== '' && c.leaseExpires > Date.now(); this.diff = c.diff;
    this.role = c.client?.handshake?.role ?? '';
    this.permissionModes = c.client?.choices('permissionModes') ?? [];
    this.collaborationModes = c.client?.choices('collaborationModes') ?? [];
    if (this.listFilter !== '' && !this.projects.some((project: AiProject): boolean => project.id === this.listFilter)) { this.listFilter = ''; }
    // Only a conversation follows its newest message; the list keeps where the reader is (a pull to refresh jumped
    // to the bottom when the list followed too).
    if (this.sessionId !== '') { this.followTranscript(); }
    this.trackWorking();
    if (this.approval !== null && !this.approvals.some((item: AiApproval): boolean => item.id === this.approval?.id)) {
      this.showApproval = false; this.approval = null; this.questions = [];
    }
  }
  async aboutToAppear(): Promise<void> {
    const mount = ++this.mountGeneration;
    this.alive = true; this.controller.onChange = (): void => this.sync();
    try { this.pageAccount = AiAccess.getInstance().capture(); }
    catch (error) { this.error = aiErrorText((error as Error).message); return; }
    this.stopPageAccess = AiAccess.getInstance().subscribe((): void => {
      if (!this.alive) { return; }
      if (this.pageAccount === null || !AiAccess.getInstance().current(this.pageAccount)) {
        this.controller.close(); this.controller.status = '账号已变化，请返回主机列表'; this.sync();
      } else if (!AiAccess.getInstance().proVisible() ||
        (this.host !== null && !AiAccess.getInstance().executable(this.host.backend))) {
        this.resetDrafts(); this.showDetails = false; this.showApproval = false; this.allowed = false;
      }
      this.canReconnect = this.accessible();
    });
    this.inBackground = AppStorage.get<boolean>('remoteDesktopBgFlag') === true;
    const application = (getContext(this) as common.UIAbilityContext).getApplicationContext();
    this.appStateCallback = {
      onApplicationBackground: (): void => {
        if (!this.preferencesReady) { this.pausedDuringSetup = true; }
        this.resumeSession = this.controller.sessionId; this.resumeProject = this.controller.projectId;
        this.resumeAccount = this.controller.client?.account ?? null;
        this.inBackground = true; this.controller.close(); this.resetDrafts(); this.showDetails = false; this.controller.status = '已暂停连接'; this.sync();
      },
      onApplicationForeground: (): void => {
        const wasBackground = this.inBackground; this.inBackground = false;
        if (wasBackground && this.alive && this.preferencesReady && this.reconnectForeground) {
          if (this.busy) { this.pendingForeground = true; } else { void this.reconnect(); }
        }
      }
    };
    application.on('applicationStateChange', this.appStateCallback);
    const params = router.getParams() as Record<string, string>;
    await AiHostService.getInstance().refresh(getContext(this) as common.UIAbilityContext);
    if (!this.alive || mount !== this.mountGeneration || this.pageAccount === null || !AiAccess.getInstance().current(this.pageAccount)) { return; }
    this.host = AiHostService.getInstance().find(params['hostId'] ?? '');
    if (this.host === null) { this.error = '主机不存在或当前账号已变化'; return; }
    this.canReconnect = this.accessible();
    try {
      const account = AiAccess.getInstance().capture();
      const settings = await AiLocalStore.getInstance().settings(account);
      if (!this.alive || mount !== this.mountGeneration) { return; }
      AiAccess.getInstance().assertCurrent(account);
      this.textSize = settings.textSize; this.showExecution = settings.showExecution;
      this.uiStyle = settings.uiStyle === 'codex' ? 'codex' : 'claude';
      this.reconnectForeground = settings.reconnectOnForeground; this.preferencesReady = true;
    } catch (error) { if (this.alive) { this.error = aiErrorText((error as Error).message); } return; }
    this.inBackground = AppStorage.get<boolean>('remoteDesktopBgFlag') === true;
    if (this.inBackground || (this.pausedDuringSetup && !this.reconnectForeground)) { this.status = '已暂停连接'; return; }
    await this.reconnect();
  }
  aboutToDisappear(): void {
    if (this.elapsedTimer >= 0) { clearInterval(this.elapsedTimer); this.elapsedTimer = -1; }
    this.restoreKeyboardAvoid();
    this.mountGeneration++; this.alive = false; this.stopPageAccess(); this.stopPageAccess = (): void => {};
    this.controller.close(); this.resetDrafts();
    this.showDetails = false; this.host = null; this.pageAccount = null;
    if (this.appStateCallback !== null) {
      (getContext(this) as common.UIAbilityContext).getApplicationContext().off('applicationStateChange', this.appStateCallback);
      this.appStateCallback = null;
    }
  }
  private async run(work: () => Promise<void>): Promise<void> {
    if (this.busy || !this.alive || this.inBackground) { return; }
    this.busy = true; this.error = '';
    const mount = this.mountGeneration;
    try { await work(); }
    catch (error) { if (mount === this.mountGeneration && !this.inBackground) { this.controller.error = aiErrorText((error as Error).message); } }
    finally {
      this.busy = false; this.sync();
      if (this.pendingForeground && this.alive && !this.inBackground) { this.pendingForeground = false; void this.reconnect(); }
    }
  }
  /** Pro access lets this page use its host's backend right now (the connection itself may still be closed). */
  private accessible(): boolean {
    const host = this.host;
    return host !== null && this.pageAccount !== null && AiAccess.getInstance().current(this.pageAccount) &&
      AiAccess.getInstance().proVisible() && AiAccess.getInstance().executable(host.backend);
  }
  /** A new session, project or connection starts at the bottom of the conversation with everything folded. */
  private resetView(): void {
    this.followBottom = true; this.expandedIds = []; this.codexTab = 0;
  }
  private async reconnect(): Promise<void> {
    const host = this.host;
    // Gated on access, not on `allowed`: that reflects the connection, which the first open has yet to make.
    if (host === null || !this.accessible()) { return; }
    const resumeValid = this.resumeAccount !== null && AiAccess.getInstance().current(this.resumeAccount);
    const session = this.controller.sessionId || (resumeValid ? this.resumeSession : '');
    const project = this.controller.projectId || (resumeValid ? this.resumeProject : '');
    this.resumeSession = ''; this.resumeProject = ''; this.resumeAccount = null;
    await this.run(async (): Promise<void> => {
      this.resetView(); this.resetDrafts(); await this.controller.connect(host);
      if (project !== '' && this.controller.projects.some((item: AiProject): boolean => item.id === project)) {
        await this.controller.selectProject(project);
        if (session !== '' && this.controller.sessions.some((item: AiSession): boolean => item.id === session)) {
          await this.controller.selectSession(session);
        }
      }
    });
  }
  private resetDrafts(): void {
    this.model = ''; this.provider = ''; this.effort = ''; this.efforts = [];
    this.permission = ''; this.collaboration = ''; this.newTitle = '';
    this.attachments = []; this.draft = ''; this.approval = null; this.questions = []; this.showApproval = false;
    this.showApprovalDetails = false; this.detailTab = 0;
  }
  private capability(name: string): boolean { return this.controller.client?.capability(name) === true; }
  private async leave(): Promise<void> {
    if (this.leaving) { return; } this.leaving = true;
    const mount = this.mountGeneration;
    let timer: number = -1;
    try {
      const released = this.controller.release().then((): void => {}, (): void => {});
      const deadline = new Promise<void>((resolve): void => { timer = setTimeout(resolve, 800); });
      await Promise.race([released, deadline]);
    } finally {
      if (timer >= 0) { clearTimeout(timer); }
      this.controller.close();
      if (this.alive && mount === this.mountGeneration) { router.back(); }
    }
  }
  /** Back from a conversation returns to the list (like the Codex and Claude apps); back from the list leaves. */
  onBackPress(): boolean {
    if (this.sessionId !== '') { void this.backToList(); } else { void this.leave(); }
    return true;
  }
  private trackWorking(): void {
    const running = this.sessionId !== '' && this.working();
    if (running && this.workingSince === 0) {
      this.workingSince = Date.now(); this.nowTick = this.workingSince;
      if (this.elapsedTimer < 0) { this.elapsedTimer = setInterval((): void => { this.nowTick = Date.now(); }, 1000); }
    } else if (!running && this.workingSince !== 0) {
      this.workingSince = 0;
      if (this.elapsedTimer >= 0) { clearInterval(this.elapsedTimer); this.elapsedTimer = -1; }
    }
  }
  private changeStats(): string {
    let added = 0, removed = 0;
    this.stepDiffs().forEach((file: AiDiffFile): void => { added += file.added; removed += file.removed; });
    return aiDiffStats(added, removed);
  }
  private async refreshList(): Promise<void> {
    try { await this.run(async (): Promise<void> => { await this.controller.refreshSessions(); }); }
    finally { this.listRefreshing = false; }
  }
  private async backToList(): Promise<void> {
    this.resetView(); this.followBottom = false; this.showModelPicker = false;
    await this.run(async (): Promise<void> => { this.resetDrafts(); await this.controller.closeSession(); });
    try { this.listScroller?.scrollEdge(Edge.Top); } catch (_error) { /* not laid out */ }
  }
  /** Fades and lifts a row in (made on first use: the page fields are plain values). */
  private enterEffect(): TransitionEffect {
    if (this.enterEffectValue === null) {
      this.enterEffectValue = TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 14 }))
        .animation({ duration: 280, curve: Curve.FastOutSlowIn });
    }
    return this.enterEffectValue;
  }
  /** True only the first moment a row is drawn, so it animates in once. */
  private fresh(key: string): boolean {
    const now = Date.now(), seen = this.firstSeen.get(key);
    if (seen === undefined) {
      if (this.firstSeen.size > 4000) { this.firstSeen.clear(); }
      this.firstSeen.set(key, now); return true;
    }
    return now - seen < 500;
  }
  private modelRow(id: string): Record<string, Object> | undefined {
    return this.models.find((row: Record<string, Object>): boolean =>
      aiString(row['model'], aiString(row['id'])) === id || aiString(row['id']) === id);
  }
  private chosenModel(): string {
    if (this.model !== '') { return this.model; }
    if (this.currentModel !== '') { return this.currentModel; }
    // Before a conversation reports its model (the home composer, a new conversation): the engine's default.
    const fallback = this.models.find((row: Record<string, Object>): boolean => row['isDefault'] === true) ?? this.models[0];
    return fallback === undefined ? '' : aiString(fallback['model'], aiString(fallback['id']));
  }
  private chosenEffort(): string {
    if (this.effort !== '') { return this.effort; }
    if (this.currentEffort !== '') { return this.currentEffort; }
    const row = this.modelRow(this.chosenModel());
    return row === undefined ? '' : aiString(row['defaultReasoningEffort']);
  }
  private modelName(id: string): string {
    const row = this.modelRow(id);
    return row === undefined ? id : aiString(row['displayName'], aiString(row['name'], id));
  }
  private effortChoices(): string[] {
    if (this.efforts.length > 0) { return this.efforts; }
    const row = this.modelRow(this.chosenModel());
    return row === undefined ? [] : aiArray(row['supportedReasoningEfforts']).map((value: Object): string =>
      aiString(aiRecord(value)['reasoningEffort'])).filter((value: string): boolean => value !== '');
  }
  private chooseModel(row: Record<string, Object>): void {
    if (this.busy || !this.allowed) { return; }
    this.model = aiString(row['model'], aiString(row['id'])); this.provider = aiString(row['provider']); this.effort = '';
    this.efforts = aiArray(row['supportedReasoningEfforts']).map((value: Object): string => aiString(aiRecord(value)['reasoningEffort']));
  }
  private chosenPermission(): string {
    if (this.permission !== '') { return this.permission; }
    if (this.currentPermission !== '') { return this.currentPermission; }
    // What the bridge applies when nothing is chosen: Codex starts read-only, DSH in the project folder.
    const fallback = this.host?.backend === 'dsh' ? 'workspace-write' : 'read-only';
    return this.permissionModes.includes(fallback) ? fallback : '';
  }
  private homeProjectId(): string {
    if (this.homeProject !== '' && this.projects.some((project: AiProject): boolean => project.id === this.homeProject)) { return this.homeProject; }
    if (this.listFilter !== '') { return this.listFilter; }
    const recent = this.listedSessions()[0];
    return recent !== undefined ? recent.project : (this.projects.length > 0 ? this.projects[0].id : '');
  }
  private composerPlaceholder(): string {
    if (this.sessionId === '') { return '向 ' + this.backendName() + ' 提问，开始新对话'; }
    if (this.archived) { return '先恢复归档会话'; }
    return this.uiStyle === 'codex' ? '跟进' : '回复 ' + this.backendName() + '…';
  }
  /** The home composer's send: a new conversation in the chosen project, titled by the prompt, then the prompt. */
  private async startChat(): Promise<void> {
    const text = this.draft.trim(), project = this.homeProjectId();
    if (text === '' || project === '' || !this.allowed || !AiAccess.getInstance().proVisible()) { return; }
    this.resetView();
    await this.run(async (): Promise<void> => {
      const title = text.split('\n')[0].slice(0, 40);
      await this.controller.create(title, project);
      const params: Record<string, Object> = aiParams(["text"], [text]);
      params['settings'] = this.settings();
      if (this.attachments.length > 0) { params['attachments'] = this.attachments.slice(); }
      const sentAt = this.controller.transcript.mark();
      const result = await this.controller.action('turn.start', params);
      if (this.host !== null && aiAgentEvents(this.host.backend)) { this.controller.transcript.echo(text, aiString(result['turnId']), sentAt); }
      this.draft = ''; this.attachments = [];
    });
  }
  private modelChipLabel(): string {
    const model = this.chosenModel(), effort = this.chosenEffort();
    return (model !== '' ? this.modelName(model) : '模型') + (effort !== '' ? ' · ' + aiEffortLabel(effort) : '');
  }
  private settings(): Record<string, Object> {
    const settings: Record<string, Object> = {};
    if (this.model !== '') { settings['model'] = this.model; }
    if (this.provider !== '' && this.host?.backend === 'dsh') { settings['provider'] = this.provider; }
    if (this.effort !== '') { settings['reasoningEffort'] = this.effort; }
    if (this.permission !== '') { settings['permissionMode'] = this.permission; }
    if (this.collaboration !== '') { settings['collaborationMode'] = this.collaboration; }
    return settings;
  }
  private async send(steer: boolean): Promise<void> {
    const text = this.draft.trim(); if (text === '' || !this.allowed || !AiAccess.getInstance().proVisible()) { return; }
    await this.run(async (): Promise<void> => {
      const params: Record<string, Object> = aiParams(["text"], [text]);
      if (!steer) {
        params['settings'] = this.settings();
        if (this.attachments.length > 0) { params['attachments'] = this.attachments.slice(); }
      }
      // Taken before sending: the engine's own copy of the prompt may arrive before the acknowledgement.
      const sentAt = this.controller.transcript.mark();
      const result = await this.controller.action(steer ? 'turn.steer' : 'turn.start', params);
      // Pi echoes the prompt only once its turn takes it; show it until its own event arrives.
      if (this.host !== null && aiAgentEvents(this.host.backend)) { this.controller.transcript.echo(text, aiString(result['turnId']), sentAt); }
      this.draft = ''; this.attachments = [];
    });
  }
  private async attach(photo: boolean = false): Promise<void> {
    if (!this.allowed || !AiAccess.getInstance().proVisible()) { return; }
    await this.run(async (): Promise<void> => {
      const client = this.controller.client; const project = this.projectId;
      if (client === null || this.attachments.length >= 4) { return; }
      // Photos come from the gallery picker, files (text and images) from the file picker.
      const selected: string[] = photo ?
        (await new photoAccessHelper.PhotoViewPicker().select({ MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
          maxSelectNumber: 1 })).photoUris :
        await new picker.DocumentViewPicker().select({ maxSelectNumber: 1, fileSuffixFilters: ['附件|.txt,.md,.png,.jpg,.jpeg'] });
      if (selected.length !== 1 || client !== this.controller.client || project !== this.projectId || !this.alive) { return; }
      const uri = selected[0];
      let mime = 'text/plain';
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      let bytes = new Uint8Array(0);
      try {
        const size = fileIo.statSync(file.fd).size;
        if (size <= 0 || size > 512000) { throw new Error('AI_ATTACHMENT_SIZE'); }
        bytes = new Uint8Array(size); const count = fileIo.readSync(file.fd, bytes.buffer);
        if (count !== size) { throw new Error('AI_ATTACHMENT_READ'); }
      } finally { fileIo.closeSync(file); }
      if (bytes.length >= 8 && bytes[0] === 137 && bytes[1] === 80 && bytes[2] === 78 && bytes[3] === 71 &&
        bytes[4] === 13 && bytes[5] === 10 && bytes[6] === 26 && bytes[7] === 10) { mime = 'image/png'; }
      else if (bytes.length >= 3 && bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) { mime = 'image/jpeg'; }
      else { util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes); }
      if (mime !== 'text/plain') {
        const selection = this.models.find((row: Record<string, Object>): boolean =>
          aiString(row['model'], aiString(row['id'])) === this.model &&
          (this.provider === '' || aiString(row['provider']) === this.provider));
        const modalities = selection === undefined ? this.controller.inputModalities : aiArray(selection['inputModalities']);
        if (!modalities.includes('image')) { throw new Error('AI_MODEL_IMAGE_UNAVAILABLE'); }
      }
      const result = await client.write('attachment.upload', aiParams(["projectId", "mime", "data"], [project, mime, new util.Base64Helper().encodeToStringSync(bytes)]));
      if (client === this.controller.client && project === this.projectId) {
        this.attachments = this.attachments.concat([aiString(result['attachmentId'])]);
      }
    });
  }
  private inspect(approval: AiApproval): void {
    this.prepareApproval(approval);
    this.showApproval = true;
  }
  /** Makes `approval` the one the answer buttons act on, without opening the full request sheet. */
  private prepareApproval(approval: AiApproval): void {
    if (this.approval?.id === approval.id) { return; }
    this.approval = approval; this.showApprovalDetails = false;
    this.questions = aiArray(approval.request['questions']).map((value: Object): AiQuestionValue => {
      const row = aiRecord(value);
      return { id: aiString(row['id']), title: aiString(row['question'], aiString(row['header'])),
        options: aiArray(row['options']).map((option: Object): string => typeof option === 'string' ? option as string : aiString(aiRecord(option)['label'])),
        descriptions: aiArray(row['options']).map((option: Object): string => typeof option === 'string' ? '' : aiString(aiRecord(option)['description'])),
        multiple: row['multiSelect'] === true, selected: [], text: '' };
    });
  }
  private palette(): AiStylePalette { return aiStylePalette(this.uiStyle === 'codex' ? 'codex' : 'claude', this.theme !== 'light'); }
  private backendName(): string { return this.host === null ? '远程 AI' : aiBackendName(this.host.backend); }
  /** A turn is under way (or was just accepted and has not reported back yet). */
  private working(): boolean {
    return ['running', 'inProgress'].includes(this.rawStatus) || this.rawStatus.startsWith('请求已接受');
  }
  /** The turn ended but tasks it started (a dev server, a watcher) still run on the computer. */
  private backgroundTasks(): boolean { return this.rawStatus === 'background'; }
  /** The composer's main button: stop the running turn, or send a new one (also while background tasks run). */
  /** An operator device sends and approves; control is taken on its first action, there is no separate step. */
  private operator(): boolean { return this.role === 'operator'; }
  private composerMode(): string { return this.working() && this.operator() ? 'stop' : 'send'; }
  /** Follows new output while the reader is at the bottom; scrolling up stops following until they return. */
  private listScroller: Scroller | null = null;
  private followBottom: boolean = true;
  private scroller(): Scroller {
    if (this.listScroller === null) { this.listScroller = new Scroller(); }
    return this.listScroller;
  }
  /** The transcript rows the current style and tab show (the Codex diff tab shows its own pane instead). */
  private shownItems(): AiTranscriptItem[] { return this.visibleItems(); }
  /** Messages, and each run of consecutive steps as one entry (computed once per transcript change). */
  private stepEntriesFor: AiTranscriptItem[] | null = null;
  private stepEntriesValue: AiStepEntry[] = [];
  private stepEntries(): AiStepEntry[] {
    const items = this.shownItems();
    if (this.stepEntriesFor !== items) { this.stepEntriesFor = items; this.stepEntriesValue = aiStepEntries(items); }
    return this.stepEntriesValue;
  }
  private entryKey(entry: AiStepEntry): string {
    if (entry.item !== null) {
      const item = entry.item;
      return item.id + ':' + item.state + ':' + item.text.length.toString() + ':' + (item.output ?? '').length.toString() +
        (this.expanded(item.id) ? ':open' : '');
    }
    let signature = '';
    entry.steps.forEach((step: AiTranscriptItem): void => {
      signature += step.state.slice(0, 2) + (step.text.length + (step.output ?? '').length).toString() + (this.expanded(step.id) ? 'o' : '') + ',';
    });
    return entry.key + ':' + entry.steps.length.toString() + ':' + signature + (this.expanded(entry.key) ? ':open' : '');
  }
  /** Rows in the list, the same way build() lays them out, so following knows where the bottom is. */
  private listLength(): number {
    if (this.sessionId === '') { return 1 + this.homeRows().length; }
    let count = (this.historyCursor !== '' ? 1 : 0) + (this.items.length === 0 ? 1 : 0);
    count += this.stepEntries().length + (this.working() ? 1 : 0);
    if (this.changeSummary() !== '') { count++; }
    return count;
  }
  /**
   * The home list: in 全部 with several projects, each project (most recently used first) heads its newest
   * conversations, five at first with the rest behind 展开; a filtered project lists all of its conversations.
   */
  private homeRows(): AiHomeRow[] {
    const listed = this.listedSessions();
    const rows: AiHomeRow[] = [];
    if (this.listFilter !== '' || this.projects.length === 0 || this.uiStyle !== 'codex' || this.query.trim() !== '') {
      listed.forEach((session: AiSession): void => {
        rows.push({ key: 's:' + session.id + ':' + session.title + ':' + session.updatedAt.toString(), session,
          project: session.project, title: '', count: 0, more: 0 });
      });
      return rows;
    }
    const order: string[] = [];
    listed.forEach((session: AiSession): void => { if (!order.includes(session.project)) { order.push(session.project); } });
    this.projects.forEach((project: AiProject): void => { if (!order.includes(project.id)) { order.push(project.id); } });
    for (const project of order) {
      const own = listed.filter((session: AiSession): boolean => session.project === project);
      const open = this.expandedProjects.includes(project);
      rows.push({ key: 'h:' + project + ':' + own.length.toString(), session: null, project,
        title: this.projectTitle(project), count: own.length, more: 0 });
      own.slice(0, open ? own.length : 5).forEach((session: AiSession): void => {
        rows.push({ key: 's:' + session.id + ':' + session.title + ':' + session.updatedAt.toString() + ':g', session,
          project, title: '', count: 0, more: 0 });
      });
      if (own.length > 5) {
        rows.push({ key: 'm:' + project + ':' + (open ? 'open' : own.length.toString()), session: null, project,
          title: open ? '收起' : '还有 ' + (own.length - 5).toString() + ' 个对话', count: own.length, more: own.length - 5 });
      }
    }
    return rows;
  }
  /** Until then the list is still settling (rows measured lazily, chrome measured late): keep pinning the bottom. */
  private pinBottomUntil: number = 0;
  private followTranscript(): void {
    const scroller = this.listScroller;
    if (scroller === null || !this.followBottom) { return; }
    // One scroll on the next frame landed above the end when a session opened: the rows below were not measured yet
    // and the first layout from the top reported "not at the bottom". Pin it while the layout settles.
    this.pinBottomUntil = Date.now() + 700;
    for (const delay of [0, 120, 360, 700]) {
      setTimeout((): void => {
        if (!this.followBottom) { return; }
        try { scroller.scrollEdge(Edge.Bottom); } catch (_error) { /* list not laid out yet */ }
      }, delay);
    }
  }
  private canAttach(): boolean {
    return this.allowed && !this.busy && (this.controller.client?.choices('attachments').length ?? 0) > 0 &&
      this.attachments.length < 4;
  }
  private measured(next: Area, current: number): number {
    const height = Number(next.height);
    return Number.isFinite(height) && height >= 0 && Math.abs(height - current) > 0.5 ? height : current;
  }
  /**
   * The keyboard resizes this page instead of pushing it up: the header stays under the status bar and the composer
   * and its send button stay above the keyboard (by default the whole page slid up and the send button was covered).
   */
  onPageShow(): void {
    if (this.oldKeyboardAvoidMode !== null) { return; }
    try {
      const ui = this.getUIContext();
      const previous = ui.getKeyboardAvoidMode();
      ui.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
      this.oldKeyboardAvoidMode = previous;
    } catch (_error) { this.oldKeyboardAvoidMode = null; }
  }
  onPageHide(): void { this.restoreKeyboardAvoid(); }
  private restoreKeyboardAvoid(): void {
    const previous = this.oldKeyboardAvoidMode;
    if (previous === null) { return; }
    this.oldKeyboardAvoidMode = null;
    try { this.getUIContext().setKeyboardAvoidMode(previous); } catch (_error) { /* the window is gone */ }
  }
  private composerMaxHeight(): number { return this.pageHeight < 500 ? 72 : 140; }
  private expanded(id: string): boolean { return this.expandedIds.includes(id); }
  private toggleExpanded(id: string): void {
    this.expandedIds = this.expanded(id) ? this.expandedIds.filter((value: string): boolean => value !== id) :
      this.expandedIds.concat([id]);
  }
  /** With 显示工具执行过程 off only tool steps and thinking are hidden; notices (errors, compaction) stay. */
  private visibleItems(): AiTranscriptItem[] {
    if (this.showExecution) { return this.items; }
    return this.items.filter((item: AiTranscriptItem): boolean => {
      const kind = item.kind ?? (item.role === 'execution' ? 'tool' : item.role);
      return kind !== 'tool' && kind !== 'thinking';
    });
  }
  private toolView(item: AiTranscriptItem): AiToolView { return aiToolView(item); }
  // Diffs are parsed and signed once per change of the steps (or of the native diff), not on every render: streamed
  // answer text changes the transcript many times a second without changing any step.
  private stepDiffItems: AiTranscriptItem[] | null = null;
  private stepDiffKey: string = '';
  private stepDiffFiles: AiDiffFile[] = [];
  private nativeDiffSource: string | null = null;
  private nativeDiffFiles: AiDiffFile[] = [];
  private nativeDiffSig: string = '';
  private sessionDiffBase: AiDiffFile[] | null = null;
  private sessionDiffFiles: AiDiffFile[] = [];
  private sessionDiffSig: string = '';
  /** Every change the steps of this session carry, newest last (used when the engine has no native diff). */
  private stepDiffs(): AiDiffFile[] {
    if (this.stepDiffItems !== this.items) {
      this.stepDiffItems = this.items;
      // Diffs come from tool steps only; their inputs and outputs grow or settle. Lengths and both ends tell a change.
      const ends = (text: string): string => text.length.toString() + ':' +
        (text.length > 48 ? text.slice(0, 24) + text.slice(text.length - 24) : text);
      const key = this.items.filter((item: AiTranscriptItem): boolean => item.role === 'execution')
        .map((item: AiTranscriptItem): string => item.id + '\u0001' + item.title + '\u0001' + ends(item.detail ?? '') +
          '\u0001' + ends(item.output ?? '')).join('\u0002');
      if (key !== this.stepDiffKey) {
        let files: AiDiffFile[] = [];
        this.items.forEach((item: AiTranscriptItem): void => { files = files.concat(aiItemDiff(item)); });
        this.stepDiffFiles = files.filter((file: AiDiffFile): boolean => file.lines.length > 0);
        this.stepDiffKey = key;
      }
    }
    return this.stepDiffFiles;
  }
  /** The engine's own diff (diff.read), parsed and bounded; empty when it is not a diff. */
  private nativeDiffs(): AiDiffFile[] {
    if (this.nativeDiffSource !== this.diff) {
      this.nativeDiffFiles = this.diff.includes('@@') || this.diff.startsWith('diff ') ? aiDiffFiles(this.diff) : [];
      this.nativeDiffSig = aiDiffSignature(this.nativeDiffFiles);
      this.nativeDiffSource = this.diff;
    }
    return this.nativeDiffFiles;
  }
  /** Identifies the native diff's content (the details sheet rebuilds its view when it changes). */
  private nativeDiffKey(): string {
    this.nativeDiffs();
    return this.nativeDiffSig;
  }
  private sessionDiffs(): AiDiffFile[] {
    const native = this.nativeDiffs();
    const base = native.length > 0 ? native : this.stepDiffs();
    if (this.sessionDiffBase !== base) {
      this.sessionDiffFiles = base;
      this.sessionDiffSig = base === native ? this.nativeDiffSig : aiDiffSignature(base);
      this.sessionDiffBase = base;
    }
    return this.sessionDiffFiles;
  }
  /** Identifies the diff pane's content, so the pane is rebuilt exactly when the diff changes. */
  private sessionDiffKey(): string {
    this.sessionDiffs();
    return this.sessionDiffSig;
  }
  /** What diff.read said when it is not a diff (unavailable, an error), bounded for display. */
  private diffNotice(empty: string): string {
    if (this.diff === '' || this.nativeDiffs().length > 0) { return empty; }
    return this.diff.length > 2000 ? this.diff.slice(0, 2000) + '\n…（其余内容在电脑端）' : this.diff;
  }
  private changeSummary(): string {
    const files = this.stepDiffs();
    if (files.length === 0) { return ''; }
    let added = 0, removed = 0;
    files.forEach((file: AiDiffFile): void => { added += file.added; removed += file.removed; });
    return '修改了 ' + files.length.toString() + ' 个文件 · ' + aiDiffStats(added, removed);
  }
  /** Pi's file approvals carry the whole edit in their input; Codex ones need the native item to be complete. */
  private approvalAcceptable(approval: AiApproval): boolean {
    return approval.request['kind'] !== 'fileChange' || approval.request['nativeItemComplete'] === true ||
      approval.request['engine'] === 'pi';
  }
  /** A collapsed log output: its first lines, and never more than a screenful of characters. */
  private outputPreview(output: string): string {
    const head = output.length > 800 ? output.slice(0, 800) : output;
    const lines = head.split('\n');
    const preview = lines.slice(0, 6).join('\n');
    return preview.length < output.length ? preview + '\n…' : preview;
  }
  private toolSymbol(icon: string): Resource {
    switch (icon) {
      case 'terminal': return $r('sys.symbol.code_square');
      case 'doc': return $r('sys.symbol.doc_text');
      case 'edit': return $r('sys.symbol.square_and_pencil');
      case 'search': return $r('sys.symbol.magnifyingglass');
      case 'globe': return $r('sys.symbol.link');
      case 'list': return $r('sys.symbol.list_bullet');
      case 'agent': return $r('sys.symbol.person_2_fill');
      default: return $r('sys.symbol.puzzle_fill');
    }
  }
  private approvalSummary(approval: AiApproval): string {
    const kind = aiString(approval.request['kind']);
    if (kind === 'questions') { return aiArray(approval.request['questions']).length.toString() + ' 个问题待回答'; }
    const text = aiApprovalDetails(approval.request);
    const lines = text.split('\n').filter((line: string): boolean => line.trim() !== '');
    return lines.slice(0, 6).join('\n') + (lines.length > 6 ? '\n…' : '');
  }
  private async answerInline(approval: AiApproval, decision: string): Promise<void> {
    this.prepareApproval(approval);
    await this.answer(decision);
  }
  private async answer(decision: string): Promise<void> {
    const approval = this.approval;
    if (approval === null || !this.allowed || !AiAccess.getInstance().proVisible()) { return; }
    await this.run(async (): Promise<void> => {
      if (approval.expires <= Date.now()) { throw new Error('APPROVAL_STALE'); }
      const kind = aiString(approval.request['kind']);
      const answer: Record<string, Object> = {};
      if (kind !== 'questions') { answer['decision'] = decision; }
      if (kind === 'questions') {
        const answers: Record<string, Object> = {};
        for (const question of this.questions) {
          const selected = question.selected.slice(); if (question.text.trim() !== '') { selected.push(question.text.trim()); }
          if (selected.length === 0) { throw new Error('AI_QUESTION_ANSWER_REQUIRED'); }
          answers[question.id] = aiParams(["answers"], [selected]);
        }
        answer['answers'] = answers;
      }
      if (kind === 'permissions' && decision === 'accept') { answer['scope'] = 'turn'; }
      await this.controller.action('approval.answer', aiParams(["approvalId", "answer"], [approval.id, answer]));
      this.showApproval = false; this.approval = null; this.questions = []; await this.controller.refreshApprovals();
    });
  }
  private canAccept(): boolean {
    const approval = this.approval;
    return approval !== null && approval.expires > Date.now() && this.operator() && this.allowed &&
      this.approvalAcceptable(approval);
  }
  @Builder private approvalSheet() {
    Column() {
      AppSheetHeader({ title: '确认 AI 请求', showProBadge: true, onClose: (): void => { this.showApproval = false; } })
      Scroll() {
        Column({ space: 14 }) {
          if (this.approval !== null) {
            Text(aiRequestTitle(aiString(this.approval.request['kind']))).fontSize(16).fontFamily(AppConfig.fontFamily).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
            Text(aiApprovalDetails(this.approval.request)).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
              .copyOption(CopyOptions.InApp).width('100%')
            ForEach(this.questions, (question: AiQuestionValue, index: number): void => {
              Column({ space: 8 }) {
                Text(question.title).fontSize(15).fontFamily(AppConfig.fontFamily).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
                ForEach(question.options, (option: string, optionIndex: number): void => {
                  Button((question.selected.includes(option) ? '✓ ' : '') + option).constraintSize({ minHeight: AppUiMetrics.minTouchTarget }).padding({ left: 12, right: 12, top: 10, bottom: 10 }).borderRadius(12).fontSize(14).fontFamily(AppConfig.fontFamily).backgroundColor(this.pal().surface).fontColor(this.pal().text).focusable(true).width('100%')
                    .enabled(!this.busy && this.allowed).onClick((): void => {
                      if (this.busy || !this.allowed) { return; }
                      question.selected = question.selected.includes(option) ? question.selected.filter((v: string): boolean => v !== option) : (question.multiple ? question.selected.concat([option]) : [option]);
                      if (!question.multiple) { question.text = ''; }
                      this.questions[index] = question; this.questions = this.questions.slice();
                    })
                  if (question.descriptions[optionIndex] !== '') {
                    Text(question.descriptions[optionIndex]).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2).width('100%')
                  }
                })
                TextInput({ text: question.text, placeholder: '补充回答' }).constraintSize({ minHeight: AppUiMetrics.minTouchTarget }).fontSize(14).fontFamily(AppConfig.fontFamily).enabled(!this.busy && this.allowed).accessibilityText(question.title).onChange((value: string): void => {
                  if (this.busy || !this.allowed) { return; }
                  question.text = value;
                  if (!question.multiple && value.trim() !== '') { question.selected = []; }
                  this.questions[index] = question; this.questions = this.questions.slice();
                })
              }
            }, (question: AiQuestionValue): string => question.id)
            Button(this.showApprovalDetails ? '收起完整请求' : '查看完整请求与授权范围').constraintSize({ minHeight: AppUiMetrics.minTouchTarget }).padding({ left: 12, right: 12, top: 10, bottom: 10 }).borderRadius(12).fontSize(14).fontFamily(AppConfig.fontFamily).backgroundColor(this.pal().surface).fontColor(this.pal().text).focusable(true).width('100%')
              .onClick((): void => { this.showApprovalDetails = !this.showApprovalDetails; })
            if (this.showApprovalDetails) {
              Text(JSON.stringify(this.approval.request, null, 2)).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2)
                .copyOption(CopyOptions.InApp).width('100%')
            }
          }
        }.padding(24).width('100%')
      }.layoutWeight(1).width('100%')
      Row({ space: 10 }) {
        if (this.questions.length > 0) {
          AiActionButton({ label: '停止回合', isEnabled: this.operator() && !this.busy, onAction: (): void => {
            void this.run(async (): Promise<void> => { await this.controller.action('turn.cancel'); this.showApproval = false; });
          } }).layoutWeight(1)
        } else {
          AiActionButton({ label: '拒绝', isEnabled: this.operator() && this.allowed && !this.busy,
            onAction: (): void => { void this.answer('decline'); } }).layoutWeight(1)
        }
        AiActionButton({ label: this.questions.length > 0 ? '提交回答' : '允许此次请求', primary: true,
          isEnabled: this.canAccept() && !this.busy, onAction: (): void => { void this.answer('accept'); } }).layoutWeight(1)
      }.padding(AppUiMetrics.sheetPadding).width('100%')
      if (this.error !== '') { Text(this.error).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().danger).padding(12) }
    }.height('100%').width('100%').safeAreaPadding({ bottom: 16 }).backgroundColor(this.pal().sheetBg)
  }
  /** Tabs of the details sheet: one segmented row (it wrapped into a 2x2 grid of small buttons on phones). */
  @Builder private detailTabButton(t: AiWsTab) {
    Text(t.label).fontSize(14).fontFamily(AppConfig.fontFamily).textAlign(TextAlign.Center).maxLines(1)
      .fontWeight(t.selected ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(t.selected ? this.palette().onAccent : this.pal().text)
      .backgroundColor(t.selected ? this.palette().accent : Color.Transparent).borderRadius(10)
      .layoutWeight(1).height(AppUiMetrics.minTouchTarget - 8).opacity(t.enabled ? 1 : 0.4).enabled(t.enabled)
      .accessibilityText(t.label + (t.selected ? '，已选中' : '')).onClick((): void => { if (t.enabled) { t.action(); } })
  }
  @Builder private sectionTitle(text: string) {
    Text(text).fontSize(13).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text2)
      .width('100%').margin({ top: 4 })
  }
  /** A full-width sheet action in the workspace palette; danger only tints the label. */
  @Builder private blockButton(b: AiWsButton) {
    Text(b.label).fontSize(15).fontFamily(AppConfig.fontFamily).textAlign(TextAlign.Center).width('100%')
      .fontColor(b.primary ? this.palette().onAccent : this.pal().text)
      .constraintSize({ minHeight: AppUiMetrics.minTouchTarget }).padding({ left: 12, right: 12 }).borderRadius(12)
      .backgroundColor(b.primary ? this.palette().accent : this.pal().surface)
      .opacity(b.enabled ? 1 : 0.45).enabled(b.enabled).focusable(true).accessibilityText(b.label)
      .onClick((): void => { if (b.enabled) { b.action(); } })
  }
  @Builder private modeChoices(m: AiWsModes) {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(m.values, (value: string): void => {
        Text(aiModeLabel(value)).fontSize(14).fontFamily(AppConfig.fontFamily)
          .fontColor(m.selected === value ? this.palette().onAccent : this.pal().text)
          .backgroundColor(m.selected === value ? this.palette().accent : this.pal().surface)
          .padding({ left: 14, right: 14 }).height(AppUiMetrics.minTouchTarget - 4).borderRadius(18)
          .margin({ right: 8, bottom: 8 }).enabled(!this.busy && this.allowed)
          .accessibilityText(aiModeLabel(value) + (m.selected === value ? '，已选中' : ''))
          .onClick((): void => { if (!this.busy && this.allowed) { m.choose(m.selected === value ? '' : value); } })
      }, (value: string): string => value)
    }.width('100%')
  }
  /** The apps' sheet title: a round × on the left, the title centred. */
  @Builder private refSheetHeader(h: AiWsSheetHead) {
    Row() {
      Stack() {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.pal().text])
      }.width(AppUiMetrics.minTouchTarget).height(AppUiMetrics.minTouchTarget).borderRadius(22)
      .backgroundColor(this.pal().card).shadow({ radius: 8, color: '#10000000', offsetY: 1 })
      .accessibilityText('关闭').focusable(true)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 }).onClick((): void => { h.close(); })
      Text(h.title).fontSize(18).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
        .layoutWeight(1).textAlign(TextAlign.Center)
      Blank().width(AppUiMetrics.minTouchTarget)
    }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 8 })
  }
  @Builder private choiceRow(r: AiWsChoice) {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text(r.label).fontSize(17).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
        if (r.detail !== '') {
          Text(r.detail).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (r.selected) {
        SymbolGlyph($r('sys.symbol.checkmark')).fontSize(20).fontColor([this.uiStyle === 'codex' ? '#2F6BFF' : this.palette().accent])
      }
    }.width('100%').constraintSize({ minHeight: AppUiMetrics.minTouchTarget + 16 }).padding({ left: 18, right: 18, top: 10, bottom: 10 })
    .stateStyles({ normal: { .backgroundColor(Color.Transparent) }, pressed: { .backgroundColor(this.pal().surface) } })
    .enabled(r.enabled).opacity(r.enabled ? 1 : 0.45).accessibilityText(r.label + (r.selected ? '，已选中' : ''))
    .onClick((): void => { if (r.enabled) { r.action(); } })
  }
  /** A white card row with a value and › (Effort, Permission). */
  @Builder private valueRow(r: AiWsChoice) {
    Row({ space: 8 }) {
      Text(r.label).fontSize(17).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text).layoutWeight(1)
      Text(r.detail).fontSize(16).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3)
      SymbolGlyph(r.selected ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right')).fontSize(14).fontColor([this.pal().text3])
    }.width('100%').height(60).padding({ left: 18, right: 18 }).borderRadius(18).backgroundColor(this.pal().card)
    .enabled(r.enabled).opacity(r.enabled ? 1 : 0.45).focusable(true).accessibilityText(r.label + ' ' + r.detail)
    .onClick((): void => { if (r.enabled) { r.action(); } })
  }
  @Builder private contextCard() {
    if (this.contextUsed > 0 || this.contextWindow > 0) {
      Column({ space: 10 }) {
        Row() {
          Text('上下文窗口').fontSize(17).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text).layoutWeight(1)
          if (this.contextWindow > 0) {
            Text(Math.min(100, Math.round(this.contextUsed * 100 / this.contextWindow)).toString() + '% 已用')
              .fontSize(15).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3)
          }
        }.width('100%')
        if (this.contextWindow > 0) {
          Progress({ value: Math.min(this.contextUsed, this.contextWindow), total: this.contextWindow, type: ProgressType.Capsule })
            .width('100%').height(8)
            .color(this.contextUsed > this.contextWindow * 0.85 ? this.palette().danger : (this.uiStyle === 'codex' ? '#2F6BFF' : this.palette().accent))
            .backgroundColor(this.pal().surface)
        }
        Text(this.contextWindow > 0 ? aiTokens(this.contextUsed) + ' / ' + aiTokens(this.contextWindow) + ' tokens' :
          '已用 ' + aiTokens(this.contextUsed) + ' tokens').fontSize(14).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3)
          .width('100%')
        if (this.capability('compact') && this.contextWindow > 0 && this.contextUsed > this.contextWindow * 0.7) {
          Text('上下文快满了，可以在 ⋯ 菜单里压缩上下文').fontSize(13).fontFamily(AppConfig.fontFamily)
            .fontColor(this.pal().text3).width('100%')
        }
      }.width('100%').padding(18).borderRadius(18).backgroundColor(this.pal().card)
    }
  }
  /**
   * The model picker. Claude: Select model (one card of models with descriptions and a check), an Effort row that
   * opens its levels, and the context window. Codex: the model and effort over a stepped slider, the models behind
   * the title, and the context window.
   */
  @Builder private modelSheet() {
    Column() {
      this.refSheetHeader({ title: this.uiStyle === 'codex' ? '模型与智能' : '选择模型', close: (): void => { this.showModelPicker = false; } })
      Scroll() {
        Column({ space: 14 }) {
          if (this.uiStyle === 'codex') {
            Row({ space: 6 }) {
              Text(this.chosenModel() !== '' ? this.modelName(this.chosenModel()) : '模型').fontSize(24).fontWeight(FontWeight.Medium)
                .fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
              if (this.chosenEffort() !== '') {
                Text(aiEffortLabel(this.chosenEffort())).fontSize(24).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3)
              }
              SymbolGlyph(this.showModelList ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
                .fontSize(18).fontColor([this.pal().text3])
            }.justifyContent(FlexAlign.Center).width('100%').padding({ top: 4 }).focusable(true)
            .accessibilityText('选择模型').onClick((): void => {
              this.getUIContext().animateTo({ duration: 240, curve: Curve.FastOutSlowIn }, (): void => { this.showModelList = !this.showModelList; });
            })
            if (this.effortChoices().length > 0) {
              Slider({ value: Math.max(0, this.effortChoices().indexOf(this.chosenEffort())), min: 0,
                max: Math.max(1, this.effortChoices().length - 1), step: 1, style: SliderStyle.InSet })
                .showSteps(true).trackThickness(52).blockColor(Color.White).selectedColor('#2F6BFF')
                .trackColor(this.pal().surface).width('100%').enabled(!this.busy && this.allowed)
                .accessibilityText('思考强度 ' + aiEffortLabel(this.chosenEffort()))
                .onChange((value: number): void => {
                  const level = this.effortChoices()[Math.round(value)];
                  if (level !== undefined && !this.busy && this.allowed) { this.effort = level; }
                })
            }
            if (this.showModelList) {
              this.modelCard()
            }
          } else {
            this.modelCard()
            if (this.effortChoices().length > 0) {
              this.valueRow({ label: '思考强度', detail: this.chosenEffort() !== '' ? aiEffortLabel(this.chosenEffort()) : '默认',
                selected: this.showEffortList, enabled: !this.busy && this.allowed, action: (): void => {
                  this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, (): void => { this.showEffortList = !this.showEffortList; });
                } })
              if (this.showEffortList) {
                Column() {
                  ForEach(this.effortChoices(), (value: string, index: number): void => {
                    if (index > 0) { Divider().color(this.palette().border).margin({ left: 18, right: 18 }) }
                    this.choiceRow({ label: aiEffortLabel(value), detail: '', selected: this.chosenEffort() === value,
                      enabled: !this.busy && this.allowed, action: (): void => { this.effort = value; } })
                  }, (value: string): string => value)
                }.width('100%').borderRadius(18).backgroundColor(this.pal().card).clip(true)
                .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
              }
            }
          }
          this.contextCard()
          Text('从下一条消息开始生效').fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3).width('100%')
        }.padding({ left: 16, right: 16, top: 6, bottom: 24 }).width('100%')
      }.layoutWeight(1).width('100%').align(Alignment.Top)
    }.height('100%').width('100%').safeAreaPadding({ bottom: 16 }).backgroundColor(this.pal().surface)
  }
  @Builder private modelCard() {
    Column() {
      ForEach(this.models, (row: Record<string, Object>, index: number): void => {
        if (index > 0) { Divider().color(this.palette().border).margin({ left: 18, right: 18 }) }
        this.choiceRow({ label: aiString(row['displayName'], aiString(row['name'], aiString(row['id']))),
          detail: aiString(row['description']),
          selected: this.chosenModel() === aiString(row['model'], aiString(row['id'])),
          enabled: !this.busy && this.allowed, action: (): void => { this.chooseModel(row); } })
      }, (row: Record<string, Object>): string => aiString(row['id']))
    }.width('100%').borderRadius(18).backgroundColor(this.pal().card).clip(true)
  }
  /** The Claude app's Add context: photo and file tiles, then permission and plan mode. */
  @Builder private addSheet() {
    Column() {
      this.refSheetHeader({ title: '添加内容', close: (): void => { this.showAddSheet = false; } })
      Scroll() {
        Column({ space: 12 }) {
          Row({ space: 12 }) {
            this.addTile({ symbol: $r('sys.symbol.picture'), label: '照片', enabled: this.canAttach(),
              action: (): void => { this.showAddSheet = false; void this.attach(true); } })
            this.addTile({ symbol: $r('sys.symbol.doc'), label: '文件', enabled: this.canAttach(),
              action: (): void => { this.showAddSheet = false; void this.attach(false); } })
          }.width('100%')
          if (this.permissionModes.length > 0) {
            this.valueRow({ label: '权限', detail: aiModeLabel(this.chosenPermission() || '默认'), selected: this.showPermissionList,
              enabled: !this.busy && this.allowed, action: (): void => {
                this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, (): void => { this.showPermissionList = !this.showPermissionList; });
              } })
            if (this.showPermissionList) {
              Column() {
                ForEach(this.permissionModes, (mode: string, index: number): void => {
                  if (index > 0) { Divider().color(this.palette().border).margin({ left: 18, right: 18 }) }
                  this.choiceRow({ label: aiModeLabel(mode), detail: aiModeDetail(mode, this.host?.backend ?? ''), selected: this.chosenPermission() === mode,
                    enabled: !this.busy && this.allowed, action: (): void => { this.permission = mode; } })
                }, (mode: string): string => mode)
              }.width('100%').borderRadius(18).backgroundColor(this.pal().card).clip(true)
              .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
            }
          }
          if (this.collaborationModes.includes('plan')) {
            Row({ space: 8 }) {
              Column({ space: 3 }) {
                Text('方案模式').fontSize(17).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
                Text('先给出方案，你确认后再动手').fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3)
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Toggle({ type: ToggleType.Switch, isOn: (this.collaboration !== '' ? this.collaboration : this.currentCollaboration) === 'plan' })
                .selectedColor(this.palette().accent).enabled(!this.busy && this.allowed)
                .onChange((on: boolean): void => { this.collaboration = on ? 'plan' : 'default'; })
            }.width('100%').padding({ left: 18, right: 14, top: 12, bottom: 12 }).borderRadius(18).backgroundColor(this.pal().card)
          }
        }.padding({ left: 16, right: 16, top: 6, bottom: 24 }).width('100%')
      }.layoutWeight(1).width('100%').align(Alignment.Top)
    }.height('100%').width('100%').safeAreaPadding({ bottom: 16 }).backgroundColor(this.pal().surface)
  }
  @Builder private addTile(t: AiWsIconButton) {
    Column({ space: 10 }) {
      SymbolGlyph(t.symbol).fontSize(26).fontColor([this.pal().text])
      Text(t.label).fontSize(16).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
    }.layoutWeight(1).height(108).justifyContent(FlexAlign.Center).borderRadius(18).backgroundColor(this.pal().card)
    .enabled(t.enabled).opacity(t.enabled ? 1 : 0.45).focusable(true).accessibilityText(t.label)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
    .onClick((): void => { if (t.enabled) { t.action(); } })
  }
  @Builder private detailsSheet() {
    Column() {
      AppSheetHeader({ title: '会话设置', showProBadge: true, onClose: (): void => { this.showDetails = false; } })
      Column() {
        Row({ space: 4 }) {
          this.detailTabButton({ label: '设置', selected: this.detailTab === 0, enabled: true, action: (): void => { this.detailTab = 0; } })
          this.detailTabButton({ label: '差异', selected: this.detailTab === 1, enabled: this.capability('diffs'), action: (): void => {
            this.detailTab = 1; void this.run(async (): Promise<void> => { await this.controller.loadDiff(); });
          } })
          this.detailTabButton({ label: '终端', selected: this.detailTab === 2, enabled: this.capability('terminalManagement'), action: (): void => {
            this.detailTab = 2; void this.run(async (): Promise<void> => { await this.controller.loadTerminals(); });
          } })
          this.detailTabButton({ label: '操作', selected: this.detailTab === 3, enabled: true, action: (): void => {
            this.detailTab = 3; void this.run(async (): Promise<void> => { await this.controller.refreshOperations(); });
          } })
        }.width('100%').padding(4).borderRadius(14).backgroundColor(this.pal().surface)
      }.width('100%').padding({ left: AppUiMetrics.sheetPadding, right: AppUiMetrics.sheetPadding })
      Scroll() {
        Column({ space: 10 }) {
          if (this.detailTab === 0) {
            if (!this.operator()) {
              Text('这台设备只有查看权限，不能修改会话。').fontSize(12)
                .fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3).width('100%')
            }
            Text('模型和思考强度在输入框下方的模型按钮里选择。').fontSize(12).fontFamily(AppConfig.fontFamily)
              .fontColor(this.pal().text3).width('100%')
            if (this.permissionModes.length > 0) {
              this.sectionTitle('权限模式（不选则保持当前）')
              this.modeChoices({ values: this.permissionModes, selected: this.chosenPermission(),
                choose: (value: string): void => { this.permission = value; } })
            }
            if (this.collaborationModes.length > 0) {
              this.sectionTitle('协作模式（不选则保持当前）')
              this.modeChoices({ values: this.collaborationModes, selected: this.collaboration !== '' ? this.collaboration : this.currentCollaboration,
                choose: (value: string): void => { this.collaboration = value; } })
            }
            AiFormField({ title: '会话名称', value: this.newTitle, hint: '留空则不改名', limit: 200, isEnabled: !this.busy && this.allowed, onChange: (value: string): void => { this.newTitle = value; } })
            this.blockButton({ label: '保存会话设置', primary: true, enabled: this.capability('rename') && this.allowed && this.operator() && !this.busy, action: (): void => {
              void this.run(async (): Promise<void> => {
                const params: Record<string, Object> = aiParams(["settings"], [this.settings()]);
                if (this.newTitle.trim() !== '') { params['title'] = this.newTitle.trim(); }
                await this.controller.action('session.update', params); this.controller.title = this.newTitle || this.title;
              });
            } })
            this.sectionTitle('会话操作')
            if (this.capability('fork')) {
              this.blockButton({ label: '从已完成的历史分叉一个新会话', primary: false, enabled: this.allowed && this.operator() && !this.busy, action: (): void => {
                void this.run(async (): Promise<void> => {
                  const result = await this.controller.action('session.fork');
                  this.resetView(); this.resetDrafts();
                  await this.controller.selectProject(this.projectId); await this.controller.selectSession(aiString(result['sessionId']));
                });
              } })
            }
            if (this.capability('compact')) {
              this.blockButton({ label: '压缩上下文', primary: false, enabled: this.allowed && this.operator() && !this.busy, action: (): void => {
                void this.run(async (): Promise<void> => { await this.controller.action('session.compact'); });
              } })
            }
            this.blockButton({ label: '重新连接电脑', primary: false, enabled: this.canReconnect && !this.busy, action: (): void => {
              this.showDetails = false; void this.reconnect();
            } })
            this.blockButton({ label: this.archived ? '恢复会话' : '归档会话', primary: false, enabled: this.allowed && this.operator() && !this.busy, action: (): void => {
              void this.run(async (): Promise<void> => { await this.controller.action(this.archived ? 'session.resume' : 'session.archive'); });
            } })
          } else if (this.detailTab === 1) {
            Text('仅显示原生引擎已报告的差异').fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3).width('100%')
            if (this.nativeDiffs().length > 0) {
              ForEach([this.nativeDiffKey()], (_key: string): void => {
                AiDiffView({ files: this.nativeDiffs(), textSize: 12, palette: this.palette(),
                  startOpen: this.nativeDiffs().length <= 3 })
              }, (key: string): string => key)
            } else {
              Text(this.diffNotice('还没有读取到差异')).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text)
                .copyOption(CopyOptions.InApp).width('100%')
            }
          } else if (this.detailTab === 2) {
            if (this.terminals.length === 0) {
              Text('没有正在运行的终端任务').fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3)
                .width('100%').padding({ top: 24 }).textAlign(TextAlign.Center)
            }
            ForEach(this.terminals, (terminal: Record<string, Object>): void => {
              Column({ space: 8 }) {
                Text(aiString(terminal['command'], aiString(terminal['title'], '终端任务 ' + aiString(terminal['processId']))))
                  .fontSize(14).fontFamily('monospace').fontColor(this.pal().text).width('100%').maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).copyOption(CopyOptions.InApp)
                Text([aiString(terminal['status']), aiString(terminal['cwd'])].filter((part: string): boolean => part !== '').join(' · ') || '运行中')
                  .fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3).width('100%')
                this.blockButton({ label: '停止此任务', primary: false, enabled: this.operator() && !this.busy, action: (): void => {
                  void this.run(async (): Promise<void> => {
                    await this.controller.action('terminal.stop', aiParams(["processId"], [aiString(terminal['processId'])]));
                    await this.controller.loadTerminals();
                  });
                } })
              }.width('100%').padding(12).backgroundColor(this.pal().surface).borderRadius(12)
            })
          } else {
            Text('结果未确认的操作不会自动重发：核对原操作后，再看会话内容决定下一步。').fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3).width('100%')
            if (this.unsettledOperations().length === 0) {
              Text('没有待确认的操作').fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3)
                .width('100%').padding({ top: 24 }).textAlign(TextAlign.Center)
            }
            if (this.operations.length > this.unsettledOperations().length) {
              Text('另有 ' + (this.operations.length - this.unsettledOperations().length).toString() +
                ' 条已完成的记录（如续期控制权），可在 AI 设置中清理').fontSize(12).fontFamily(AppConfig.fontFamily)
                .fontColor(this.pal().text3).width('100%')
            }
            ForEach(this.unsettledOperations(), (operation: AiPendingOperation): void => {
              Column({ space: 6 }) {
                Row() {
                  Text(aiOperationSummary(operation.body, operation.receipt)[0]).fontSize(14).fontWeight(FontWeight.Medium)
                    .fontFamily(AppConfig.fontFamily).fontColor(this.pal().text).layoutWeight(1)
                  Text(aiOperationSummary(operation.body, operation.receipt)[1]).fontSize(12).fontFamily(AppConfig.fontFamily)
                    .fontColor(this.pal().text2)
                }.width('100%')
                Text(aiShortTime(operation.createdAt)).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3).width('100%')
                this.blockButton({ label: '核对原操作', primary: false, enabled: this.allowed && !this.busy, action: (): void => {
                  void this.run(async (): Promise<void> => { await this.controller.reconcile(operation.id); });
                } })
              }.width('100%').padding(12).backgroundColor(this.pal().surface).borderRadius(12)
            }, (operation: AiPendingOperation): string => operation.id + ':' + operation.receipt.length.toString())
          }
        }.padding({ left: AppUiMetrics.sheetPadding, right: AppUiMetrics.sheetPadding, top: 14, bottom: 20 }).width('100%')
      }.layoutWeight(1).width('100%').align(Alignment.Top)
      if (this.error !== '') { Text(this.error).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().danger).padding(12) }
    }.height('100%').width('100%').safeAreaPadding({ bottom: 16 }).backgroundColor(this.pal().sheetBg)
  }
  private async chooseSession(id: string): Promise<void> {
    if (!this.allowed || !AiAccess.getInstance().proVisible() || !this.sessions.some((session: AiSession): boolean => session.id === id)) { return; }
    this.resetView();
    await this.run(async (): Promise<void> => { this.resetDrafts(); await this.controller.openSession(id); });
  }
  private async newSession(projectId: string): Promise<void> {
    if (!this.allowed || !AiAccess.getInstance().proVisible() || projectId === '') { return; }
    this.resetView();
    await this.run(async (): Promise<void> => { this.resetDrafts(); await this.controller.create('新会话', projectId); });
  }
  /** Where a new conversation goes without asking: the filtered project, or the only one. */
  private newChatTarget(): string {
    if (this.listFilter !== '') { return this.listFilter; }
    return this.projects.length === 1 ? this.projects[0].id : '';
  }
  private projectTitle(id: string): string {
    return this.projects.find((project: AiProject): boolean => project.id === id)?.title ?? id;
  }
  /** Chat: engine · project · turn status. List: engine · connection · how many conversations. */
  private headerSubtitle(): string {
    if (this.sessionId !== '') {
      return this.projectTitle(this.projectId) + ' · ' + (this.working() ? this.status : (this.host?.label || this.backendName()));
    }
    if (!this.allowed) { return this.backendName() + ' · ' + this.status; }
    return this.backendName() + ' · 已连接 · ' + this.listedSessions().length.toString() + ' 个对话';
  }
  private projectCount(id: string): number {
    return this.sessions.filter((session: AiSession): boolean => !session.archived && (id === '' || session.project === id)).length;
  }
  private listedSessions(): AiSession[] {
    const query = this.query.trim().toLowerCase();
    return this.sessions.filter((session: AiSession): boolean =>
      !session.archived && (this.listFilter === '' || session.project === this.listFilter) &&
      (query === '' || session.title.toLowerCase().includes(query)));
  }
  /** Writes whose result is not known to have succeeded: the ones worth checking (renewals pile up every 30 s). */
  private unsettledOperations(): AiPendingOperation[] {
    return this.operations.filter((operation: AiPendingOperation): boolean =>
      aiOperationSummary(operation.body, operation.receipt)[1] !== '已完成');
  }
  /** The status bar height arrives in px; layout is in vp (it was used as vp, a ~3x gap above the header). */
  private topVp(): number { return this.topInset > 0 ? this.getUIContext().px2vp(this.topInset) : 0; }
  // One object parameter: @Builder arguments passed by value never refresh, so a button drawn while connecting
  // (busy) stayed disabled after the connection settled. An object literal is passed by reference and does refresh.
  @Builder private pillButton(b: AiWsButton) {
    Text(b.label).fontSize(14).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily)
      .fontColor(b.primary ? this.palette().onAccent : this.palette().text).textAlign(TextAlign.Center)
      .padding({ left: 16, right: 16 }).constraintSize({ minHeight: AppUiMetrics.minTouchTarget }).borderRadius(20)
      .backgroundColor(b.primary ? this.palette().accent : this.palette().surface)
      .border({ width: b.primary ? 0 : 0.5, color: this.palette().border })
      .opacity(b.enabled ? 1 : 0.45).enabled(b.enabled).focusable(true).accessibilityText(b.label)
      .onClick((): void => { if (b.enabled) { b.action(); } })
  }
  @Builder private iconButton(b: AiWsIconButton) {
    Stack() {
      SymbolGlyph(b.symbol).fontSize(20).fontColor([this.palette().text2])
    }.width(AppUiMetrics.minTouchTarget).height(AppUiMetrics.minTouchTarget).borderRadius(22).enabled(b.enabled)
    .opacity(b.enabled ? 1 : 0.4).accessibilityText(b.label).focusable(true)
    .onClick((): void => { if (b.enabled) { b.action(); } })
  }
  /** A round floating button of the Codex and Claude apps (back, search): raised, hairline, soft shadow. */
  @Builder private circleButton(b: AiWsIconButton) {
    Stack() {
      SymbolGlyph(b.symbol).fontSize(20).fontColor([this.palette().text])
    }.width(AppUiMetrics.minTouchTarget).height(AppUiMetrics.minTouchTarget).borderRadius(22)
    .backgroundColor(this.palette().raised).border({ width: 0.5, color: this.palette().border })
    .shadow({ radius: 10, color: '#12000000', offsetY: 2 })
    .enabled(b.enabled).opacity(b.enabled ? 1 : 0.4).focusable(true).accessibilityText(b.label)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
    .onClick((): void => { if (b.enabled) { b.action(); } })
  }
  /** The apps' round ⋯: the conversation's menu. */
  @Builder private moreButton() {
    Stack() {
      Row({ space: 4 }) {
        Column().width(5).height(5).borderRadius(3).backgroundColor(this.palette().text)
        Column().width(5).height(5).borderRadius(3).backgroundColor(this.palette().text)
        Column().width(5).height(5).borderRadius(3).backgroundColor(this.palette().text)
      }
    }.width(AppUiMetrics.minTouchTarget).height(AppUiMetrics.minTouchTarget).borderRadius(22)
    .accessibilityText('更多').focusable(true).enabled(this.allowed || this.canReconnect)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
    .bindMenu(this.moreMenu())
  }
  private goBack(): void { if (this.sessionId !== '') { void this.backToList(); } else { void this.leave(); } }
  /** The conversation's ⋯ menu: settings, changes, background tasks, compaction, reconnect, archive. */
  private moreMenu(): MenuElement[] {
    const items: MenuElement[] = [
      { value: '会话设置', action: (): void => { this.detailTab = 0; this.showDetails = true; } }
    ];
    if (this.capability('diffs')) {
      items.push({ value: '查看改动', action: (): void => {
        this.detailTab = 1; this.showDetails = true;
        void this.run(async (): Promise<void> => { await this.controller.loadDiff(); });
      } });
    }
    if (this.capability('terminalManagement')) {
      items.push({ value: '后台任务', action: (): void => {
        this.detailTab = 2; this.showDetails = true;
        void this.run(async (): Promise<void> => { await this.controller.loadTerminals(); });
      } });
    }
    items.push({ value: '待确认操作', action: (): void => {
      this.detailTab = 3; this.showDetails = true;
      void this.run(async (): Promise<void> => { await this.controller.refreshOperations(); });
    } });
    if (this.capability('compact') && this.operator()) {
      items.push({ value: '压缩上下文', action: (): void => {
        void this.run(async (): Promise<void> => { await this.controller.action('session.compact'); });
      } });
    }
    items.push({ value: '重新连接', action: (): void => { void this.reconnect(); } });
    if (this.operator()) {
      items.push({ value: this.archived ? '恢复会话' : '归档会话', action: (): void => {
        void this.run(async (): Promise<void> => {
          await this.controller.action(this.archived ? 'session.resume' : 'session.archive');
        });
      } });
    }
    return items;
  }
  /** The home title is also the project switch (Codex ⌄): all projects or one. */
  private filterMenu(): MenuElement[] {
    const items: MenuElement[] = [{ value: '全部项目', action: (): void => { this.listFilter = ''; } }];
    this.projects.forEach((project: AiProject): void => {
      items.push({ value: project.title, action: (): void => { this.listFilter = project.id; } });
    });
    return items;
  }
  @Builder private titleSwitch() {
    Row({ space: 4 }) {
      Text(this.listFilter === '' ? this.backendName() : this.projectTitle(this.listFilter)).fontSize(18)
        .fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 200 })
      if (this.projects.length > 1) {
        SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14).fontColor([this.palette().text2])
      }
    }.padding({ left: 8, right: 8, top: 6, bottom: 6 }).enabled(this.projects.length > 1)
    .accessibilityText('切换项目，当前 ' + (this.listFilter === '' ? '全部项目' : this.projectTitle(this.listFilter)))
    .bindMenu(this.filterMenu())
  }
  /**
   * The apps' headers. Home: round back, the title as a project switch, round search. A conversation: Codex puts
   * its title over project · computer beside a pill of new and ⋯; Claude centres them, with a round spinner while
   * it works and a round ⋯.
   */
  @Builder private appHeader() {
    if (this.sessionId === '') {
      Row() {
        this.circleButton({ symbol: $r('sys.symbol.chevron_left'), label: '返回', enabled: true, action: (): void => { this.goBack(); } })
        Blank()
        this.titleSwitch()
        Blank()
        this.circleButton({ symbol: this.searching ? $r('sys.symbol.xmark') : $r('sys.symbol.magnifyingglass'),
          label: this.searching ? '关闭搜索' : '搜索对话', enabled: true,
          action: (): void => { this.searching = !this.searching; if (!this.searching) { this.query = ''; } } })
      }.width('100%').padding({ left: 12, right: 12, top: 6, bottom: 6 })
    } else if (this.uiStyle === 'codex') {
      Row({ space: 10 }) {
        this.circleButton({ symbol: $r('sys.symbol.chevron_left'), label: '返回对话列表', enabled: true, action: (): void => { this.goBack(); } })
        Column({ space: 2 }) {
          Text(this.title).fontSize(17).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily)
            .fontColor(this.palette().text).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.headerSubtitle()).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Row() {
          this.iconButton({ symbol: $r('sys.symbol.square_and_pencil'), label: '新建对话',
            enabled: this.allowed && !this.busy && this.operator() && this.projectId !== '',
            action: (): void => { void this.newSession(this.projectId); } })
          this.moreButton()
        }.borderRadius(22).backgroundColor(this.palette().raised).border({ width: 0.5, color: this.palette().border })
        .shadow({ radius: 10, color: '#12000000', offsetY: 2 })
      }.width('100%').padding({ left: 12, right: 12, top: 6, bottom: 6 })
    } else {
      Row({ space: 8 }) {
        this.circleButton({ symbol: $r('sys.symbol.chevron_left'), label: '返回对话列表', enabled: true, action: (): void => { this.goBack(); } })
        Column({ space: 2 }) {
          Text(this.title).fontSize(17).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily)
            .fontColor(this.palette().text).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.headerSubtitle()).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Center)
        if (this.working()) {
          Stack() {
            LoadingProgress().width(22).height(22).color(this.palette().accent)
          }.width(AppUiMetrics.minTouchTarget).height(AppUiMetrics.minTouchTarget).borderRadius(22)
          .backgroundColor(this.palette().raised).border({ width: 0.5, color: this.palette().border })
          .accessibilityText(this.backendName() + ' 正在工作')
        }
        Stack() { this.moreButton() }.borderRadius(22).backgroundColor(this.palette().raised)
          .border({ width: 0.5, color: this.palette().border }).shadow({ radius: 10, color: '#12000000', offsetY: 2 })
      }.width('100%').padding({ left: 12, right: 12, top: 6, bottom: 6 })
    }
  }
  @Builder private claudeHeader() { this.appHeader() }
  @Builder private codexHeader() { this.appHeader() }
  /** Codex home: a project heads its conversations (folder, name, new conversation). */
  @Builder private projectHeader(row: AiHomeRow) {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.folder')).fontSize(22).fontColor([this.palette().text])
      Text(row.title).fontSize(17).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      this.iconButton({ symbol: $r('sys.symbol.square_and_pencil'), label: '在「' + row.title + '」新建对话',
        enabled: this.allowed && !this.busy && this.operator(), action: (): void => { void this.newSession(row.project); } })
    }.width('100%').padding({ top: 12 })
  }
  @Builder private moreRow(row: AiHomeRow) {
    Text(row.title).fontSize(14).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
      .width('100%').padding({ left: this.uiStyle === 'codex' ? 34 : 12, top: 10, bottom: 10 }).focusable(true)
      .onClick((): void => {
        this.expandedProjects = this.expandedProjects.includes(row.project) ?
          this.expandedProjects.filter((id: string): boolean => id !== row.project) : this.expandedProjects.concat([row.project]);
      })
  }
  /** A folded run of steps: what it did in one line (已运行 4 条命令、已浏览 3 个文件 ›), the steps when opened. */
  @Builder private stepGroup(entry: AiStepEntry) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        if (entry.steps.some((step: AiTranscriptItem): boolean => aiStepState(step.state) === 'running')) {
          LoadingProgress().width(16).height(16).color(this.palette().accent)
        } else {
          SymbolGlyph(aiStepGroupIcon(entry.steps) === 'thinking' ? $r('sys.symbol.wand_and_stars') :
            this.toolSymbol(aiStepGroupIcon(entry.steps))).fontSize(15).fontColor([this.palette().text3])
        }
        Text(aiStepSummary(entry.steps)).fontSize(this.textSize - 1).fontFamily(AppConfig.fontFamily)
          .fontColor(this.palette().text2).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        SymbolGlyph(this.expanded(entry.key) ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
          .fontSize(12).fontColor([this.palette().text3])
      }.width('100%').focusable(true).accessibilityText(aiStepSummary(entry.steps))
      .onClick((): void => { this.toggleExpanded(entry.key); })
      if (this.expanded(entry.key)) {
        Column({ space: 10 }) {
          ForEach(entry.steps, (step: AiTranscriptItem): void => { this.claudeItem(step) },
            (step: AiTranscriptItem): string => step.id + ':' + step.state + ':' + step.text.length.toString() +
              (this.expanded(step.id) ? ':open' : ''))
        }.width('100%').padding({ left: 10 }).border({ width: { left: 1 }, color: this.palette().border })
      }
    }.width('100%')
  }
  @Builder private filterChip(t: AiWsTab) {
    Text(t.label).fontSize(14).fontFamily(AppConfig.fontFamily).maxLines(1)
      .fontColor(t.selected ? this.palette().onAccent : this.palette().text)
      .backgroundColor(t.selected ? this.palette().accent : this.palette().surface)
      .padding({ left: 14, right: 14 }).height(AppUiMetrics.minTouchTarget - 8).borderRadius(18)
      .enabled(t.enabled).opacity(t.enabled ? 1 : 0.45).accessibilityText(t.label + (t.selected ? '，已选中' : ''))
      .onClick((): void => { if (t.enabled) { t.action(); } })
  }
  /** The search field the round magnifier opens over the list (titles of every project's conversations). */
  @Builder private conversationFilters() {
    if (this.searching) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(18).fontColor([this.palette().text3])
        TextInput({ text: this.query, placeholder: '搜索对话' }).layoutWeight(1).fontSize(16)
          .fontFamily(AppConfig.fontFamily).fontColor(this.palette().text).placeholderColor(this.palette().text3)
          .backgroundColor(Color.Transparent).padding(0).defaultFocus(true).accessibilityText('搜索对话')
          .onChange((value: string): void => { this.query = value; })
      }.width('100%').height(44).padding({ left: 14, right: 14 }).borderRadius(22)
      .backgroundColor(this.palette().surface).margin({ bottom: 4 })
    }
  }
  /**
   * One conversation on the home list as the apps draw it: Codex a plain title under its project's folder; Claude
   * a code icon and the title. Both highlight a rounded row while pressed.
   */
  @Builder private conversationRow(session: AiSession) {
    Column() {
      Row({ space: 12 }) {
        if (this.uiStyle !== 'codex') {
          SymbolGlyph(session.origin === 'computer' ? $r('sys.symbol.code') : $r('sys.symbol.ellipsis_bubble'))
            .fontSize(20).fontColor([this.palette().text2])
        }
        Text(session.title).fontSize(17).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        Text(aiRelativeTime(session.updatedAt)).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
      }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: this.rowInset(), right: 12 })
      // A hairline from the title's start, as in the apps' lists, so each conversation reads on its own.
      Divider().color(this.palette().border).margin({ left: this.rowInset() + (this.uiStyle !== 'codex' ? 32 : 0) })
    }.width('100%').borderRadius(12)
    .stateStyles({ normal: { .backgroundColor(Color.Transparent) }, pressed: { .backgroundColor(this.palette().surface) } })
    .enabled(this.allowed && !this.busy).focusable(true)
    .accessibilityText((session.origin === 'computer' ? '电脑上的对话 ' : '对话 ') + session.title + '，' +
      this.projectTitle(session.project) + '，' + aiRelativeTime(session.updatedAt))
    .onClick((): void => { void this.chooseSession(session.id); })
  }
  /** Where a conversation's title starts: under its project's name in the Codex grouping (folder 22 + gap 12). */
  private rowInset(): number {
    return this.uiStyle === 'codex' && this.listFilter === '' && this.query.trim() === '' ? 34 : 4;
  }
  @Builder private stepIndicator(state: string) {
    Stack() {
      if (aiStepState(state) === 'running') {
        LoadingProgress().width(16).height(16).color(this.palette().accent)
      } else if (aiStepState(state) === 'ok') {
        SymbolGlyph($r('sys.symbol.checkmark')).fontSize(13).fontColor([this.palette().ok])
      } else if (aiStepState(state) === 'failed') {
        SymbolGlyph($r('sys.symbol.xmark')).fontSize(13).fontColor([this.palette().danger])
      } else {
        Column().width(5).height(5).borderRadius(3).backgroundColor(this.palette().text3)
      }
    }.width(18).height(18)
  }
  @Builder private stats(text: string) {
    Row({ space: 4 }) {
      ForEach(text.split(' ').filter((part: string): boolean => part !== ''), (part: string): void => {
        Text(part).fontSize(12).fontFamily(AppConfig.fontFamily)
          .fontColor(part.startsWith('+') ? this.palette().addText : this.palette().delText)
      }, (part: string, index: number): string => index.toString() + part)
    }
  }
  @Builder private codeBlock(text: string, label: string) {
    Column({ space: 4 }) {
      if (label !== '') {
        Text(label).fontSize(11).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
      }
      Scroll() {
        Text(text.length > 6000 ? text.slice(0, 6000) + '\n…（已截断，完整内容在电脑端）' : text)
          .fontSize(12).lineHeight(18).fontFamily('monospace').fontColor(this.palette().codeText)
          .copyOption(CopyOptions.InApp).padding(10)
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
      .borderRadius(8).backgroundColor(this.palette().codeBg).border({ width: 0.5, color: this.palette().border })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder private toolDetail(item: AiTranscriptItem) {
    Column({ space: 8 }) {
      if (aiItemDiff(item).length > 0) {
        AiDiffView({ files: aiItemDiff(item), textSize: 12, palette: this.palette(), startOpen: true })
      } else if ((item.detail ?? '') !== '') {
        this.codeBlock(item.detail ?? '', '输入')
      } else if (item.text !== '') {
        this.codeBlock(item.text, '')
      }
      if ((item.output ?? '') !== '' && item.title !== 'fileChange') {
        this.codeBlock(item.output ?? '', '输出')
      }
    }.width('100%').padding({ left: 26 })
  }
  /** One step as the apps show it: its icon, 已运行 ls (正在运行 while it runs), › to open input and output. */
  @Builder private toolRow(item: AiTranscriptItem) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        if (aiStepState(item.state) === 'running') {
          LoadingProgress().width(16).height(16).color(this.palette().text3)
        } else {
          SymbolGlyph(this.toolSymbol(this.toolView(item).icon)).fontSize(16)
            .fontColor([aiStepState(item.state) === 'failed' ? this.palette().danger : this.palette().text3])
        }
        Text((aiStepState(item.state) === 'running' ? '正在' : aiStepState(item.state) === 'failed' ? '未完成：' : '已') +
          this.toolView(item).verb + ' ' + this.toolView(item).target)
          .fontSize(this.textSize - 1).fontFamily(AppConfig.fontFamily)
          .fontColor(aiStepState(item.state) === 'failed' ? this.palette().danger : this.palette().text2)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        if (this.toolView(item).stats !== '') { this.stats(this.toolView(item).stats) }
        SymbolGlyph(this.expanded(item.id) ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
          .fontSize(12).fontColor([this.palette().text3])
      }.width('100%').focusable(true)
      .accessibilityText(this.toolView(item).verb + ' ' + this.toolView(item).target)
      .onClick((): void => { this.toggleExpanded(item.id); })
      if (this.expanded(item.id)) { this.toolDetail(item) }
    }.width('100%')
  }
  @Builder private thinkingRow(item: AiTranscriptItem) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        if (aiStepState(item.state) === 'running') {
          // 正在思考 breathes while the model reasons (the apps' shimmer).
          Text('正在思考').fontSize(this.textSize).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text2)
            .opacity(this.pulse ? 0.35 : 1).animation({ duration: 900, iterations: -1, playMode: PlayMode.Alternate })
            .onAppear((): void => { this.pulse = true; })
        } else {
          Text('已思考').fontSize(this.textSize - 1).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
        }
        SymbolGlyph(this.expanded(item.id) ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
          .fontSize(12).fontColor([this.palette().text3])
      }.focusable(true).accessibilityText('思考过程').onClick((): void => { this.toggleExpanded(item.id); })
      if (this.expanded(item.id)) {
        Text(item.text).fontSize(this.textSize - 1).lineHeight(Math.round((this.textSize - 1) * 1.5))
          .fontFamily(AppConfig.fontFamily).fontColor(this.palette().text2)
          .copyOption(CopyOptions.InApp).padding({ left: 12 }).width('100%')
          .border({ width: { left: 1 }, color: this.palette().border })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder private noticeRow(item: AiTranscriptItem) {
    Row({ space: 8 }) {
      SymbolGlyph(aiStepState(item.state) === 'failed' ? $r('sys.symbol.exclamationmark_triangle') :
        $r('sys.symbol.info_circle')).fontSize(14)
        .fontColor([aiStepState(item.state) === 'failed' ? this.palette().danger : this.palette().text3])
      Text(item.title + (item.text !== '' ? '：' + item.text : '')).fontSize(13).fontFamily(AppConfig.fontFamily)
        .fontColor(aiStepState(item.state) === 'failed' ? this.palette().danger : this.palette().text2)
        .layoutWeight(1).copyOption(CopyOptions.InApp)
    }.width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 }).borderRadius(10)
    .backgroundColor(this.palette().surface).alignItems(VerticalAlign.Top)
  }
  @Builder private userBubble(item: AiTranscriptItem) {
    Row() {
      Blank()
      Text(item.text).fontSize(this.textSize).lineHeight(Math.round(this.textSize * 1.5)).fontFamily(AppConfig.fontFamily)
        .fontColor(this.palette().text).copyOption(CopyOptions.InApp)
        .padding({ left: 14, right: 14, top: 10, bottom: 10 }).borderRadius(18)
        .backgroundColor(this.palette().userBubble).constraintSize({ maxWidth: '86%' })
    }.width('100%')
  }
  @Builder private claudeItem(item: AiTranscriptItem) {
    if (item.role === 'user') {
      this.userBubble(item)
    } else if (item.role === 'assistant') {
      AiRemoteMarkdown({ text: item.text, textSize: this.textSize, palette: this.palette() })
    } else if (item.kind === 'thinking') {
      this.thinkingRow(item)
    } else if (item.kind === 'notice') {
      this.noticeRow(item)
    } else {
      this.toolRow(item)
    }
  }
  /** While a turn runs: Codex 正在思考 breathing; Claude a turning clay ✳ and 正在工作… (Clauding…). */
  @Builder private workingRow() {
    if (this.uiStyle === 'codex') {
      Row({ space: 6 }) {
        Text('正在思考').fontSize(this.textSize).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text2)
          .opacity(this.pulse ? 0.35 : 1).animation({ duration: 900, iterations: -1, playMode: PlayMode.Alternate })
          .onAppear((): void => { this.pulse = true; })
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([this.palette().text3])
      }.padding({ top: 2, bottom: 2 })
    } else {
      Row({ space: 8 }) {
        Text('✳').fontSize(20).fontColor(this.palette().accent)
          .rotate({ angle: this.spin }).animation({ duration: 1800, curve: Curve.Linear, iterations: -1 })
          .onAppear((): void => { this.spin = 360; })
        Text(this.backendName() + ' 正在工作…').fontSize(this.textSize).fontFamily(AppConfig.fontFamily)
          .fontColor(this.palette().accent)
        if (this.backgroundTasks()) {
          Text('· 后台任务运行中').fontSize(this.textSize).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
        }
      }.padding({ top: 2, bottom: 2 })
    }
  }
  /** The Codex app's 已运行 13 分钟 29 秒 under the header while a turn runs. */
  @Builder private elapsedLine() {
    if (this.uiStyle === 'codex' && this.sessionId !== '' && this.working() && this.workingSince > 0) {
      Column() {
        Text('已运行 ' + aiElapsed(this.nowTick - this.workingSince)).fontSize(17).fontFamily(AppConfig.fontFamily)
          .fontColor(this.palette().text3).width('100%').padding({ left: 16, right: 16, top: 4, bottom: 8 })
        Divider().color(this.palette().border).margin({ left: 16, right: 16 })
      }.width('100%')
    }
  }
  @Builder private emptyState() {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.ellipsis_bubble')).fontSize(36).fontColor([this.palette().text3])
      if (this.sessionId !== '') {
        Text('还没有消息，在下面输入开始对话').fontSize(14).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text2)
      } else if (!this.allowed) {
        Text(this.status === '连接中' ? '正在连接电脑…' : '还没有连上电脑').fontSize(14).fontFamily(AppConfig.fontFamily)
          .fontColor(this.palette().text2)
        if (this.status !== '连接中') {
          this.pillButton({ label: '重新连接', primary: true, enabled: this.canReconnect && !this.busy, action: (): void => { void this.reconnect(); } })
        }
      } else {
        Text(this.projects.length === 0 ? '电脑还没有开放项目给这台设备' : '这里还没有对话').fontSize(14)
          .fontFamily(AppConfig.fontFamily).fontColor(this.palette().text2)
        if (this.newChatTarget() !== '' && this.operator()) {
          this.pillButton({ label: '新建对话', primary: true, enabled: !this.busy, action: (): void => { void this.newSession(this.newChatTarget()); } })
        }
      }
    }.width('100%').padding({ top: 48, bottom: 48 })
  }
  @Builder private approvalCard(approval: AiApproval) {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.lock_shield')).fontSize(18).fontColor([this.palette().accent])
        Text(aiRequestTitle(aiString(approval.request['kind']))).fontSize(15).fontWeight(FontWeight.Medium)
          .fontFamily(AppConfig.fontFamily).fontColor(this.palette().text).layoutWeight(1)
        if (this.approvals.length > 1) {
          Text('还有 ' + (this.approvals.length - 1).toString() + ' 项').fontSize(12).fontFamily(AppConfig.fontFamily)
            .fontColor(this.palette().text3)
        }
      }.width('100%')
      Text(this.approvalSummary(approval)).fontSize(12).lineHeight(17).fontFamily('monospace')
        .fontColor(this.palette().codeText).maxLines(6).textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding(10).borderRadius(8).backgroundColor(this.palette().codeBg).width('100%')
      if (!this.operator()) {
        Text('这台设备只有查看权限，不能处理这个请求').fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
      }
      Row({ space: 10 }) {
        if (aiString(approval.request['kind']) === 'questions') {
          this.pillButton({ label: '回答问题', primary: true, enabled: this.operator() && this.allowed && !this.busy, action: (): void => { this.inspect(approval); } })
        } else {
          this.pillButton({ label: '拒绝', primary: false, enabled: this.operator() && this.allowed && !this.busy, action: (): void => { void this.answerInline(approval, 'decline'); } })
          this.pillButton({ label: '允许此次', primary: true, enabled: this.operator() && this.allowed && !this.busy && approval.expires > Date.now() &&
            this.approvalAcceptable(approval), action: (): void => { void this.answerInline(approval, 'accept'); } })
        }
        Blank()
        Text('完整请求').fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().accent)
          .focusable(true).accessibilityText('查看完整请求与授权范围').onClick((): void => { this.inspect(approval); })
      }.width('100%')
    }.width('100%').padding(14).borderRadius(16).backgroundColor(this.palette().raised)
    .border({ width: 1, color: this.palette().accent })
  }
  @Builder private chip(b: AiWsChip) {
    Text(b.label).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text2)
      .padding({ left: 10, right: 10, top: 6, bottom: 6 }).borderRadius(14)
      .border({ width: 0.5, color: this.palette().border }).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      .constraintSize({ maxWidth: 150 }).enabled(b.enabled).opacity(b.enabled ? 1 : 0.45).focusable(true)
      .accessibilityText(b.label).onClick((): void => { if (b.enabled) { b.action(); } })
  }
  @Builder private roundAction(b: AiWsRoundAction) {
    Stack() {
      SymbolGlyph(b.symbol).fontSize(18).fontColor([b.primary ? this.palette().onAccent : this.palette().text2])
    }.width(40).height(40).borderRadius(20).backgroundColor(b.primary ? this.palette().accent : Color.Transparent)
    .opacity(b.enabled ? 1 : 0.35).enabled(b.enabled).focusable(true).accessibilityText(b.label)
    .onClick((): void => { if (b.enabled) { b.action(); } })
  }
  /** Send (arrow) or stop (square) in a filled circle: blue in the Codex style, clay / ink in the Claude style. */
  @Builder private sendButton(b: AiWsRoundAction) {
    Stack() {
      if (b.primary) {
        Column().width(12).height(12).borderRadius(2).backgroundColor(Color.White)
      } else {
        SymbolGlyph($r('sys.symbol.arrow_up')).fontSize(20).fontWeight(FontWeight.Medium)
          .fontColor([b.enabled ? Color.White : this.palette().text3])
      }
    }.width(40).height(40).borderRadius(20)
    .backgroundColor(b.enabled || b.primary ? this.actionFill() : this.palette().surface)
    .scale({ x: b.enabled || b.primary ? 1 : 0.92, y: b.enabled || b.primary ? 1 : 0.92 })
    // Grey to blue (and back) as text comes and goes, eased like the apps.
    .animation({ duration: 240, curve: Curve.FastOutSlowIn })
    .enabled(b.enabled).focusable(true).accessibilityText(b.label)
    .clickEffect({ level: ClickEffectLevel.MIDDLE, scale: 0.88 })
    .onClick((): void => { if (b.enabled) { b.action(); } })
  }
  private actionFill(): string {
    if (this.uiStyle === 'codex') { return this.theme === 'light' ? '#2F6BFF' : '#4C82FF'; }
    return this.composerMode() === 'stop' && this.sessionId !== '' ? this.palette().text : this.palette().accent;
  }
  @Builder private composerSend() {
    if (this.sessionId !== '' && this.composerMode() === 'stop' && this.draft.trim() === '') {
      this.sendButton({ symbol: $r('sys.symbol.stop_circle_fill'), label: '停止', primary: true,
        enabled: this.capability('cancel') && !this.busy,
        action: (): void => { void this.run(async (): Promise<void> => { await this.controller.action('turn.cancel'); }); } })
    } else {
      this.sendButton({ symbol: $r('sys.symbol.arrow_up'), label: this.sessionId === '' ? '开始新对话' :
        (this.composerMode() === 'stop' ? '补充指令' : '发送'), primary: false,
        enabled: this.operator() && this.allowed && !this.busy && this.draft.trim() !== '' &&
          (this.sessionId === '' ? this.homeProjectId() !== '' : !this.archived),
        action: (): void => {
          if (this.sessionId === '') { void this.startChat(); }
          else { void this.send(this.composerMode() === 'stop' && this.capability('steer')); }
        } })
    }
  }
  /** The Claude style's model pill: the model, its effort in grey. */
  @Builder private modelPill() {
    Row({ space: 4 }) {
      Text(this.chosenModel() !== '' ? this.modelName(this.chosenModel()) : '模型').fontSize(14)
        .fontFamily(AppConfig.fontFamily).fontColor(this.palette().text).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: 150 })
      if (this.chosenEffort() !== '') {
        Text(aiEffortLabel(this.chosenEffort())).fontSize(14).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
      }
    }.height(36).padding({ left: 14, right: 14 }).borderRadius(18).backgroundColor(this.palette().surface)
    .enabled(this.allowed && !this.busy && this.models.length > 0).focusable(true)
    .accessibilityText('模型 ' + this.modelChipLabel()).clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
    .onClick((): void => { if (this.allowed && !this.busy && this.models.length > 0) { this.showModelPicker = true; } })
  }
  /** Status chips above the Codex composer: changes, background work, attachments. */
  @Builder private composerChips() {
    if (this.sessionId !== '' && (this.changeSummary() !== '' || this.backgroundTasks() || this.attachments.length > 0)) {
      Scroll() {
        Row({ space: 8 }) {
          if (this.changeSummary() !== '') {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(14).fontColor([this.palette().text2])
              this.stats(this.changeStats())
            }.height(36).padding({ left: 14, right: 14 }).borderRadius(18).backgroundColor(this.palette().raised)
            .border({ width: 0.5, color: this.palette().border }).accessibilityText(this.changeSummary())
            .onClick((): void => {
              this.detailTab = 1; this.showDetails = true;
              void this.run(async (): Promise<void> => { await this.controller.loadDiff(); });
            })
          }
          if (this.backgroundTasks()) {
            Row({ space: 6 }) {
              LoadingProgress().width(14).height(14).color(this.palette().text2)
              Text('后台任务运行中').fontSize(14).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text)
            }.height(36).padding({ left: 14, right: 14 }).borderRadius(18).backgroundColor(this.palette().raised)
            .border({ width: 0.5, color: this.palette().border })
            .onClick((): void => {
              if (!this.capability('terminalManagement')) { return; }
              this.detailTab = 2; this.showDetails = true;
              void this.run(async (): Promise<void> => { await this.controller.loadTerminals(); });
            })
          }
          if (this.attachments.length > 0) {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.paperclip')).fontSize(14).fontColor([this.palette().text2])
              Text(this.attachments.length.toString() + ' 个附件').fontSize(14).fontFamily(AppConfig.fontFamily)
                .fontColor(this.palette().text)
              SymbolGlyph($r('sys.symbol.xmark')).fontSize(12).fontColor([this.palette().text3])
            }.height(36).padding({ left: 14, right: 14 }).borderRadius(18).backgroundColor(this.palette().raised)
            .border({ width: 0.5, color: this.palette().border }).accessibilityText('移除附件')
            .onClick((): void => { if (!this.busy) { this.attachments = []; } })
          }
        }.padding({ left: 12, right: 12 })
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
    }
  }
  private composerExpanded(): boolean { return this.composerFocused || this.draft !== ''; }
  @Builder private composerInput() {
    TextArea({ text: this.draft, placeholder: this.composerPlaceholder() })
      .constraintSize({ minHeight: 40, maxHeight: this.composerMaxHeight() })
      // Codex sets the text between + and send in one row; in Claude's card it sits on its own line.
      .layoutWeight(this.uiStyle === 'codex' ? 1 : 0)
      .fontSize(this.textSize + 1).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text)
      .placeholderColor(this.palette().text3).backgroundColor(Color.Transparent).padding({ left: 6, right: 6, top: 8, bottom: 8 })
      .enabled(this.allowed && !this.busy && this.operator() && !(this.sessionId !== '' && this.archived))
      .accessibilityText('任务内容')
      .onFocus((): void => { this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, (): void => { this.composerFocused = true; }); })
      .onBlur((): void => { this.getUIContext().animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, (): void => { this.composerFocused = false; }); })
      .onChange((value: string): void => { if (this.allowed && !this.busy) { this.draft = value; } }).maxLength(128000)
  }
  /**
   * The composer. Codex: a pill (+, 跟进, send) that opens into a card with + / permissions / model when focused.
   * Claude: a card with the text over +, the model pill and send. The Claude home list starts conversations from its
   * 新对话 button instead.
   */
  @Builder private composer() {
    Column({ space: 8 }) {
      if (this.sessionId !== '' && this.role !== '' && !this.operator()) {
        Text('这台设备只有查看权限，可以看对话，不能发送或批准').fontSize(12).fontFamily(AppConfig.fontFamily)
          .fontColor(this.palette().text3).width('100%').padding({ left: 16, right: 16 })
      }
      if (this.uiStyle === 'codex') {
        this.composerChips()
        if (this.sessionId === '' && this.projects.length > 1) {
          Row({ space: 4 }) {
            Text('新对话 · ' + this.projectTitle(this.homeProjectId())).fontSize(13).fontFamily(AppConfig.fontFamily)
              .fontColor(this.palette().text2).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(12).fontColor([this.palette().text3])
          }.padding({ left: 18, right: 6, top: 2, bottom: 2 }).alignSelf(ItemAlign.Start)
          .bindMenu(this.projects.map((project: AiProject): MenuElement => ({ value: project.title,
            action: (): void => { this.homeProject = project.id; } })))
          .accessibilityText('新对话所在项目 ' + this.projectTitle(this.homeProjectId()))
        }
        Column({ space: 2 }) {
          Row({ space: 2 }) {
            if (!this.composerExpanded()) { this.plusButton() }
            this.composerInput()
            if (!this.composerExpanded()) { this.composerSend() }
          }.width('100%').alignItems(VerticalAlign.Center)
          if (this.composerExpanded()) {
            Row({ space: 2 }) {
              this.plusButton()
              if (this.permissionModes.length > 0) { this.permissionButton() }
              this.chip({ label: this.modelChipLabel(), enabled: this.allowed && !this.busy && this.models.length > 0,
                action: (): void => { this.showModelPicker = true; } })
              Blank()
              this.composerSend()
            }.width('100%').transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
          }
        }
        .width('100%').padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .borderRadius(28).backgroundColor(this.palette().raised)
        .border({ width: 0.5, color: this.palette().border })
        .shadow({ radius: 16, color: '#1A000000', offsetY: 3 })
      } else if (this.sessionId !== '') {
        Column({ space: 4 }) {
          this.composerInput()
          Row({ space: 8 }) {
            this.plusButton()
            this.modelPill()
            Blank()
            this.composerSend()
          }.width('100%')
        }
        .width('100%').padding({ left: 10, right: 10, top: 6, bottom: 10 })
        .borderRadius(26).backgroundColor(this.palette().raised)
        .border({ width: 0.5, color: this.palette().border })
        .shadow({ radius: 16, color: '#14000000', offsetY: 3 })
      } else {
        // The Claude app's black New session pill (a project menu when several projects could take it).
        if (this.projects.length > 1 && this.newChatTarget() === '') {
          Row({ space: 8 }) { this.newChatPillContent() }
            .height(52).padding({ left: 26, right: 26 }).borderRadius(26).backgroundColor(this.palette().text)
            .shadow({ radius: 16, color: '#22000000', offsetY: 3 })
            .enabled(this.allowed && !this.busy && this.operator()).opacity(this.allowed && !this.busy && this.operator() ? 1 : 0.4)
            .clickEffect({ level: ClickEffectLevel.MIDDLE, scale: 0.94 }).accessibilityText('新对话，选择项目')
            .bindMenu(this.projects.map((project: AiProject): MenuElement => ({ value: '在「' + project.title + '」新建对话',
              action: (): void => { void this.newSession(project.id); } })))
        } else {
          Row({ space: 8 }) { this.newChatPillContent() }
            .height(52).padding({ left: 26, right: 26 }).borderRadius(26).backgroundColor(this.palette().text)
            .shadow({ radius: 16, color: '#22000000', offsetY: 3 })
            .enabled(this.allowed && !this.busy && this.operator() && this.homeProjectId() !== '')
            .opacity(this.allowed && !this.busy && this.operator() ? 1 : 0.4)
            .clickEffect({ level: ClickEffectLevel.MIDDLE, scale: 0.94 }).accessibilityText('新对话')
            .onClick((): void => { void this.newSession(this.homeProjectId()); })
        }
      }
    }.width('100%').padding({ left: 12, right: 12, top: 6, bottom: 8 })
  }
  @Builder private newChatPillContent() {
    SymbolGlyph($r('sys.symbol.plus')).fontSize(18).fontColor([this.palette().bg])
    Text('新对话').fontSize(16).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily).fontColor(this.palette().bg)
  }
  /** + : the Codex style's menu (photo, file, plan mode); the Claude style's 添加内容 sheet. */
  @Builder private plusButton() {
    if (this.uiStyle === 'codex') {
      Stack() {
        SymbolGlyph($r('sys.symbol.plus')).fontSize(22).fontColor([this.palette().text])
      }.width(40).height(40).borderRadius(20).focusable(true).accessibilityText('添加')
      .enabled(this.allowed && !this.busy && this.operator()).opacity(this.allowed && !this.busy && this.operator() ? 1 : 0.4)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
      .bindMenu(this.plusMenu())
    } else {
      Stack() {
        SymbolGlyph($r('sys.symbol.plus')).fontSize(20).fontColor([this.palette().text])
      }.width(40).height(40).borderRadius(20).backgroundColor(this.palette().surface).focusable(true).accessibilityText('添加内容')
      .enabled(this.allowed && !this.busy && this.operator()).opacity(this.allowed && !this.busy && this.operator() ? 1 : 0.4)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
      .onClick((): void => { this.showAddSheet = true; })
    }
  }
  private plusMenu(): MenuElement[] {
    const items: MenuElement[] = [
      { value: '照片', enabled: this.canAttach(), action: (): void => { void this.attach(true); } },
      { value: '文件', enabled: this.canAttach(), action: (): void => { void this.attach(false); } }
    ];
    if (this.collaborationModes.includes('plan')) {
      const planning = (this.collaboration !== '' ? this.collaboration : this.currentCollaboration) === 'plan';
      items.push({ value: planning ? '关闭方案模式' : '方案模式',
        action: (): void => { this.collaboration = planning ? 'default' : 'plan'; } });
    }
    return items;
  }
  /** How the agent asks before acting (the Codex app's shield): each mode with what it allows. */
  @Builder private permissionButton() {
    Stack() {
      SymbolGlyph($r('sys.symbol.lock_shield')).fontSize(19)
        .fontColor([this.chosenPermission() === 'read-only' || this.chosenPermission() === '' ? this.palette().text2 : '#E8590C'])
    }.width(40).height(40).borderRadius(20).focusable(true)
    .accessibilityText('权限：' + aiModeLabel(this.chosenPermission() || '默认'))
    .enabled(this.allowed && !this.busy).opacity(this.allowed && !this.busy ? 1 : 0.4)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
    .bindMenu(this.permissionMenu())
  }
  @Builder private permissionMenu() {
    Column() {
      Text('应如何批准 ' + this.backendName() + ' 的操作？').fontSize(14).fontFamily(AppConfig.fontFamily)
        .fontColor(this.palette().text3).width('100%').padding({ left: 16, right: 16, top: 12, bottom: 6 })
      ForEach(this.permissionModes, (mode: string): void => {
        Row({ space: 12 }) {
          Column({ space: 3 }) {
            Text(aiModeLabel(mode)).fontSize(16).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text)
            if (aiModeDetail(mode, this.host?.backend ?? '') !== '') {
              Text(aiModeDetail(mode, this.host?.backend ?? '')).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
            }
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          if (this.chosenPermission() === mode) {
            SymbolGlyph($r('sys.symbol.checkmark')).fontSize(18).fontColor([this.palette().text])
          }
        }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .onClick((): void => { this.permission = mode; })
      }, (mode: string): string => mode)
    }.width(310).padding({ bottom: 8 })
  }
  @Builder private workspace() {
    Column() {
      Column() {
        if (this.uiStyle === 'codex') { this.codexHeader() } else { this.claudeHeader() }
        this.elapsedLine()
        if (this.error !== '') {
          Text(this.error).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().danger)
            .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 4 })
        }
      }.width('100%').onAreaChange((_old: Area, next: Area): void => { this.topChrome = this.measured(next, this.topChrome); })
      Refresh({ refreshing: $$this.listRefreshing }) {
      List({ space: this.sessionId === '' ? 2 : 18, scroller: this.scroller() }) {
        if (this.sessionId === '') {
          ListItem() { this.conversationFilters() }
          if (this.uiStyle !== 'codex' && this.query === '' && this.listedSessions().length > 0) {
            ListItem() {
              Text('最近').fontSize(15).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
                .width('100%').padding({ left: 12, top: 4 })
            }
          }
          if (this.listedSessions().length === 0) { ListItem() { this.emptyState() } }
          ForEach(this.homeRows(), (row: AiHomeRow): void => {
            ListItem() {
              if (row.session !== null) { this.conversationRow(row.session) }
              else if (row.more > 0) { this.moreRow(row) }
              else { this.projectHeader(row) }
            }.transition(row.session !== null && this.fresh('s:' + row.session.id + ':' + row.session.updatedAt.toString()) ?
              this.enterEffect() : TransitionEffect.IDENTITY)
          }, (row: AiHomeRow): string => row.key)
        } else {
          if (this.historyCursor !== '') {
            ListItem() {
              Text('加载更早的记录').fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().accent)
                .width('100%').textAlign(TextAlign.Center).padding(10).enabled(this.allowed && !this.busy)
                .onClick((): void => { void this.run(async (): Promise<void> => { await this.controller.snapshot(true); }); })
            }
          }
          if (this.items.length === 0) { ListItem() { this.emptyState() } }
          // Messages, and runs of steps folded into one line each, like the Codex and Claude apps.
          ForEach(this.stepEntries(), (entry: AiStepEntry): void => {
            ListItem() {
              if (entry.item !== null) { this.claudeItem(entry.item) }
              else if (entry.steps.length === 1) { this.claudeItem(entry.steps[0]) }
              else { this.stepGroup(entry) }
            }.transition(this.fresh('t:' + entry.key) ? this.enterEffect() : TransitionEffect.IDENTITY)
          }, (entry: AiStepEntry): string => this.entryKey(entry))
          if (this.changeSummary() !== '') {
            ListItem() {
              Row({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(14).fontColor([this.palette().text2])
                Text(this.changeSummary()).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text)
                  .layoutWeight(1)
                Text('查看差异').fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().accent)
              }.width('100%').padding(12).borderRadius(12).border({ width: 0.5, color: this.palette().border })
              .onClick((): void => {
                this.detailTab = 1; this.showDetails = true;
                void this.run(async (): Promise<void> => { await this.controller.loadDiff(); });
              })
            }
          }
          if (this.working()) { ListItem() { this.workingRow() } }
        }
      }.width('100%').padding({ left: 16, right: 16 }).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
        .onScrollIndex((_start: number, end: number): void => {
          if (Date.now() < this.pinBottomUntil) { return; }
          this.followBottom = end >= this.listLength() - 2;
        })
      }.height(Math.max(180, this.pageHeight - this.topVp() - this.topChrome - this.bottomChrome - 16))
      // Pull down on the conversation list to read it again (the chat follows its own stream).
      .pullToRefresh(this.sessionId === '' && this.allowed)
      .onRefreshing((): void => { void this.refreshList(); })
      Column() {
        if (this.approvals.length > 0 && this.sessionId !== '') {
          Column() { this.approvalCard(this.approvals[0]) }.width('100%').padding({ left: 12, right: 12, top: 6 })
        }
        this.composer()
      }.width('100%').onAreaChange((_old: Area, next: Area): void => {
        const before = this.bottomChrome; this.bottomChrome = this.measured(next, this.bottomChrome);
        if (before !== this.bottomChrome && this.sessionId !== '') { this.followTranscript(); }
      })
    }.width('100%').constraintSize({ minHeight: Math.max(1, this.pageHeight - this.topVp() - 12), maxWidth: 1100 })
    .bindSheet($$this.showAddSheet, this.addSheet(), { height: SheetSize.MEDIUM, showClose: false, dragBar: true,
      preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER, backgroundColor: this.pal().surface,
      blurStyle: BlurStyle.NONE })
  }
  build() {
    // One sheet per node: three bindSheets on the Row shared one slot, so the closed details/approval bindings
    // dismissed the picker the moment it opened (and its flag stayed true, so later taps did nothing).
    Row() {
      Stack() {
        Scroll() { this.workspace() }.width('100%').height('100%')
          .scrollable(ScrollDirection.Vertical).scrollBar(BarState.Auto)
          .bindSheet($$this.showApproval, this.approvalSheet(), { height: SheetSize.LARGE, showClose: false, dragBar: false,
            preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
            keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY, backgroundColor: this.pal().sheetBg, blurStyle: BlurStyle.NONE })
      }.width('100%').height('100%')
      .bindSheet($$this.showDetails, this.detailsSheet(), { height: SheetSize.LARGE, showClose: false, dragBar: false,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY, backgroundColor: this.pal().sheetBg, blurStyle: BlurStyle.NONE })
    }.justifyContent(FlexAlign.Center).width('100%').height('100%')
      .padding({ top: this.topVp() }).safeAreaPadding({ bottom: 12 }).backgroundColor(this.palette().bg)
      .bindSheet($$this.showModelPicker, this.modelSheet(), { height: SheetSize.LARGE, showClose: false, dragBar: true,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER, backgroundColor: this.pal().surface,
        blurStyle: BlurStyle.NONE })
      .onAreaChange((_old: Area, next: Area): void => {
        const width = Number(next.width), height = Number(next.height);
        if (Number.isFinite(width) && width > 0 && Math.abs(width - this.pageWidth) > 0.5) { this.pageWidth = width; }
        if (Number.isFinite(height) && height > 0 && Math.abs(height - this.pageHeight) > 0.5) { this.pageHeight = height; }
      })
  }
}
