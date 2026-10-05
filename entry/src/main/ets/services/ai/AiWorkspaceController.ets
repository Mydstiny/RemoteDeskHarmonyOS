import { aiParams } from './AiWirePolicy';
import { AiAccess } from './AiAccess';
import { AiBridgeClient } from './AiBridgeClient';
import { aiRandomId } from './AiTransport';
import { AiLifecycle } from './AiLifecycle';
import { AiLocalStore } from './AiLocalStore';
import { AiHost, AiProject, AiSession, AiApproval, AiEvent, AiPendingOperation } from './AiModels';
import { AiTranscript } from './AiTranscript';
import { aiArray, aiRecord, aiString, aiNumber, aiErrorText } from './AiWirePolicy';

export class AiWorkspaceController {
  client: AiBridgeClient | null = null;
  projects: AiProject[] = [];
  sessions: AiSession[] = [];
  approvals: AiApproval[] = [];
  models: Record<string, Object>[] = [];
  terminals: Record<string, Object>[] = [];
  operations: AiPendingOperation[] = [];
  transcript: AiTranscript = new AiTranscript();
  projectId: string = '';
  sessionId: string = '';
  title: string = '';
  status: string = '未连接';
  error: string = '';
  diff: string = '';
  lease: string = '';
  leaseExpires: number = 0;
  archived: boolean = false;
  busy: boolean = false;
  allowed: boolean = false;
  inputModalities: string[] = [];
  private accessRevoked: boolean = false;
  historyCursor: string = '';
  onChange: () => void = (): void => {};
  private generation: number = 0;
  private eventCursor: number = 0;
  private renewTimer: number = -1;
  private refreshTimer: number = -1;
  private writerOwners: Map<string, string> = new Map();
  private writerUnregister: Map<string, () => void> = new Map();
  private liveBusy: Set<number> = new Set();
  private liveDirty: Set<number> = new Set();
  private streamToken: number = 0;
  private changeTimer: number = -1;
  private stopAccess: () => void = (): void => {};
  private key(): string { return (this.client?.host.id ?? '') + ':' + this.sessionId; }
  /** Maps the events recorded since the last change, then tells the page. */
  private changed(): void {
    if (this.changeTimer >= 0) { clearTimeout(this.changeTimer); this.changeTimer = -1; }
    const problem = this.transcript.flush();
    if (problem !== '') {
      // DSH could not place a surface replacement: the transcript is only right again after a new snapshot.
      this.error = aiErrorText(problem); this.status = '需重新连接以恢复快照'; this.client?.stopEvents();
    }
    this.onChange();
  }
  /** Streamed events arrive token by token; the page follows them a few times a second rather than per event. */
  private changeSoon(): void {
    if (this.changeTimer >= 0) { return; }
    this.changeTimer = setTimeout((): void => { this.changeTimer = -1; this.changed(); }, 80);
  }
  private assertGeneration(generation: number): void {
    if (generation !== this.generation || this.client === null) { throw new Error('AI_CONNECTION_CLOSED'); }
    AiAccess.getInstance().assertCurrent(this.client.account);
  }
  async connect(host: AiHost): Promise<void> {
    this.close(); const generation = this.generation;
    this.busy = true; this.status = '连接中'; this.error = ''; this.changed();
    let connected: AiBridgeClient | null = null;
    try {
      const client = await AiBridgeClient.connect(host);
      connected = client;
      if (generation !== this.generation) { client.close(); return; }
      this.client = client;
      this.stopAccess = AiAccess.getInstance().subscribe((): void => {
        const executable = AiAccess.getInstance().executable(host.backend);
        if (!executable) { this.accessRevoked = true; }
        this.allowed = executable && !this.accessRevoked;
        if (!AiAccess.getInstance().current(client.account)) { this.close(); this.status = '账号已变化'; }
        else if (!this.allowed) { this.status = executable ? 'Pro 权益已恢复，请重新连接' : 'Pro 权益不可用，可停止已有任务'; this.clearTimers(); }
        this.changed();
      });
      if (this.client !== client) { this.stopAccess(); throw new Error('AI_ACCOUNT_CHANGED'); }
      const projects = aiArray(await client.read('project.list')).map((value: Object): AiProject => {
        const row = aiRecord(value); return { id: aiString(row['id']), title: aiString(row['title']) };
      });
      this.assertGeneration(generation);
      this.projects = projects; this.status = '已连接'; this.busy = false;
      if (this.projects.length > 0) { await this.selectProject(this.projects[0].id); }
    } catch (error) { if (generation === this.generation || (connected !== null && this.client === connected)) { this.error = aiErrorText((error as Error).message); this.status = '连接未完成'; } }
    finally { if (generation === this.generation || (connected !== null && this.client === connected)) { this.busy = false; this.changed(); } }
  }
  async selectProject(id: string): Promise<void> {
    if (this.client === null) { return; }
    const generation = ++this.generation;
    await this.release();
    this.assertGeneration(generation);
    this.client.stopEvents(); this.streamToken++; this.projectId = id; this.sessionId = '';
    this.sessions = []; this.approvals = []; this.transcript.clear(); this.changed();
    let cursor = '';
    const sessions: AiSession[] = [];
    do {
      const params: Record<string, Object> = aiParams(["projectId", "limit"], [id, 100]);
      if (cursor !== '') { params['cursor'] = cursor; }
      const result = aiRecord(await this.client.read('session.list', params));
      this.assertGeneration(generation);
      aiArray(result['data']).forEach((value: Object): void => {
        const row = aiRecord(value); sessions.push({ id: aiString(row['id']), project: aiString(row['project']),
          title: aiString(row['title'], '未命名会话'), archived: row['archived'] === true });
      });
      const next = aiString(result['nextCursor']);
      if (next !== '' && next === cursor) { throw new Error('AI_PAGINATION_INVALID'); }
      cursor = next;
    } while (cursor !== '' && sessions.length < 1000);
    this.sessions = sessions; this.changed();
    await this.loadModels();
  }
  async selectSession(id: string): Promise<void> {
    if (this.client === null) { return; }
    const generation = ++this.generation;
    await this.release();
    this.assertGeneration(generation);
    this.client.stopEvents(); this.streamToken++;
    this.sessionId = id; this.approvals = []; this.diff = ''; this.terminals = []; this.transcript.clear();
    await this.snapshot(false);
    this.assertGeneration(generation);
    await this.refreshApprovals(); await this.refreshOperations();
    void this.stream(++this.streamToken);
  }
  async snapshot(older: boolean): Promise<void> {
    const client = this.client;
    if (client === null || this.sessionId === '') { return; }
    const generation = this.generation;
    let cursor = older ? this.historyCursor : '';
    if (!older) { this.transcript.clear(); }
    const olderIds: string[] = [];
    do {
      const params: Record<string, Object> = aiParams(["sessionId"], [this.sessionId]);
      if (cursor !== '') { params['cursor'] = cursor; }
      const result = aiRecord(await client.read('session.read', params));
      this.assertGeneration(generation);
      const session = aiRecord(result['session']); const snapshot = aiRecord(result['snapshot']);
      this.title = aiString(session['title']); this.archived = session['archived'] === true;
      if (!older && cursor === '') { this.eventCursor = aiNumber(result['cursor']); }
      this.status = aiString(snapshot['status'], '状态未知');
      this.inputModalities = aiArray(snapshot['inputModalities']).map((value: Object): string => aiString(value));
      if (client.host.backend === 'codex') {
        const turns = aiArray(snapshot['turns']).slice().reverse();
        for (const value of turns) {
          const turn = aiRecord(value); const turnId = aiString(turn['id']);
          for (const item of aiArray(turn['items'])) {
            const row = aiRecord(item); olderIds.push(aiString(row['id']));
            this.transcript.codexItem(row, turnId, aiString(turn['status']));
          }
          let itemCursor = aiString(turn['nextCursor']);
          while (itemCursor !== '') {
            const page = aiRecord(await client.read('session.items', aiParams(["sessionId", "turnId", "cursor"], [this.sessionId, turnId, itemCursor])));
            this.assertGeneration(generation);
            aiArray(page['data']).forEach((item: Object): void => {
              const row = aiRecord(item); olderIds.push(aiString(row['id'])); this.transcript.codexItem(row, turnId);
            });
            const next = aiString(page['nextCursor']);
            if (next === itemCursor) { throw new Error('AI_PAGINATION_INVALID'); } itemCursor = next;
          }
        }
      } else if (client.host.backend === 'claudecode') {
        aiArray(snapshot['events']).forEach((event: Object): void => this.transcript.claudeEvent(aiRecord(event), true));
      } else {
        aiArray(snapshot['events']).forEach((event: Object): void => this.transcript.dshEvent(aiRecord(event), true));
        // A page is mapped once; a surface replacement it cannot place ends the snapshot.
        const problem = this.transcript.flush();
        if (problem !== '') { throw new Error(problem); }
      }
      const next = aiString(snapshot['nextCursor']);
      if (next !== '' && next === cursor) { throw new Error('AI_PAGINATION_INVALID'); }
      cursor = next; this.historyCursor = cursor;
      if (older && client.host.backend === 'codex') { this.transcript.prependIds(olderIds); }
      this.changed();
      // DSH replacements need their full source interval before SSE admission.
    } while (client.host.backend !== 'codex' && cursor !== '');
  }
  private async stream(token: number): Promise<void> {
    const client = this.client; if (client === null) { return; }
    try {
      await client.events(this.eventCursor, (event: AiEvent): void => {
        if (token !== this.streamToken || event.cursor <= this.eventCursor) { return; }
        this.eventCursor = event.cursor;
        if (event.session !== this.sessionId) { return; }
        const type = aiString(event.event['type']);
        if (client.host.backend === 'codex') { this.scheduleLiveSnapshot(token); }
        else if (client.host.backend === 'claudecode') { this.transcript.claudeEvent(event.event, true); }
        else { this.transcript.dshEvent(event.event, true); }
        if (type.startsWith('execution.')) { this.status = type.slice(10); }
        if (type.startsWith('approval.')) { void this.refreshApprovals().catch((): void => {}); }
        if (type === 'snapshot.required') { this.status = '需重新连接以恢复快照'; client.stopEvents(); this.changed(); }
        else { this.changeSoon(); }
      });
      if (token === this.streamToken) { this.status = '事件连接已断开，请重新连接'; this.changed(); }
    } catch (error) {
      if (token === this.streamToken) { this.error = aiErrorText((error as Error).message); this.status = '事件连接已断开'; this.changed(); }
    }
  }
  private scheduleLiveSnapshot(token: number): void {
    this.liveDirty.add(token);
    if (this.refreshTimer >= 0 || this.liveBusy.has(token)) { return; }
    this.refreshTimer = setTimeout((): void => {
      this.refreshTimer = -1;
      void this.flushLiveSnapshots(token).catch((error: Error): void => {
        if (token === this.streamToken) { this.error = aiErrorText(error.message); this.changed(); }
      });
    }, 300);
  }
  private async flushLiveSnapshots(token: number): Promise<void> {
    this.liveBusy.add(token);
    try {
      do {
        this.liveDirty.delete(token); await this.refreshLiveSnapshot(token);
      } while (token === this.streamToken && this.liveDirty.has(token));
    } finally { this.liveBusy.delete(token); this.liveDirty.delete(token); }
  }
  private async refreshLiveSnapshot(token: number): Promise<void> {
    const client = this.client, session = this.sessionId, generation = this.generation;
    if (client === null || session === '' || token !== this.streamToken) { return; }
    const result = aiRecord(await client.read('session.read', aiParams(['sessionId'], [session])));
    this.assertGeneration(generation);
    if (token !== this.streamToken) { return; }
    const snapshot = aiRecord(result['snapshot']);
    for (const value of aiArray(snapshot['turns']).slice().reverse()) {
      const turn = aiRecord(value); const turnId = aiString(turn['id']);
      for (const item of aiArray(turn['items'])) { this.transcript.codexItem(aiRecord(item), turnId, aiString(turn['status'])); }
      let cursor = aiString(turn['nextCursor']);
      while (cursor !== '') {
        const page = aiRecord(await client.read('session.items', aiParams(['sessionId', 'turnId', 'cursor'], [session, turnId, cursor])));
        this.assertGeneration(generation);
        if (token !== this.streamToken) { return; }
        aiArray(page['data']).forEach((item: Object): void => this.transcript.codexItem(aiRecord(item), turnId));
        const next = aiString(page['nextCursor']);
        if (next === cursor) { throw new Error('AI_PAGINATION_INVALID'); } cursor = next;
      }
    }
    this.status = aiString(snapshot['status'], this.status); this.changed();
  }
  async acquire(): Promise<void> {
    const client = this.client, session = this.sessionId, generation = this.generation;
    if (client === null || session === '' || this.lease !== '') { return; }
    const key = client.host.id + ':' + session;
    const writer = aiRandomId();
    if (!AiLifecycle.claim(key, writer)) { throw new Error('LEASE_BUSY'); }
    this.writerOwners.set(key, writer);
    this.writerUnregister.set(writer, AiLifecycle.register(writer, client.host.id, (): void => { this.dropWriter(key, writer); }));
    try {
      const result = await client.write('lease.acquire', aiParams(['sessionId'], [session]), session);
      const lease = aiString(result['lease']);
      if (generation !== this.generation || client !== this.client) {
        if (lease !== '') { await client.write('lease.release', aiParams(['sessionId', 'lease'], [session, lease]), session); }
        throw new Error('AI_CONNECTION_CLOSED');
      }
      this.assertGeneration(generation);
      this.lease = lease; this.leaseExpires = aiNumber(result['expires']);
      if (this.lease === '' || this.leaseExpires <= Date.now()) { throw new Error('LEASE_REQUIRED'); }
      this.clearTimers(); this.renewTimer = setInterval((): void => { void this.renew(); }, 30000);
      await this.refreshApprovals(); this.changed();
    } catch (error) { this.dropWriter(key, writer); throw new Error((error as Error).message); }
  }
  private async renew(): Promise<void> {
    const client = this.client; const generation = this.generation;
    if (client === null || this.lease === '') { return; }
    try {
      const result = await client.write('lease.renew', aiParams(["sessionId", "lease"], [this.sessionId, this.lease]), this.sessionId);
      this.assertGeneration(generation); this.leaseExpires = aiNumber(result['expires']);
    } catch (error) { if (generation === this.generation) { this.clearTimers(); this.leaseExpires = 0; this.error = aiErrorText((error as Error).message); } }
    this.changed();
  }
  async release(): Promise<void> {
    this.clearTimers(); const client = this.client, session = this.sessionId, lease = this.lease;
    const key = this.key(), writer = this.writerOwners.get(key) ?? '';
    this.lease = ''; this.leaseExpires = 0;
    if (client !== null && lease !== '' && session !== '') {
      try { await client.write('lease.release', aiParams(['sessionId', 'lease'], [session, lease]), session); }
      finally { this.dropWriter(key, writer); }
    }
  }
  async action(method: string, extra: Record<string, Object> = {}): Promise<Record<string, Object>> {
    const client = this.client;
    if (client === null || this.sessionId === '' || this.lease === '' || this.leaseExpires <= Date.now()) { throw new Error('LEASE_REQUIRED'); }
    const generation = this.generation, session = this.sessionId;
    const params: Record<string, Object> = aiParams(["sessionId", "lease"], [session, this.lease]);
    Object.keys(extra).forEach((key: string): void => { params[key] = extra[key]; });
    const statusBefore = this.status;
    try {
      const result = await client.write(method, params, session);
      this.assertGeneration(generation);
      if (method === 'session.archive') { this.archived = true; }
      if (method === 'session.resume') { this.archived = false; }
      // The stream may already have reported the turn (even its end) before the acknowledgement arrived.
      if ((method === 'turn.start' || method === 'session.compact') && this.status === statusBefore) {
        this.status = '请求已接受，等待执行结果';
      }
      return result;
    } finally { if (generation === this.generation) { await this.refreshOperations().catch((): void => {}); this.changed(); } }
  }
  async create(title: string): Promise<void> {
    if (this.client === null || this.projectId === '') { return; }
    const generation = this.generation;
    const result = await this.client.write('session.create', aiParams(["projectId", "title"], [this.projectId, title]));
    this.assertGeneration(generation);
    const id = aiString(result['sessionId']);
    await this.selectProject(this.projectId); await this.selectSession(id); await this.acquire();
  }
  async refreshApprovals(): Promise<void> {
    if (this.client === null || this.sessionId === '') { return; }
    const generation = this.generation;
    const values = await this.client.read('approval.list', aiParams(["sessionId"], [this.sessionId]));
    this.assertGeneration(generation);
    this.approvals = aiArray(values).map((value: Object): AiApproval => {
      const row = aiRecord(value); return { id: aiString(row['id']), request: aiRecord(row['request']), expires: aiNumber(row['expires']) };
    }); this.changed();
  }
  async refreshOperations(): Promise<void> {
    if (this.client === null) { return; }
    const generation = this.generation;
    const operations = await AiLocalStore.getInstance().operations(this.client.account, this.client.host.id);
    this.assertGeneration(generation); this.operations = operations; this.changed();
  }
  async reconcile(id: string): Promise<void> {
    const operation = this.operations.find((value: AiPendingOperation): boolean => value.id === id);
    if (this.client === null || operation === undefined) { return; }
    await this.client.reconcile(operation); await this.refreshOperations();
  }
  async loadModels(): Promise<void> {
    if (this.client === null || !this.client.capability('models')) { return; }
    const generation = this.generation; this.models = []; let cursor = '';
    do {
      const params: Record<string, Object> = aiParams(["projectId"], [this.projectId]);
      if (cursor !== '') { params['cursor'] = cursor; }
      const result = aiRecord(await this.client.read('model.list', params)); this.assertGeneration(generation);
      this.models = this.models.concat(aiArray(result['data']).map((value: Object): Record<string, Object> => aiRecord(value)));
      const next = aiString(result['nextCursor']);
      if (next !== '' && next === cursor) { throw new Error('AI_PAGINATION_INVALID'); } cursor = next;
    } while (cursor !== ''); this.changed();
  }
  async loadDiff(): Promise<void> {
    if (this.client === null) { return; }
    const generation = this.generation;
    const result = aiRecord(await this.client.read('diff.read', aiParams(["sessionId"], [this.sessionId])));
    this.assertGeneration(generation);
    this.diff = result['available'] === true ? aiString(result['diff'], JSON.stringify(result, null, 2)) : '此会话暂无可用的原生差异'; this.changed();
  }
  async loadTerminals(): Promise<void> {
    if (this.client === null) { return; }
    const generation = this.generation; this.terminals = []; let cursor = '';
    do {
      const params: Record<string, Object> = aiParams(["sessionId"], [this.sessionId]);
      if (cursor !== '') { params['cursor'] = cursor; }
      const result = aiRecord(await this.client.read('terminal.list', params));
      this.assertGeneration(generation);
      this.terminals = this.terminals.concat(aiArray(result['data']).map((value: Object): Record<string, Object> => aiRecord(value)));
      const next = aiString(result['nextCursor']);
      if (next !== '' && next === cursor) { throw new Error('AI_PAGINATION_INVALID'); } cursor = next;
    } while (cursor !== ''); this.changed();
  }
  private dropWriter(key: string, writer: string): void {
    AiLifecycle.release(key, writer);
    this.writerUnregister.get(writer)?.(); this.writerUnregister.delete(writer);
    if (this.writerOwners.get(key) === writer) { this.writerOwners.delete(key); }
  }
  private clearTimers(): void {
    if (this.renewTimer >= 0) { clearInterval(this.renewTimer); this.renewTimer = -1; }
    if (this.refreshTimer >= 0) { clearTimeout(this.refreshTimer); this.refreshTimer = -1; }
  }
  close(): void {
    this.generation++; this.streamToken++; this.clearTimers(); this.stopAccess(); this.stopAccess = (): void => {};
    if (this.changeTimer >= 0) { clearTimeout(this.changeTimer); this.changeTimer = -1; }
    this.client?.close(); this.client = null;
    this.writerOwners.forEach((writer: string, key: string): void => { this.dropWriter(key, writer); }); this.lease = ''; this.leaseExpires = 0;
    this.projects = []; this.sessions = []; this.models = []; this.projectId = ''; this.sessionId = '';
    this.title = ''; this.allowed = false; this.accessRevoked = false; this.inputModalities = []; this.historyCursor = ''; this.archived = false; this.busy = false;
    this.transcript.clear(); this.approvals = []; this.diff = ''; this.terminals = []; this.operations = [];
  }
}
