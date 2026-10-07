import { AppUiMetrics } from '../common/AppUiMetrics';
import { AppSettingsChoiceButton } from '../components/AppSettingsChoiceButton';
import { AiActionButton } from '../components/ai/AiActionButton';
import { AiFormField } from '../components/ai/AiFormField';
import { aiStatusLabel, aiRequestTitle, aiApprovalDetails } from '../services/ai/AiPresentation';
import { aiParams } from '../services/ai/AiWirePolicy';
import { router, promptAction } from '@kit.ArkUI';
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
  @State showSessionPicker: boolean = false;
  @State pageWidth: number = 320;
  @State pageHeight: number = 800;
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
      this.resetDrafts(); this.showDetails = false; this.showSessionPicker = false;
    } else if (!c.allowed) {
      this.resetDrafts(); this.showDetails = false; this.showSessionPicker = false;
    }
    this.title = c.title || this.host?.label || '远程 AI'; this.status = aiStatusLabel(c.status); this.error = c.error;
    this.rawStatus = c.status;
    this.followTranscript();
    this.projects = c.projects.slice(); this.sessions = c.sessions.slice(); this.items = c.transcript.items.slice();
    this.approvals = c.approvals.slice(); this.operations = c.operations.slice(); this.terminals = c.terminals.slice();
    this.models = c.models.slice(); this.allowed = c.allowed; this.archived = c.archived;
    this.sessionId = c.sessionId; this.projectId = c.projectId; this.historyCursor = c.historyCursor;
    this.control = c.lease !== '' && c.leaseExpires > Date.now(); this.diff = c.diff;
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
        this.resetDrafts(); this.showDetails = false; this.showSessionPicker = false; this.showApproval = false; this.allowed = false;
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
        this.inBackground = true; this.controller.close(); this.resetDrafts(); this.showDetails = false; this.showSessionPicker = false; this.controller.status = '已暂停连接'; this.sync();
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
    this.mountGeneration++; this.alive = false; this.stopPageAccess(); this.stopPageAccess = (): void => {};
    this.controller.close(); this.resetDrafts();
    this.showDetails = false; this.showSessionPicker = false; this.host = null; this.pageAccount = null;
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
  onBackPress(): boolean { void this.leave(); return true; }
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
  private composerMode(): string { return this.working() && this.control ? 'stop' : 'send'; }
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
  private followTranscript(): void {
    const scroller = this.listScroller;
    if (scroller === null || !this.followBottom) { return; }
    setTimeout((): void => { try { scroller.scrollEdge(Edge.Bottom); } catch (_error) { /* list not laid out yet */ } }, 0);
  }
  private canAttach(): boolean {
    return this.allowed && !this.busy && (this.controller.client?.choices('attachments').length ?? 0) > 0 &&
      this.attachments.length < 4;
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
    return approval !== null && approval.expires > Date.now() && this.control && this.allowed &&
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
          AiActionButton({ label: '停止回合', isEnabled: this.control && !this.busy, onAction: (): void => {
            void this.run(async (): Promise<void> => { await this.controller.action('turn.cancel'); this.showApproval = false; });
          } }).layoutWeight(1)
        } else {
          AiActionButton({ label: '拒绝', isEnabled: this.control && this.allowed && !this.busy,
            onAction: (): void => { void this.answer('decline'); } }).layoutWeight(1)
        }
        AiActionButton({ label: this.questions.length > 0 ? '提交回答' : '允许此次请求', primary: true,
          isEnabled: this.canAccept() && !this.busy, onAction: (): void => { void this.answer('accept'); } }).layoutWeight(1)
      }.padding(AppUiMetrics.sheetPadding).width('100%')
      if (this.error !== '') { Text(this.error).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().danger).padding(12) }
    }.height('100%').width('100%').safeAreaPadding({ bottom: 16 }).backgroundColor(this.pal().sheetBg)
  }
  @Builder private detailsSheet() {
    Column() {
      AppSheetHeader({ title: '会话详情', showProBadge: true, onClose: (): void => { this.showDetails = false; } })
      Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        AppSettingsChoiceButton({ label: '模型', isSelected: this.detailTab === 0, onSelect: (): void => { this.detailTab = 0; } })
          .width(this.pageWidth < 600 ? '48%' : '23%').margin({ bottom: 8 })
        AppSettingsChoiceButton({ label: '差异', isSelected: this.detailTab === 1, onSelect: (): void => {
          if (!this.capability('diffs')) { return; } this.detailTab = 1; void this.run(async (): Promise<void> => { await this.controller.loadDiff(); });
        } }).width(this.pageWidth < 600 ? '48%' : '23%').margin({ bottom: 8 }).enabled(this.capability('diffs'))
        AppSettingsChoiceButton({ label: '终端', isSelected: this.detailTab === 2, onSelect: (): void => {
          if (!this.capability('terminalManagement')) { return; } this.detailTab = 2; void this.run(async (): Promise<void> => { await this.controller.loadTerminals(); });
        } }).width(this.pageWidth < 600 ? '48%' : '23%').margin({ bottom: 8 }).enabled(this.capability('terminalManagement'))
        AppSettingsChoiceButton({ label: '操作', isSelected: this.detailTab === 3, onSelect: (): void => {
          this.detailTab = 3; void this.run(async (): Promise<void> => { await this.controller.refreshOperations(); });
        } }).width(this.pageWidth < 600 ? '48%' : '23%').margin({ bottom: 8 })
      }.width('100%').padding({ left: AppUiMetrics.sheetPadding, right: AppUiMetrics.sheetPadding })
      Scroll() {
        Column({ space: 12 }) {
          if (this.detailTab === 0) {
            Text('模型与会话').fontSize(16).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text).width('100%')
            Select(this.models.map((row: Record<string, Object>): SelectOption => ({ value: aiString(row['displayName'], aiString(row['name'], aiString(row['id']))) })))
              .value(this.model || '保持当前模型').enabled(!this.busy && this.allowed).width('100%').accessibilityText('模型').onSelect((index: number): void => {
                const row = this.models[index]; if (row === undefined || this.busy || !this.allowed) { return; } this.model = aiString(row['model'], aiString(row['id']));
                this.provider = aiString(row['provider']); this.effort = '';
                this.efforts = aiArray(row['supportedReasoningEfforts']).map((value: Object): string => aiString(aiRecord(value)['reasoningEffort']));
              })
            if (this.efforts.length > 0) {
              Select(this.efforts.map((value: string): SelectOption => ({ value }))).value(this.effort || '保持推理强度').width('100%').enabled(!this.busy && this.allowed).accessibilityText('推理强度')
                .onSelect((index: number): void => { if (!this.busy && this.allowed && index >= 0 && index < this.efforts.length) { this.effort = this.efforts[index]; } })
            }
            ForEach(this.controller.client?.choices('permissionModes') ?? [], (value: string): void => {
              AppSettingsChoiceButton({ label: value, isSelected: this.permission === value, onSelect: (): void => { if (!this.busy && this.allowed) { this.permission = value; } } }).width('100%').enabled(!this.busy && this.allowed)
            })
            ForEach(this.controller.client?.choices('collaborationModes') ?? [], (value: string): void => {
              AppSettingsChoiceButton({ label: value, isSelected: this.collaboration === value, onSelect: (): void => { if (!this.busy && this.allowed) { this.collaboration = value; } } }).width('100%').enabled(!this.busy && this.allowed)
            })
            AiFormField({ title: '会话名称', value: this.newTitle, hint: '填写新的会话名称', limit: 200, isEnabled: !this.busy && this.allowed, onChange: (value: string): void => { this.newTitle = value; } })
            Button('保存会话设置').constraintSize({ minHeight: AppUiMetrics.minTouchTarget }).padding({ left: 12, right: 12, top: 10, bottom: 10 }).borderRadius(12).fontSize(14).fontFamily(AppConfig.fontFamily).backgroundColor(this.pal().surface).fontColor(this.pal().text).focusable(true).enabled(this.capability('rename') && this.allowed && this.control && !this.busy).onClick((): void => {
              void this.run(async (): Promise<void> => {
                const params: Record<string, Object> = aiParams(["settings"], [this.settings()]);
                if (this.newTitle.trim() !== '') { params['title'] = this.newTitle.trim(); }
                await this.controller.action('session.update', params); this.controller.title = this.newTitle || this.title;
              });
            })
            Button('从已完成历史分叉').constraintSize({ minHeight: AppUiMetrics.minTouchTarget }).padding({ left: 12, right: 12, top: 10, bottom: 10 }).borderRadius(12).fontSize(14).fontFamily(AppConfig.fontFamily).backgroundColor(this.pal().surface).fontColor(this.pal().text).focusable(true).enabled(this.capability('fork') && this.allowed && this.control && !this.busy).onClick((): void => {
              void this.run(async (): Promise<void> => {
                const result = await this.controller.action('session.fork');
                this.resetView(); this.resetDrafts();
                await this.controller.selectProject(this.projectId); await this.controller.selectSession(aiString(result['sessionId']));
              });
            })
            Button('压缩上下文').constraintSize({ minHeight: AppUiMetrics.minTouchTarget }).padding({ left: 12, right: 12, top: 10, bottom: 10 }).borderRadius(12).fontSize(14).fontFamily(AppConfig.fontFamily).backgroundColor(this.pal().surface).fontColor(this.pal().text).focusable(true).enabled(this.capability('compact') && this.allowed && this.control && !this.busy).onClick((): void => {
              void this.run(async (): Promise<void> => { await this.controller.action('session.compact'); });
            })
            Button(this.archived ? '恢复会话' : '归档会话').constraintSize({ minHeight: AppUiMetrics.minTouchTarget }).padding({ left: 12, right: 12, top: 10, bottom: 10 }).borderRadius(12).fontSize(14).fontFamily(AppConfig.fontFamily).backgroundColor(this.pal().surface).fontColor(this.pal().text).focusable(true).enabled(this.allowed && this.control && !this.busy).onClick((): void => {
              void this.run(async (): Promise<void> => { await this.controller.action(this.archived ? 'session.resume' : 'session.archive'); });
            })
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
            ForEach(this.terminals, (terminal: Record<string, Object>): void => {
              Column({ space: 8 }) {
                Text(JSON.stringify(terminal, null, 2)).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text).width('100%')
                Button('停止此任务').constraintSize({ minHeight: AppUiMetrics.minTouchTarget }).padding({ left: 12, right: 12, top: 10, bottom: 10 }).borderRadius(12).fontSize(14).fontFamily(AppConfig.fontFamily).backgroundColor(this.pal().surface).fontColor(this.pal().text).focusable(true).enabled(this.control && !this.busy).onClick((): void => {
                  void this.run(async (): Promise<void> => {
                    await this.controller.action('terminal.stop', aiParams(["processId"], [aiString(terminal['processId'])]));
                    await this.controller.loadTerminals();
                  });
                })
              }.padding(12).backgroundColor(this.pal().surface).borderRadius(12)
            })
          } else {
            Text('结果未确认时，核对原回执与会话内容后再决定下一步。不会自动重发。').fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3)
            ForEach(this.operations, (operation: AiPendingOperation): void => {
              Column({ space: 8 }) {
                Text(operation.receipt === '' ? '结果待确认' : operation.receipt).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text).width('100%')
                Text(new Date(operation.createdAt).toLocaleString()).fontSize(11).fontFamily(AppConfig.fontFamily).fontColor(this.pal().text3)
                Button('核对原操作').constraintSize({ minHeight: AppUiMetrics.minTouchTarget }).padding({ left: 12, right: 12, top: 10, bottom: 10 }).borderRadius(12).fontSize(14).fontFamily(AppConfig.fontFamily).backgroundColor(this.pal().surface).fontColor(this.pal().text).focusable(true).enabled(this.allowed && !this.busy).onClick((): void => {
                  void this.run(async (): Promise<void> => { await this.controller.reconcile(operation.id); });
                })
              }.width('100%').padding(12).backgroundColor(this.pal().surface).borderRadius(12)
            }, (operation: AiPendingOperation): string => operation.id)
          }
        }.padding(20).width('100%')
      }.layoutWeight(1).width('100%')
      if (this.error !== '') { Text(this.error).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.pal().danger).padding(12) }
    }.height('100%').width('100%').safeAreaPadding({ bottom: 16 }).backgroundColor(this.pal().sheetBg)
  }
  private async chooseProject(id: string): Promise<void> {
    if (!this.allowed || !AiAccess.getInstance().proVisible() || !this.projects.some((project: AiProject): boolean => project.id === id)) { return; }
    this.resetView();
    await this.run(async (): Promise<void> => { this.resetDrafts(); await this.controller.selectProject(id); });
  }
  private async chooseSession(id: string): Promise<void> {
    if (!this.allowed || !AiAccess.getInstance().proVisible() || !this.sessions.some((session: AiSession): boolean => session.id === id)) { return; }
    this.resetView();
    await this.run(async (): Promise<void> => { this.resetDrafts(); await this.controller.selectSession(id); this.showSessionPicker = false; });
  }
  private async newSession(): Promise<void> {
    if (!this.allowed || !AiAccess.getInstance().proVisible()) { return; }
    this.resetView();
    await this.run(async (): Promise<void> => { this.resetDrafts(); await this.controller.create('新会话'); this.showSessionPicker = false; });
  }
  /** The status bar height arrives in px; layout is in vp (it was used as vp, a ~3x gap above the header). */
  private topVp(): number { return this.topInset > 0 ? px2vp(this.topInset) : 0; }
  @Builder private pillButton(label: string, primary: boolean, enabled: boolean, action: () => void) {
    Text(label).fontSize(14).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily)
      .fontColor(primary ? this.palette().onAccent : this.palette().text).textAlign(TextAlign.Center)
      .padding({ left: 16, right: 16 }).constraintSize({ minHeight: AppUiMetrics.minTouchTarget }).borderRadius(20)
      .backgroundColor(primary ? this.palette().accent : this.palette().surface)
      .border({ width: primary ? 0 : 0.5, color: this.palette().border })
      .opacity(enabled ? 1 : 0.45).enabled(enabled).focusable(true).accessibilityText(label)
      .onClick((): void => { if (enabled) { action(); } })
  }
  @Builder private iconButton(symbol: Resource, label: string, enabled: boolean, action: () => void) {
    Stack() {
      SymbolGlyph(symbol).fontSize(20).fontColor([this.palette().text2])
    }.width(40).height(40).borderRadius(20).enabled(enabled).opacity(enabled ? 1 : 0.4)
    .accessibilityText(label).focusable(true).onClick((): void => { if (enabled) { action(); } })
  }
  @Builder private sessionRow(session: AiSession) {
    Row({ space: 10 }) {
      SymbolGlyph(session.id === this.sessionId ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.ellipsis_bubble'))
        .fontSize(18).fontColor([session.id === this.sessionId ? this.palette().accent : this.palette().text3])
      Column({ space: 2 }) {
        Text(session.title).fontSize(15).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (session.archived) {
          Text('已归档').fontSize(11).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([this.palette().text3])
    }
    .width('100%').padding({ left: 12, right: 12, top: 12, bottom: 12 }).borderRadius(12)
    .backgroundColor(session.id === this.sessionId ? this.palette().surface : Color.Transparent)
    .enabled(!this.busy && this.allowed).focusable(true)
    .accessibilityText((session.archived ? '已归档会话 ' : '会话 ') + session.title)
    .onClick((): void => { void this.chooseSession(session.id); })
  }
  @Builder private sessionSelectors() {
    Column({ space: 12 }) {
      if (this.projects.length > 1) {
        Text('项目').fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3).width('100%')
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.projects, (project: AiProject): void => {
              Text(project.title).fontSize(14).fontFamily(AppConfig.fontFamily)
                .fontColor(project.id === this.projectId ? this.palette().onAccent : this.palette().text)
                .padding({ left: 14, right: 14, top: 8, bottom: 8 }).borderRadius(18)
                .backgroundColor(project.id === this.projectId ? this.palette().accent : this.palette().surface)
                .enabled(!this.busy && this.allowed).accessibilityText('项目 ' + project.title)
                .onClick((): void => { void this.chooseProject(project.id); })
            }, (project: AiProject): string => project.id)
          }
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
      } else if (this.projects.length === 1) {
        Text('项目：' + this.projects[0].title).fontSize(13).fontFamily(AppConfig.fontFamily)
          .fontColor(this.palette().text3).width('100%')
      }
      Row() {
        Text(this.uiStyle === 'codex' ? '任务' : '会话').fontSize(13).fontFamily(AppConfig.fontFamily)
          .fontColor(this.palette().text3).layoutWeight(1)
        this.pillButton(this.uiStyle === 'codex' ? '新建任务' : '新建会话', true,
          this.allowed && this.projectId !== '' && !this.busy, (): void => { void this.newSession(); })
      }.width('100%')
      if (this.sessions.length === 0) {
        Text(this.projectId === '' ? '请先选择项目' : '这个项目还没有会话').fontSize(13).fontFamily(AppConfig.fontFamily)
          .fontColor(this.palette().text3).width('100%').padding({ top: 12 })
      }
      ForEach(this.sessions, (session: AiSession): void => {
        this.sessionRow(session)
      }, (session: AiSession): string => session.id + ':' + (session.archived ? 'a' : '') + session.title)
    }.width('100%')
  }
  @Builder private sessionPickerSheet() {
    Column() {
      AppSheetHeader({ title: this.uiStyle === 'codex' ? '任务' : '项目与会话', showProBadge: true,
        onClose: (): void => { this.showSessionPicker = false; } })
      Scroll() { this.sessionSelectors() }.width('100%').layoutWeight(1).padding(AppUiMetrics.sheetPadding)
      if (this.error !== '') { Text(this.error).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().danger).padding(AppUiMetrics.sheetPadding) }
    }.height('100%').width('100%').safeAreaPadding({ bottom: 16 }).backgroundColor(this.palette().bg)
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
  @Builder private claudeHeader() {
    Row({ space: 2 }) {
      this.iconButton($r('sys.symbol.chevron_left'), '返回', true, (): void => { void this.leave(); })
      Column({ space: 3 }) {
        Text(this.title).fontSize(17).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily)
          .fontColor(this.palette().text).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          Column().width(7).height(7).borderRadius(4)
            .backgroundColor(this.working() ? this.palette().accent : this.control ? this.palette().ok : this.palette().text3)
          Text(this.backendName() + ' · ' + this.status).fontSize(12).fontFamily(AppConfig.fontFamily)
            .fontColor(this.palette().text3).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start).padding({ left: 4 })
      ProBadge().alignSelf(ItemAlign.Center).margin({ right: 4 })
      this.iconButton($r('sys.symbol.list_bullet'), '项目与会话', this.allowed && !this.busy,
        (): void => { this.showSessionPicker = true; })
      this.moreMenuButton()
    }.width('100%').padding({ left: 6, right: 6, top: 4, bottom: 4 })
  }
  @Builder private codexHeader() {
    Row({ space: 2 }) {
      this.iconButton($r('sys.symbol.chevron_left'), '返回', true, (): void => { void this.leave(); })
      Column({ space: 3 }) {
        Text(this.title).fontSize(16).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily)
          .fontColor(this.palette().text).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.backendName() + ' · ' + (this.projects.find((project: AiProject): boolean =>
          project.id === this.projectId)?.title ?? '未选择项目') + ' · ' + this.status)
          .fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start).padding({ left: 4 })
      ProBadge().alignSelf(ItemAlign.Center).margin({ right: 6 })
      Text('任务').fontSize(13).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily)
        .fontColor(this.palette().text).padding({ left: 12, right: 12, top: 6, bottom: 6 }).borderRadius(14)
        .border({ width: 0.5, color: this.palette().border }).enabled(this.allowed && !this.busy)
        .accessibilityText('任务列表').onClick((): void => { this.showSessionPicker = true; })
      this.moreMenuButton()
    }.width('100%').padding({ left: 6, right: 6, top: 4, bottom: 4 })
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
      Text(this.sessionId === '' ? '选择项目和会话，或新建会话开始使用。' : '会话准备就绪，取得控制权后即可发送任务。')
        .fontSize(14).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text2).textAlign(TextAlign.Center)
      if (this.sessionId === '' && this.allowed) {
        this.pillButton(this.uiStyle === 'codex' ? '打开任务列表' : '项目与会话', true, !this.busy,
          (): void => { this.showSessionPicker = true; })
      } else if (this.sessionId === '') {
        this.pillButton('重新连接', true, this.canReconnect && !this.busy, (): void => { void this.reconnect(); })
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
      if (!this.control) {
        Text('取得控制权后才能处理这个请求').fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
      }
      Row({ space: 10 }) {
        if (aiString(approval.request['kind']) === 'questions') {
          this.pillButton('回答问题', true, this.control && this.allowed && !this.busy, (): void => { this.inspect(approval); })
        } else {
          this.pillButton('拒绝', false, this.control && this.allowed && !this.busy,
            (): void => { void this.answerInline(approval, 'decline'); })
          this.pillButton('允许此次', true, this.control && this.allowed && !this.busy && approval.expires > Date.now() &&
            this.approvalAcceptable(approval), (): void => { void this.answerInline(approval, 'accept'); })
        }
        Blank()
        Text('完整请求').fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().accent)
          .focusable(true).accessibilityText('查看完整请求与授权范围').onClick((): void => { this.inspect(approval); })
      }.width('100%')
    }.width('100%').padding(14).borderRadius(16).backgroundColor(this.palette().raised)
    .border({ width: 1, color: this.palette().accent })
  }
  @Builder private chip(label: string, enabled: boolean, action: () => void) {
    Text(label).fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text2)
      .padding({ left: 10, right: 10, top: 6, bottom: 6 }).borderRadius(14)
      .border({ width: 0.5, color: this.palette().border }).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      .constraintSize({ maxWidth: 150 }).enabled(enabled).opacity(enabled ? 1 : 0.45).focusable(true)
      .accessibilityText(label).onClick((): void => { if (enabled) { action(); } })
  }
  @Builder private roundAction(symbol: Resource, label: string, primary: boolean, enabled: boolean, action: () => void) {
    Stack() {
      SymbolGlyph(symbol).fontSize(18).fontColor([primary ? this.palette().onAccent : this.palette().text2])
    }.width(36).height(36).borderRadius(18).backgroundColor(primary ? this.palette().accent : Color.Transparent)
    .opacity(enabled ? 1 : 0.35).enabled(enabled).focusable(true).accessibilityText(label)
    .onClick((): void => { if (enabled) { action(); } })
  }
  @Builder private composer() {
    Column({ space: 8 }) {
      if (!this.control) {
        Row({ space: 10 }) {
          Text(this.controller.client?.handshake?.role === 'operator' ? '正在查看 · 取得控制权后才能发送和批准' : '这台设备只有查看权限')
            .fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3).layoutWeight(1)
          if (this.controller.client?.handshake?.role === 'operator') {
            this.pillButton('取得控制权', true, this.allowed && !this.busy,
              (): void => { void this.run(async (): Promise<void> => { await this.controller.acquire(); }); })
          }
        }.width('100%')
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
          this.roundAction($r('sys.symbol.paperclip'), '附件', false, this.canAttach(), (): void => { void this.attach(); })
          this.chip(this.model !== '' ? this.model : '模型', this.allowed && !this.busy,
            (): void => { this.detailTab = 0; this.showDetails = true; })
          if ((this.controller.client?.choices('permissionModes').length ?? 0) > 0) {
            this.chip(this.permission !== '' ? this.permission : '权限模式', this.allowed && !this.busy,
              (): void => { this.detailTab = 0; this.showDetails = true; })
          }
          Blank()
          if (this.composerMode() === 'stop') {
            if (this.draft.trim() !== '' && this.capability('steer')) {
              this.roundAction($r('sys.symbol.arrow_up'), '补充指令', false, this.allowed && !this.busy && !this.archived,
                (): void => { void this.send(true); })
            }
            this.roundAction($r('sys.symbol.stop_circle_fill'), '停止', true, this.capability('cancel') && !this.busy,
              (): void => { void this.run(async (): Promise<void> => { await this.controller.action('turn.cancel'); }); })
          } else {
            this.roundAction($r('sys.symbol.arrow_up'), '发送', true,
              this.control && this.allowed && !this.busy && !this.archived && this.draft.trim() !== '',
              (): void => { void this.send(false); })
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
      if (this.uiStyle === 'codex') { this.codexHeader() } else { this.claudeHeader() }
      if (this.error !== '') {
        Text(this.error).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().danger)
          .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 4 })
      }
      if (this.uiStyle === 'codex' && this.sessionId !== '') { this.codexTabs() }
      List({ space: this.uiStyle === 'codex' ? 10 : 14, scroller: this.scroller() }) {
        if (this.historyCursor !== '' && !(this.uiStyle === 'codex' && this.codexTab === 2)) {
          ListItem() {
            Text('加载更早的记录').fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().accent)
              .width('100%').textAlign(TextAlign.Center).padding(10).enabled(this.allowed && !this.busy)
              .onClick((): void => { void this.run(async (): Promise<void> => { await this.controller.snapshot(true); }); })
          }
        }
        if (this.items.length === 0 && !(this.uiStyle === 'codex' && this.codexTab === 2)) {
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
      }.height(Math.max(180, this.pageHeight - this.topVp() - (this.sessionId !== '' ? (this.uiStyle === 'codex' ? 250 : 206) : 90) -
        (this.approvals.length > 0 ? 170 : 0)))
        .width('100%').padding({ left: 16, right: 16 }).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
        .onScrollIndex((_start: number, end: number): void => { this.followBottom = end >= this.listLength() - 2; })
      if (this.approvals.length > 0 && this.sessionId !== '') {
        Column() { this.approvalCard(this.approvals[0]) }.width('100%').padding({ left: 12, right: 12, top: 6 })
      }
      if (this.sessionId !== '') { this.composer() }
    }.width('100%').constraintSize({ minHeight: Math.max(1, this.pageHeight - this.topVp() - 12), maxWidth: 1100 })
  }
  build() {
    Row() {
      Scroll() { this.workspace() }.width('100%').height('100%')
        .scrollable(ScrollDirection.Vertical).scrollBar(BarState.Auto)
    }.justifyContent(FlexAlign.Center).width('100%').height('100%')
      .padding({ top: this.topVp() }).safeAreaPadding({ bottom: 12 }).backgroundColor(this.palette().bg)
      .onAreaChange((_old: Area, next: Area): void => {
        const width = Number(next.width), height = Number(next.height);
        if (Number.isFinite(width) && width > 0 && Math.abs(width - this.pageWidth) > 0.5) { this.pageWidth = width; }
        if (Number.isFinite(height) && height > 0 && Math.abs(height - this.pageHeight) > 0.5) { this.pageHeight = height; }
      })
      .bindSheet($$this.showSessionPicker, this.sessionPickerSheet(), { height: SheetSize.LARGE, showClose: false, dragBar: false,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY, backgroundColor: this.palette().bg, blurStyle: BlurStyle.NONE })
      .bindSheet($$this.showDetails, this.detailsSheet(), { height: SheetSize.LARGE, showClose: false, dragBar: false,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY, backgroundColor: this.pal().sheetBg, blurStyle: BlurStyle.NONE })
      .bindSheet($$this.showApproval, this.approvalSheet(), { height: SheetSize.LARGE, showClose: false, dragBar: false,
        preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
        keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY, backgroundColor: this.pal().sheetBg, blurStyle: BlurStyle.NONE })
  }
}
