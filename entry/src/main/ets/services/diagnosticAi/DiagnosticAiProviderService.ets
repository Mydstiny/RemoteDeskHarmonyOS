import { http } from '@kit.NetworkKit';
import { DiagnosticAiEvidenceRef, DiagnosticAiModelInfo, DiagnosticAiProviderManifest, DiagnosticAiProviderProfile, DiagnosticAiResult, DiagnosticAiSettingProposal } from './DiagnosticAiModels';
import { diagnosticAiProviderManifest } from './DiagnosticAiProviderCatalog';
import { validateDiagnosticAiEndpoint } from './DiagnosticAiEndpointPolicy';
import { diagnosticAiProposalIsSafe } from './DiagnosticAiSettingsActionPolicy';

const TIMEOUT_MS: number = 15000;
const MAX_RESPONSE_BYTES: number = 2 * 1024 * 1024;

function safeText(value: Object | undefined | null, fallback: string = ''): string {
  return typeof value === 'string' ? value as string : fallback;
}

function responseText(result: Object): string { return typeof result === 'string' ? result as string : JSON.stringify(result); }

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
        safeText(row['risk']) as 'low' | 'medium' | 'high' : 'high',
      requiresUserConfirmation: row['requiresUserConfirmation'] === true,
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
}

export class DiagnosticAiProviderService {
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
    const endpoint = this.endpoint(profile, path);
    const decision = validateDiagnosticAiEndpoint(endpoint, manifest.adapterFamily, false);
    if (!decision.ok) { throw new Error('DIAGNOSTIC_AI_ENDPOINT_INVALID'); }
    const client: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: body === null ? http.RequestMethod.GET : http.RequestMethod.POST,
        expectDataType: http.HttpDataType.STRING, usingCache: false, maxRedirects: 0,
        maxLimit: MAX_RESPONSE_BYTES, connectTimeout: TIMEOUT_MS, readTimeout: TIMEOUT_MS,
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
      throw new Error('DIAGNOSTIC_AI_NETWORK');
    } finally { client.destroy(); }
  }

  async listModels(profile: DiagnosticAiProviderProfile, secret: string): Promise<DiagnosticAiModelInfo[]> {
    const manifest = diagnosticAiProviderManifest(profile.providerId);
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

  async analyze(profile: DiagnosticAiProviderProfile, secret: string, input: DiagnosticAiAnalysisInput): Promise<DiagnosticAiResult> {
    const manifest = diagnosticAiProviderManifest(profile.providerId);
    if (manifest === null || manifest.chatPath === '') { throw new Error('DIAGNOSTIC_AI_ANALYSIS_UNAVAILABLE'); }
    const prompt = '你是 RemoteDesktop 的只读诊断助手。只使用提供的结构化事件和本地知识。' +
      '必须区分事实、假设和未知，不执行任何工具或设置操作。问题：' + input.question +
      '\n本地知识：' + input.knowledge + '\n诊断包：' + input.bundle;
    const messages: DiagnosticAiChatMessage[] = [
      { role: 'system', content: '只输出 JSON，不要 Markdown。字段为 summary、severity(info/low/medium/high/unknown)、confidence(0到1)、evidenceRefs、hypotheses、recommendedReadOnlySteps、unknowns、settingProposals。settingProposals 每项必须包含 settingId、currentValue、proposedValue、reason、evidenceRefs、risk、requiresUserConfirmation=true、rollbackValue。只提出白名单且可回滚的设置。输出简洁、证据优先的诊断建议。' },
      { role: 'user', content: prompt }
    ];
    const body: DiagnosticAiChatBody = {
      model: profile.modelId, stream: false,
      messages, response_format: { type: 'json_object' }
    };
    const raw = JSON.parse(await this.request(profile, secret, manifest.chatPath, body)) as Record<string, Object>;
    const choices = Array.isArray(raw['choices']) ? raw['choices'] as Object[] : [];
    let first: Record<string, Object> | null = null;
    if (choices.length > 0) { first = choices[0] as Record<string, Object>; }
    const message = first === null ? null : first['message'] as Record<string, Object>;
    const content = assistantContent(message === null ? null : message['content']) ||
      assistantContent(first === null ? null : first['text']) || assistantContent(raw['output']);
    if (content === '') { throw new Error('DIAGNOSTIC_AI_EMPTY_RESULT'); }
    let parsed: Record<string, Object> | null = null;
    try {
      const candidate = JSON.parse(content) as Object;
      if (candidate !== null && typeof candidate === 'object') { parsed = candidate as Record<string, Object>; }
    } catch (_error) { parsed = null; }
    if (parsed === null) {
      return { summary: content.slice(0, 6000), severity: 'unknown', confidence: 0,
        evidenceRefs: [], hypotheses: [], recommendedReadOnlySteps: [], settingProposals: [],
        unknowns: ['Provider 返回的是自由文本，尚未提供结构化证据引用'],
        knowledgeVersion: manifest.verifiedAt, createdAt: Date.now() };
    }
    const severityValue: string = safeText(parsed['severity'], 'unknown');
    const severity = ['info', 'low', 'medium', 'high'].indexOf(severityValue) >= 0 ?
      severityValue as 'info' | 'low' | 'medium' | 'high' : 'unknown';
    const confidenceValue: number = typeof parsed['confidence'] === 'number' ? parsed['confidence'] as number : 0;
    return { summary: safeText(parsed['summary'], content).slice(0, 6000), severity,
      confidence: Math.max(0, Math.min(1, confidenceValue)), evidenceRefs: evidenceRefs(parsed['evidenceRefs']),
      hypotheses: stringArray(parsed['hypotheses']), recommendedReadOnlySteps: stringArray(parsed['recommendedReadOnlySteps']),
      settingProposals: safeProposals(parsed['settingProposals']), unknowns: stringArray(parsed['unknowns']),
      knowledgeVersion: safeText(parsed['knowledgeVersion'], manifest.verifiedAt).slice(0, 128), createdAt: Date.now() };
  }

  /**
   * General in-app Agent request. This path intentionally does not require a capture bundle:
   * ordinary usage questions and safe setting requests should receive an answer immediately.
   * A structured response is preferred, but several OpenAI-compatible domestic endpoints reject
   * response_format, so the same request is retried once without that optional field.
   */
  async assist(profile: DiagnosticAiProviderProfile, secret: string, input: DiagnosticAiAssistInput): Promise<DiagnosticAiResult> {
    const manifest = diagnosticAiProviderManifest(profile.providerId);
    if (manifest === null || manifest.chatPath === '') { throw new Error('DIAGNOSTIC_AI_ANALYSIS_UNAVAILABLE'); }
    const modeInstruction: string = input.mode === 'configure'
      ? '用户希望你帮助设置 RemoteDesktop。只提出白名单、低风险、可回滚的设置建议；不要假装已经修改。'
      : input.mode === 'diagnose'
        ? '用户希望诊断问题。若没有诊断包，只说明需要用户确认抓取；如果有诊断包，只引用其中事实。'
        : input.mode === 'feedback'
          ? '用户希望把问题反馈给开发者。先总结需要收集的信息；不要自动发送邮件。'
          : '用户在询问 RemoteDesktop 的使用方法、隐私、安全或功能。直接回答并给出简短步骤。';
    const prompt = modeInstruction + '\n问题：' + input.question +
      '\n最近对话：' + input.history + '\n本地知识：' + input.knowledge +
      '\n脱敏诊断包（可能为空）：' + input.bundle;
    const messages: DiagnosticAiChatMessage[] = [
      { role: 'system', content: '你是 RemoteDesktop 的全应用 AI 助手，不是通用代码代理。只回答应用使用、设置、隐私、安全、诊断和反馈问题。' +
        '必须区分事实、建议和未知；不能执行工具、修改密码/密钥/网络安全配置、连接主机或发送邮件。' +
        '只输出 JSON，不要 Markdown。字段为 summary、severity(info/low/medium/high/unknown)、confidence(0到1)、evidenceRefs、hypotheses、recommendedReadOnlySteps、unknowns、settingProposals。' +
        'settingProposals 每项必须包含 settingId、currentValue、proposedValue、reason、evidenceRefs、risk、requiresUserConfirmation=true、rollbackValue；只提出应用白名单中的可回滚设置。' },
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
    const choices = Array.isArray(raw['choices']) ? raw['choices'] as Object[] : [];
    let first: Record<string, Object> | null = null;
    if (choices.length > 0) { first = choices[0] as Record<string, Object>; }
    const message = first === null ? null : first['message'] as Record<string, Object>;
    let content = assistantContent(message === null ? null : message['content']) ||
      assistantContent(first === null ? null : first['text']) || assistantContent(raw['output']);
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
        evidenceRefs: [], hypotheses: [], recommendedReadOnlySteps: [], settingProposals: [],
        unknowns: ['Provider 返回的是自由文本，已显示原文但没有结构化证据引用'],
        knowledgeVersion, createdAt: Date.now() };
    }
    const severityValue: string = safeText(parsed['severity'], 'unknown');
    const severity = ['info', 'low', 'medium', 'high'].indexOf(severityValue) >= 0 ?
      severityValue as 'info' | 'low' | 'medium' | 'high' : 'unknown';
    const confidenceValue: number = typeof parsed['confidence'] === 'number' ? parsed['confidence'] as number : 0;
    return { summary: safeText(parsed['summary'], content).slice(0, 6000), severity,
      confidence: Math.max(0, Math.min(1, confidenceValue)), evidenceRefs: evidenceRefs(parsed['evidenceRefs']),
      hypotheses: stringArray(parsed['hypotheses']), recommendedReadOnlySteps: stringArray(parsed['recommendedReadOnlySteps']),
      settingProposals: safeProposals(parsed['settingProposals']), unknowns: stringArray(parsed['unknowns']),
      knowledgeVersion: safeText(parsed['knowledgeVersion'], knowledgeVersion).slice(0, 128), createdAt: Date.now() };
  }
}

export function diagnosticAiPrivacySummary(profile: DiagnosticAiProviderProfile): string {
  const privacy = profile.privacy;
  return '数据地区：' + (privacy.region === 'unknown' ? '待确认' : privacy.region) +
    ' · 留存：' + (privacy.retention === 'unknown' ? '待确认' : privacy.retention) +
    ' · 训练用途：' + (privacy.trainingUse === 'unknown' ? '待确认' : privacy.trainingUse);
}
