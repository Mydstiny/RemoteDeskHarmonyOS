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
  turns: DiagnosticAiConversationTurn[];
}

export interface DiagnosticAiUsageSnapshot {
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
  memoryEnabled: boolean;
  memorySummary: string;
  updatedAt: number;
}

export function defaultDiagnosticAiAssistantPreferences(): DiagnosticAiAssistantPreferences {
  return { name: '小远', personality: 'balanced', memoryEnabled: true, memorySummary: '', updatedAt: 0 };
}

export function defaultDiagnosticAiUsageSnapshot(): DiagnosticAiUsageSnapshot {
  return { requestCount: 0, promptTokens: 0, completionTokens: 0, cachedTokens: 0, estimatedCostCny: 0, updatedAt: 0 };
}

function scopeKey(owner: string): string {
  const normalized = owner.trim() === '' ? 'device-local' : owner.trim();
  return normalized.replace(/[^A-Za-z0-9_-]/g, '_').slice(-64);
}

function cloneSession(value: DiagnosticAiConversationSession): DiagnosticAiConversationSession {
  return { id: value.id, title: value.title, createdAt: value.createdAt, updatedAt: value.updatedAt,
    turns: value.turns.map((turn: DiagnosticAiConversationTurn): DiagnosticAiConversationTurn => ({
      question: turn.question, answer: turn.answer, mode: turn.mode, createdAt: turn.createdAt
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

  usage(): DiagnosticAiUsageSnapshot {
    const store = this.prefs(); if (store === null) { return defaultDiagnosticAiUsageSnapshot(); }
    try {
      const value = JSON.parse(store.getSync('usage', '{}') as string) as DiagnosticAiUsageSnapshot;
      return { requestCount: Number(value.requestCount) || 0, promptTokens: Number(value.promptTokens) || 0,
        completionTokens: Number(value.completionTokens) || 0, cachedTokens: Number(value.cachedTokens) || 0,
        estimatedCostCny: Number(value.estimatedCostCny) || 0, updatedAt: Number(value.updatedAt) || 0 };
    } catch (_error) { return defaultDiagnosticAiUsageSnapshot(); }
  }

  recordUsage(promptTokens: number, completionTokens: number, cachedTokens: number, estimatedCostCny: number): boolean {
    const store = this.prefs(); if (store === null) { return false; }
    const previous = this.usage();
    const next: DiagnosticAiUsageSnapshot = {
      requestCount: previous.requestCount + 1,
      promptTokens: previous.promptTokens + Math.max(0, Math.round(promptTokens)),
      completionTokens: previous.completionTokens + Math.max(0, Math.round(completionTokens)),
      cachedTokens: previous.cachedTokens + Math.max(0, Math.round(cachedTokens)),
      estimatedCostCny: previous.estimatedCostCny + Math.max(0, estimatedCostCny), updatedAt: Date.now()
    };
    try { store.putSync('usage', JSON.stringify(next)); store.flushSync(); return true; }
    catch (_error) { return false; }
  }

  assistantPreferences(): DiagnosticAiAssistantPreferences {
    const store = this.prefs(); if (store === null) { return defaultDiagnosticAiAssistantPreferences(); }
    try {
      const value = JSON.parse(store.getSync('assistant', '{}') as string) as DiagnosticAiAssistantPreferences;
      const allowed: string[] = ['balanced', 'warm', 'concise', 'technical'];
      return { name: typeof value.name === 'string' && value.name.trim() !== '' ? value.name.slice(0, 32) : '小远',
        personality: allowed.indexOf(value.personality) >= 0 ? value.personality : 'balanced',
        memoryEnabled: value.memoryEnabled !== false, memorySummary: typeof value.memorySummary === 'string' ? value.memorySummary.slice(0, 4000) : '',
        updatedAt: Number(value.updatedAt) || 0 };
    } catch (_error) { return defaultDiagnosticAiAssistantPreferences(); }
  }

  saveAssistantPreferences(value: DiagnosticAiAssistantPreferences): boolean {
    const store = this.prefs(); if (store === null) { return false; }
    try { store.putSync('assistant', JSON.stringify({ name: value.name.slice(0, 32), personality: value.personality,
      memoryEnabled: value.memoryEnabled, memorySummary: value.memorySummary.slice(0, 4000), updatedAt: Date.now() }));
      store.flushSync(); return true;
    } catch (_error) { return false; }
  }
}
