import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { localChatModel } from '@kit.DataAugmentationKit';
import { http } from '@kit.NetworkKit';
import { DiagnosticAiCapturePlanProposal, DiagnosticAiClarifyQuestion, DiagnosticAiEvidenceRef, DiagnosticAiModelInfo, DiagnosticAiModelPriceEntry, DiagnosticAiProviderManifest, DiagnosticAiProviderProfile, DiagnosticAiResult, DiagnosticAiSettingProposal, DiagnosticAiUsageMetadata } from './DiagnosticAiModels';
import { diagnosticAiHarmonyLocalDeviceSupported, diagnosticAiProviderIsHarmonyLocal, diagnosticAiProviderManifest, HARMONY_LOCAL_MODEL_ID } from './DiagnosticAiProviderCatalog';
import { validateDiagnosticAiEndpoint } from './DiagnosticAiEndpointPolicy';
import { diagnosticAiProposalIsSafe, diagnosticAiSettingCatalog } from './DiagnosticAiSettingsActionPolicy';
import { diagnosticFacetCatalog, normalizeDiagnosticFacets, normalizeDiagnosticPlanDuration } from '../DiagnosticCaptureFacetPolicy';
import { diagnosticAiEventGlossary } from './DiagnosticAiEventGlossary';
import { AI_MODE_MODELS, DiagnosticAiRequestLog } from './DiagnosticAiRequestLog';
import { diagnosticAiAppActionCatalog, diagnosticAiAppActionId } from './DiagnosticAiAppActionPolicy';
import { diagnosticAiUseCaseDecision, diagnosticAiUseCaseError } from './DiagnosticAiUseCasePolicy';

const TIMEOUT_MS: number = 15000;
/** A model answering (above all with a capture to read) easily takes longer than connecting does. */
const CHAT_READ_TIMEOUT_MS: number = 90000;
/** @ohos.net.http: "Timeout was reached". */
const HTTP_TIMEOUT_CODE: number = 2300028;
const MAX_RESPONSE_BYTES: number = 2 * 1024 * 1024;
const LOCAL_CHAT_MAX_BYTES: number = 4300;
const LOCAL_CHAT_TIMEOUT_MS: number = 30000;
const LOCAL_MODEL_INIT_TIMEOUT_MS: number = 10000;

function safeText(value: Object | undefined | null, fallback: string = ''): string {
  return typeof value === 'string' ? value as string : fallback;
}

function nonNegativeNumber(value: Object | undefined): number {
  return typeof value === 'number' && isFinite(value as number) ? Math.max(0, Math.round(value as number)) : 0;
}

function nestedNumber(row: Record<string, Object>, parent: string, keys: string[]): number {
  const nested = row[parent] as Record<string, Object>;
  if (nested !== undefined && nested !== null && typeof nested === 'object') {
    for (const key of keys) {
      if (typeof nested[key] === 'number') { return nonNegativeNumber(nested[key]); }
    }
  }
  return 0;
}

function usageMetadata(raw: Record<string, Object>): DiagnosticAiUsageMetadata | undefined {
  const usage = raw['usage'] as Record<string, Object>;
  if (usage === undefined || usage === null || typeof usage !== 'object') { return undefined; }
  const prompt: number = nonNegativeNumber(usage['prompt_tokens'] ?? usage['input_tokens']);
  const completion: number = nonNegativeNumber(usage['completion_tokens'] ?? usage['output_tokens']);
  const cached: number = nonNegativeNumber(usage['cached_tokens'] ?? usage['cache_read_input_tokens']) ||
    nestedNumber(usage, 'prompt_tokens_details', ['cached_tokens', 'cache_read_input_tokens']) ||
    nestedNumber(usage, 'input_tokens_details', ['cached_tokens', 'cache_read_input_tokens']);
  if (prompt === 0 && completion === 0 && cached === 0) { return undefined; }
  return { promptTokens: prompt, completionTokens: completion, cachedTokens: Math.min(prompt, cached) };
}

function priceNumber(row: Record<string, Object>, pricing: Record<string, Object>, keys: string[]): number {
  for (const key of keys) {
    const value: Object | undefined = row[key] ?? pricing[key];
    if (typeof value === 'number' && isFinite(value as number)) { return Math.max(0, value as number); }
  }
  return -1;
}

function responseText(result: Object): string { return typeof result === 'string' ? result as string : JSON.stringify(result); }

function limitUtf8(value: string, maxBytes: number): string {
  const encoder = new util.TextEncoder();
  if (encoder.encode(value).length <= maxBytes) { return value; }
  let result: string = '';
  for (let i = 0; i < value.length; i++) {
    const next: string = result + value.charAt(i);
    if (encoder.encode(next).length > maxBytes) { break; }
    result = next;
  }
  return result;
}

function errorCode(error: Object): string {
  if (error instanceof Error) { return error.message; }
  const row = error as Record<string, Object>;
  return typeof row['code'] === 'number' ? (row['code'] as number).toString() : 'unknown';
}

function assistantContent(value: Object | undefined | null): string {
  if (typeof value === 'string') { return value as string; }
  if (!Array.isArray(value)) { return ''; }
  return (value as Object[]).map((item: Object): string => {
    if (typeof item === 'string') { return item as string; }
    if (item !== null && typeof item === 'object') {
      const row = item as Record<string, Object>;
      return safeText(row['text'], safeText(row['content']));
    }
    return '';
  }).filter((item: string): boolean => item !== '').join('');
}

function responseContent(raw: Record<string, Object>, first: Record<string, Object> | null): string {
  const message = first === null ? null : first['message'] as Record<string, Object>;
  const directMessage = raw['message'] as Record<string, Object>;
  return assistantContent(message === null ? null : message['content']) ||
    assistantContent(first === null ? null : first['text']) ||
    assistantContent(directMessage === undefined ? null : directMessage['content']) ||
    safeText(raw['response']) || safeText(raw['content']) || safeText(raw['output']);
}

function stringArray(value: Object | undefined): string[] {
  return Array.isArray(value) ? (value as Object[]).filter((item: Object): boolean => typeof item === 'string')
    .map((item: Object): string => item as string).slice(0, 32) : [];
}

function evidenceRefs(value: Object | undefined): DiagnosticAiEvidenceRef[] {
  if (!Array.isArray(value)) { return []; }
  return (value as Object[]).slice(0, 64).map((item: Object): DiagnosticAiEvidenceRef | null => {
    const row = item as Record<string, Object>;
    return { captureId: safeText(row['captureId'], 'unknown').slice(0, 128),
      sequence: typeof row['sequence'] === 'number' ? row['sequence'] as number : 0,
      moduleId: safeText(row['moduleId'], 'unknown').slice(0, 64),
      eventCode: safeText(row['eventCode'], 'unknown').slice(0, 128) };
  }).filter((item: DiagnosticAiEvidenceRef | null): boolean => item !== null)
    .map((item: DiagnosticAiEvidenceRef | null): DiagnosticAiEvidenceRef => item as DiagnosticAiEvidenceRef);
}

/** The model's capture plan, kept only with known sub-modules and an allowed duration. */
function safeCapturePlan(value: Object | undefined): DiagnosticAiCapturePlanProposal | undefined {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) { return undefined; }
  const row = value as Record<string, Object>;
  const focus: string[] = normalizeDiagnosticFacets(stringArray(row['focus']).concat(stringArray(row['subModules'])))
    .slice(0, 8);
  if (focus.length === 0) { return undefined; }
  const minutes: number = typeof row['durationMinutes'] === 'number' ? row['durationMinutes'] as number : 3;
  return { focus: focus, durationMinutes: normalizeDiagnosticPlanDuration(minutes),
    steps: stringArray(row['steps']).map((step: string): string => step.slice(0, 200)).slice(0, 4),
    reason: safeText(row['reason']).slice(0, 400) };
}

/** Up to three short questions with two to five short answers each; anything else is dropped. */
function safeClarifyQuestions(value: Object | undefined): DiagnosticAiClarifyQuestion[] | undefined {
  if (!Array.isArray(value)) { return undefined; }
  const questions: DiagnosticAiClarifyQuestion[] = [];
  (value as Object[]).slice(0, 3).forEach((item: Object): void => {
    if (item === null || typeof item !== 'object') { return; }
    const row = item as Record<string, Object>;
    const question: string = safeText(row['question']).slice(0, 60);
    const options: string[] = stringArray(row['options']).map((option: string): string => option.slice(0, 16)).slice(0, 5);
    if (question !== '' && options.length >= 2) { questions.push({ question: question, options: options }); }
  });
  return questions.length > 0 ? questions : undefined;
}

/** How the model asks for logs: a capture plan over the sub-module catalog. */
function capturePlanInstruction(): string {
  return '\n需要日志才能判断问题时（连接失败、黑屏、卡顿、崩溃、同步异常等），填写 capturePlan：' +
    '{"focus":[日志子模块 ID，最多 8 个，只选与问题相关的],"durationMinutes":1/3/5/10,' +
    '"steps":[用户在抓取期间要做的复现步骤，最多 4 条，以动词开头],"reason":一句话说明为什么要抓这些}；' +
    '不需要日志时不要填写。日志子模块目录（ID|名称|覆盖内容）：\n' + diagnosticFacetCatalog();
}

function safeProposals(value: Object | undefined): DiagnosticAiSettingProposal[] {
  if (!Array.isArray(value)) { return []; }
  return (value as Object[]).slice(0, 16).map((item: Object): DiagnosticAiSettingProposal | null => {
    const row = item as Record<string, Object>;
    const proposal: DiagnosticAiSettingProposal = {
      settingId: safeText(row['settingId']).slice(0, 96),
      currentValue: safeText(row['currentValue']).slice(0, 256),
      proposedValue: safeText(row['proposedValue']).slice(0, 256),
      reason: safeText(row['reason']).slice(0, 2000), evidenceRefs: evidenceRefs(row['evidenceRefs']),
      risk: ['low', 'medium', 'high'].indexOf(safeText(row['risk'])) >= 0 ?
        safeText(row['risk']) as 'low' | 'medium' | 'high' : 'low',
      // Every proposal waits for the user's tap in the app, whatever the model wrote here; a model that leaves the
      // field out must not lose its proposals.
      requiresUserConfirmation: true,
      rollbackValue: safeText(row['rollbackValue']).slice(0, 256)
    };
    return diagnosticAiProposalIsSafe(proposal) ? proposal : null;
  }).filter((item: DiagnosticAiSettingProposal | null): boolean => item !== null)
    .map((item: DiagnosticAiSettingProposal | null): DiagnosticAiSettingProposal => item as DiagnosticAiSettingProposal);
}

export interface DiagnosticAiAnalysisInput { question: string; bundle: string; knowledge: string; }
interface DiagnosticAiChatMessage { role: string; content: string; }
interface DiagnosticAiResponseFormat { type: string; }
interface DiagnosticAiChatBody {
  model: string;
  stream: boolean;
  messages: DiagnosticAiChatMessage[];
  response_format?: DiagnosticAiResponseFormat;
}

export interface DiagnosticAiAssistInput {
  mode: 'answer' | 'configure' | 'diagnose' | 'feedback';
  question: string;
  history: string;
  bundle: string;
  knowledge: string;
  assistantContext?: string;
  answerStyle?: string;
}

/**
 * Who the answer is for. Unless the user chose the technical style, the answer solves the problem in plain words and
 * the technical reading goes to developerNotes, which only the developer mail carries.
 */
function answerStyleInstruction(style: string): string {
  if (style === 'technical') {
    return '\n回答风格：用户选择了“技术”风格。summary 第一句先给结论，再给关键技术依据（可以引用事件代码、错误码和时间线）；' +
      'developerNotes 写完整的技术分析。';
  }
  return '\n回答风格：回答对象是普通用户，目的是帮他解决问题。summary 第一句直接说结论（出了什么问题），' +
    '再用一两句白话说最可能的原因和影响；不要出现事件代码、模块 ID、错误码、字段名、证据序号或协议内部术语；' +
    'recommendedReadOnlySteps 只写用户自己能完成的操作；hypotheses 和 unknowns 也用白话，各最多 2 条。' +
    '把技术分析（依据的事件代码、错误码、时间线、推断过程）完整写进 developerNotes，它只会出现在发给开发者的邮件里。';
}

export class DiagnosticAiProviderService {
  private localInit: Promise<boolean> | null = null;
  private localQuestionId: number = 0;

  private async ensureHarmonyLocalModel(): Promise<void> {
    let type: string = 'unknown';
    let api: number = 0;
    try { type = deviceInfo.deviceType; api = deviceInfo.sdkApiVersion; } catch (_error) { /* fail closed */ }
    if (api < 20 || !diagnosticAiHarmonyLocalDeviceSupported(type)) {
      throw new Error('DIAGNOSTIC_AI_LOCAL_MODEL_PC_ONLY');
    }
    if (this.localInit === null) {
      this.localInit = localChatModel.init();
    }
    try {
      const ready: boolean = await this.awaitLocalModelInit(this.localInit);
      if (!ready) { throw new Error('DIAGNOSTIC_AI_LOCAL_MODEL_UNAVAILABLE'); }
    } catch (error) {
      this.localInit = null;
      const message: string = errorCode(error as Object);
      if (message.indexOf('DIAGNOSTIC_AI_') === 0) { throw new Error(message); }
      throw new Error('DIAGNOSTIC_AI_LOCAL_MODEL_INIT_' + message);
    }
  }

  private nextLocalQuestionId(): number {
    this.localQuestionId = (this.localQuestionId + 1) % 65536;
    return this.localQuestionId === 0 ? 1 : this.localQuestionId;
  }

  private async awaitLocalModelInit(pending: Promise<boolean>): Promise<boolean> {
    return await new Promise<boolean>((resolve: (value: boolean) => void,
      reject: (reason?: Object) => void): void => {
      let settled: boolean = false;
      const timer: number = setTimeout((): void => {
        if (settled) { return; }
        settled = true;
        reject(new Error('DIAGNOSTIC_AI_LOCAL_MODEL_INIT_TIMEOUT'));
      }, LOCAL_MODEL_INIT_TIMEOUT_MS);
      pending.then((ready: boolean): void => {
        if (settled) { return; }
        settled = true;
        clearTimeout(timer);
        resolve(ready);
      }).catch((error: Object): void => {
        if (settled) { return; }
        settled = true;
        clearTimeout(timer);
        reject(error);
      });
    });
  }

  private async harmonyLocalChat(content: string): Promise<string> {
    await this.ensureHarmonyLocalModel();
    const questionId: number = this.nextLocalQuestionId();
    const info: localChatModel.QuestionInfo = { questionId, content: limitUtf8(content, LOCAL_CHAT_MAX_BYTES) };
    const config: localChatModel.Config = { isStream: true };
    return await new Promise<string>((resolve: (value: string) => void, reject: (reason?: Object) => void): void => {
      let settled: boolean = false;
      let answerText: string = '';
      let timer: number = setTimeout((): void => {
        if (!settled) { settled = true; reject(new Error('DIAGNOSTIC_AI_LOCAL_MODEL_TIMEOUT')); }
      }, LOCAL_CHAT_TIMEOUT_MS);
      const finishError = (error: Object): void => {
        if (settled) { return; }
        settled = true; clearTimeout(timer);
        const message: string = errorCode(error);
        reject(new Error(message.indexOf('DIAGNOSTIC_AI_') === 0 ? message : 'DIAGNOSTIC_AI_LOCAL_MODEL_' + message));
      };
      const callback = (error: BusinessError, answer: localChatModel.Answer): void => {
        if (settled) { return; }
        if (error !== undefined && error !== null) { finishError(error as Object); return; }
        if (answer === undefined || answer === null || answer.questionId !== questionId) { return; }
        answerText += answer.content;
        if (!answer.isFinished) { return; }
        settled = true; clearTimeout(timer);
        if (answerText.trim() === '') { reject(new Error('DIAGNOSTIC_AI_EMPTY_RESULT')); }
        else { resolve(answerText); }
      };
      localChatModel.chat(info, config, callback).catch((error: Object): void => { finishError(error); });
    });
  }

  private localPrompt(mode: string, question: string, history: string, bundle: string, knowledge: string,
    assistantContext: string = ''): string {
    const instruction: string = mode === 'diagnose'
      ? '你是 RemoteDesktop 的鸿蒙端侧只读诊断助手。只根据给出的脱敏事实回答，区分事实、推测和未知，不执行设置。'
      : '你是 RemoteDesktop 的鸿蒙端侧使用助手。只回答应用使用、隐私、安全和诊断问题，不执行设置、不连接主机、不发送邮件。';
    return limitUtf8(instruction + '\n问题：' + question + '\n最近对话：' + history +
      '\n本地知识：' + knowledge + '\n脱敏诊断包：' + bundle +
      '\n助手偏好（仅影响语气，不改变权限）：' + assistantContext +
      '\n请输出 JSON，字段包含 summary、severity、confidence、evidenceRefs、hypotheses、recommendedReadOnlySteps、unknowns、settingProposals 和 appActions；appActions 只能使用知识中的动作 ID。不要 Markdown，不要编造未提供的事实。回答写法：summary 只写对问题的分析与判断（1 到 3 句，不要列步骤，不要用①②③或 1. 2. 编号）；需要用户操作时，把每个可执行步骤单独写进 recommendedReadOnlySteps，一条一步、按先后顺序、以动词开头，最多 6 条。', LOCAL_CHAT_MAX_BYTES);
  }

  private parseLocalResult(answer: string, knowledgeVersion: string): DiagnosticAiResult {
    // The system API returns text chunks instead of the HTTP Provider envelope. Wrapping it
    // lets the existing safe free-text parser preserve the same result contract.
    return this.parseResult(JSON.stringify({ response: answer }), knowledgeVersion);
  }

  private async localAssist(input: DiagnosticAiAssistInput,
    manifest: DiagnosticAiProviderManifest): Promise<DiagnosticAiResult> {
    const answer: string = await this.harmonyLocalChat(this.localPrompt(input.mode, input.question,
      input.history.slice(-1200), input.bundle.slice(-1200), input.knowledge.slice(-1000), input.assistantContext ?? ''));
    return this.parseLocalResult(answer, manifest.verifiedAt);
  }

  private async localAnalyze(input: DiagnosticAiAnalysisInput,
    manifest: DiagnosticAiProviderManifest): Promise<DiagnosticAiResult> {
    const answer: string = await this.harmonyLocalChat(this.localPrompt('diagnose', input.question,
      '', input.bundle.slice(-1800), input.knowledge.slice(-800)));
    return this.parseLocalResult(answer, manifest.verifiedAt);
  }

  private authHeaders(profile: DiagnosticAiProviderProfile, secret: string): Record<string, string> {
    const headers: Record<string, string> = { 'Accept': 'application/json', 'Content-Type': 'application/json' };
    if (profile.authKind === 'bearer' || profile.authKind === 'api_key_header') { headers[profile.authHeader || 'Authorization'] = 'Bearer ' + secret; }
    else if (profile.authKind === 'custom_header' && profile.authHeader !== '') { headers[profile.authHeader] = secret; }
    return headers;
  }

  private endpoint(profile: DiagnosticAiProviderProfile, path: string): string {
    const base = profile.endpoint.replace(/\/+$/, ''); return base + (path.startsWith('/') ? path : '/' + path);
  }

  private async request(profile: DiagnosticAiProviderProfile, secret: string, path: string,
    body: Object | null): Promise<string> {
    const manifest = diagnosticAiProviderManifest(profile.providerId);
    if (manifest === null) { throw new Error('DIAGNOSTIC_AI_PROVIDER_UNKNOWN'); }
    const policy = diagnosticAiUseCaseDecision(manifest, profile, 'diagnostic_assistant');
    if (!policy.ok) { throw diagnosticAiUseCaseError(policy); }
    const endpoint = this.endpoint(profile, path);
    const decision = validateDiagnosticAiEndpoint(endpoint, manifest.adapterFamily, false);
    if (!decision.ok) { throw new Error('DIAGNOSTIC_AI_ENDPOINT_INVALID'); }
    const client: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: body === null ? http.RequestMethod.GET : http.RequestMethod.POST,
        expectDataType: http.HttpDataType.STRING, usingCache: false, maxRedirects: 0,
        maxLimit: MAX_RESPONSE_BYTES, connectTimeout: TIMEOUT_MS,
        readTimeout: body === null ? TIMEOUT_MS : CHAT_READ_TIMEOUT_MS,
        header: this.authHeaders(profile, secret)
      };
      if (body !== null) { options.extraData = JSON.stringify(body); }
      const response = await client.request(decision.normalized, options);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error('DIAGNOSTIC_AI_HTTP_' + response.responseCode.toString());
      }
      const value = responseText(response.result as Object);
      if (value.length > MAX_RESPONSE_BYTES) { throw new Error('DIAGNOSTIC_AI_RESPONSE_TOO_LARGE'); }
      return value;
    } catch (error) {
      const message = error instanceof Error ? error.message : 'network';
      if (message.startsWith('DIAGNOSTIC_AI_')) { throw new Error(message); }
      const code: number = (error as BusinessError).code ?? 0;
      hilog.warn(0x0000, 'AiAgent', 'request failed code=%{public}s', code.toString());
      if (code === HTTP_TIMEOUT_CODE) { throw new Error('DIAGNOSTIC_AI_TIMEOUT'); }
      throw new Error('DIAGNOSTIC_AI_NETWORK');
    } finally { client.destroy(); }
  }

  /** The provider's model list; also the AI self-check's reachability test (logged as an ai_request of kind 5). */
  async listModels(profile: DiagnosticAiProviderProfile, secret: string): Promise<DiagnosticAiModelInfo[]> {
    const startedAt: number = Date.now();
    try {
      const models: DiagnosticAiModelInfo[] = await this.fetchModels(profile, secret);
      DiagnosticAiRequestLog.record(AI_MODE_MODELS, null, Date.now() - startedAt, 0);
      return models;
    } catch (error) {
      DiagnosticAiRequestLog.record(AI_MODE_MODELS, error as Object, Date.now() - startedAt, 0);
      throw error as Error;
    }
  }

  private async fetchModels(profile: DiagnosticAiProviderProfile, secret: string): Promise<DiagnosticAiModelInfo[]> {
    const manifest = diagnosticAiProviderManifest(profile.providerId);
    if (manifest !== null && diagnosticAiProviderIsHarmonyLocal(profile.providerId)) {
      await this.ensureHarmonyLocalModel();
      return [{ id: HARMONY_LOCAL_MODEL_ID, displayName: '系统管理的鸿蒙端侧模型', providerId: profile.providerId,
        supportsStreaming: true, supportsVision: false, supportsTools: false, fetchedAt: Date.now(), stale: false }];
    }
    if (manifest === null || manifest.modelListPath === '') { throw new Error('DIAGNOSTIC_AI_MODEL_LIST_UNAVAILABLE'); }
    const raw = JSON.parse(await this.request(profile, secret, manifest.modelListPath, null)) as Record<string, Object>;
    const rows: Object[] = Array.isArray(raw['data']) ? raw['data'] as Object[] :
      Array.isArray(raw['models']) ? raw['models'] as Object[] : [];
    const now = Date.now(); const models: DiagnosticAiModelInfo[] = [];
    rows.slice(0, 256).forEach((value: Object): void => {
      const row = value as Record<string, Object>; const id = safeText(row['id'], safeText(row['name']));
      if (id === '' || models.some((item: DiagnosticAiModelInfo): boolean => item.id === id)) { return; }
      models.push({ id, displayName: safeText(row['display_name'], id), providerId: profile.providerId,
        supportsStreaming: manifest.supportsStreaming, supportsVision: manifest.supportsVision,
        supportsTools: manifest.supportsTools, fetchedAt: now, stale: false });
    });
    if (models.length === 0) { throw new Error('DIAGNOSTIC_AI_MODEL_LIST_EMPTY'); }
    return models;
  }

  /**
   * Read the provider's official model-list response and retain any explicitly
   * published CNY-per-million pricing fields. Providers that expose only model
   * IDs still produce rows so the local maintained baseline can keep them in
   * the usage table; no API key is sent to a third-party pricing site.
   */
  async listModelCatalog(profile: DiagnosticAiProviderProfile, secret: string): Promise<DiagnosticAiModelPriceEntry[]> {
    const manifest = diagnosticAiProviderManifest(profile.providerId);
    if (manifest !== null && diagnosticAiProviderIsHarmonyLocal(profile.providerId)) {
      await this.ensureHarmonyLocalModel();
      return [{ providerId: profile.providerId, modelId: HARMONY_LOCAL_MODEL_ID,
        displayName: '鸿蒙端侧小模型', inputCnyPerMillion: 0, outputCnyPerMillion: 0,
        cachedInputCnyPerMillion: 0, source: 'HarmonyOS 端侧模型清单', sourceKind: 'provider', updatedAt: Date.now() }];
    }
    if (manifest === null || manifest.modelListPath === '') { throw new Error('DIAGNOSTIC_AI_MODEL_LIST_UNAVAILABLE'); }
    const raw = JSON.parse(await this.request(profile, secret, manifest.modelListPath, null)) as Record<string, Object>;
    const rows: Object[] = Array.isArray(raw['data']) ? raw['data'] as Object[] :
      Array.isArray(raw['models']) ? raw['models'] as Object[] : [];
    const now: number = Date.now(); const result: DiagnosticAiModelPriceEntry[] = [];
    rows.slice(0, 256).forEach((value: Object): void => {
      const row = value as Record<string, Object>;
      const id: string = safeText(row['id'], safeText(row['name']));
      if (id === '' || result.some((item: DiagnosticAiModelPriceEntry): boolean => item.modelId === id)) { return; }
      const pricing = row['pricing'] as Record<string, Object>;
      const priceRow: Record<string, Object> = pricing === undefined || pricing === null || typeof pricing !== 'object' ? {} : pricing;
      result.push({ providerId: profile.providerId, modelId: id.slice(0, 160), displayName: safeText(row['display_name'], id).slice(0, 160),
        inputCnyPerMillion: priceNumber(row, priceRow, ['input_cny_per_million', 'inputPriceCnyPerMillion', 'prompt_cny_per_million']),
        outputCnyPerMillion: priceNumber(row, priceRow, ['output_cny_per_million', 'outputPriceCnyPerMillion', 'completion_cny_per_million']),
        cachedInputCnyPerMillion: priceNumber(row, priceRow, ['cached_input_cny_per_million', 'cachedPriceCnyPerMillion', 'cache_cny_per_million']),
        source: manifest.displayName + ' /models', sourceKind: 'provider', updatedAt: now });
    });
    if (result.length === 0) { throw new Error('DIAGNOSTIC_AI_MODEL_LIST_EMPTY'); }
    return result;
  }

  async analyze(profile: DiagnosticAiProviderProfile, secret: string, input: DiagnosticAiAnalysisInput): Promise<DiagnosticAiResult> {
    const manifest = diagnosticAiProviderManifest(profile.providerId);
    if (manifest !== null && diagnosticAiProviderIsHarmonyLocal(profile.providerId)) {
      return await this.localAnalyze(input, manifest);
    }
    if (manifest === null || manifest.chatPath === '') { throw new Error('DIAGNOSTIC_AI_ANALYSIS_UNAVAILABLE'); }
    const prompt = '你是 RemoteDesktop 的只读诊断助手。只使用提供的结构化事件和本地知识。' +
      '必须区分事实、假设和未知，不执行任何工具或设置操作。问题：' + input.question +
      '\n本地知识：' + input.knowledge + '\n诊断包：' + input.bundle;
    const messages: DiagnosticAiChatMessage[] = [
      { role: 'system', content: '只输出 JSON，不要 Markdown。字段为 summary、severity(info/low/medium/high/unknown)、confidence(0到1)、evidenceRefs、hypotheses、recommendedReadOnlySteps、unknowns、settingProposals、appActions。appActions 只能使用知识中的动作目录 ID。settingProposals 每项必须使用下方设置目录 ID，包含 currentValue、proposedValue、reason、evidenceRefs、risk、requiresUserConfirmation=true、rollbackValue；只提出白名单且可回滚的设置。设置目录：\n' + diagnosticAiSettingCatalog() + '\n输出简洁、证据优先的诊断建议。回答写法：summary 只写对问题的分析与判断（1 到 3 句，不要列步骤，不要用①②③或 1. 2. 编号）；需要用户操作时，把每个可执行步骤单独写进 recommendedReadOnlySteps，一条一步、按先后顺序、以动词开头，最多 6 条。' },
      { role: 'user', content: prompt }
    ];
    const body: DiagnosticAiChatBody = {
      model: profile.modelId, stream: false,
      messages, response_format: { type: 'json_object' }
    };
    const raw = JSON.parse(await this.request(profile, secret, manifest.chatPath, body)) as Record<string, Object>;
    const usage: DiagnosticAiUsageMetadata | undefined = usageMetadata(raw);
    const choices = Array.isArray(raw['choices']) ? raw['choices'] as Object[] : [];
    let first: Record<string, Object> | null = null;
    if (choices.length > 0) { first = choices[0] as Record<string, Object>; }
    const content = responseContent(raw, first);
    if (content === '') { throw new Error('DIAGNOSTIC_AI_EMPTY_RESULT'); }
    let parsed: Record<string, Object> | null = null;
    try {
      const candidate = JSON.parse(content) as Object;
      if (candidate !== null && typeof candidate === 'object') { parsed = candidate as Record<string, Object>; }
    } catch (_error) { parsed = null; }
    if (parsed === null) {
      return { summary: content.slice(0, 6000), severity: 'unknown', confidence: 0,
        evidenceRefs: [], hypotheses: [], recommendedReadOnlySteps: [], settingProposals: [], appActions: [],
        unknowns: ['Provider 返回的是自由文本，尚未提供结构化证据引用'],
        knowledgeVersion: manifest.verifiedAt, createdAt: Date.now(), usage };
    }
    const severityValue: string = safeText(parsed['severity'], 'unknown');
    const severity = ['info', 'low', 'medium', 'high'].indexOf(severityValue) >= 0 ?
      severityValue as 'info' | 'low' | 'medium' | 'high' : 'unknown';
    const confidenceValue: number = typeof parsed['confidence'] === 'number' ? parsed['confidence'] as number : 0;
    return { summary: safeText(parsed['summary'], content).slice(0, 6000), severity,
      confidence: Math.max(0, Math.min(1, confidenceValue)), evidenceRefs: evidenceRefs(parsed['evidenceRefs']),
      hypotheses: stringArray(parsed['hypotheses']), recommendedReadOnlySteps: stringArray(parsed['recommendedReadOnlySteps']),
      settingProposals: safeProposals(parsed['settingProposals']), unknowns: stringArray(parsed['unknowns']),
      appActions: stringArray(parsed['appActions']).map((value: string): string | null => diagnosticAiAppActionId(value))
        .filter((value: string | null): boolean => value !== null).map((value: string | null): string => value as string).slice(0, 16),
      knowledgeVersion: safeText(parsed['knowledgeVersion'], manifest.verifiedAt).slice(0, 128), createdAt: Date.now(), usage,
      capturePlan: safeCapturePlan(parsed['capturePlan']), developerNotes: safeText(parsed['developerNotes']).slice(0, 6000),
      clarifyQuestions: safeClarifyQuestions(parsed['clarifyQuestions']) };
  }

  /**
   * General in-app Agent request. This path intentionally does not require a capture bundle:
   * ordinary usage questions and safe setting requests should receive an answer immediately.
   * A structured response is preferred, but several OpenAI-compatible domestic endpoints reject
   * response_format, so the same request is retried once without that optional field.
   */
  async assist(profile: DiagnosticAiProviderProfile, secret: string, input: DiagnosticAiAssistInput): Promise<DiagnosticAiResult> {
    const manifest = diagnosticAiProviderManifest(profile.providerId);
    if (manifest !== null && diagnosticAiProviderIsHarmonyLocal(profile.providerId)) {
      return await this.localAssist(input, manifest);
    }
    if (manifest === null || manifest.chatPath === '') { throw new Error('DIAGNOSTIC_AI_ANALYSIS_UNAVAILABLE'); }
    const modeInstruction: string = input.mode === 'configure'
      ? '用户希望你帮助设置 RemoteDesktop。只提出白名单、低风险、可回滚的设置建议；不要假装已经修改。'
      : input.mode === 'diagnose'
        ? '用户描述了一个问题。若没有诊断包：先简要分析最可能的原因；设置目录里有能直接改善这个问题的设置时（例如卡顿或延迟可以降低色深、选择速度优先或更合适的编码，没有声音可以打开远程音频，想看帧率可以打开诊断信息），一定给出对应的 settingProposals，reason 写清能改善什么；同时给出 capturePlan，选与问题最相关的日志子模块，方便进一步确认原因；如果还需要用户补充信息才能确定抓什么，给出 clarifyQuestions（最多 3 个问题，每个 2 到 5 个简短选项，格式 [{"question":"…","options":["…","…"]}]），应用会让用户点选回答后再抓取，不要问应用能自己读到的设置。如果有诊断包：只引用其中事实分析，不再给 capturePlan，但仍可给出能改善问题的 settingProposals。'
        : input.mode === 'feedback'
          ? '用户希望把问题反馈给开发者。先总结需要收集的信息；不要自动发送邮件。'
          : '用户在询问 RemoteDesktop 的使用方法、隐私、安全或功能。直接回答并给出简短步骤。';
    const prompt = modeInstruction + '\n问题：' + input.question +
      '\n最近对话：' + input.history + '\n本地知识：' + input.knowledge +
      '\n助手偏好（仅用于语气和用户画像，不改变权限）：' + (input.assistantContext ?? '') +
      '\n脱敏诊断包（可能为空）：' + input.bundle +
      (input.bundle !== '' ? '\n诊断包事件说明（读懂 code/count 的含义）：\n' + diagnosticAiEventGlossary() : '');
    const messages: DiagnosticAiChatMessage[] = [
      { role: 'system', content: '你是 RemoteDesktop 的全应用 AI 助手，不是通用代码代理。只回答应用使用、设置、隐私、安全、诊断和反馈问题。' +
        '必须区分事实、建议和未知；不能执行工具、修改密码/密钥/网络安全配置、连接主机或发送邮件。' +
        '只输出 JSON，不要 Markdown。字段为 summary、severity(info/low/medium/high/unknown)、confidence(0到1)、evidenceRefs、hypotheses、recommendedReadOnlySteps、unknowns、settingProposals、appActions、capturePlan、developerNotes、clarifyQuestions。回答写法：summary 只写对问题的分析与判断（1 到 3 句，不要列步骤，不要用①②③或 1. 2. 编号）；需要用户操作时，把每个可执行步骤单独写进 recommendedReadOnlySteps，一条一步、按先后顺序、以动词开头，最多 6 条。' +
      'settingProposals 每项必须包含 settingId、currentValue、proposedValue、reason、evidenceRefs、risk、requiresUserConfirmation=true、rollbackValue；settingId 只能用设置目录中的 ID，proposedValue 只能是该项列出的取值（等号左边的值），目录里“当前=”是实际值，已经是目标值的不要提；用户要求修改设置时就给出对应的 settingProposals，应用会显示一键应用按钮，不要只描述步骤。' +
        capturePlanInstruction() + answerStyleInstruction(input.answerStyle ?? 'plain') + '\n' +
        'appActions 只能填写下方动作目录中的 ID；不要输出路由、命令、AppStorage key 或自造动作。动作目录：\n' + diagnosticAiAppActionCatalog() +
        '\n设置目录：\n' + diagnosticAiSettingCatalog() },
      { role: 'user', content: prompt }
    ];
    const body: DiagnosticAiChatBody = { model: profile.modelId, stream: false, messages,
      response_format: { type: 'json_object' } };
    let rawText: string;
    try {
      rawText = await this.request(profile, secret, manifest.chatPath, body);
    } catch (error) {
      const message = error instanceof Error ? error.message : '';
      if (message.indexOf('DIAGNOSTIC_AI_HTTP_400') < 0 && message.indexOf('DIAGNOSTIC_AI_HTTP_415') < 0 &&
          message.indexOf('DIAGNOSTIC_AI_HTTP_422') < 0) { throw new Error(message); }
      const fallbackBody: DiagnosticAiChatBody = { model: profile.modelId, stream: false, messages };
      rawText = await this.request(profile, secret, manifest.chatPath, fallbackBody);
    }
    return this.parseResult(rawText, manifest.verifiedAt);
  }

  private parseResult(rawText: string, knowledgeVersion: string): DiagnosticAiResult {
    const raw = JSON.parse(rawText) as Record<string, Object>;
    const usage: DiagnosticAiUsageMetadata | undefined = usageMetadata(raw);
    const choices = Array.isArray(raw['choices']) ? raw['choices'] as Object[] : [];
    let first: Record<string, Object> | null = null;
    if (choices.length > 0) { first = choices[0] as Record<string, Object>; }
    let content = responseContent(raw, first);
    if (content.indexOf('```') === 0) {
      content = content.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '').trim();
    }
    if (content === '') { throw new Error('DIAGNOSTIC_AI_EMPTY_RESULT'); }
    let parsed: Record<string, Object> | null = null;
    try {
      const candidate = JSON.parse(content) as Object;
      if (candidate !== null && typeof candidate === 'object') { parsed = candidate as Record<string, Object>; }
    } catch (_error) { parsed = null; }
    if (parsed === null) {
      return { summary: content.slice(0, 6000), severity: 'unknown', confidence: 0,
        evidenceRefs: [], hypotheses: [], recommendedReadOnlySteps: [], settingProposals: [], appActions: [],
        unknowns: ['Provider 返回的是自由文本，已显示原文但没有结构化证据引用'],
        knowledgeVersion, createdAt: Date.now(), usage };
    }
    const severityValue: string = safeText(parsed['severity'], 'unknown');
    const severity = ['info', 'low', 'medium', 'high'].indexOf(severityValue) >= 0 ?
      severityValue as 'info' | 'low' | 'medium' | 'high' : 'unknown';
    const confidenceValue: number = typeof parsed['confidence'] === 'number' ? parsed['confidence'] as number : 0;
    return { summary: safeText(parsed['summary'], content).slice(0, 6000), severity,
      confidence: Math.max(0, Math.min(1, confidenceValue)), evidenceRefs: evidenceRefs(parsed['evidenceRefs']),
      hypotheses: stringArray(parsed['hypotheses']), recommendedReadOnlySteps: stringArray(parsed['recommendedReadOnlySteps']),
      settingProposals: safeProposals(parsed['settingProposals']), unknowns: stringArray(parsed['unknowns']),
      appActions: stringArray(parsed['appActions']).map((value: string): string | null => diagnosticAiAppActionId(value))
        .filter((value: string | null): boolean => value !== null).map((value: string | null): string => value as string).slice(0, 16),
      knowledgeVersion: safeText(parsed['knowledgeVersion'], knowledgeVersion).slice(0, 128), createdAt: Date.now(), usage,
      capturePlan: safeCapturePlan(parsed['capturePlan']), developerNotes: safeText(parsed['developerNotes']).slice(0, 6000),
      clarifyQuestions: safeClarifyQuestions(parsed['clarifyQuestions']) };
  }
}

export function diagnosticAiPrivacySummary(profile: DiagnosticAiProviderProfile): string {
  const privacy = profile.privacy;
  return '数据地区：' + (privacy.region === 'unknown' ? '待确认' : privacy.region) +
    ' · 留存：' + (privacy.retention === 'unknown' ? '待确认' : privacy.retention) +
    ' · 训练用途：' + (privacy.trainingUse === 'unknown' ? '待确认' : privacy.trainingUse);
}
