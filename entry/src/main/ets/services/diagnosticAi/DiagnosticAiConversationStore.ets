import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export interface DiagnosticAiConversationTurn {
  question: string;
  answer: string;
  mode: string;
  createdAt: number;
  /** 聊天模式: names of the documents the user added with this question. */
  attachments?: string[];
  /** 聊天模式: documents the AI wrote in this answer (still on the device unless deleted). */
  documents?: DiagnosticAiTurnDocument[];
}

export interface DiagnosticAiTurnDocument {
  name: string;
  format: string;
  path: string;
  bytes: number;
}

/** 助理 (about the app: settings, diagnosis) or 聊天 (a general chat with document tools). */
export type DiagnosticAiSessionKind = 'assistant' | 'chat';

export interface DiagnosticAiConversationSession {
  id: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  /** Provider/model used by the session so continuing it does not silently switch subscriptions. */
  providerId: string;
  modelId: string;
  turns: DiagnosticAiConversationTurn[];
  /** Missing on sessions saved before 聊天模式: those are 助理 sessions. */
  kind?: DiagnosticAiSessionKind;
}

export function diagnosticAiSessionKind(session: DiagnosticAiConversationSession): DiagnosticAiSessionKind {
  return session.kind === 'chat' ? 'chat' : 'assistant';
}

export interface DiagnosticAiUsageSnapshot {
  requestCount: number;
  promptTokens: number;
  completionTokens: number;
  cachedTokens: number;
  estimatedCostCny: number;
  updatedAt: number;
  providerUsage: DiagnosticAiProviderUsage[];
  /** Requests that failed (no tokens are known for them). */
  failedCount?: number;
  /** Answered requests whose tokens were estimated locally (the provider returned no usage). */
  estimatedCount?: number;
  /** One row per day (local date), newest first, at most 30. */
  daily?: DiagnosticAiDailyUsage[];
  /** The part of the totals that came from 聊天模式. */
  chatRequestCount?: number;
  chatTokens?: number;
  chatCostCny?: number;
}

/** Usage of one local day, all subscriptions together and per subscription. */
export interface DiagnosticAiDailyUsage {
  day: string;
  requestCount: number;
  failedCount: number;
  promptTokens: number;
  completionTokens: number;
  cachedTokens: number;
  estimatedCostCny: number;
  /** Per subscription for that day (providerId + '\u001f' + modelId → tokens/requests/cost). */
  providers: DiagnosticAiDailyProviderUsage[];
}

export interface DiagnosticAiDailyProviderUsage {
  key: string;
  requestCount: number;
  failedCount: number;
  promptTokens: number;
  completionTokens: number;
  cachedTokens: number;
  estimatedCostCny: number;
}

export interface DiagnosticAiProviderUsage {
  providerId: string;
  modelId: string;
  requestCount: number;
  promptTokens: number;
  completionTokens: number;
  cachedTokens: number;
  estimatedCostCny: number;
  updatedAt: number;
  failedCount?: number;
  estimatedCount?: number;
}

export interface DiagnosticAiAssistantPreferences {
  name: string;
  personality: 'balanced' | 'warm' | 'concise' | 'technical';
  verbosity: 'concise' | 'standard' | 'detailed';
  role: 'remote-expert' | 'beginner-guide' | 'diagnostic-first' | 'privacy-first';
  language: 'zh-CN' | 'en-US';
  memoryEnabled: boolean;
  /** Summary generated locally from saved conversation turns. */
  memorySummary: string;
  /** Optional user-authored memory, kept separate from the generated summary. */
  manualMemorySummary: string;
  proactiveSuggestions: boolean;
  confirmBeforeActions: boolean;
  updatedAt: number;
}

export function defaultDiagnosticAiAssistantPreferences(): DiagnosticAiAssistantPreferences {
  return { name: 'RD Assistant', personality: 'balanced', verbosity: 'standard', role: 'remote-expert', language: 'zh-CN',
    memoryEnabled: true, memorySummary: '', manualMemorySummary: '', proactiveSuggestions: true, confirmBeforeActions: true, updatedAt: 0 };
}

export function defaultDiagnosticAiUsageSnapshot(): DiagnosticAiUsageSnapshot {
  return { requestCount: 0, promptTokens: 0, completionTokens: 0, cachedTokens: 0, estimatedCostCny: 0, updatedAt: 0, providerUsage: [],
    failedCount: 0, estimatedCount: 0, daily: [], chatRequestCount: 0, chatTokens: 0, chatCostCny: 0 };
}

/** The local calendar day of a time, as YYYY-MM-DD. */
export function diagnosticAiUsageDay(time: number): string {
  const date: Date = new Date(time);
  const pad = (value: number): string => (value < 10 ? '0' : '') + value.toString();
  return date.getFullYear().toString() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate());
}

function safeCount(value: Object | undefined): number {
  const n: number = Number(value);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

function parseDaily(value: Object | undefined): DiagnosticAiDailyUsage[] {
  if (!Array.isArray(value)) { return []; }
  return (value as Object[]).slice(0, 30).map((item: Object): DiagnosticAiDailyUsage => {
    const row = item as Record<string, Object>;
    const providers: DiagnosticAiDailyProviderUsage[] = Array.isArray(row['providers']) ?
      (row['providers'] as Object[]).slice(0, 16).map((p: Object): DiagnosticAiDailyProviderUsage => {
        const r = p as Record<string, Object>;
        return { key: typeof r['key'] === 'string' ? (r['key'] as string).slice(0, 200) : '',
          requestCount: safeCount(r['requestCount']), failedCount: safeCount(r['failedCount']),
          promptTokens: safeCount(r['promptTokens']), completionTokens: safeCount(r['completionTokens']),
          cachedTokens: safeCount(r['cachedTokens']), estimatedCostCny: safeCount(r['estimatedCostCny']) };
      }) : [];
    return { day: typeof row['day'] === 'string' ? (row['day'] as string).slice(0, 10) : '',
      requestCount: safeCount(row['requestCount']), failedCount: safeCount(row['failedCount']),
      promptTokens: safeCount(row['promptTokens']), completionTokens: safeCount(row['completionTokens']),
      cachedTokens: safeCount(row['cachedTokens']), estimatedCostCny: safeCount(row['estimatedCostCny']), providers: providers };
  }).filter((row: DiagnosticAiDailyUsage): boolean => row.day.length === 10);
}

function scopeKey(owner: string): string {
  const normalized = owner.trim() === '' ? 'device-local' : owner.trim();
  return normalized.replace(/[^A-Za-z0-9_-]/g, '_').slice(-64);
}

function cloneDocuments(value: DiagnosticAiTurnDocument[] | undefined): DiagnosticAiTurnDocument[] | undefined {
  if (!Array.isArray(value) || value.length === 0) { return undefined; }
  return value.slice(0, 8).map((doc: DiagnosticAiTurnDocument): DiagnosticAiTurnDocument => ({
    name: typeof doc.name === 'string' ? doc.name.slice(0, 120) : '', format: typeof doc.format === 'string' ? doc.format.slice(0, 8) : '',
    path: typeof doc.path === 'string' ? doc.path.slice(0, 512) : '', bytes: Number(doc.bytes) || 0 }));
}

function cloneSession(value: DiagnosticAiConversationSession): DiagnosticAiConversationSession {
  const chat: boolean = value.kind === 'chat';
  const keep: number = chat ? 40 : 20;
  return { id: value.id, title: value.title, createdAt: value.createdAt, updatedAt: value.updatedAt,
    providerId: typeof value.providerId === 'string' ? value.providerId.slice(0, 64) : '',
    modelId: typeof value.modelId === 'string' ? value.modelId.slice(0, 128) : '',
    kind: chat ? 'chat' : 'assistant',
    // A chat answer may be a long piece of writing; it keeps more of it.
    turns: value.turns.slice(0 - keep).map((turn: DiagnosticAiConversationTurn): DiagnosticAiConversationTurn => ({
      question: turn.question.slice(0, chat ? 8000 : 4000), answer: turn.answer.slice(0, chat ? 12000 : 6000), mode: turn.mode,
      createdAt: turn.createdAt,
      attachments: Array.isArray(turn.attachments) && turn.attachments.length > 0 ?
        turn.attachments.slice(0, 8).map((name: string): string => String(name).slice(0, 120)) : undefined,
      documents: cloneDocuments(turn.documents)
    })) };
}

/** Local-only, owner-scoped conversation history, assistant preferences and usage accounting. */
export class DiagnosticAiConversationStore {
  private context: common.Context | null = null;
  private owner: string = 'device-local';
  private prefsName: string = '';

  init(context: common.Context, owner: string): void {
    this.context = context; this.owner = owner.trim() === '' ? 'device-local' : owner.trim();
    this.prefsName = 'RemoteDeskDiagnosticAiConversation-' + scopeKey(this.owner);
  }

  private prefs(): preferences.Preferences | null {
    if (this.context === null) { return null; }
    try { return preferences.getPreferencesSync(this.context, { name: this.prefsName }); }
    catch (_error) { return null; }
  }

  listSessions(): DiagnosticAiConversationSession[] {
    const store = this.prefs(); if (store === null) { return []; }
    try {
      const rows = JSON.parse(store.getSync('sessions', '[]') as string) as DiagnosticAiConversationSession[];
      return Array.isArray(rows) ? rows.slice(0, 50).map((row: DiagnosticAiConversationSession): DiagnosticAiConversationSession => cloneSession(row)) : [];
    } catch (_error) { return []; }
  }

  session(id: string): DiagnosticAiConversationSession | undefined {
    return this.listSessions().find((item: DiagnosticAiConversationSession): boolean => item.id === id);
  }

  saveSession(session: DiagnosticAiConversationSession): boolean {
    const store = this.prefs(); if (store === null) { return false; }
    const rows = this.listSessions().filter((item: DiagnosticAiConversationSession): boolean => item.id !== session.id);
    rows.unshift(cloneSession(session));
    try { store.putSync('sessions', JSON.stringify(rows.slice(0, 50))); store.flushSync(); return true; }
    catch (_error) { return false; }
  }

  /**
   * Produce a bounded, deterministic local summary from recent sessions. This
   * deliberately does not call a Provider: it is only a compact memory index
   * for the user to review and the next request to reference.
   */
  summarizedSessionMemory(kind: DiagnosticAiSessionKind = 'assistant'): string {
    // 助理 and 聊天 remember separately: chats never feed the app assistant, nor the reverse.
    const rows: DiagnosticAiConversationSession[] = this.listSessions()
      .filter((session: DiagnosticAiConversationSession): boolean => diagnosticAiSessionKind(session) === kind).slice(0, 8);
    if (rows.length === 0) { return ''; }
    const lines: string[] = ['最近会话摘要（自动生成，仅保存在本机）：'];
    rows.forEach((session: DiagnosticAiConversationSession): void => {
      const latest: DiagnosticAiConversationTurn | undefined = session.turns.length === 0 ? undefined : session.turns[session.turns.length - 1];
      const title: string = (session.title || '未命名会话').replace(/[\r\n]+/g, ' ').trim().slice(0, 80);
      const question: string = latest === undefined ? '' : latest.question.replace(/[\r\n]+/g, ' ').trim().slice(0, 140);
      const answer: string = latest === undefined ? '' : latest.answer.replace(/[\r\n]+/g, ' ').trim().slice(0, 180);
      const detail: string = question === '' ? '' : '：' + question + (answer === '' ? '' : ' → ' + answer);
      lines.push('• ' + title + detail);
    });
    return lines.join('\n').slice(0, 3200);
  }

  /** Generated and manual memory are kept distinct in storage but joined only
   * at the request boundary. */
  memoryContext(kind: DiagnosticAiSessionKind = 'assistant'): string {
    const prefs = this.assistantPreferences();
    const generated: string = this.summarizedSessionMemory(kind);
    const manual: string = prefs.manualMemorySummary.trim() !== '' ? prefs.manualMemorySummary.trim() :
      (prefs.memorySummary.trim() !== '' && generated === '' ? prefs.memorySummary.trim() : '');
    return [generated, manual].filter((value: string): boolean => value !== '').join('\n用户补充偏好：').slice(0, 4000);
  }

  usage(): DiagnosticAiUsageSnapshot {
    const store = this.prefs(); if (store === null) { return defaultDiagnosticAiUsageSnapshot(); }
    try {
      const value = JSON.parse(store.getSync('usage', '{}') as string) as DiagnosticAiUsageSnapshot;
      return { requestCount: Number(value.requestCount) || 0, promptTokens: Number(value.promptTokens) || 0,
        completionTokens: Number(value.completionTokens) || 0, cachedTokens: Number(value.cachedTokens) || 0,
        estimatedCostCny: Number(value.estimatedCostCny) || 0, updatedAt: Number(value.updatedAt) || 0,
        providerUsage: Array.isArray(value.providerUsage) ? (value.providerUsage as DiagnosticAiProviderUsage[]).slice(0, 32).map((item: DiagnosticAiProviderUsage): DiagnosticAiProviderUsage => ({
          providerId: typeof item.providerId === 'string' ? item.providerId.slice(0, 64) : '',
          modelId: typeof item.modelId === 'string' ? item.modelId.slice(0, 128) : '',
          requestCount: Number(item.requestCount) || 0, promptTokens: Number(item.promptTokens) || 0,
          completionTokens: Number(item.completionTokens) || 0, cachedTokens: Number(item.cachedTokens) || 0,
          estimatedCostCny: Number(item.estimatedCostCny) || 0, updatedAt: Number(item.updatedAt) || 0,
          failedCount: Number(item.failedCount) || 0, estimatedCount: Number(item.estimatedCount) || 0
        })) : [],
        failedCount: Number(value.failedCount) || 0, estimatedCount: Number(value.estimatedCount) || 0,
        daily: parseDaily(value.daily as Object), chatRequestCount: Number(value.chatRequestCount) || 0,
        chatTokens: Number(value.chatTokens) || 0, chatCostCny: Number(value.chatCostCny) || 0 };
    } catch (_error) { return defaultDiagnosticAiUsageSnapshot(); }
  }

  /**
   * One answered request: tokens (from the provider, or estimated locally when it returned none) and the estimated
   * cost, added to the totals, to its subscription and to today's row.
   */
  recordUsage(promptTokens: number, completionTokens: number, cachedTokens: number, estimatedCostCny: number,
    providerId: string = '', modelId: string = '', estimated: boolean = false, chat: boolean = false): boolean {
    return this.addUsage(false, Math.max(0, Math.round(promptTokens)), Math.max(0, Math.round(completionTokens)),
      Math.max(0, Math.round(cachedTokens)), Math.max(0, estimatedCostCny), providerId, modelId, estimated, chat);
  }

  /** A request that failed: counted as a failure for its subscription and today, without tokens. */
  recordFailure(providerId: string, modelId: string): boolean {
    return this.addUsage(true, 0, 0, 0, 0, providerId, modelId, false);
  }

  private addUsage(failed: boolean, prompt: number, completion: number, cached: number, cost: number,
    providerId: string, modelId: string, estimated: boolean, chat: boolean = false): boolean {
    const store = this.prefs(); if (store === null) { return false; }
    const previous = this.usage();
    const now: number = Date.now();
    const providerRows: DiagnosticAiProviderUsage[] = previous.providerUsage.slice();
    const key: string = providerId.trim() + '\u001f' + modelId.trim();
    if (providerId.trim() !== '') {
      let row: DiagnosticAiProviderUsage | undefined = providerRows.find((item: DiagnosticAiProviderUsage): boolean =>
        item.providerId + '\u001f' + item.modelId === key);
      if (row === undefined) {
        row = { providerId: providerId.trim().slice(0, 64), modelId: modelId.trim().slice(0, 128), requestCount: 0,
          promptTokens: 0, completionTokens: 0, cachedTokens: 0, estimatedCostCny: 0, updatedAt: now, failedCount: 0,
          estimatedCount: 0 };
        providerRows.unshift(row);
      }
      if (failed) { row.failedCount = (row.failedCount ?? 0) + 1; } else { row.requestCount += 1; }
      row.promptTokens += prompt; row.completionTokens += completion; row.cachedTokens += cached;
      row.estimatedCostCny += cost; row.updatedAt = now;
      if (estimated) { row.estimatedCount = (row.estimatedCount ?? 0) + 1; }
    }
    const today: string = diagnosticAiUsageDay(now);
    const daily: DiagnosticAiDailyUsage[] = (previous.daily ?? []).slice();
    let day: DiagnosticAiDailyUsage | undefined = daily.find((item: DiagnosticAiDailyUsage): boolean => item.day === today);
    if (day === undefined) {
      day = { day: today, requestCount: 0, failedCount: 0, promptTokens: 0, completionTokens: 0, cachedTokens: 0,
        estimatedCostCny: 0, providers: [] };
      daily.unshift(day);
    }
    if (failed) { day.failedCount += 1; } else { day.requestCount += 1; }
    day.promptTokens += prompt; day.completionTokens += completion; day.cachedTokens += cached; day.estimatedCostCny += cost;
    if (providerId.trim() !== '') {
      let p: DiagnosticAiDailyProviderUsage | undefined = day.providers.find((item: DiagnosticAiDailyProviderUsage): boolean =>
        item.key === key);
      if (p === undefined) {
        p = { key: key, requestCount: 0, failedCount: 0, promptTokens: 0, completionTokens: 0, cachedTokens: 0, estimatedCostCny: 0 };
        day.providers.push(p);
      }
      if (failed) { p.failedCount += 1; } else { p.requestCount += 1; }
      p.promptTokens += prompt; p.completionTokens += completion; p.cachedTokens += cached; p.estimatedCostCny += cost;
    }
    const next: DiagnosticAiUsageSnapshot = {
      requestCount: previous.requestCount + (failed ? 0 : 1),
      promptTokens: previous.promptTokens + prompt,
      completionTokens: previous.completionTokens + completion,
      cachedTokens: previous.cachedTokens + cached,
      estimatedCostCny: previous.estimatedCostCny + cost, updatedAt: now,
      providerUsage: providerRows.slice(0, 32),
      failedCount: (previous.failedCount ?? 0) + (failed ? 1 : 0),
      estimatedCount: (previous.estimatedCount ?? 0) + (estimated ? 1 : 0),
      daily: daily.sort((a: DiagnosticAiDailyUsage, b: DiagnosticAiDailyUsage): number => a.day < b.day ? 1 : -1).slice(0, 30),
      chatRequestCount: (previous.chatRequestCount ?? 0) + (chat && !failed ? 1 : 0),
      chatTokens: (previous.chatTokens ?? 0) + (chat ? prompt + completion : 0),
      chatCostCny: (previous.chatCostCny ?? 0) + (chat ? cost : 0)
    };
    try { store.putSync('usage', JSON.stringify(next)); store.flushSync(); return true; }
    catch (_error) { return false; }
  }

  /** Forget the usage history (totals, subscriptions and days). */
  clearUsage(): boolean {
    const store = this.prefs(); if (store === null) { return false; }
    try { store.putSync('usage', JSON.stringify(defaultDiagnosticAiUsageSnapshot())); store.flushSync(); return true; }
    catch (_error) { return false; }
  }

  deleteSession(id: string): boolean {
    const store = this.prefs(); if (store === null) { return false; }
    const rows = this.listSessions().filter((item: DiagnosticAiConversationSession): boolean => item.id !== id);
    try { store.putSync('sessions', JSON.stringify(rows)); store.flushSync(); return true; }
    catch (_error) { return false; }
  }

  /** Forget saved sessions: all of them, or only 助理's or only 聊天's. */
  clearSessions(kind: string = ''): boolean {
    const store = this.prefs(); if (store === null) { return false; }
    const kept: DiagnosticAiConversationSession[] = kind === '' ? [] : this.listSessions()
      .filter((session: DiagnosticAiConversationSession): boolean => diagnosticAiSessionKind(session) !== kind);
    try { store.putSync('sessions', JSON.stringify(kept)); store.flushSync(); return true; }
    catch (_error) { return false; }
  }

  assistantPreferences(): DiagnosticAiAssistantPreferences {
    const store = this.prefs(); if (store === null) { return defaultDiagnosticAiAssistantPreferences(); }
    try {
      const value = JSON.parse(store.getSync('assistant', '{}') as string) as DiagnosticAiAssistantPreferences;
      const allowed: string[] = ['balanced', 'warm', 'concise', 'technical'];
      const verbosity: string[] = ['concise', 'standard', 'detailed'];
      const roles: string[] = ['remote-expert', 'beginner-guide', 'diagnostic-first', 'privacy-first'];
      const languages: string[] = ['zh-CN', 'en-US'];
      const storedMemory: string = typeof value.memorySummary === 'string' ? value.memorySummary.slice(0, 4000) : '';
      const storedManualMemory: string = typeof value.manualMemorySummary === 'string' ? value.manualMemorySummary.slice(0, 4000) : '';
      const storedName: string = typeof value.name === 'string' ? value.name.trim() : '';
      return { name: storedName !== '' && storedName !== '小远' ? storedName.slice(0, 32) : 'RD Assistant',
        personality: allowed.indexOf(value.personality) >= 0 ? value.personality : 'balanced',
        verbosity: verbosity.indexOf(value.verbosity) >= 0 ? value.verbosity : 'standard',
        role: roles.indexOf(value.role) >= 0 ? value.role : 'remote-expert',
        language: languages.indexOf(value.language) >= 0 ? value.language : 'zh-CN',
        memoryEnabled: value.memoryEnabled !== false, memorySummary: storedMemory,
        // Builds before the generated summary existed stored the user's text in
        // memorySummary. Treat it as manual input during the one-way migration.
        manualMemorySummary: storedManualMemory !== '' ? storedManualMemory : storedMemory,
        proactiveSuggestions: value.proactiveSuggestions !== false, confirmBeforeActions: value.confirmBeforeActions !== false,
        updatedAt: Number(value.updatedAt) || 0 };
    } catch (_error) { return defaultDiagnosticAiAssistantPreferences(); }
  }

  saveAssistantPreferences(value: DiagnosticAiAssistantPreferences): boolean {
    const store = this.prefs(); if (store === null) { return false; }
    try { store.putSync('assistant', JSON.stringify({ name: value.name.slice(0, 32), personality: value.personality,
      verbosity: value.verbosity, role: value.role, language: value.language, memoryEnabled: value.memoryEnabled,
      memorySummary: value.memorySummary.slice(0, 4000), manualMemorySummary: value.manualMemorySummary.slice(0, 4000),
      proactiveSuggestions: value.proactiveSuggestions,
      confirmBeforeActions: value.confirmBeforeActions, updatedAt: Date.now() }));
      store.flushSync(); return true;
    } catch (_error) { return false; }
  }
}
