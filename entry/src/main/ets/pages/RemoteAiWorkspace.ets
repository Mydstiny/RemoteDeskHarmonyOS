import { SearchBarSurface } from '../common/SearchBarSurface';
import { AppUiMetrics } from '../common/AppUiMetrics';
import { AiActionButton } from '../components/ai/AiActionButton';
import { AiFormField } from '../components/ai/AiFormField';
import { aiStatusLabel, aiRequestTitle, aiApprovalDetails, aiModeLabel, aiModeDetail, aiOperationSummary, aiShortTime, aiRelativeTime, aiEffortLabel, aiTokens, aiElapsed } from '../services/ai/AiPresentation';
import { aiParams } from '../services/ai/AiWirePolicy';
import { KeyboardAvoidMode, curves, router, promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common, ApplicationStateChangeCallback } from '@kit.AbilityKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { util } from '@kit.ArkTS';
import { AppConfig, Palette, buildDark, buildLight } from '../common/Theme';
import { AppSheetHeader } from '../components/AppSheetHeader';
import { AiAccess, AiAccountLease } from '../services/ai/AiAccess';
import { AiHostService } from '../services/ai/AiHostService';
import { AiHost, AiProject, AiSession, AiTranscriptItem, AiApproval, AiPendingOperation, aiAgentEvents, aiBackendName } from '../services/ai/AiModels';
import { AiEngineCommand, AiWorkspaceController } from '../services/ai/AiWorkspaceController';
import { AiLocalStore } from '../services/ai/AiLocalStore';
import { aiArray, aiRecord, aiString, aiErrorText } from '../services/ai/AiWirePolicy';
import { AiStylePalette, aiStylePalette } from '../services/ai/AiStylePalette';
import { AiStepEntry, aiLastEntryRunning, aiStepEntries, aiStepSummary, aiStepGroupIcon } from '../services/ai/AiTimeline';
import { AiDiffFile, AiToolView, aiConversationItem, aiDiffFiles, aiDiffSignature, aiDiffStats, aiItemDiff, aiStepState, aiToolView } from '../services/ai/AiTimeline';
import { AiRemoteMarkdown } from '../components/ai/AiRemoteMarkdown';
import { AiDiffView } from '../components/ai/AiDiffView';
import { AiShimmerText } from '../components/ai/AiShimmerText';
import { AiThinkingIndicator } from '../components/diagnosticAi/AiMotionViews';
import { AiStreamText, AiTypewriter } from '../components/ai/AiTypewriter';
import { WorkspaceStore } from '../services/pro/workspace/WorkspaceStore';
import { Workspace, WORKSPACE_COLORS, newWorkspace, newWorkspaceEntry } from '../services/pro/workspace/WorkspacePolicy';
import { aiPairRef } from '../services/ai/AiWorkspacePairPolicy';

interface AiWsButton { label: string; primary: boolean; enabled: boolean; action: () => void; }
interface AiWsIconButton { symbol: Resource; label: string; enabled: boolean; action: () => void; }
interface AiWsTab { label: string; selected: boolean; enabled: boolean; action: () => void; }
interface AiHomeRow { key: string; session: AiSession | null; project: string; title: string; count: number; more: number; }
/** A / command: the app's own (it acts here) or the engine's (it is sent for the engine to expand). */
interface AiWsCommand { name: string; description: string; local: boolean; }
/** A box in window coordinates (vp). */
interface AiWsRect { x: number; y: number; w: number; h: number; }
/** Where a sent message lands: this far below the top of the conversation (about 2 cm from the top of the screen). */
interface AiWsSheetHead { title: string; close: () => void; }
interface AiWsChoice { label: string; detail: string; selected: boolean; enabled: boolean; action: () => void; }
interface AiWsModes { values: string[]; selected: string; choose: (value: string) => void; }
interface AiWsChip { label: string; enabled: boolean; action: () => void; }
interface AiWsRoundAction { symbol: Resource; label: string; primary: boolean; enabled: boolean; action: () => void; hold?: () => void; }
interface AiQuestionValue { id: string; title: string; options: string[]; descriptions: string[]; multiple: boolean; selected: string[]; text: string; }
/** What the page asks of a conversation view: back, its page hooks, and what it shows. */
class AiViewHandle {
  back: () => boolean = (): boolean => false;
  pageShow: () => void = (): void => {};
  pageHide: () => void = (): void => {};
  hostId: () => string = (): string => '';
  sessionId: () => string = (): string => '';
  title: () => string = (): string => '';
}

/**
 * One remote AI host's conversations. On a phone, and in each half of two conversations side by side, the list and
 * then a conversation; on a Pad or PC the list on the left and the open conversation on the right (1:2).
 */
@Component
export struct RemoteAiWorkspace {
  /** The AI host to open ('' reads the page's route), a conversation to open at once, and the layout. */
  hostId: string = '';
  initialSession: string = '';
  /** 'auto': list and conversation side by side on a wide Pad or PC; 'pane': a half of two conversations. */
  layout: string = 'auto';
  handle: AiViewHandle = new AiViewHandle();
  /** Leaves the view (in a pane: closes it); opens another AI beside this one; keeps two panes as a workspace. */
  onExit: () => void = (): void => {};
  onSplit: (hostId: string) => void = (_hostId: string): void => {};
  onSaveCombo: () => void = (): void => {};
  @StorageProp('isPadDevice') isPadDevice: boolean = false;
  @StorageProp('isDesktopDevice') isDesktopDevice: boolean = false;
  @State sideRefreshing: boolean = false;
  private sideScrollerValue: Scroller | null = null;
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
  /** The + and permission menus, shown once the keyboard is down (see afterKeyboard). */
  @State plusMenuShown: boolean = false;
  @State permissionMenuShown: boolean = false;
  /** A composer menu is opening or open: the composer stays expanded so the menu keeps its anchor. */
  @State composerHold: boolean = false;
  /** Opening or leaving a conversation slides the view in from the side it comes from. */
  @State viewShift: number = 0;
  @State viewOpacity: number = 1;
  /** The slide the next change of conversation plays: 1 opening, -1 back to the list, 0 none (reconnects, resumes). */
  private slideNext: number = 0;
  /** Another app on the computer holds this conversation open (see AiWorkspaceController.openIn). */
  @State openIn: string = '';
  /**
   * Rows at or past this index arrived since the last update and may animate in; rows before it were already shown
   * (a streamed reply re-keys its row, a finished reply or a re-read conversation renames rows: none of those animate).
   */
  private entryBase: number = 0;
  private entryCount: number = 0;
  private seenSnapshot: number = 0;
  @State searching: boolean = false;
  @State query: string = '';
  @State showAddSheet: boolean = false;
  @State showModelList: boolean = false;
  @State showEffortList: boolean = false;
  @State showPermissionList: boolean = false;
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
  /** Free room at the list's end for what floats over its foot (the composer, its chips, an approval card). */
  @State listEndRoom: number = 0;
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
    // An approval card comes and goes with its own motion, and the conversation makes room for it smoothly.
    const approvals = c.approvals.slice();
    if (approvals.length !== this.approvals.length && this.alive) {
      this.getUIContext().animateTo({ curve: curves.springMotion(0.4, 0.86) }, (): void => { this.approvals = approvals; });
    } else { this.approvals = approvals; }
    this.operations = c.operations.slice(); this.terminals = c.terminals.slice();
    this.models = c.models.slice(); this.allowed = c.allowed; this.archived = c.archived;
    const sessionChanged = c.sessionId !== this.sessionId;
    if (sessionChanged && this.slideNext !== 0 && (c.sessionId !== '') === (this.slideNext > 0)) {
      this.slideView(this.slideNext > 0); this.slideNext = 0;
    }
    const reread = sessionChanged || c.snapshotCount !== this.seenSnapshot;
    this.seenSnapshot = c.snapshotCount; this.openIn = c.openIn;
    this.sessionId = c.sessionId; this.projectId = c.projectId; this.historyCursor = c.historyCursor;
    this.control = c.lease !== '' && c.leaseExpires > Date.now(); this.diff = c.diff;
    this.role = c.client?.handshake?.role ?? '';
    this.permissionModes = c.client?.choices('permissionModes') ?? [];
    this.collaborationModes = c.client?.choices('collaborationModes') ?? [];
    if (this.listFilter !== '' && !this.projects.some((project: AiProject): boolean => project.id === this.listFilter)) { this.listFilter = ''; }
    // Only a conversation follows its newest message; the list keeps where the reader is (a pull to refresh jumped
    // to the bottom when the list followed too).
    // A send belongs to its conversation; the engine's own copy of the message replaces the one shown at once.
    if (this.sendSession !== '' && this.sessionId !== this.sendSession) { this.endSend(); }
    if (this.pendingSend !== null && this.userCount(this.items, this.pendingSend.text) > this.pendingBefore) { this.pendingSend = null; }
    // Only rows that arrived with this update animate in; a conversation opened or read again appears as it is.
    this.entryBase = reread ? Number.MAX_SAFE_INTEGER : this.entryCount;
    this.entryCount = this.sessionId === '' ? 0 : this.stepEntries().length;
    if (this.sessionId !== '') { this.feedStreams(); }
    if (this.sessionId !== '') { this.followTranscript(reread); }
    this.trackWorking();
    if (this.approval !== null && !this.approvals.some((item: AiApproval): boolean => item.id === this.approval?.id)) {
      this.showApproval = false; this.approval = null; this.questions = [];
    }
  }
  async aboutToAppear(): Promise<void> {
    const mount = ++this.mountGeneration;
    this.alive = true; this.controller.onChange = (): void => this.sync();
    this.handle.back = (): boolean => this.onBackPress();
    this.handle.pageShow = (): void => { this.onPageShow(); };
    this.handle.pageHide = (): void => { this.onPageHide(); };
    this.handle.hostId = (): string => this.host?.id ?? this.hostId;
    this.handle.sessionId = (): string => this.sessionId;
    this.handle.title = (): string => this.sessionId !== '' ? this.title : (this.host?.label ?? '远程 AI');
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
        this.inBackground = true;
        if (this.controller.client !== null) {
          // Paused, not closed: the conversation, its approvals and the draft stay as they are, and nothing is
          // released on the computer (closing here dropped control, so the computer cancelled open approvals, and
          // the conversation was read again from nothing on return).
          this.controller.pause(); this.controller.status = '已暂停连接'; this.sync();
        } else {
          this.resumeSession = this.controller.sessionId; this.resumeProject = this.controller.projectId;
          this.resumeAccount = null; this.controller.close(); this.controller.status = '已暂停连接'; this.sync();
        }
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
    this.host = AiHostService.getInstance().find(this.hostId !== '' ? this.hostId : (params['hostId'] ?? ''));
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
    // A workspace pair (or a link) names the conversation to open.
    if (this.initialSession !== '' && this.alive && mount === this.mountGeneration && this.sessionId === '') {
      this.sync(); await this.chooseSession(this.initialSession);
    }
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
    // A paused connection (the app was in the background) resumes in place: the conversation stays on screen and is
    // replaced only once it has been read again.
    if (this.controller.paused && !this.inBackground) {
      this.controller.status = '正在恢复连接…'; this.sync();
      try {
        if (await this.controller.resume()) { this.sync(); return; }
      } catch (_error) { /* the connection did not come back: connect again below */ }
    }
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
      if (this.alive && mount === this.mountGeneration) { if (this.layout === 'pane') { this.onExit(); } else { router.back(); } }
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
    this.resetView(); this.followBottom = false; this.showModelPicker = false; this.slideNext = -1;
    await this.run(async (): Promise<void> => { this.resetDrafts(); await this.controller.closeSession(); });
    try { this.listScroller?.scrollEdge(Edge.Top); } catch (_error) { /* not laid out */ }
  }
  /**
   * Opening a conversation slides it in from the right and going back slides the list in from the left (the
   * apps' push and pop). A message sent from the home composer flies into its new conversation instead.
   */
  private slideView(forward: boolean): void {
    if (!this.alive || (forward && this.flyText !== '')) { return; }
    this.viewShift = forward ? Math.min(96, this.pageWidth * 0.25) : -Math.min(64, this.pageWidth * 0.16);
    this.viewOpacity = 0;
    setTimeout((): void => {
      if (!this.alive) { return; }
      this.getUIContext().animateTo({ curve: curves.springMotion(0.42, 0.9) }, (): void => {
        this.viewShift = 0; this.viewOpacity = 1;
      });
    }, 0);
  }
  /** Fades and lifts a row in (made on first use: the page fields are plain values). */
  private enterEffect(): TransitionEffect {
    if (this.enterEffectValue === null) {
      // In only: a row that goes is gone at once (fading it out while its replacement faded in showed both).
      this.enterEffectValue = TransitionEffect.asymmetric(
        TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 14 })).animation({ duration: 280, curve: Curve.FastOutSlowIn }),
        TransitionEffect.IDENTITY);
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
    if (text === '' || !this.allowed || !AiAccess.getInstance().proVisible()) { return; }
    const command = this.localCommandFor(text);
    if (command !== null) { this.runCommand(command); return; }
    if (project === '' || this.busy || !this.alive || this.inBackground) { return; }
    this.resetView();
    const settings = this.settings(), attachments = this.attachments.slice();
    // The message leaves the composer now; it lands in the new conversation as soon as that opens.
    this.beginSend(text); this.pendingBefore = 0;
    await this.run(async (): Promise<void> => {
      try {
        const title = text.split('\n')[0].slice(0, 40);
        await this.controller.create(title, project);
        this.sendSession = this.controller.sessionId;
        const params: Record<string, Object> = aiParams(["text"], [text]);
        params['settings'] = settings;
        if (attachments.length > 0) { params['attachments'] = attachments; }
        const sentAt = this.controller.transcript.mark();
        const result = await this.controller.action('turn.start', params);
        if (this.host !== null && aiAgentEvents(this.host.backend)) { this.controller.transcript.echo(text, aiString(result['turnId']), sentAt); }
        this.attachments = [];
      } catch (error) { this.failSend(text); throw new Error((error as Error).message); }
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
    const command = this.localCommandFor(text);
    if (command !== null) { this.runCommand(command); return; }
    if (this.busy || !this.alive || this.inBackground) { return; }
    const params: Record<string, Object> = aiParams(["text"], [text]);
    if (!steer) {
      params['settings'] = this.settings();
      if (this.attachments.length > 0) { params['attachments'] = this.attachments.slice(); }
    }
    // Taken before sending: the engine's own copy of the prompt may arrive before the acknowledgement.
    const sentAt = this.controller.transcript.mark();
    // The message leaves the composer at once (every engine) and flies into its place at the foot of the conversation.
    this.beginSend(text);
    await this.run(async (): Promise<void> => {
      try {
        let result: Record<string, Object>;
        try {
          result = await this.controller.action(steer ? 'turn.steer' : 'turn.start', params);
        } catch (error) {
          // The turn ended just as the guidance went out: send it as a new turn instead.
          if (!steer || !(error as Error).message.includes('NO_ACTIVE_TURN')) { throw new Error((error as Error).message); }
          params['settings'] = this.settings();
          if (this.attachments.length > 0) { params['attachments'] = this.attachments.slice(); }
          result = await this.controller.action('turn.start', params);
        }
        // Pi echoes the prompt only once its turn takes it; show it until its own event arrives.
        if (this.host !== null && aiAgentEvents(this.host.backend)) { this.controller.transcript.echo(text, aiString(result['turnId']), sentAt); }
        this.attachments = []; this.controller.openIn = '';
      } catch (error) {
        this.failSend(text);
        if ((error as Error).message.includes('PI_SESSION_OPEN_IN_APP')) { this.controller.openIn = 'pi-gui'; }
        throw new Error((error as Error).message);
      }
    });
  }
  /** Stops the running turn, waits for the computer to report it ended, then sends what is typed as a new turn. */
  private async interruptAndSend(): Promise<void> {
    if (this.draft.trim() === '' || !this.operator() || this.busy || !this.capability('cancel')) { return; }
    try { promptAction.showToast({ message: '正在打断当前任务，随后发送', duration: 1500 }); } catch (_error) { /* no toast */ }
    await this.run(async (): Promise<void> => { await this.controller.action('turn.cancel'); });
    const until = Date.now() + 6000;
    while (this.alive && this.working() && Date.now() < until) {
      await new Promise<void>((resolve): void => { setTimeout(resolve, 150); });
    }
    if (!this.alive || this.draft.trim() === '') { return; }
    await this.send(false);
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
  /**
   * A message just sent, shown at once for every engine until the engine's own copy of it is in the transcript
   * (how many user messages had its text when it was sent tells the two apart).
   */
  @State pendingSend: AiTranscriptItem | null = null;
  private pendingBefore: number = 0;
  private sendCount: number = 0;
  /**
   * Sending, as in Messages: the composer turns into the bubble where it stands (its own width, height and pill
   * shape), shrinks to the bubble's size with its right edge fixed (a one-line message narrows from the full input
   * width; a longer one keeps its width and mostly changes height), then rises with a spring into its place at the
   * foot of the conversation while the rows above slide up to make room. The bubble in the list stays hidden until
   * the flyer lands on it. Replies, like messages, sit at the foot of the conversation above the composer.
   */
  private sendSession: string = '';
  @State flyText: string = '';
  @State flyX: number = 0;
  @State flyY: number = 0;
  @State flyW: number = 0;
  @State flyH: number = 0;
  @State flyRadius: number = 20;
  /** The text's own width inside the flyer, fixed for the flight so it never re-wraps while the bubble narrows. */
  @State flyTextW: number = 0;
  /** As many lines as the bubble in the list has, so a rounding error can never add a line under the first. */
  @State flyLines: number = 1;
  /** The rows above lift by the new bubble's height as it rises (they jumped at once before). */
  @State listLift: number = 0;
  private flyGeneration: number = 0;
  private rootX: number = 0;
  private rootY: number = 0;
  private shownFor: AiTranscriptItem[] | null = null;
  private shownPending: AiTranscriptItem | null = null;
  private shownValue: AiTranscriptItem[] = [];
  private followBottom: boolean = true;
  private scroller(): Scroller {
    if (this.listScroller === null) { this.listScroller = new Scroller(); }
    return this.listScroller;
  }
  /** The transcript rows the current style and tab show (the Codex diff tab shows its own pane instead). */
  /** The transcript as shown: the visible items, then a message just sent until the engine's copy of it arrives. */
  private shownItems(): AiTranscriptItem[] {
    const items = this.visibleItems(), pending = this.pendingSend;
    if (this.shownFor === items && this.shownPending === pending) { return this.shownValue; }
    this.shownFor = items; this.shownPending = pending;
    this.shownValue = pending !== null && this.userCount(items, pending.text) <= this.pendingBefore ? items.concat([pending]) : items;
    return this.shownValue;
  }
  private userCount(items: AiTranscriptItem[], text: string): number {
    return items.filter((item: AiTranscriptItem): boolean => item.role === 'user' && item.text.trim() === text).length;
  }
  /** The height the conversation list gets between the header and the composer. */
  private transcriptHeight(): number {
    return Math.max(180, this.pageHeight - this.topVp() - this.topChrome - this.bottomChrome - 16);
  }
  /** Ids that tell this page's composer, root and flying bubble apart from another pane's. */
  private readonly uid: string = Math.random().toString(36).slice(2, 10);
  private flyId(part: string): string { return 'aiws-' + part + '-' + this.uid; }
  /**
   * A node's box in window coordinates (vp), read now from the layout: the bubble's place changes as the list scrolls
   * to its end, so the flight reads it again every frame instead of trusting a first measurement.
   */
  private boxOf(id: string): AiWsRect | null {
    try {
      const ui = this.getUIContext();
      const info = ui.getComponentUtils().getRectangleById(id);
      const rect: AiWsRect = { x: ui.px2vp(info.windowOffset.x), y: ui.px2vp(info.windowOffset.y),
        w: ui.px2vp(info.size.width), h: ui.px2vp(info.size.height) };
      return [rect.x, rect.y, rect.w, rect.h].every((value: number): boolean => Number.isFinite(value)) && rect.w > 0 && rect.h > 0 ?
        rect : null;
    } catch (_error) { return null; }
  }
  /**
   * The same boxes as the layout reports them (onAreaChange), for when the window query is not available: one
   * flight reads all its boxes from one source, so start, target and page always share coordinates.
   */
  private areaBoxes: Map<string, AiWsRect> = new Map();
  private flyMode: string = 'window';
  private noteBox(part: string, area: Area): void {
    const x = Number(area.globalPosition.x), y = Number(area.globalPosition.y), w = Number(area.width), h = Number(area.height);
    if ([x, y, w, h].every((value: number): boolean => Number.isFinite(value)) && w > 0 && h > 0) {
      this.areaBoxes.set(part, { x, y, w, h });
    }
  }
  private box(part: string): AiWsRect | null {
    if (this.flyMode !== 'window') { return this.areaBoxes.get(part) ?? null; }
    return this.boxOf(part === 'target' ? this.flyTargetId() : this.flyId(part));
  }
  /** The id of the bubble this flight goes to (a new one each flight). */
  private flyTargetId(): string { return this.flyId('target-' + this.flyGeneration.toString()); }
  /** Starts a send: the message joins the foot of the conversation, and the composer flies into it. */
  private beginSend(text: string): void {
    this.sendSession = this.sessionId;
    this.pendingBefore = this.userCount(this.items, text);
    this.pendingSend = { id: 'send:' + (++this.sendCount).toString(), role: 'user', title: 'user', text, state: 'completed',
      turnId: '', kind: 'user', detail: '', output: '' };
    this.areaBoxes.delete('target');
    this.flyMode = this.boxOf(this.flyId('composer')) !== null && this.boxOf(this.flyId('root')) !== null ? 'window' : 'area';
    const from = this.box('composer'), root = this.box('root');
    hilog.info(0x0000, 'RemoteAiFly', 'send mode=%{public}s from=%{public}s root=%{public}s', this.flyMode,
      String(from !== null), String(root !== null));
    this.draft = ''; this.followBottom = true;
    const generation = ++this.flyGeneration;
    if (from !== null && root !== null) {
      // The flyer covers the composer exactly: the input has become the bubble, still where it was.
      this.rootX = root.x; this.rootY = root.y;
      this.flyText = text.trim();
      this.flyX = from.x - root.x; this.flyY = from.y - root.y; this.flyW = from.w; this.flyH = from.h;
      this.flyRadius = Math.min(from.h / 2, 22); this.flyTextW = Math.max(40, from.w - 28); this.flyLines = 99;
      // The rows above make room for the bubble as it rises rather than jumping when it is added.
      this.listLift = Math.max(40, from.h) + 18;
    } else {
      this.flyText = '';
    }
    this.followTranscript(true);
    if (from !== null && root !== null) { this.flyTick(generation, from, Date.now(), 0, null); }
  }
  /**
   * One frame of a flight. Waits for the bubble in the list to be laid out, takes its size beside the composer
   * (right edges and bottoms together), then rises with a spring; while the list settles at its end the bubble's
   * place is read again each frame and the flyer is steered to it. It lands once it has been on target for a while.
   */
  private flyTick(generation: number, from: AiWsRect, started: number, phase: number, aim: AiWsRect | null): void {
    if (!this.alive || generation !== this.flyGeneration) { return; }
    const target = this.box('target');
    const now = Date.now();
    const next = (nextPhase: number, nextAim: AiWsRect | null): void => {
      setTimeout((): void => { this.flyTick(generation, from, started, nextPhase, nextAim); }, 16);
    };
    if (target === null) {
      // Not laid out yet (a new conversation is still opening): wait a little, then let the row simply appear.
      if (now - started > 900) {
        hilog.info(0x0000, 'RemoteAiFly', 'no target mode=%{public}s', this.flyMode);
        this.endFlight(generation);
      } else { next(phase, aim); }
      return;
    }
    const ui = this.getUIContext();
    const tx = target.x - this.rootX, ty = target.y - this.rootY;
    if (phase === 0) {
      // Beside the composer as it is now (it can have moved since the send).
      const base = this.box('composer') ?? from;
      this.flyLines = Math.max(1, Math.round((target.h - 20) / Math.round(this.textSize * 1.5)));
      hilog.info(0x0000, 'RemoteAiFly', 'aim composerY=%{public}d targetY=%{public}d targetH=%{public}d',
        Math.round(base.y), Math.round(target.y), Math.round(target.h));
      // The bubble's own text width, plus a few vp of slack: measured to the last fraction, the same text wrapped its
      // last character onto a second line that drew over the first. Left aligned, the slack falls in the padding.
      this.flyTextW = Math.max(20, target.w - 28 + 6);
      ui.animateTo({ duration: 170, curve: Curve.FastOutSlowIn }, (): void => {
        this.flyW = target.w; this.flyH = target.h; this.flyX = tx;
        this.flyY = base.y - this.rootY + base.h - target.h; this.flyRadius = 18;
      });
      setTimeout((): void => { this.flyTick(generation, from, now, 1, null); }, 130);
      return;
    }
    // Steered only while the list settles at its end (a moment after the rise begins). Later moves are the
    // conversation going on underneath (a reply still streaming pushes the new message up): the flyer does not chase
    // them across the screen, it lands and the list carries the bubble from there.
    const settling = now - started < 450;
    if (aim === null || (settling && (Math.abs(aim.y - target.y) > 1.5 || Math.abs(aim.x - target.x) > 1.5 ||
      Math.abs(aim.h - target.h) > 1.5))) {
      // Rise (or steer) to where the bubble is now, the rows above sliding up with it.
      ui.animateTo({ curve: curves.springMotion(0.42, 0.82) }, (): void => {
        this.flyY = ty; this.flyX = tx; this.flyW = target.w; this.flyH = target.h; this.listLift = 0;
      });
      next(2, target);
      // Remember when it was last steered: it lands once the target has held still long enough for the spring.
      this.flySteered = now;
      return;
    }
    if (now - this.flySteered > 420 || now - started > 900) {
      hilog.info(0x0000, 'RemoteAiFly', 'landed mode=%{public}s after=%{public}d', this.flyMode, now - started);
      if (aim !== null && (Math.abs(aim.y - target.y) > 3 || Math.abs(aim.x - target.x) > 3)) {
        // The bubble moved a little since: meet it there before handing over, rather than jump.
        ui.animateTo({ duration: 160, curve: Curve.FastOutSlowIn }, (): void => { this.flyY = ty; this.flyX = tx; });
        setTimeout((): void => { this.endFlight(generation); }, 170);
        return;
      }
      this.endFlight(generation); return;
    }
    next(2, aim);
  }
  private flySteered: number = 0;
  /** The flyer has landed (or could not): the bubble in the list shows in its place. */
  private endFlight(generation: number): void {
    if (generation !== this.flyGeneration) { return; }
    this.listLift = 0; this.flyText = '';
  }
  /** The row that the flyer is on its way to (the newest user message with its text), hidden until it lands. */
  private flyingRow(item: AiTranscriptItem): boolean {
    if (this.flyText === '' || item.role !== 'user' || item.text.trim() !== this.flyText) { return false; }
    const items = this.shownItems();
    for (let i = items.length - 1; i >= 0; i--) {
      if (items[i].role === 'user') { return items[i] === item || items[i].id === item.id; }
    }
    return false;
  }
  /** A send that failed: the bubble goes and the text is back in the composer. */
  private failSend(text: string): void {
    this.endSend();
    if (this.draft === '') { this.draft = text; }
    this.followBottom = true; this.followTranscript();
  }
  private endSend(): void {
    this.flyGeneration++; this.flyText = ''; this.listLift = 0;
    this.pendingSend = null; this.sendSession = '';
  }
  /** The transition of a row appearing: the sent message has its own flight; other new rows fade up once. */
  private entryEffect(entry: AiStepEntry, index: number): TransitionEffect {
    if (index < this.entryBase || !this.fresh('t:' + entry.key)) { return TransitionEffect.IDENTITY; }
    const item = entry.item;
    if (item !== null && item.role === 'user' && (this.flyText !== '' || item.id.startsWith('send:'))) {
      return TransitionEffect.IDENTITY;
    }
    return this.enterEffect();
  }
  /** The app's own / commands that make sense here. */
  private localCommands(): AiWsCommand[] {
    const rows: AiWsCommand[] = [];
    if (this.sessionId !== '' && this.capability('compact') && this.operator()) {
      rows.push({ name: '/compact', description: '压缩上下文', local: true });
    }
    if (this.models.length > 0) { rows.push({ name: '/model', description: '选择模型与思考强度', local: true }); }
    if (this.sessionId !== '' && this.working() && this.capability('cancel') && this.operator()) {
      rows.push({ name: '/stop', description: '停止这一轮', local: true });
    }
    if (this.sessionId !== '' && this.capability('diffs')) { rows.push({ name: '/diff', description: '查看改动', local: true }); }
    if (this.sessionId !== '') { rows.push({ name: '/new', description: '回到对话列表，开始新对话', local: true }); }
    rows.push({ name: '/reconnect', description: '重新连接电脑', local: true });
    return rows;
  }
  /** While the composer holds just "/…": the app's and the engine's commands that start with it. */
  private slashSuggestions(): AiWsCommand[] {
    const draft = this.draft;
    if (!draft.startsWith('/') || /\s/.test(draft) || !this.allowed) { return []; }
    const query = draft.toLowerCase();
    const engine = this.controller.commands.map((command: AiEngineCommand): AiWsCommand => ({ name: command.name,
      description: command.description + (command.hint !== '' ? ' · ' + command.hint : ''), local: false }));
    return this.localCommands().concat(engine)
      .filter((command: AiWsCommand): boolean => command.name.toLowerCase().startsWith(query)).slice(0, 8);
  }
  /** An engine command goes into the composer (with a space for its arguments); the app's own act at once. */
  private runCommand(command: AiWsCommand): void {
    if (!command.local) { this.draft = command.name + ' '; return; }
    this.draft = '';
    if (command.name === '/compact') {
      void this.run(async (): Promise<void> => { await this.controller.action('session.compact'); });
    } else if (command.name === '/model') {
      this.showModelPicker = true;
    } else if (command.name === '/stop') {
      void this.run(async (): Promise<void> => { await this.controller.action('turn.cancel'); });
    } else if (command.name === '/diff') {
      this.detailTab = 1; this.showDetails = true;
      void this.run(async (): Promise<void> => { await this.controller.loadDiff(); });
    } else if (command.name === '/new') {
      void this.backToList();
    } else if (command.name === '/reconnect') {
      void this.reconnect();
    }
  }
  /** Sending exactly one of the app's own commands runs it instead of sending it as text. */
  private localCommandFor(text: string): AiWsCommand | null {
    return this.localCommands().find((command: AiWsCommand): boolean => command.name === text) ?? null;
  }
  /**
   * The text of each reply still streaming in, which its typewriter reads: the page sets it on every update, and the
   * row (keyed by the reply alone while it streams) is not made again for each batch of words.
   */
  private streamTexts: Map<string, AiStreamText> = new Map();
  private streamSource(item: AiTranscriptItem): AiStreamText {
    let source = this.streamTexts.get(item.id);
    if (source === undefined) {
      source = new AiStreamText(item.text);
      if (this.streamTexts.size > 32) { this.streamTexts.clear(); }
      this.streamTexts.set(item.id, source);
    } else if (source.text !== item.text) {
      source.text = item.text;
    }
    return source;
  }
  private streaming(item: AiTranscriptItem): boolean {
    return item.role === 'assistant' && aiStepState(item.state) === 'running';
  }
  /** Feeds every streaming reply's typewriter with the newest text. */
  private feedStreams(): void {
    for (const item of this.shownItems()) {
      if (this.streaming(item)) { this.streamSource(item); }
    }
  }
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
      // A reply streaming in keeps its row: its typewriter follows the text (see streamSource).
      if (this.streaming(item)) { return item.id + ':stream'; }
      // Opening a row does not change its key: it opens in place, animated, instead of being made again.
      return item.id + ':' + item.state + ':' + item.text.length.toString() + ':' + (item.output ?? '').length.toString();
    }
    let signature = '';
    entry.steps.forEach((step: AiTranscriptItem): void => {
      signature += step.state.slice(0, 2) + (step.text.length + (step.output ?? '').length).toString() + ',';
    });
    return entry.key + ':' + entry.steps.length.toString() + ':' + signature;
  }
  /** The working line shows while a turn runs, unless the newest row already shows it at work. */
  private showWorkingRow(): boolean { return this.working() && !aiLastEntryRunning(this.stepEntries()); }
  /** Rows in the list, the same way build() lays them out, so following knows where the bottom is. */
  private listLength(): number {
    if (this.sessionId === '') { return this.wide() ? 1 : 1 + this.homeRows().length; }
    let count = (this.historyCursor !== '' ? 1 : 0) + (this.shownItems().length === 0 ? 1 : 0);
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
  /**
   * Keeps the newest row in view. `settle` (a conversation opened or read again) pins the end a few times while the
   * rows are measured; a streamed update scrolls once, so the reader's own scrolling is not fought.
   */
  private followTranscript(settle: boolean = false): void {
    const scroller = this.listScroller;
    if (scroller === null || !this.followBottom) { return; }
    // One scroll on the next frame landed above the end when a session opened: the rows below were not measured yet
    // and the first layout from the top reported "not at the bottom". Pin it while the layout settles.
    if (settle) { this.pinBottomUntil = Date.now() + 700; }
    for (const delay of (settle ? [0, 120, 360, 700] : [0])) {
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
  /** Opens or closes a row in place: its detail unfolds and the rows below slide, as in the apps. */
  private toggleExpanded(id: string): void {
    const next = this.expanded(id) ? this.expandedIds.filter((value: string): boolean => value !== id) :
      this.expandedIds.concat([id]);
    this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, (): void => { this.expandedIds = next; });
  }
  /** How an opened row's detail appears: it unfolds down from its line; closing just fades. */
  private unfoldEffect(): TransitionEffect {
    if (this.unfoldEffectValue === null) {
      this.unfoldEffectValue = TransitionEffect.asymmetric(
        TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: -6 })).animation({ duration: 240, curve: Curve.FastOutSlowIn }),
        TransitionEffect.OPACITY.animation({ duration: 150 }));
    }
    return this.unfoldEffectValue;
  }
  private unfoldEffectValue: TransitionEffect | null = null;

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
      }.width('100%').align(Alignment.Top)
      // Sized to its content (FIT_CONTENT); a long model list scrolls within most of the window.
      .constraintSize({ maxHeight: Math.max(240, this.pageHeight * 0.78) })
    }.width('100%').safeAreaPadding({ bottom: 16 }).backgroundColor(this.pal().surface)
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
    this.resetView(); this.slideNext = 1;
    await this.run(async (): Promise<void> => { this.resetDrafts(); await this.controller.openSession(id); });
  }
  private async newSession(projectId: string): Promise<void> {
    if (!this.allowed || !AiAccess.getInstance().proVisible() || projectId === '') { return; }
    this.resetView(); this.slideNext = 1;
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
      // How long the turn has run sits here rather than on a line of its own that came and went with each turn
      // (and moved the conversation under it each time).
      if (this.working() && this.workingSince > 0) {
        return this.projectTitle(this.projectId) + ' · 已运行 ' + aiElapsed(this.nowTick - this.workingSince);
      }
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
  /** A Pad or PC window wide enough for the list beside the conversation (not a half of two conversations). */
  private wide(): boolean { return this.layout === 'auto' && (this.isPadDevice || this.isDesktopDevice) && this.pageWidth >= 600; }
  /** Every AI host of this account, this one included: the same host can sit beside itself (two conversations). */
  private otherHosts(): AiHost[] { return AiHostService.getInstance().list().slice(0, 8); }
  private sideScroller(): Scroller {
    if (this.sideScrollerValue === null) { this.sideScrollerValue = new Scroller(); }
    return this.sideScrollerValue;
  }
  private async refreshSide(): Promise<void> {
    try { await this.run(async (): Promise<void> => { await this.controller.refreshSessions(); }); }
    finally { this.sideRefreshing = false; }
  }
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
    // Pad and PC: a second AI conversation beside this one (1:1); two panes can be kept as a workspace pair.
    if (this.layout === 'auto' && this.wide()) {
      this.otherHosts().forEach((host: AiHost): void => {
        items.push({ value: '分屏打开「' + host.label + '」', action: (): void => { this.onSplit(host.id); } });
      });
    }
    if (this.layout === 'pane') {
      items.push({ value: '保存为工作区组合', action: (): void => { this.onSaveCombo(); } });
      items.push({ value: '关闭这一侧', action: (): void => { void this.leave(); } });
    }
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
    if (this.sessionId === '' && this.wide()) {
      // The list (with back and search) is on the left; here only what to start and the ⋯ menu.
      Row() {
        Text('新对话').fontSize(17).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text)
          .layoutWeight(1)
        Stack() { this.moreButton() }.borderRadius(22).backgroundColor(this.palette().raised)
          .border({ width: 0.5, color: this.palette().border })
      }.width('100%').padding({ left: 16, right: 12, top: 6, bottom: 6 })
    } else if (this.sessionId === '') {
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
            (step: AiTranscriptItem): string => step.id + ':' + step.state + ':' + step.text.length.toString())
        }.width('100%').padding({ left: 10 }).border({ width: { left: 1 }, color: this.palette().border })
        .transition(this.unfoldEffect())
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
      .attributeModifier(new SearchBarSurface<RowAttribute>(this.theme !== 'light', { background: this.palette().surface }))
      .margin({ bottom: 4 })
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
    // On a Pad or PC the open conversation stays marked in the list beside it.
    .stateStyles({ normal: { .backgroundColor(this.wide() && session.id === this.sessionId ? this.palette().surface : Color.Transparent) },
      pressed: { .backgroundColor(this.palette().surface) } })
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
      if (this.expanded(item.id)) { Column() { this.toolDetail(item) }.width('100%').transition(this.unfoldEffect()) }
    }.width('100%')
  }
  @Builder private thinkingRow(item: AiTranscriptItem) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        if (aiStepState(item.state) === 'running') {
          // 正在思考 with a band of light flowing across it while the model reasons (the apps' shimmer).
          AiShimmerText({ text: '正在思考', fontSize: this.textSize, baseColor: this.palette().text3,
            highlight: this.palette().text })
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
          .transition(this.unfoldEffect())
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
        // The message being sent stays hidden until the flyer lands on it; its box is where the flyer goes.
        .opacity(this.flyingRow(item) ? 0 : 1)
        // Every bubble has an id of its own, and the one being flown to an id of this flight: an id set to '' keeps
        // the old one, so the previous message still answered to the target id and the next flight went to it.
        .id(this.flyingRow(item) ? this.flyTargetId() : this.flyId('bubble-' + item.id))
        .onAreaChange((_old: Area, next: Area): void => { if (this.flyingRow(item)) { this.noteBox('target', next); } })
    }.width('100%')
  }
  /** The composer on its way into the conversation: the input turned bubble, over everything else. */
  @Builder private sendFlyer() {
    if (this.flyText !== '') {
      Stack({ alignContent: Alignment.TopStart }) {
        Text(this.flyText).width(this.flyTextW).fontSize(this.textSize).lineHeight(Math.round(this.textSize * 1.5))
          .fontFamily(AppConfig.fontFamily).fontColor(this.palette().text).textAlign(TextAlign.Start)
          .maxLines(this.flyLines).textOverflow({ overflow: TextOverflow.Clip })
      }.position({ x: this.flyX, y: this.flyY }).width(this.flyW).height(this.flyH)
      .padding({ left: 14, right: 14, top: 10, bottom: 10 }).borderRadius(this.flyRadius)
      .backgroundColor(this.palette().userBubble).clip(true).hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no')
    }
  }
  @Builder private claudeItem(item: AiTranscriptItem) {
    if (item.role === 'user') {
      this.userBubble(item)
    } else if (item.role === 'assistant' && this.streaming(item)) {
      AiTypewriter({ source: this.streamSource(item), textSize: this.textSize, palette: this.palette() })
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
  /** While a turn runs: Codex 正在思考 with light flowing across it; Claude a turning clay ✳ and 正在工作… (Clauding…). */
  @Builder private workingRow() {
    if (this.uiStyle === 'codex') {
      Row({ space: 6 }) {
        AiShimmerText({ text: '正在思考', fontSize: this.textSize, baseColor: this.palette().text3,
          highlight: this.palette().text })
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([this.palette().text3])
      }.padding({ top: 2, bottom: 2 })
    } else {
      Row({ space: 8 }) {
        // The app's own 极光环 (from AI 动效): a softly glowing rainbow ring, clear on light and dark pages alike.
        AiThinkingIndicator({ indicatorSize: 20, style: 'aurora', opensFromDot: false })
        AiShimmerText({ text: this.backendName() + ' 正在工作…', fontSize: this.textSize, baseColor: this.palette().accent,
          highlight: this.palette().text })
        if (this.backgroundTasks()) {
          Text('· 后台任务运行中').fontSize(this.textSize).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
        }
      }.padding({ top: 2, bottom: 2 })
    }
  }
  /** The Codex app's 已运行 13 分钟 29 秒 under the header while a turn runs. */
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
    // A long press does the button's second action (while a turn runs: stop it and send as a new turn).
    .gesture(LongPressGesture({ repeat: false, duration: 450 }).onAction((): void => {
      if (b.enabled && b.hold !== undefined) { b.hold(); }
    }))
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
    } else if (this.sessionId !== '' && this.composerMode() === 'stop') {
      // While a turn runs with something typed: stop stays at hand beside send, and send guides the running turn (the
      // engine reads it after its current step); a long press on send stops the turn and sends it as a new one.
      Row({ space: 6 }) {
        this.sendButton({ symbol: $r('sys.symbol.stop_circle_fill'), label: '停止', primary: true,
          enabled: this.capability('cancel') && !this.busy,
          action: (): void => { void this.run(async (): Promise<void> => { await this.controller.action('turn.cancel'); }); } })
        this.sendButton({ symbol: $r('sys.symbol.arrow_up'), label: '引导当前任务（长按：打断并发送）', primary: false,
          enabled: this.operator() && this.allowed && !this.busy && !this.archived,
          action: (): void => { void this.send(this.capability('steer')); },
          hold: (): void => { void this.interruptAndSend(); } })
      }
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
    .onClick((): void => {
      if (this.allowed && !this.busy && this.models.length > 0) { this.afterKeyboard((): void => { this.showModelPicker = true; }, false); }
    })
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
  private composerExpanded(): boolean { return this.composerFocused || this.draft !== '' || this.composerHold; }
  /**
   * Opens a composer menu or sheet once the keyboard is down. Opened over the keyboard, the menu took the focus, the
   * keyboard went down, the page resized and the composer folded: the menu lost its anchor and was gone at once.
   * `hold` keeps the composer open until the menu closes (a sheet is anchored elsewhere and needs no hold).
   */
  private afterKeyboard(open: () => void, hold: boolean): void {
    if (!this.composerFocused) { open(); return; }
    if (hold) { this.composerHold = true; }
    try { this.getUIContext().getFocusController().clearFocus(); } catch (_error) { /* nothing focused */ }
    setTimeout((): void => {
      if (!this.alive) { return; }
      open();
      if (!hold) { this.composerHold = false; }
    }, 320);
  }
  private menuClosed(): void { this.plusMenuShown = false; this.permissionMenuShown = false; this.composerHold = false; }
  /** One line of the composer: its height and the padding that centres it in the 40 vp row of + and send. */
  private composerLine(): number { return Math.round((this.textSize + 1) * 1.375); }
  private composerPad(): number { return Math.max(4, Math.floor((40 - this.composerLine()) / 2)); }
  @Builder private composerInput() {
    TextArea({ text: this.draft, placeholder: this.composerPlaceholder() })
      // The line height and padding add up to the 40 vp minimum, so one line (and the placeholder) sits in the middle
      // of the row instead of riding high with the leftover space below it.
      .constraintSize({ minHeight: this.composerLine() + 2 * this.composerPad(), maxHeight: this.composerMaxHeight() })
      // Codex sets the text between + and send in one row; in Claude's card it sits on its own line.
      .layoutWeight(this.uiStyle === 'codex' ? 1 : 0)
      .fontSize(this.textSize + 1).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text)
      .lineHeight(this.composerLine())
      .placeholderFont({ size: this.textSize + 1, family: AppConfig.fontFamily })
      .placeholderColor(this.palette().text3).backgroundColor(Color.Transparent)
      .padding({ left: 6, right: 6, top: this.composerPad(), bottom: this.composerPad() })
      // Not disabled while a send is under way: a disabled input drops the keyboard, the page jumped to full height
      // under the flying message, and the next message could not be typed meanwhile.
      .enabled(this.allowed && this.operator() && !(this.sessionId !== '' && this.archived))
      .accessibilityText('任务内容')
      // Not inside animateTo: that animated every layout change of the moment (the keyboard resizing the page, the
      // list shrinking), and the conversation slid about. The second row fades in on its own.
      .onFocus((): void => { this.composerFocused = true; })
      .onBlur((): void => { this.composerFocused = false; })
      .onChange((value: string): void => { if (this.allowed) { this.draft = value; } }).maxLength(128000)
      // Where a send starts from: the input's own box.
      .id(this.flyId('composer'))
      .onAreaChange((_old: Area, next: Area): void => { this.noteBox('composer', next); })
  }
  /**
   * The composer. Codex: a pill (+, 跟进, send) that opens into a card with + / permissions / model when focused.
   * Claude: a card with the text over +, the model pill and send. The Claude home list starts conversations from its
   * 新对话 button instead.
   */
  /** The / commands matching what is typed, above the composer: the app's own act at once, the engine's fill in. */
  @Builder private commandPanel() {
    Column() {
      ForEach(this.slashSuggestions(), (command: AiWsCommand, index: number): void => {
        if (index > 0) { Divider().color(this.palette().border).margin({ left: 14, right: 14 }) }
        Row({ space: 10 }) {
          Text(command.name).fontSize(15).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily)
            .fontColor(this.palette().text)
          Text(command.description).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
            .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (!command.local) {
            Text(this.backendName()).fontSize(11).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 }).borderRadius(6).backgroundColor(this.palette().surface)
          }
        }.width('100%').height(46).padding({ left: 14, right: 14 })
        .accessibilityText(command.name + '，' + command.description)
        .onClick((): void => { this.runCommand(command); })
      }, (command: AiWsCommand): string => command.name)
    }.width('100%').borderRadius(18).backgroundColor(this.palette().raised)
    .border({ width: 0.5, color: this.palette().border }).shadow({ radius: 16, color: '#14000000', offsetY: 2 }).clip(true)
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 8 })).animation({ duration: 180 }))
  }
  /**
   * The conversation is open in another app on the computer (Pi: pi-gui holds every conversation it has open until
   * it is closed there): the phone reads it, and can go on in a copy right away.
   */
  @Builder private openInNotice() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        SymbolGlyph($r('sys.symbol.lock_fill')).fontSize(16).fontColor([this.palette().text2])
        Column({ space: 2 }) {
          Text('这个对话在电脑上的 ' + (this.openIn === 'pi-gui' ? 'pi-gui' : this.backendName()) + ' 里打开着')
            .fontSize(14).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text)
          Text('手机现在只能查看。在电脑上关闭这个对话（或退出 pi-gui）后就能直接继续，也可以复制到新对话马上继续。')
            .fontSize(12).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').alignItems(VerticalAlign.Top)
      if (this.capability('fork') && this.operator()) {
        Row({ space: 8 }) {
          Blank()
          this.pillButton({ label: '复制到新对话继续', primary: true, enabled: this.allowed && !this.busy, action: (): void => {
            void this.run(async (): Promise<void> => {
              this.resetView(); this.slideNext = 1;
              await this.controller.forkToContinue((this.title || '对话') + ' · 手机继续');
            });
          } })
        }.width('100%')
      }
    }.width('100%').padding(12).borderRadius(18).backgroundColor(this.palette().surface)
    .border({ width: 0.5, color: this.palette().border })
    .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
  }
  @Builder private composer() {
    Column({ space: 8 }) {
      if (this.sessionId !== '' && this.openIn !== '') { this.openInNotice() }
      if (this.slashSuggestions().length > 0) { this.commandPanel() }
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
                action: (): void => { this.afterKeyboard((): void => { this.showModelPicker = true; }, false); } })
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
      .onClick((): void => { this.afterKeyboard((): void => { this.plusMenuShown = true; }, true); })
      .bindMenu(this.plusMenuShown, this.plusMenu(), { onDisappear: (): void => { this.menuClosed(); } })
    } else {
      Stack() {
        SymbolGlyph($r('sys.symbol.plus')).fontSize(20).fontColor([this.palette().text])
      }.width(40).height(40).borderRadius(20).backgroundColor(this.palette().surface).focusable(true).accessibilityText('添加内容')
      .enabled(this.allowed && !this.busy && this.operator()).opacity(this.allowed && !this.busy && this.operator() ? 1 : 0.4)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
      .onClick((): void => { this.afterKeyboard((): void => { this.showAddSheet = true; }, false); })
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
    .onClick((): void => { this.afterKeyboard((): void => { this.permissionMenuShown = true; }, true); })
    .bindMenu(this.permissionMenuShown, this.permissionMenu(), { onDisappear: (): void => { this.menuClosed(); } })
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
        .onClick((): void => { this.permission = mode; this.permissionMenuShown = false; })
      }, (mode: string): string => mode)
    }.width(310).padding({ bottom: 8 })
  }
  /** Pad and PC: the conversation list beside the open conversation (a third of the width). */
  @Builder private sidebar() {
    Column() {
      Row({ space: 8 }) {
        this.circleButton({ symbol: $r('sys.symbol.chevron_left'), label: '返回', enabled: true, action: (): void => { void this.leave(); } })
        Column({ space: 2 }) {
          Text(this.host?.label ?? '远程 AI').fontSize(17).fontWeight(FontWeight.Medium).fontFamily(AppConfig.fontFamily)
            .fontColor(this.palette().text).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.backendName() + ' · ' + this.status).fontSize(12).fontFamily(AppConfig.fontFamily)
            .fontColor(this.palette().text3).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        this.circleButton({ symbol: this.searching ? $r('sys.symbol.xmark') : $r('sys.symbol.magnifyingglass'),
          label: this.searching ? '关闭搜索' : '搜索对话', enabled: true,
          action: (): void => { this.searching = !this.searching; if (!this.searching) { this.query = ''; } } })
      }.width('100%').padding({ left: 10, right: 10, top: 6, bottom: 6 })
      Column() { this.conversationFilters() }.padding({ left: 10, right: 10 })
      Refresh({ refreshing: $$this.sideRefreshing }) {
        List({ space: 2, scroller: this.sideScroller() }) {
          if (this.listedSessions().length === 0) {
            ListItem() {
              Text(this.allowed ? (this.projects.length === 0 ? '电脑还没有开放项目给这台设备' : '这里还没有对话') :
                (this.status === '连接中' ? '正在连接电脑…' : '还没有连上电脑'))
                .fontSize(14).fontFamily(AppConfig.fontFamily).fontColor(this.palette().text3).width('100%')
                .textAlign(TextAlign.Center).padding({ top: 40 })
            }
          }
          ForEach(this.homeRows(), (row: AiHomeRow): void => {
            ListItem() {
              if (row.session !== null) { this.conversationRow(row.session) }
              else if (row.more > 0) { this.moreRow(row) }
              else { this.projectHeader(row) }
            }
          }, (row: AiHomeRow): string => 'side:' + row.key)
        }.width('100%').height('100%').padding({ left: 10, right: 10, bottom: 12 }).scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      }.layoutWeight(1).pullToRefresh(this.allowed)
      .onRefreshing((): void => { void this.refreshSide(); })
    }.width('100%').height('100%').backgroundColor(this.palette().bg)
  }
  /** Pad and PC with no conversation open: what to do, above the composer that starts one. */
  @Builder private splitPlaceholder() {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.ellipsis_bubble')).fontSize(40).fontColor([this.palette().text3])
      Text('选择左边的对话，或在下面直接提问开始新对话').fontSize(15).fontFamily(AppConfig.fontFamily)
        .fontColor(this.palette().text2).textAlign(TextAlign.Center)
      if (this.otherHosts().length > 0 && this.layout === 'auto') {
        Text('也可以在 ⋯ 里分屏打开另一个 AI，左右各一个对话').fontSize(13).fontFamily(AppConfig.fontFamily)
          .fontColor(this.palette().text3).textAlign(TextAlign.Center)
      }
    }.width('100%').padding({ top: 80, bottom: 40, left: 24, right: 24 })
  }
  @Builder private workspace() {
    Column() {
      Column() {
        if (this.uiStyle === 'codex') { this.codexHeader() } else { this.claudeHeader() }
      }.width('100%').onAreaChange((_old: Area, next: Area): void => { this.topChrome = this.measured(next, this.topChrome); })
      // The conversation runs down to the bottom of the page; the composer, its chips and an approval card float over
      // its foot (the conversation shows between and around them), and the list keeps their height free at its end.
      Stack({ alignContent: Alignment.Bottom }) {
      Refresh({ refreshing: $$this.listRefreshing }) {
      List({ space: this.sessionId === '' ? 2 : 18, scroller: this.scroller() }) {
        if (this.sessionId === '' && this.wide()) {
          ListItem() { this.splitPlaceholder() }
        } else if (this.sessionId === '') {
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
            // A conversation animates in the first time it is listed, not each time it is updated.
            }.transition(row.session !== null && this.fresh('s:' + row.session.id) ? this.enterEffect() : TransitionEffect.IDENTITY)
          }, (row: AiHomeRow): string => row.key)
        } else {
          if (this.historyCursor !== '') {
            ListItem() {
              Text('加载更早的记录').fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().accent)
                .width('100%').textAlign(TextAlign.Center).padding(10).enabled(this.allowed && !this.busy)
                .onClick((): void => { void this.run(async (): Promise<void> => { await this.controller.snapshot(true); }); })
            }
          }
          if (this.shownItems().length === 0) { ListItem() { this.emptyState() } }
          // Messages, and runs of steps folded into one line each, like the Codex and Claude apps.
          ForEach(this.stepEntries(), (entry: AiStepEntry, index: number): void => {
            ListItem() {
              if (entry.item !== null) { this.claudeItem(entry.item) }
              else if (entry.steps.length === 1) { this.claudeItem(entry.steps[0]) }
              else { this.stepGroup(entry) }
            }.transition(this.entryEffect(entry, index))
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
          // The working line keeps its place for the whole turn and only fades while a row above already shows the
          // turn at work: coming and going with every step, it shook the conversation up and down.
          if (this.working()) {
            ListItem() {
              Column() { this.workingRow() }.width('100%').alignItems(HorizontalAlign.Start)
                .opacity(this.showWorkingRow() ? 1 : 0).animation({ duration: 200, curve: Curve.FastOutSlowIn })
            }
          }
        }
      }.width('100%').height('100%').padding({ left: 16, right: 16 }).scrollBar(BarState.Auto)
        // A short list (a few conversations) still takes the pull from anywhere in its area and hands it to Refresh.
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        // A conversation is laid out from the bottom: its messages sit just above the composer, like a chat, and a
        // short one does not float at the top of an empty page.
        .stackFromEnd(this.sessionId !== '')
        // Room at the end for what floats over the list's foot, so the newest row sits just above the composer.
        .contentEndOffset(this.listEndRoom)
        .translate({ y: this.listLift })
        .onScrollIndex((_start: number, end: number): void => {
          if (Date.now() < this.pinBottomUntil) { return; }
          this.followBottom = end >= this.listLength() - 2;
        })
        // The reader dragging the list ends holding a sent message at the top, and stops pinning the end.
        .onWillScroll((_offset: number, _state: ScrollState, source: ScrollSource): void => {
          if (source !== ScrollSource.DRAG) { return; }
          this.pinBottomUntil = 0;
        })
      }.width('100%').height('100%')
      // Pull down on the conversation list to read it again (the chat follows its own stream).
      .pullToRefresh(this.sessionId === '' && this.allowed && !this.wide())
      .onRefreshing((): void => { void this.refreshList(); })
        // A problem shows over the top of the list instead of pushing it down; tapping it puts it away.
        if (this.error !== '') {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.exclamationmark_triangle')).fontSize(14).fontColor([this.palette().danger])
            Text(this.error).fontSize(13).fontFamily(AppConfig.fontFamily).fontColor(this.palette().danger)
              .layoutWeight(1).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 }).margin({ left: 12, right: 12, top: 4 })
          .borderRadius(12).backgroundColor(this.palette().raised).border({ width: 0.5, color: this.palette().border })
          .shadow({ radius: 10, color: '#14000000', offsetY: 2 })
          .accessibilityText(this.error).onClick((): void => { this.controller.error = ''; this.error = ''; })
          .transition(TransitionEffect.OPACITY.animation({ duration: 180 }))
          .position({ x: 0, y: 0 })
        }
        // Floating over the conversation's foot: no backdrop of its own, only the cards and the composer have one.
        Column() {
          if (this.approvals.length > 0 && this.sessionId !== '') {
            Column() { this.approvalCard(this.approvals[0]) }.width('100%').padding({ left: 12, right: 12, top: 6 })
              .transition(TransitionEffect.asymmetric(
                TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 28 }))
                  .combine(TransitionEffect.scale({ x: 0.97, y: 0.97, centerY: '100%' }))
                  .animation({ curve: curves.springMotion(0.4, 0.86) }),
                TransitionEffect.OPACITY.combine(TransitionEffect.translate({ y: 16 })).animation({ duration: 180, curve: Curve.FastOutSlowIn })))
          }
          this.composer()
        }.width('100%').hitTestBehavior(HitTestMode.Transparent)
        .onAreaChange((_old: Area, next: Area): void => {
          const before = this.bottomChrome; this.bottomChrome = this.measured(next, this.bottomChrome);
          if (before === this.bottomChrome) { return; }
          // The list's free end follows what floats over it, eased so the conversation glides rather than jumps.
          const room = Math.round(this.bottomChrome + 8);
          if (this.listEndRoom === 0) { this.listEndRoom = room; }
          else { this.getUIContext().animateTo({ duration: 260, curve: Curve.FastOutSlowIn }, (): void => { this.listEndRoom = room; }); }
          if (this.sessionId !== '') { this.followTranscript(); }
        })
      }.width('100%').layoutWeight(1)
    // The page's own height (as the window reports it), so the transcript's layoutWeight has a definite height to share.
    }.width('100%').height(Math.max(320, this.pageHeight - this.topVp() - 12)).constraintSize({ maxWidth: 1100 })
    .translate({ x: this.viewShift }).opacity(this.viewOpacity)
    .bindSheet($$this.showAddSheet, this.addSheet(), { height: SheetSize.MEDIUM, showClose: false, dragBar: true,
      preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER, backgroundColor: this.pal().surface,
      blurStyle: BlurStyle.NONE })
  }
  build() {
    // The flyer of a send sits over the whole page (it starts in the composer and lands in the list).
    Stack({ alignContent: Alignment.TopStart }) {
      // One sheet per node: three bindSheets on the Row shared one slot, so the closed details/approval bindings
      // dismissed the picker the moment it opened (and its flag stayed true, so later taps did nothing).
      Row() {
        if (this.wide()) {
          Column() { this.sidebar() }.width('34%').height('100%')
          Divider().vertical(true).color(this.palette().border).height('100%')
        }
        Stack() {
          Scroll() { this.workspace() }.width('100%').height('100%')
            .scrollable(ScrollDirection.Vertical).scrollBar(BarState.Auto)
            .bindSheet($$this.showApproval, this.approvalSheet(), { height: SheetSize.LARGE, showClose: false, dragBar: false,
              preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
              keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY, backgroundColor: this.pal().sheetBg, blurStyle: BlurStyle.NONE })
        }.layoutWeight(1).height('100%')
        .bindSheet($$this.showDetails, this.detailsSheet(), { height: SheetSize.LARGE, showClose: false, dragBar: false,
          preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER,
          keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY, backgroundColor: this.pal().sheetBg, blurStyle: BlurStyle.NONE })
      }.justifyContent(FlexAlign.Center).width('100%').height('100%')
        .padding({ top: this.topVp() }).safeAreaPadding({ bottom: 12 }).backgroundColor(this.palette().bg)
        .bindSheet($$this.showModelPicker, this.modelSheet(), { height: SheetSize.FIT_CONTENT, showClose: false, dragBar: true,
          preferType: this.breakpoint === 'sm' ? SheetType.BOTTOM : SheetType.CENTER, backgroundColor: this.pal().surface,
          blurStyle: BlurStyle.NONE })
        .onAreaChange((_old: Area, next: Area): void => {
            const width = Number(next.width), height = Number(next.height);
          if (Number.isFinite(width) && width > 0 && Math.abs(width - this.pageWidth) > 0.5) { this.pageWidth = width; }
          if (Number.isFinite(height) && height > 0 && Math.abs(height - this.pageHeight) > 0.5) { this.pageHeight = height; }
        })
      this.sendFlyer()
    }.width('100%').height('100%').id(this.flyId('root'))
    .onAreaChange((_old: Area, next: Area): void => { this.noteBox('root', next); })
  }
}

/**
 * The remote AI page: one host's conversations (on a Pad or PC the list beside the conversation), or two
 * conversations side by side (1:1) — opened from a workspace pair or with ⋯ 分屏打开 — each with its own connection.
 */
@Entry
@Component
struct RemoteAiWorkspacePage {
  @State firstHost: string = '';
  @State firstSession: string = '';
  @State secondHost: string = '';
  @State secondSession: string = '';
  private first: AiViewHandle = new AiViewHandle();
  private second: AiViewHandle = new AiViewHandle();

  aboutToAppear(): void {
    const params = (router.getParams() ?? {}) as Record<string, string>;
    this.firstHost = params['hostId'] ?? ''; this.firstSession = params['sessionId'] ?? '';
    this.secondHost = params['hostId2'] ?? ''; this.secondSession = params['sessionId2'] ?? '';
  }
  // One keyboard owner: with two panes the first sets and restores the page's keyboard mode.
  onPageShow(): void { this.first.pageShow(); }
  onPageHide(): void { this.first.pageHide(); }
  onBackPress(): boolean { return this.secondHost === '' ? this.first.back() : false; }

  /** The open view becomes the left pane (at its conversation) and the chosen host opens on the right. */
  private split(hostId: string): void {
    this.firstSession = this.first.sessionId();
    this.secondSession = ''; this.secondHost = hostId;
  }
  /** Closing one pane leaves the other alone on the page. */
  private closePane(left: boolean): void {
    if (left) { this.firstHost = this.secondHost; this.firstSession = this.second.sessionId(); }
    else { this.firstSession = this.first.sessionId(); }
    this.secondHost = ''; this.secondSession = '';
  }
  /** Keeps the two panes (hosts and open conversations) as a workspace: one tap opens them side by side again. */
  private saveCombo(): void {
    const store = WorkspaceStore.getInstance();
    if (!store.canAdd()) { promptAction.showToast({ message: '工作区已达上限', duration: 2000 }); return; }
    const firstRef = aiPairRef(this.first.hostId(), this.first.sessionId(), '');
    const secondRef = aiPairRef(this.second.hostId(), this.second.sessionId(), firstRef);
    const name = (this.first.title() + ' + ' + this.second.title()).slice(0, 48);
    const workspace: Workspace = newWorkspace('workspace-' + Date.now().toString(36), name,
      WORKSPACE_COLORS[store.list().length % WORKSPACE_COLORS.length], 'sym.message', store.list().length);
    workspace.layout = 'split';
    workspace.entries = [newWorkspaceEntry(firstRef, 'ai', 0), newWorkspaceEntry(secondRef, 'ai', 1)];
    const saved = store.save(workspace);
    promptAction.showToast({ message: saved ? '已保存工作区「' + name + '」，在主机列表的工作区里一键打开' : '没有保存，请确认 Pro 工作区可用',
      duration: 2400 });
  }

  /** The page slides in over the host list and back out to the right (the system's push and pop). */
  pageTransition() {
    PageTransitionEnter({ type: RouteType.Push, duration: 360, curve: Curve.FastOutSlowIn }).slide(SlideEffect.END)
    PageTransitionEnter({ type: RouteType.Pop, duration: 360, curve: Curve.FastOutSlowIn }).slide(SlideEffect.START).opacity(0.6)
    PageTransitionExit({ type: RouteType.Pop, duration: 320, curve: Curve.FastOutSlowIn }).slide(SlideEffect.END)
    PageTransitionExit({ type: RouteType.Push, duration: 320, curve: Curve.FastOutSlowIn }).slide(SlideEffect.START).opacity(0.6)
  }
  build() {
    if (this.secondHost === '') {
      RemoteAiWorkspace({ hostId: this.firstHost, initialSession: this.firstSession, layout: 'auto', handle: this.first,
        onSplit: (hostId: string): void => { this.split(hostId); } })
    } else {
      Row() {
        Column() {
          RemoteAiWorkspace({ hostId: this.firstHost, initialSession: this.firstSession, layout: 'pane', handle: this.first,
            onExit: (): void => { this.closePane(true); }, onSaveCombo: (): void => { this.saveCombo(); } })
        }.layoutWeight(1).height('100%')
        Divider().vertical(true).height('100%')
        Column() {
          RemoteAiWorkspace({ hostId: this.secondHost, initialSession: this.secondSession, layout: 'pane', handle: this.second,
            onExit: (): void => { this.closePane(false); }, onSaveCombo: (): void => { this.saveCombo(); } })
        }.layoutWeight(1).height('100%')
      }.width('100%').height('100%')
    }
  }
}
