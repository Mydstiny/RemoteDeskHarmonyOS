import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export interface DiagnosticAiConversationTurn {
  question: string;
  answer: string;
  mode: string;
  createdAt: number;
}

export interface DiagnosticAiConversationSession {
  id: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  /** Provider/model used by the session so continuing it does not silently switch subscriptions. */
  providerId: string;
  modelId: string;
  turns: DiagnosticAiConversationTurn[];
}

export interface DiagnosticAiUsageSnapshot {
  requestCount: number;
  promptTokens: number;
  completionTokens: number;
  cachedTokens: number;
  estimatedCostCny: number;
  updatedAt: number;
  providerUsage: DiagnosticAiProviderUsage[];
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
  return { requestCount: 0, promptTokens: 0, completionTokens: 0, cachedTokens: 0, estimatedCostCny: 0, updatedAt: 0, providerUsage: [] };
}

function scopeKey(owner: string): string {
  const normalized = owner.trim() === '' ? 'device-local' : owner.trim();
  return normalized.replace(/[^A-Za-z0-9_-]/g, '_').slice(-64);
}

function cloneSession(value: DiagnosticAiConversationSession): DiagnosticAiConversationSession {
  return { id: value.id, title: value.title, createdAt: value.createdAt, updatedAt: value.updatedAt,
    providerId: typeof value.providerId === 'string' ? value.providerId.slice(0, 64) : '',
    modelId: typeof value.modelId === 'string' ? value.modelId.slice(0, 128) : '',
    turns: value.turns.slice(-20).map((turn: DiagnosticAiConversationTurn): DiagnosticAiConversationTurn => ({
      question: turn.question.slice(0, 4000), answer: turn.answer.slice(0, 6000), mode: turn.mode, createdAt: turn.createdAt
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
  summarizedSessionMemory(): string {
    const rows: DiagnosticAiConversationSession[] = this.listSessions().slice(0, 8);
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
  memoryContext(): string {
    const prefs = this.assistantPreferences();
    const generated: string = this.summarizedSessionMemory();
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
          estimatedCostCny: Number(item.estimatedCostCny) || 0, updatedAt: Number(item.updatedAt) || 0
        })) : [] };
    } catch (_error) { return defaultDiagnosticAiUsageSnapshot(); }
  }

  recordUsage(promptTokens: number, completionTokens: number, cachedTokens: number, estimatedCostCny: number,
    providerId: string = '', modelId: string = ''): boolean {
    const store = this.prefs(); if (store === null) { return false; }
    const previous = this.usage();
    const providerRows: DiagnosticAiProviderUsage[] = previous.providerUsage.slice();
    const providerKey: string = providerId.trim() + '\u001f' + modelId.trim();
    if (providerId.trim() !== '') {
      const existing: DiagnosticAiProviderUsage | undefined = providerRows.find((item: DiagnosticAiProviderUsage): boolean =>
        item.providerId + '\u001f' + item.modelId === providerKey);
      if (existing === undefined) {
        providerRows.unshift({ providerId: providerId.trim().slice(0, 64), modelId: modelId.trim().slice(0, 128),
          requestCount: 1, promptTokens: Math.max(0, Math.round(promptTokens)), completionTokens: Math.max(0, Math.round(completionTokens)),
          cachedTokens: Math.max(0, Math.round(cachedTokens)), estimatedCostCny: Math.max(0, estimatedCostCny), updatedAt: Date.now() });
      } else {
        existing.requestCount += 1; existing.promptTokens += Math.max(0, Math.round(promptTokens));
        existing.completionTokens += Math.max(0, Math.round(completionTokens)); existing.cachedTokens += Math.max(0, Math.round(cachedTokens));
        existing.estimatedCostCny += Math.max(0, estimatedCostCny); existing.updatedAt = Date.now();
      }
    }
    const next: DiagnosticAiUsageSnapshot = {
      requestCount: previous.requestCount + 1,
      promptTokens: previous.promptTokens + Math.max(0, Math.round(promptTokens)),
      completionTokens: previous.completionTokens + Math.max(0, Math.round(completionTokens)),
      cachedTokens: previous.cachedTokens + Math.max(0, Math.round(cachedTokens)),
      estimatedCostCny: previous.estimatedCostCny + Math.max(0, estimatedCostCny), updatedAt: Date.now(),
      providerUsage: providerRows.slice(0, 32)
    };
    try { store.putSync('usage', JSON.stringify(next)); store.flushSync(); return true; }
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
