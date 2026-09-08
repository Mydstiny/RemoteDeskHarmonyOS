import { aiStatusLabel, aiRequestTitle, aiApprovalDetails } from '../services/ai/AiPresentation';
import { aiParams } from '../services/ai/AiWirePolicy';
import { router, promptAction } from '@kit.ArkUI';
import { common, ApplicationStateChangeCallback } from '@kit.AbilityKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Palette, buildDark, buildLight } from '../common/Theme';
import { AppSheetHeader } from '../components/AppSheetHeader';
import { AiAccess, AiAccountLease } from '../services/ai/AiAccess';
import { AiHostService } from '../services/ai/AiHostService';
import { AiHost, AiProject, AiSession, AiTranscriptItem, AiApproval, AiPendingOperation } from '../services/ai/AiModels';
import { AiWorkspaceController } from '../services/ai/AiWorkspaceController';
import { AiLocalStore } from '../services/ai/AiLocalStore';
import { aiArray, aiRecord, aiString, aiErrorText } from '../services/ai/AiWirePolicy';

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
  private controller: AiWorkspaceController = new AiWorkspaceController();
  private host: AiHost | null = null;
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
    this.title = c.title || this.host?.label || '远程 AI'; this.status = aiStatusLabel(c.status); this.error = c.error;
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
    this.inBackground = AppStorage.get<boolean>('remoteDesktopBgFlag') === true;
    const application = (getContext(this) as common.UIAbilityContext).getApplicationContext();
    this.appStateCallback = {
      onApplicationBackground: (): void => {
        if (!this.preferencesReady) { this.pausedDuringSetup = true; }
        this.resumeSession = this.controller.sessionId; this.resumeProject = this.controller.projectId;
        this.resumeAccount = this.controller.client?.account ?? null;
        this.inBackground = true; this.controller.close(); this.draft = ''; this.attachments = [];
        this.approval = null; this.questions = []; this.showApproval = false; this.controller.status = '已暂停连接'; this.sync();
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
    if (!this.alive || mount !== this.mountGeneration) { return; }
    this.host = AiHostService.getInstance().find(params['hostId'] ?? '');
    if (this.host === null) { this.error = '主机不存在或当前账号已变化'; return; }
    try {
      const account = AiAccess.getInstance().capture();
      const settings = await AiLocalStore.getInstance().settings(account);
      if (!this.alive || mount !== this.mountGeneration) { return; }
      AiAccess.getInstance().assertCurrent(account);
      this.textSize = settings.textSize; this.showExecution = settings.showExecution;
      this.reconnectForeground = settings.reconnectOnForeground; this.preferencesReady = true;
    } catch (error) { if (this.alive) { this.error = aiErrorText((error as Error).message); } return; }
    this.inBackground = AppStorage.get<boolean>('remoteDesktopBgFlag') === true;
    if (this.inBackground || (this.pausedDuringSetup && !this.reconnectForeground)) { this.status = '已暂停连接'; return; }
    await this.reconnect();
  }
  aboutToDisappear(): void {
    this.mountGeneration++; this.alive = false; this.controller.close(); this.draft = ''; this.attachments = []; this.approval = null;
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
  private async reconnect(): Promise<void> {
    const host = this.host; if (host === null) { return; }
    const resumeValid = this.resumeAccount !== null && AiAccess.getInstance().current(this.resumeAccount);
    const session = this.controller.sessionId || (resumeValid ? this.resumeSession : '');
    const project = this.controller.projectId || (resumeValid ? this.resumeProject : '');
    this.resumeSession = ''; this.resumeProject = ''; this.resumeAccount = null;
    await this.run(async (): Promise<void> => {
      this.resetDrafts(); await this.controller.connect(host);
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
    const text = this.draft.trim(); if (text === '') { return; }
    await this.run(async (): Promise<void> => {
      const params: Record<string, Object> = aiParams(["text"], [text]);
      if (!steer) {
        params['settings'] = this.settings();
        if (this.attachments.length > 0) { params['attachments'] = this.attachments.slice(); }
      }
      await this.controller.action(steer ? 'turn.steer' : 'turn.start', params);
      this.draft = ''; this.attachments = [];
    });
  }
  private async attach(): Promise<void> {
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
    this.approval = approval; this.showApprovalDetails = false;
    this.questions = aiArray(approval.request['questions']).map((value: Object): AiQuestionValue => {
      const row = aiRecord(value);
      return { id: aiString(row['id']), title: aiString(row['question'], aiString(row['header'])),
        options: aiArray(row['options']).map((option: Object): string => typeof option === 'string' ? option as string : aiString(aiRecord(option)['label'])),
        descriptions: aiArray(row['options']).map((option: Object): string => typeof option === 'string' ? '' : aiString(aiRecord(option)['description'])),
        multiple: row['multiSelect'] === true, selected: [], text: '' };
    });
    this.showApproval = true;
  }
  private async answer(decision: string): Promise<void> {
    const approval = this.approval; if (approval === null) { return; }
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
      (approval.request['kind'] !== 'fileChange' || approval.request['nativeItemComplete'] === true);
  }
  @Builder private approvalSheet() {
    Column() {
      AppSheetHeader({ title: '确认 AI 请求', onClose: (): void => { this.showApproval = false; } })
      Scroll() {
        Column({ space: 14 }) {
          if (this.approval !== null) {
            Text(aiRequestTitle(aiString(this.approval.request['kind']))).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
            Text(aiApprovalDetails(this.approval.request)).fontSize(13).fontColor(this.pal().text)
              .copyOption(CopyOptions.InApp).width('100%')
            ForEach(this.questions, (question: AiQuestionValue, index: number): void => {
              Column({ space: 8 }) {
                Text(question.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.pal().text).width('100%')
                ForEach(question.options, (option: string, optionIndex: number): void => {
                  Button((question.selected.includes(option) ? '✓ ' : '') + option).width('100%')
                    .onClick((): void => {
                      question.selected = question.selected.includes(option) ? question.selected.filter((v: string): boolean => v !== option) : (question.multiple ? question.selected.concat([option]) : [option]);
                      if (!question.multiple) { question.text = ''; }
                      this.questions[index] = question; this.questions = this.questions.slice();
                    })
                  if (question.descriptions[optionIndex] !== '') {
                    Text(question.descriptions[optionIndex]).fontSize(12).fontColor(this.pal().text2).width('100%')
                  }
                })
                TextInput({ text: question.text, placeholder: '补充回答' }).onChange((value: string): void => {
                  question.text = value;
                  if (!question.multiple && value.trim() !== '') { question.selected = []; }
                  this.questions[index] = question; this.questions = this.questions.slice();
                })
              }
            }, (question: AiQuestionValue): string => question.id)
            Button(this.showApprovalDetails ? '收起完整请求' : '查看完整请求与授权范围').width('100%')
              .onClick((): void => { this.showApprovalDetails = !this.showApprovalDetails; })
            if (this.showApprovalDetails) {
              Text(JSON.stringify(this.approval.request, null, 2)).fontSize(12).fontColor(this.pal().text2)
                .copyOption(CopyOptions.InApp).width('100%')
            }
          }
        }.padding(24).width('100%')
      }.layoutWeight(1).width('100%')
      Row({ space: 10 }) {
        if (this.questions.length > 0) {
          Button('停止回合').layoutWeight(1).enabled(this.control && !this.busy).onClick((): void => {
            void this.run(async (): Promise<void> => { await this.controller.action('turn.cancel'); this.showApproval = false; });
          })
        }
        if (this.questions.length === 0) {
          Button('拒绝').layoutWeight(1).enabled(this.canAccept() && !this.busy).onClick((): void => { void this.answer('decline'); })
        }
        Button(this.questions.length > 0 ? '提交回答' : '允许此次请求').layoutWeight(1).enabled(this.canAccept() && !this.busy)
          .backgroundColor(this.accent).fontColor(Color.White).onClick((): void => { void this.answer('accept'); })
      }.padding(20).width('100%')
      if (this.error !== '') { Text(this.error).fontSize(12).fontColor(this.pal().danger).padding(12) }
    }.height('100%').width('100%').backgroundColor(this.pal().sheetBg)
  }
  @Builder private detailsSheet() {
    Column() {
      AppSheetHeader({ title: '会话详情', onClose: (): void => { this.showDetails = false; } })
      Row({ space: 8 }) {
        Button('模型').onClick((): void => { this.detailTab = 0; })
        Button('差异').enabled(this.capability('diffs')).onClick((): void => { this.detailTab = 1; void this.run(async (): Promise<void> => { await this.controller.loadDiff(); }); })
        Button('终端').enabled(this.capability('terminalManagement')).onClick((): void => { this.detailTab = 2; void this.run(async (): Promise<void> => { await this.controller.loadTerminals(); }); })
        Button('操作').onClick((): void => { this.detailTab = 3; void this.run(async (): Promise<void> => { await this.controller.refreshOperations(); }); })
      }.padding(12)
      Scroll() {
        Column({ space: 12 }) {
          if (this.detailTab === 0) {
            Text('模型与会话').fontSize(16).fontColor(this.pal().text).width('100%')
            Select(this.models.map((row: Record<string, Object>): SelectOption => ({ value: aiString(row['displayName'], aiString(row['name'], aiString(row['id']))) })))
              .value(this.model || '保持当前模型').onSelect((index: number): void => {
                const row = this.models[index]; this.model = aiString(row['model'], aiString(row['id']));
                this.provider = aiString(row['provider']); this.effort = '';
                this.efforts = aiArray(row['supportedReasoningEfforts']).map((value: Object): string => aiString(aiRecord(value)['reasoningEffort']));
              })
            if (this.efforts.length > 0) {
              Select(this.efforts.map((value: string): SelectOption => ({ value }))).value(this.effort || '保持推理强度')
                .onSelect((index: number): void => { this.effort = this.efforts[index]; })
            }
            ForEach(this.controller.client?.choices('permissionModes') ?? [], (value: string): void => {
              Button((this.permission === value ? '✓ ' : '') + value).onClick((): void => { this.permission = value; })
            })
            ForEach(this.controller.client?.choices('collaborationModes') ?? [], (value: string): void => {
              Button((this.collaboration === value ? '✓ ' : '') + value).onClick((): void => { this.collaboration = value; })
            })
            TextInput({ text: this.newTitle, placeholder: '会话名称' }).onChange((value: string): void => { this.newTitle = value; })
            Button('保存会话设置').enabled(this.capability('rename') && this.allowed && this.control && !this.busy).onClick((): void => {
              void this.run(async (): Promise<void> => {
                const params: Record<string, Object> = aiParams(["settings"], [this.settings()]);
                if (this.newTitle.trim() !== '') { params['title'] = this.newTitle.trim(); }
                await this.controller.action('session.update', params); this.controller.title = this.newTitle || this.title;
              });
            })
            Button('从已完成历史分叉').enabled(this.capability('fork') && this.allowed && this.control && !this.busy).onClick((): void => {
              void this.run(async (): Promise<void> => {
                const result = await this.controller.action('session.fork');
                this.resetDrafts(); await this.controller.selectProject(this.projectId); await this.controller.selectSession(aiString(result['sessionId']));
              });
            })
            Button('压缩上下文').enabled(this.capability('compact') && this.allowed && this.control && !this.busy).onClick((): void => {
              void this.run(async (): Promise<void> => { await this.controller.action('session.compact'); });
            })
            Button(this.archived ? '恢复会话' : '归档会话').enabled(this.allowed && this.control && !this.busy).onClick((): void => {
              void this.run(async (): Promise<void> => { await this.controller.action(this.archived ? 'session.resume' : 'session.archive'); });
            })
          } else if (this.detailTab === 1) {
            Text('仅显示原生引擎已报告的差异').fontSize(12).fontColor(this.pal().text3).width('100%')
            Text(this.diff).fontSize(13).fontColor(this.pal().text).copyOption(CopyOptions.InApp).width('100%')
          } else if (this.detailTab === 2) {
            ForEach(this.terminals, (terminal: Record<string, Object>): void => {
              Column({ space: 8 }) {
                Text(JSON.stringify(terminal, null, 2)).fontSize(13).fontColor(this.pal().text).width('100%')
                Button('停止此任务').enabled(this.control && !this.busy).onClick((): void => {
                  void this.run(async (): Promise<void> => {
                    await this.controller.action('terminal.stop', aiParams(["processId"], [aiString(terminal['processId'])]));
                    await this.controller.loadTerminals();
                  });
                })
              }.padding(12).backgroundColor(this.pal().surface).borderRadius(12)
            })
          } else {
            Text('结果未确认时，核对原回执与会话内容后再决定下一步。不会自动重发。').fontSize(12).fontColor(this.pal().text3)
            ForEach(this.operations, (operation: AiPendingOperation): void => {
              Column({ space: 8 }) {
                Text(operation.receipt === '' ? '结果待确认' : operation.receipt).fontSize(12).fontColor(this.pal().text).width('100%')
                Text(new Date(operation.createdAt).toLocaleString()).fontSize(11).fontColor(this.pal().text3)
                Button('核对原操作').enabled(this.allowed && !this.busy).onClick((): void => {
                  void this.run(async (): Promise<void> => { await this.controller.reconcile(operation.id); });
                })
              }.width('100%').padding(12).backgroundColor(this.pal().surface).borderRadius(12)
            }, (operation: AiPendingOperation): string => operation.id)
          }
        }.padding(20).width('100%')
      }.layoutWeight(1).width('100%')
      if (this.error !== '') { Text(this.error).fontSize(12).fontColor(this.pal().danger).padding(12) }
    }.height('100%').width('100%').backgroundColor(this.pal().sheetBg)
  }
  build() {
    Column() {
      AppSheetHeader({ title: this.title, onClose: (): void => { void this.leave(); } })
      Row({ space: 8 }) {
        Text(this.status).fontSize(12).fontColor(this.pal().text3).layoutWeight(1)
        Button('重连').fontSize(12).enabled(!this.busy).onClick((): void => { void this.reconnect(); })
        Button('详情').fontSize(12).onClick((): void => { this.showDetails = true; })
      }.padding({ left: 20, right: 20 }).width('100%')
      Row({ space: 8 }) {
        Select(this.projects.map((project: AiProject): SelectOption => ({ value: project.title }))).value(this.projects.find((project: AiProject): boolean => project.id === this.projectId)?.title ?? '选择项目')
          .enabled(!this.busy).layoutWeight(1).onSelect((index: number): void => {
            this.resetDrafts(); void this.run(async (): Promise<void> => { await this.controller.selectProject(this.projects[index].id); });
          })
        Select(this.sessions.map((session: AiSession): SelectOption => ({ value: (session.archived ? '已归档 · ' : '') + session.title })))
          .value(this.sessionId === '' ? '选择会话' : this.title).enabled(!this.busy).layoutWeight(1).onSelect((index: number): void => {
            this.resetDrafts(); void this.run(async (): Promise<void> => { await this.controller.selectSession(this.sessions[index].id); });
          })
        Button('新建').enabled(this.allowed && this.projectId !== '' && !this.busy).onClick((): void => {
          void this.run(async (): Promise<void> => { this.resetDrafts(); await this.controller.create('新会话'); });
        })
      }.padding(12).width('100%')
      if (this.error !== '') { Text(this.error).fontSize(13).fontColor(this.pal().danger).width('100%').padding(12) }
      List({ space: 12 }) {
        if (this.historyCursor !== '') {
          ListItem() { Button('加载更早记录').onClick((): void => { void this.run(async (): Promise<void> => { await this.controller.snapshot(true); }); }) }
        }
        ForEach(this.items, (item: AiTranscriptItem): void => {
          if (this.showExecution || item.role !== 'execution') {
            ListItem() {
              Column({ space: 6 }) {
                Text(item.role === 'user' ? '你' : item.role === 'assistant' ? 'AI' : item.title)
                  .fontSize(12).fontWeight(FontWeight.Medium).fontColor(item.role === 'user' ? this.accent : this.pal().text3).width('100%')
                Text(item.text).fontSize(this.textSize).fontColor(this.pal().text).copyOption(CopyOptions.InApp).width('100%')
                if (item.state !== '') { Text(aiStatusLabel(item.state)).fontSize(10).fontColor(this.pal().text3).width('100%') }
              }.padding(16).width('100%').borderRadius(16)
                .backgroundColor(item.role === 'user' ? this.pal().surface : this.pal().card)
            }
          }
        }, (item: AiTranscriptItem): string => item.id)
      }.layoutWeight(1).width('100%').padding({ left: 16, right: 16 }).scrollBar(BarState.Auto)
      ForEach(this.approvals, (approval: AiApproval): void => {
        Button(aiRequestTitle(aiString(approval.request['kind'])) + ' · 查看详情').width('100%')
          .onClick((): void => { this.inspect(approval); })
      }, (approval: AiApproval): string => approval.id)
      if (this.sessionId !== '') {
        Column({ space: 8 }) {
          if (!this.control) {
            Button('取得控制权').enabled(this.controller.client?.handshake?.role === 'operator' && this.allowed && !this.busy).onClick((): void => {
              void this.run(async (): Promise<void> => { await this.controller.acquire(); });
            })
          }
          TextArea({ text: this.draft, placeholder: this.archived ? '先恢复归档会话' : '给 AI 发送任务…' })
            .height(88).fontColor(this.pal().text).backgroundColor(this.pal().surface)
            .onChange((value: string): void => { this.draft = value; }).maxLength(128000)
          Row({ space: 8 }) {
            Button('附件' + (this.attachments.length > 0 ? ' ' + this.attachments.length : '')).fontSize(12)
              .enabled(this.allowed && !this.busy && (this.controller.client?.choices('attachments').length ?? 0) > 0).onClick((): void => { void this.attach(); })
            Button('停止').fontSize(12).enabled(this.capability('cancel') && this.control && !this.busy).onClick((): void => {
              void this.run(async (): Promise<void> => { await this.controller.action('turn.cancel'); });
            })
            Button('补充指令').fontSize(12).enabled(this.capability('steer') && this.control && this.allowed && !this.busy && !this.archived)
              .onClick((): void => { void this.send(true); })
            Button('发送').layoutWeight(1).backgroundColor(this.accent).fontColor(Color.White)
              .enabled(this.control && this.allowed && !this.busy && !this.archived).onClick((): void => { void this.send(false); })
          }.width('100%')
        }.padding(16).width('100%')
      }
    }.width('100%').height('100%').padding({ top: this.topInset }).backgroundColor(this.pal().sheetBg)
      .bindSheet($$this.showDetails, this.detailsSheet(), { height: SheetSize.LARGE, showClose: false })
      .bindSheet($$this.showApproval, this.approvalSheet(), { height: SheetSize.LARGE, showClose: false })
  }
}
