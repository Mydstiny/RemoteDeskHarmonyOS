import { AppUiMetrics } from '../common/AppUiMetrics';
import { AiActionButton } from '../components/ai/AiActionButton';
import { AiFormField } from '../components/ai/AiFormField';
import { aiStatusLabel, aiRequestTitle, aiApprovalDetails, aiModeLabel, aiOperationSummary, aiShortTime, aiRelativeTime } from '../services/ai/AiPresentation';
import { aiParams } from '../services/ai/AiWirePolicy';
import { KeyboardAvoidMode, router, promptAction } from '@kit.ArkUI';
import { common, ApplicationStateChangeCallback } from '@kit.AbilityKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import { AppSheetHeader } from '../components/AppSheetHeader';
import { AiAccess, AiAccountLease } from '../services/ai/AiAccess';
import { AiHostService } from '../services/ai/AiHostService';
import { AiHost, AiProject, AiSession, AiTranscriptItem, AiApproval, AiPendingOperation, aiBackendName } from '../services/ai/AiModels';
import { AiWorkspaceController } from '../services/ai/AiWorkspaceController';
import { AiLocalStore } from '../services/ai/AiLocalStore';
import { aiArray, aiRecord, aiString, aiErrorText } from '../services/ai/AiWirePolicy';
import { AiStylePalette, aiStylePalette } from '../services/ai/AiStylePalette';
import { AiDiffFile, AiToolView, aiConversationItem, aiDiffFiles, aiDiffSignature, aiDiffStats, aiItemDiff, aiStepState, aiToolView } from '../services/ai/AiTimeline';
import { AiRemoteMarkdown } from '../components/ai/AiRemoteMarkdown';
import { AiDiffView } from '../components/ai/AiDiffView';
import { ProBadge } from '../components/ProBadge';

interface AiWsButton { label: string; primary: boolean; enabled: boolean; action: () => void; }
interface AiWsIconButton { symbol: Resource; label: string; enabled: boolean; action: () => void; }
interface AiWsTab { label: string; selected: boolean; enabled: boolean; action: () => void; }
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
    this.followTranscript();
    this.projects = c.projects.slice(); this.sessions = c.sessions.slice(); this.items = c.transcript.items.slice();
    this.approvals = c.approvals.slice(); this.operations = c.operations.slice(); this.terminals = c.terminals.slice();
    this.models = c.models.slice(); this.allowed = c.allowed; this.archived = c.archived;
    this.sessionId = c.sessionId; this.projectId = c.projectId; this.historyCursor = c.historyCursor;
    this.control = c.lease !== '' && c.leaseExpires > Date.now(); this.diff = c.diff;
    this.role = c.client?.handshake?.role ?? '';
    if (this.listFilter !== '' && !this.projects.some((project: AiProject): boolean => project.id === this.listFilter)) { this.listFilter = ''; }
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
  private async backToList(): Promise<void> {
    this.resetView();
    await this.run(async (): Promise<void> => { this.resetDrafts(); await this.controller.closeSession(); });
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
      // Claude does not echo the prompt while the turn runs; show it until its own event arrives.
      if (this.host?.backend === 'claudecode') { this.controller.transcript.echo(text, aiString(result['turnId']), sentAt); }
      this.draft = ''; this.attachments = [];
    });
  }
  private async attach(): Promise<void> {
    if (!this.allowed || !AiAccess.getInstance().proVisible()) { return; }
    await this.run(async (): Promise<void> => {
      const client = this.controller.client; const project = this.projectId;
      if (client === null || this.attachments.length >= 4) { return; }
      const selected = await new picker.DocumentViewPicker().select({ maxSelectNumber: 1,
        fileSuffixFilters: ['附件|.txt,.md,.png,.jpg,.jpeg'] });
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
  private shownItems(): AiTranscriptItem[] {
    if (this.uiStyle !== 'codex') { return this.visibleItems(); }
    if (this.codexTab === 2) { return []; }
    return this.items.filter((item: AiTranscriptItem): boolean => (this.codexTab === 0) === aiConversationItem(item));
  }
  /** Rows in the list, the same way build() lays them out, so following knows where the bottom is. */
  private listLength(): number {
    const diffTab = this.uiStyle === 'codex' && this.codexTab === 2;
    let count = (this.historyCursor !== '' && !diffTab ? 1 : 0) + (this.items.length === 0 && !diffTab ? 1 : 0);
    if (diffTab) { return count + 1; }
    count += this.shownItems().length + (this.working() ? 1 : 0);
    if (this.uiStyle === 'codex' && this.codexTab === 0 && this.changeSummary() !== '') { count++; }
    return count;
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
  /** Claude's file approvals carry the whole edit in their input; Codex ones need the native item to be complete. */
  private approvalAcceptable(approval: AiApproval): boolean {
    return approval.request['kind'] !== 'fileChange' || approval.request['nativeItemComplete'] === true ||
      approval.request['engine'] === 'claudecode';
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
  @Builder private detailsSheet() {
    Column() {
      AppSheetHeader({ title: '会话详情', showProBadge: true, onClose: (): void => { this.showDetails = false; } })
      Column() {
        Row({ space: 4 }) {
          this.detailTabButton({ label: '模型', selected: this.detailTab === 0, enabled: true, action: (): void => { this.detailTab = 0; } })
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
            this.sectionTitle('模型')
            Select(this.models.map((row: Record<string, Object>): SelectOption => ({ value: aiString(row['displayName'], aiString(row['name'], aiString(row['id']))) })))
              .value(this.model || '保持当前模型').enabled(!this.busy && this.allowed).width('100%').accessibilityText('模型').onSelect((index: number): void => {
                const row = this.models[index]; if (row === undefined || this.busy || !this.allowed) { return; } this.model = aiString(row['model'], aiString(row['id']));
                this.provider = aiString(row['provider']); this.effort = '';
                this.efforts = aiArray(row['supportedReasoningEfforts']).map((value: Object): string => aiString(aiRecord(value)['reasoningEffort']));
              })
            if (this.efforts.length > 0) {
              this.sectionTitle('推理强度')
              Select(this.efforts.map((value: string): SelectOption => ({ value }))).value(this.effort || '保持推理强度').width('100%').enabled(!this.busy && this.allowed).accessibilityText('推理强度')
                .onSelect((index: number): void => { if (!this.busy && this.allowed && index >= 0 && index < this.efforts.length) { this.effort = this.efforts[index]; } })
            }
            if ((this.controller.client?.choices('permissionModes') ?? []).length > 0) {
              this.sectionTitle('权限模式（不选则保持当前）')
              this.modeChoices({ values: this.controller.client?.choices('permissionModes') ?? [], selected: this.permission,
                choose: (value: string): void => { this.permission = value; } })
            }
            if ((this.controller.client?.choices('collaborationModes') ?? []).length > 0) {
              this.sectionTitle('协作模式（不选则保持当前）')
              this.modeChoices({ values: this.controller.client?.choices('collaborationModes') ?? [], selected: this.collaboration,
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
  private listedSessions(): AiSession[] {
    return this.sessions.filter((session: AiSession): boolean =>
      !session.archived && (this.listFilter === '' || session.project === this.listFilter));
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
  @Builder private moreMenuButton() {
    Stack() {
      SymbolGlyph($r('sys.symbol.line_3_horizontal')).fontSize(20).fontColor([this.palette().text2])
    }.width(40).height(40).borderRadius(20).accessibilityText('更多').focusable(true).enabled(this.allowed || this.canReconnect)
    .bindMenu([
      { value: '模型与会话设置', action: (): void => { if (this.allowed) { this.detailTab = 0; this.showDetails = true; } } },
      { value: '差异', action: (): void => {
        if (!this.allowed || !this.capability('diffs')) { return; }
        if (this.uiStyle === 'codex') { this.codexTab = 2; } else { this.detailTab = 1; this.showDetails = true; }
        void this.run(async (): Promise<void> => { await this.controller.loadDiff(); });
      } },
      { value: '终端任务', action: (): void => {
        if (!this.allowed || !this.capability('terminalManagement')) { return; }
        this.detailTab = 2; this.showDetails = true;
        void this.run(async (): Promise<void> => { await this.controller.loadTerminals(); });
      } },
      { value: '待确认操作', action: (): void => {
        if (!this.allowed) { return; }
        this.detailTab = 3; this.showDetails = true;
        void this.run(async (): Promise<void> => { await this.controller.refreshOperations(); });
      } },
      { value: '重新连接', action: (): void => { void this.reconnect(); } }
    ])
  }
  /** Back from a conversation goes to the list; from the list it leaves the host. */
  @Builder private backButton() {
    this.iconButton({ symbol: $r('sys.symbol.chevron_left'), label: this.sessionId !== '' ? '返回对话列表' : '返回',
      enabled: true, action: (): void => { if (this.sessionId !== '') { void this.backToList(); } else { void this.leave(); } } })
  }
  /** New conversation: straight into the filtered (or only) project, otherwise the project is picked from a menu. */
  @Builder private newChatButton() {
    if (this.newChatTarget() !== '' || this.projects.length === 0) {
      this.iconButton({ symbol: $r('sys.symbol.square_and_pencil'), label: '新建对话',
        enabled: this.allowed && !this.busy && this.operator() && this.newChatTarget() !== '',
        action: (): void => { void this.newSession(this.newChatTarget()); } })
    } else {
      Stack() {
        SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(20).fontColor([this.palette().text2])
      }.width(AppUiMetrics.minTouchTarget).height(AppUiMetrics.minTouchTarget).borderRadius(22)
      .enabled(this.allowed && !this.busy && this.operator()).opacity(this.allowed && !this.busy && this.operator() ? 1 : 0.4)
      .accessibilityText('新建对话，选择项目').focusable(true)
      .bindMenu(this.projects.map((project: AiProject): MenuElement => ({ value: '在「' + project.title + '」新建对话',
        action: (): void => { void this.newSession(project.id); } })))
    }
  }
  @Builder private claudeHeader() {
    Row({ space: 2 }) {
      this.backButton()
      Column({ space: 3 }) {
        Text(this.title).fontSize(17).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily)
          .fontColor(this.palette().text).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          Column().width(7).height(7).borderRadius(4)
            .backgroundColor(this.working() ? this.palette().accent : this.status === '已连接' || this.control ? this.palette().ok : this.palette().text3)
          Text(this.backendName() + (this.sessionId !== '' ? ' · ' + this.projectTitle(this.projectId) : '') + ' · ' + this.status)
            .fontSize(12).fontFamily(AppConfig.fontFamily)
            .fontColor(this.palette().text3).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start).padding({ left: 4 })
      ProBadge().alignSelf(ItemAlign.Center).margin({ right: 4 })
      if (this.sessionId === '') { this.newChatButton() } else { this.moreMenuButton() }
    }.width('100%').padding({ left: 6, right: 6, top: 4, bottom: 4 })
  }
  @Builder private codexHeader() {
    Row({ space: 2 }) {
      this.backButton()
      Column({ space: 3 }) {
        Text(this.title).fontSize(16).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily)
          .fontColor(this.palette().text).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.backendName() + (this.sessionId !== '' ? ' · ' + this.projectTitle(this.projectId) : '') + ' · ' + this.status)
          .fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start).padding({ left: 4 })
      ProBadge().alignSelf(ItemAlign.Center).margin({ right: 6 })
      if (this.sessionId === '') { this.newChatButton() } else { this.moreMenuButton() }
    }.width('100%').padding({ left: 6, right: 6, top: 4, bottom: 4 })
  }
  @Builder private filterChip(t: AiWsTab) {
    Text(t.label).fontSize(14).fontFamily(AppConfig.fontFamily).maxLines(1)
      .fontColor(t.selected ? this.palette().onAccent : this.palette().text)
      .backgroundColor(t.selected ? this.palette().accent : this.palette().surface)
      .padding({ left: 14, right: 14 }).height(AppUiMetrics.minTouchTarget - 8).borderRadius(18)
      .enabled(t.enabled).opacity(t.enabled ? 1 : 0.45).accessibilityText(t.label + (t.selected ? '，已选中' : ''))
      .onClick((): void => { if (t.enabled) { t.action(); } })
  }
  /** The home of a host: every conversation, newest first, filtered by project like the Codex app's sidebar. */
  @Builder private conversationFilters() {
    Scroll() {
      Row({ space: 8 }) {
        if (this.projects.length > 1) {
          this.filterChip({ label: '全部', selected: this.listFilter === '', enabled: true, action: (): void => { this.listFilter = ''; } })
          ForEach(this.projects, (project: AiProject): void => {
            this.filterChip({ label: project.title, selected: this.listFilter === project.id, enabled: true,
              action: (): void => { this.listFilter = project.id; } })
          }, (project: AiProject): string => project.id)
        }
        this.filterChip({ label: '刷新', selected: false, enabled: this.allowed && !this.busy, action: (): void => {
          void this.run(async (): Promise<void> => { await this.controller.refreshSessions(); });
        } })
      }.padding({ top: 4, bottom: 4 })
    }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
  }
  @Builder private conversationRow(session: AiSession) {
    Row({ space: 10 }) {
      Column({ space: 4 }) {
        Text(session.title).fontSize(16).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Row({ space: 6 }) {
          if (session.origin === 'computer') {
            Text('电脑').fontSize(11).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text2)
              .padding({ left: 6, right: 6, top: 1, bottom: 1 }).borderRadius(6).backgroundColor(this.palette().surface)
          }
          Text((this.projects.length > 1 && this.listFilter === '' ? this.projectTitle(session.project) + ' · ' : '') +
            aiRelativeTime(session.updatedAt)).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        }.width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([this.palette().text3])
    }.width('100%').padding({ top: 12, bottom: 12 })
    .border({ width: { bottom: 0.5 }, color: this.palette().border })
    .enabled(this.allowed && !this.busy).focusable(true)
    .accessibilityText((session.origin === 'computer' ? '电脑上的对话 ' : '对话 ') + session.title)
    .onClick((): void => { void this.chooseSession(session.id); })
  }
  @Builder private codexTabs() {
    Row({ space: 6 }) {
      ForEach(['对话', '日志', '差异'], (label: string, index: number): void => {
        Text(label).fontSize(14).fontFamily(AppConfig.fontFamily)
          .fontWeight(this.codexTab === index ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.codexTab === index ? this.palette().text : this.palette().text3)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 }).borderRadius(16)
          .backgroundColor(this.codexTab === index ? this.palette().surface : Color.Transparent)
          .accessibilityText(label).accessibilitySelected(this.codexTab === index)
          .onClick((): void => {
            this.codexTab = index;
            if (index === 2 && this.capability('diffs') && this.allowed) {
              void this.run(async (): Promise<void> => { await this.controller.loadDiff(); });
            }
          })
      }, (label: string): string => label)
    }.width('100%').padding({ left: 12, right: 12, bottom: 6 })
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
  @Builder private toolRow(item: AiTranscriptItem) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        this.stepIndicator(item.state)
        SymbolGlyph(this.toolSymbol(this.toolView(item).icon)).fontSize(15).fontColor([this.palette().text3])
        Text() {
          Span(this.toolView(item).verb + ' ').fontWeight(FontWeight.Medium).fontColor(this.palette().text)
          Span(this.toolView(item).target).fontColor(this.palette().text2)
        }.fontSize(this.textSize - 1).fontFamily(AppConfig.fontFamily).layoutWeight(1)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.toolView(item).stats !== '') { this.stats(this.toolView(item).stats) }
        SymbolGlyph(this.expanded(item.id) ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
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
        SymbolGlyph($r('sys.symbol.wand_and_stars')).fontSize(14).fontColor([this.palette().text3])
        Text(aiStepState(item.state) === 'running' ? '思考中…' : '已思考').fontSize(13)
          .fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
        SymbolGlyph(this.expanded(item.id) ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(11).fontColor([this.palette().text3])
      }.focusable(true).accessibilityText('思考过程').onClick((): void => { this.toggleExpanded(item.id); })
      if (this.expanded(item.id)) {
        Text(item.text).fontSize(this.textSize - 1).lineHeight(Math.round((this.textSize - 1) * 1.5))
          .fontFamily(AppConfig.fontFamily).fontColor(this.palette().text2).fontStyle(FontStyle.Italic)
          .copyOption(CopyOptions.InApp).padding({ left: 22 }).width('100%')
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
  @Builder private codexConversationItem(item: AiTranscriptItem) {
    if (item.role === 'user') {
      Column({ space: 4 }) {
        Text('你').fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
        Text(item.text).fontSize(this.textSize).lineHeight(Math.round(this.textSize * 1.5)).fontFamily(AppConfig.fontFamily)
          .fontColor(this.palette().text).copyOption(CopyOptions.InApp).width('100%')
      }.width('100%').padding(14).borderRadius(14).backgroundColor(this.palette().userBubble)
      .alignItems(HorizontalAlign.Start)
    } else if (item.role === 'assistant') {
      AiRemoteMarkdown({ text: item.text, textSize: this.textSize, palette: this.palette() })
    } else {
      this.noticeRow(item)
    }
  }
  @Builder private codexLogItem(item: AiTranscriptItem) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        this.stepIndicator(item.state)
        Text(item.kind === 'thinking' ? '思考' : (this.toolView(item).icon === 'terminal' ? '$ ' + this.toolView(item).target :
          this.toolView(item).verb + ' ' + this.toolView(item).target))
          .fontSize(13).fontFamily('monospace').fontColor(this.palette().text).layoutWeight(1)
          .maxLines(this.expanded(item.id) ? 12 : 1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.toolView(item).stats !== '') { this.stats(this.toolView(item).stats) }
      }.width('100%').focusable(true).accessibilityText(this.toolView(item).verb + ' ' + this.toolView(item).target)
      .onClick((): void => { this.toggleExpanded(item.id); })
      if (item.kind === 'thinking' && this.expanded(item.id)) {
        Text(item.text).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text2).width('100%')
      }
      if (item.kind !== 'thinking' && (item.output ?? '') !== '' && item.title !== 'fileChange') {
        Text(this.expanded(item.id) ? (item.output ?? '').slice(0, 6000) : this.outputPreview(item.output ?? ''))
          .fontSize(12).lineHeight(17).fontFamily('monospace').fontColor(this.palette().codeText)
          .copyOption(CopyOptions.InApp).width('100%').padding(10).borderRadius(8).backgroundColor(this.palette().codeBg)
      }
      if (this.expanded(item.id) && item.kind !== 'thinking') {
        if (aiItemDiff(item).length > 0) {
          AiDiffView({ files: aiItemDiff(item), textSize: 12, palette: this.palette(), startOpen: true })
        } else if ((item.detail ?? '') !== '' && this.toolView(item).icon !== 'terminal') {
          this.codeBlock(item.detail ?? '', '输入')
        }
      }
    }.width('100%').padding(12).borderRadius(12).backgroundColor(this.palette().raised)
    .border({ width: 0.5, color: this.palette().border })
  }
  @Builder private codexDiffPane() {
    Column({ space: 10 }) {
      if (this.sessionDiffs().length === 0) {
        Text(this.diffNotice('这个任务还没有可显示的差异'))
          .fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3).width('100%')
          .padding({ top: 24, bottom: 24 }).textAlign(TextAlign.Center)
      } else {
        Text(this.sessionDiffs().length.toString() + ' 个文件').fontSize(12).fontFamily(AppConfig.fontFamily)
          .fontColor(this.palette().text3).width('100%')
        ForEach([this.sessionDiffKey()], (_key: string): void => {
          AiDiffView({ files: this.sessionDiffs(), textSize: 12, palette: this.palette(),
            startOpen: this.sessionDiffs().length <= 3 })
        }, (key: string): string => key)
      }
    }.width('100%')
  }
  @Builder private workingRow() {
    Row({ space: 8 }) {
      LoadingProgress().width(18).height(18).color(this.palette().accent)
      Text(this.uiStyle === 'codex' ? '正在处理…' : this.backendName() + ' 正在工作…').fontSize(13)
        .fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
    }.padding({ top: 2, bottom: 2 })
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
  @Builder private composer() {
    Column({ space: 8 }) {
      if (this.role !== '' && !this.operator()) {
        Text('这台设备只有查看权限，可以看对话，不能发送或批准').fontSize(12).fontFamily(AppConfig.fontFamily)
          .fontColor(this.palette().text3).width('100%')
      }
      if (this.backgroundTasks()) {
        Row({ space: 6 }) {
          LoadingProgress().width(14).height(14).color(this.palette().text3)
          Text('上一轮启动的任务仍在电脑上运行').fontSize(12).fontFamily(AppConfig.fontFamily)
            .fontColor(this.palette().text2).layoutWeight(1)
          if (this.capability('terminalManagement')) {
            Text('查看').fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.palette().accent)
              .enabled(this.allowed && !this.busy).onClick((): void => {
                if (!this.allowed || this.busy) { return; }
                this.detailTab = 2; this.showDetails = true;
                void this.run(async (): Promise<void> => { await this.controller.loadTerminals(); });
              })
          }
        }.width('100%')
      }
      if (this.attachments.length > 0) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.paperclip')).fontSize(13).fontColor([this.palette().text3])
          Text('已添加 ' + this.attachments.length.toString() + ' 个附件，随下一条消息发送').fontSize(12)
            .fontFamily(AppConfig.fontFamily).fontColor(this.palette().text2).layoutWeight(1)
          Text('移除').fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.palette().accent)
            .enabled(!this.busy).onClick((): void => { if (!this.busy) { this.attachments = []; } })
        }.width('100%')
      }
      Column({ space: 4 }) {
        TextArea({ text: this.draft, placeholder: this.archived ? '先恢复归档会话' :
          this.uiStyle === 'codex' ? '描述要做的修改，或提一个问题…' : '回复 ' + this.backendName() + '…' })
          .constraintSize({ minHeight: 44, maxHeight: this.composerMaxHeight() })
          .fontSize(this.textSize).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text)
          .placeholderColor(this.palette().text3).backgroundColor(Color.Transparent).padding({ left: 4, right: 4 })
          .enabled(this.allowed && !this.busy && !this.archived).accessibilityText('任务内容')
          .onChange((value: string): void => { if (this.allowed && !this.busy) { this.draft = value; } }).maxLength(128000)
        Row({ space: 6 }) {
          this.roundAction({ symbol: $r('sys.symbol.paperclip'), label: '附件', primary: false, enabled: this.canAttach(), action: (): void => { void this.attach(); } })
          this.chip({ label: this.model !== '' ? this.model : '模型', enabled: this.allowed && !this.busy, action: (): void => { this.detailTab = 0; this.showDetails = true; } })
          if ((this.controller.client?.choices('permissionModes').length ?? 0) > 0) {
            this.chip({ label: this.permission !== '' ? aiModeLabel(this.permission) : '权限模式', enabled: this.allowed && !this.busy, action: (): void => { this.detailTab = 0; this.showDetails = true; } })
          }
          Blank()
          if (this.composerMode() === 'stop') {
            if (this.draft.trim() !== '' && this.capability('steer')) {
              this.roundAction({ symbol: $r('sys.symbol.arrow_up'), label: '补充指令', primary: false, enabled: this.allowed && !this.busy && !this.archived, action: (): void => { void this.send(true); } })
            }
            this.roundAction({ symbol: $r('sys.symbol.stop_circle_fill'), label: '停止', primary: true, enabled: this.capability('cancel') && !this.busy, action: (): void => { void this.run(async (): Promise<void> => { await this.controller.action('turn.cancel'); }); } })
          } else {
            this.roundAction({ symbol: $r('sys.symbol.arrow_up'), label: '发送', primary: true, enabled: this.operator() && this.allowed && !this.busy && !this.archived && this.draft.trim() !== '', action: (): void => { void this.send(false); } })
          }
        }.width('100%')
      }
      .width('100%').padding({ left: 10, right: 8, top: 8, bottom: 6 })
      .borderRadius(this.uiStyle === 'codex' ? 16 : 22).backgroundColor(this.palette().surface)
      .border({ width: 0.5, color: this.palette().border })
    }.width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
  }
  @Builder private workspace() {
    Column() {
      Column() {
        if (this.uiStyle === 'codex') { this.codexHeader() } else { this.claudeHeader() }
        if (this.error !== '') {
          Text(this.error).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().danger)
            .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 4 })
        }
        if (this.uiStyle === 'codex' && this.sessionId !== '') { this.codexTabs() }
      }.width('100%').onAreaChange((_old: Area, next: Area): void => { this.topChrome = this.measured(next, this.topChrome); })
      List({ space: this.uiStyle === 'codex' ? 10 : 14, scroller: this.scroller() }) {
        if (this.historyCursor !== '' && !(this.uiStyle === 'codex' && this.codexTab === 2)) {
          ListItem() {
            Text('加载更早的记录').fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().accent)
              .width('100%').textAlign(TextAlign.Center).padding(10).enabled(this.allowed && !this.busy)
              .onClick((): void => { void this.run(async (): Promise<void> => { await this.controller.snapshot(true); }); })
          }
        }
        if (this.sessionId === '') {
          ListItem() { this.conversationFilters() }
          if (this.listedSessions().length === 0) { ListItem() { this.emptyState() } }
          ForEach(this.listedSessions(), (session: AiSession): void => {
            ListItem() { this.conversationRow(session) }
          }, (session: AiSession): string => session.id + ':' + session.title + ':' + session.updatedAt.toString() + ':' +
            (this.projects.length > 1 && this.listFilter === '' ? 'p' : ''))
        } else if (this.items.length === 0 && !(this.uiStyle === 'codex' && this.codexTab === 2)) {
          ListItem() { this.emptyState() }
        }
        if (this.uiStyle === 'codex' && this.codexTab === 2) {
          ListItem() { this.codexDiffPane() }
        } else {
          ForEach(this.shownItems(), (item: AiTranscriptItem): void => {
            ListItem() {
              if (this.uiStyle !== 'codex') { this.claudeItem(item) }
              else if (this.codexTab === 0) { this.codexConversationItem(item) }
              else { this.codexLogItem(item) }
            }
          }, (item: AiTranscriptItem): string => item.id + ':' + item.state + ':' + item.text.length.toString() + ':' +
            (item.output ?? '').length.toString() + ':' + this.codexTab.toString() + (this.expanded(item.id) ? ':open' : ''))
          if (this.uiStyle === 'codex' && this.codexTab === 0 && this.changeSummary() !== '') {
            ListItem() {
              Row({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(14).fontColor([this.palette().text2])
                Text(this.changeSummary()).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text)
                  .layoutWeight(1)
                Text('查看差异').fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().accent)
              }.width('100%').padding(12).borderRadius(12).border({ width: 0.5, color: this.palette().border })
              .onClick((): void => { this.codexTab = 2; })
            }
          }
          if (this.working()) { ListItem() { this.workingRow() } }
        }
      }.height(Math.max(180, this.pageHeight - this.topVp() - this.topChrome - this.bottomChrome - 16))
        .width('100%').padding({ left: 16, right: 16 }).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
        .onScrollIndex((_start: number, end: number): void => {
          if (Date.now() < this.pinBottomUntil) { return; }
          this.followBottom = end >= this.listLength() - 2;
        })
      Column() {
        if (this.approvals.length > 0 && this.sessionId !== '') {
          Column() { this.approvalCard(this.approvals[0]) }.width('100%').padding({ left: 12, right: 12, top: 6 })
        }
        if (this.sessionId !== '') { this.composer() }
      }.width('100%').onAreaChange((_old: Area, next: Area): void => {
        const before = this.bottomChrome; this.bottomChrome = this.measured(next, this.bottomChrome);
        if (before !== this.bottomChrome) { this.followTranscript(); }
      })
    }.width('100%').constraintSize({ minHeight: Math.max(1, this.pageHeight - this.topVp() - 12), maxWidth: 1100 })
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
      .onAreaChange((_old: Area, next: Area): void => {
        const width = Number(next.width), height = Number(next.height);
        if (Number.isFinite(width) && width > 0 && Math.abs(width - this.pageWidth) > 0.5) { this.pageWidth = width; }
        if (Number.isFinite(height) && height > 0 && Math.abs(height - this.pageHeight) > 0.5) { this.pageHeight = height; }
      })
  }
}
