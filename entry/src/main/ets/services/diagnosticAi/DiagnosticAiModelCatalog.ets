import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { DiagnosticAiModelPriceEntry } from './DiagnosticAiModels';

/**
 * The app keeps a small, reviewable baseline so usage estimates remain useful
 * when a Provider's /models endpoint exposes model IDs but no prices. Values
 * are CNY per million tokens and are labelled as estimates in the UI.
 */
const MAINTAINED_UPDATED_AT: number = Date.parse('2026-10-02T00:00:00Z');
const MAINTAINED_SOURCE: string = 'RemoteDesktop 本地维护基线（估算）';
const MAINTAINED: DiagnosticAiModelPriceEntry[] = [
  { providerId: 'deepseek', modelId: 'deepseek-chat', displayName: 'DeepSeek Chat', inputCnyPerMillion: 1, outputCnyPerMillion: 2, cachedInputCnyPerMillion: 0.25, source: MAINTAINED_SOURCE, sourceKind: 'maintained', updatedAt: MAINTAINED_UPDATED_AT },
  { providerId: 'deepseek', modelId: 'deepseek-reasoner', displayName: 'DeepSeek Reasoner', inputCnyPerMillion: 4, outputCnyPerMillion: 16, cachedInputCnyPerMillion: 1, source: MAINTAINED_SOURCE, sourceKind: 'maintained', updatedAt: MAINTAINED_UPDATED_AT },
  { providerId: 'qwen', modelId: 'qwen-turbo', displayName: 'Qwen Turbo', inputCnyPerMillion: 0.3, outputCnyPerMillion: 0.6, cachedInputCnyPerMillion: 0.06, source: MAINTAINED_SOURCE, sourceKind: 'maintained', updatedAt: MAINTAINED_UPDATED_AT },
  { providerId: 'qwen', modelId: 'qwen-plus', displayName: 'Qwen Plus', inputCnyPerMillion: 0.8, outputCnyPerMillion: 2, cachedInputCnyPerMillion: 0.16, source: MAINTAINED_SOURCE, sourceKind: 'maintained', updatedAt: MAINTAINED_UPDATED_AT },
  { providerId: 'qwen', modelId: 'qwen-max', displayName: 'Qwen Max', inputCnyPerMillion: 2.4, outputCnyPerMillion: 9.6, cachedInputCnyPerMillion: 0.48, source: MAINTAINED_SOURCE, sourceKind: 'maintained', updatedAt: MAINTAINED_UPDATED_AT },
  { providerId: 'zhipu', modelId: 'glm-4-plus', displayName: 'GLM-4-Plus', inputCnyPerMillion: 50, outputCnyPerMillion: 50, cachedInputCnyPerMillion: 10, source: MAINTAINED_SOURCE, sourceKind: 'maintained', updatedAt: MAINTAINED_UPDATED_AT },
  { providerId: 'zhipu', modelId: 'glm-4-air', displayName: 'GLM-4-Air', inputCnyPerMillion: 1, outputCnyPerMillion: 1, cachedInputCnyPerMillion: 0.2, source: MAINTAINED_SOURCE, sourceKind: 'maintained', updatedAt: MAINTAINED_UPDATED_AT },
  { providerId: 'kimi', modelId: 'moonshot-v1-8k', displayName: 'Moonshot V1 8K', inputCnyPerMillion: 5, outputCnyPerMillion: 5, cachedInputCnyPerMillion: 1, source: MAINTAINED_SOURCE, sourceKind: 'maintained', updatedAt: MAINTAINED_UPDATED_AT },
  { providerId: 'kimi', modelId: 'moonshot-v1-32k', displayName: 'Moonshot V1 32K', inputCnyPerMillion: 9, outputCnyPerMillion: 9, cachedInputCnyPerMillion: 1.8, source: MAINTAINED_SOURCE, sourceKind: 'maintained', updatedAt: MAINTAINED_UPDATED_AT },
  { providerId: 'siliconflow', modelId: 'deepseek-ai/DeepSeek-V3', displayName: 'DeepSeek-V3（硅基流动）', inputCnyPerMillion: 2, outputCnyPerMillion: 8, cachedInputCnyPerMillion: 0.4, source: MAINTAINED_SOURCE, sourceKind: 'maintained', updatedAt: MAINTAINED_UPDATED_AT },
  { providerId: 'doubao', modelId: 'doubao-1.5-pro-32k', displayName: '豆包 1.5 Pro 32K', inputCnyPerMillion: 0.8, outputCnyPerMillion: 2, cachedInputCnyPerMillion: 0.16, source: MAINTAINED_SOURCE, sourceKind: 'maintained', updatedAt: MAINTAINED_UPDATED_AT },
  { providerId: 'wenxin', modelId: 'ernie-4.0-turbo-8k', displayName: '文心 ERNIE 4.0 Turbo', inputCnyPerMillion: 12, outputCnyPerMillion: 12, cachedInputCnyPerMillion: 2.4, source: MAINTAINED_SOURCE, sourceKind: 'maintained', updatedAt: MAINTAINED_UPDATED_AT },
  { providerId: 'spark', modelId: 'generalv3.5', displayName: '讯飞星火 V3.5', inputCnyPerMillion: 0, outputCnyPerMillion: 0, cachedInputCnyPerMillion: 0, source: MAINTAINED_SOURCE, sourceKind: 'maintained', updatedAt: MAINTAINED_UPDATED_AT },
  { providerId: 'ollama', modelId: '*', displayName: 'Ollama 本机模型', inputCnyPerMillion: 0, outputCnyPerMillion: 0, cachedInputCnyPerMillion: 0, source: '本机推理，无 Provider Token 费用', sourceKind: 'maintained', updatedAt: MAINTAINED_UPDATED_AT },
  { providerId: 'harmony_local_chat', modelId: 'harmonyos-system-local-chat', displayName: '鸿蒙端侧小模型', inputCnyPerMillion: 0, outputCnyPerMillion: 0, cachedInputCnyPerMillion: 0, source: 'HarmonyOS 端侧推理，无云端 Token 费用', sourceKind: 'maintained', updatedAt: MAINTAINED_UPDATED_AT }
];

function scopeKey(owner: string): string {
  const normalized: string = owner.trim() === '' ? 'device-local' : owner.trim();
  return normalized.replace(/[^A-Za-z0-9_-]/g, '_').slice(-64);
}

function clone(value: DiagnosticAiModelPriceEntry): DiagnosticAiModelPriceEntry {
  return { providerId: value.providerId, modelId: value.modelId, displayName: value.displayName,
    inputCnyPerMillion: value.inputCnyPerMillion, outputCnyPerMillion: value.outputCnyPerMillion,
    cachedInputCnyPerMillion: value.cachedInputCnyPerMillion, source: value.source,
    sourceKind: value.sourceKind, updatedAt: value.updatedAt };
}

function validNumber(value: Object | undefined): number {
  return typeof value === 'number' && isFinite(value as number) ? value as number : -1;
}

/** Owner-scoped maintained model/pricing table. API keys never enter this store. */
export class DiagnosticAiModelCatalog {
  private context: common.Context | null = null;
  private owner: string = 'device-local';
  private prefsName: string = '';
  private rows: DiagnosticAiModelPriceEntry[] = [];
  private loaded: boolean = false;

  init(context: common.Context, owner: string): void {
    this.context = context; this.owner = owner.trim() === '' ? 'device-local' : owner.trim();
    this.prefsName = 'RemoteDeskDiagnosticAiModelCatalog-' + scopeKey(this.owner);
    this.loaded = false; this.load();
  }

  private load(): void {
    if (this.loaded) { return; }
    this.rows = MAINTAINED.map((value: DiagnosticAiModelPriceEntry): DiagnosticAiModelPriceEntry => clone(value));
    if (this.context !== null) {
      try {
        const store = preferences.getPreferencesSync(this.context, { name: this.prefsName });
        const stored = JSON.parse(store.getSync('rows', '[]') as string) as DiagnosticAiModelPriceEntry[];
        if (Array.isArray(stored)) { this.mergeRows(stored, false); }
      } catch (_error) { /* baseline remains available */ }
    }
    this.loaded = true;
  }

  private mergeRows(incoming: DiagnosticAiModelPriceEntry[], persist: boolean): number {
    let changed: number = 0;
    incoming.slice(0, 256).forEach((row: DiagnosticAiModelPriceEntry): void => {
      if (typeof row.providerId !== 'string' || row.providerId.trim() === '' ||
        typeof row.modelId !== 'string' || row.modelId.trim() === '') { return; }
      const providerId: string = row.providerId.trim().slice(0, 64);
      const modelId: string = row.modelId.trim().slice(0, 160);
      const index: number = this.rows.findIndex((item: DiagnosticAiModelPriceEntry): boolean =>
        item.providerId === providerId && item.modelId === modelId);
      const current: DiagnosticAiModelPriceEntry | undefined = index >= 0 ? this.rows[index] : undefined;
      const next: DiagnosticAiModelPriceEntry = {
        providerId, modelId, displayName: typeof row.displayName === 'string' && row.displayName !== '' ? row.displayName.slice(0, 160) : modelId,
        inputCnyPerMillion: validNumber(row.inputCnyPerMillion), outputCnyPerMillion: validNumber(row.outputCnyPerMillion),
        cachedInputCnyPerMillion: validNumber(row.cachedInputCnyPerMillion),
        source: typeof row.source === 'string' ? row.source.slice(0, 240) : 'Provider 模型列表',
        sourceKind: row.sourceKind === 'provider' ? 'provider' : 'maintained', updatedAt: Number(row.updatedAt) || Date.now()
      };
      // An endpoint often returns only model IDs. Keep a maintained price when
      // the response does not contain a usable price field.
      if (current !== undefined) {
        if (next.inputCnyPerMillion < 0) { next.inputCnyPerMillion = current.inputCnyPerMillion; }
        if (next.outputCnyPerMillion < 0) { next.outputCnyPerMillion = current.outputCnyPerMillion; }
        if (next.cachedInputCnyPerMillion < 0) { next.cachedInputCnyPerMillion = current.cachedInputCnyPerMillion; }
        this.rows[index] = next;
      } else {
        this.rows.push(next);
      }
      changed++;
    });
    if (persist && this.context !== null) {
      try {
        const store = preferences.getPreferencesSync(this.context, { name: this.prefsName });
        store.putSync('rows', JSON.stringify(this.rows.slice(0, 256))); store.flushSync();
      } catch (_error) { /* caller still receives the in-memory result */ }
    }
    return changed;
  }

  list(providerId: string = ''): DiagnosticAiModelPriceEntry[] {
    this.load();
    return this.rows.filter((value: DiagnosticAiModelPriceEntry): boolean => providerId.trim() === '' || value.providerId === providerId)
      .map((value: DiagnosticAiModelPriceEntry): DiagnosticAiModelPriceEntry => clone(value));
  }

  priceFor(providerId: string, modelId: string): DiagnosticAiModelPriceEntry | undefined {
    this.load();
    return this.rows.find((value: DiagnosticAiModelPriceEntry): boolean => value.providerId === providerId && value.modelId === modelId) ??
      this.rows.find((value: DiagnosticAiModelPriceEntry): boolean => value.providerId === providerId && value.modelId === '*');
  }

  /** Merge an official/provider model-list response and persist it per account. */
  updateFromProvider(rows: DiagnosticAiModelPriceEntry[]): number {
    this.load(); return this.mergeRows(rows, true);
  }

  estimateCost(providerId: string, modelId: string, promptTokens: number, completionTokens: number, cachedTokens: number): number {
    const price = this.priceFor(providerId, modelId);
    const prompt: number = Math.max(0, Math.round(promptTokens));
    const completion: number = Math.max(0, Math.round(completionTokens));
    const cached: number = Math.min(prompt, Math.max(0, Math.round(cachedTokens)));
    if (price === undefined || price.inputCnyPerMillion < 0 || price.outputCnyPerMillion < 0) {
      return (prompt + completion) / 1000000 * 0.3;
    }
    const inputRate: number = Math.max(0, price.inputCnyPerMillion);
    const cachedRate: number = price.cachedInputCnyPerMillion < 0 ? inputRate : Math.max(0, price.cachedInputCnyPerMillion);
    return ((prompt - cached) * inputRate + cached * cachedRate + completion * Math.max(0, price.outputCnyPerMillion)) / 1000000;
  }
}

export function maintainedDiagnosticAiModelPrices(): DiagnosticAiModelPriceEntry[] {
  return MAINTAINED.map((value: DiagnosticAiModelPriceEntry): DiagnosticAiModelPriceEntry => clone(value));
}
