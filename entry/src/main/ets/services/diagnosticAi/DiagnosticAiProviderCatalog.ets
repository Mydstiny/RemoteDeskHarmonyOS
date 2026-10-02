import { DiagnosticAiProviderManifest, DiagnosticAiDeviceType } from './DiagnosticAiModels';

export const HARMONY_LOCAL_PROVIDER_ID: string = 'harmony_local_chat';
export const HARMONY_LOCAL_MODEL_ID: string = 'harmonyos-system-local-chat';

/**
 * The first catalog is intentionally conservative. URLs and capability claims
 * are versioned data and must be rechecked against the provider's current
 * official contract before changing a manifest from optional to verified.
 */
const PROVIDERS: DiagnosticAiProviderManifest[] = [
  {
    schemaVersion: 1, providerId: 'deepseek', displayName: 'DeepSeek', market: 'mainland-cn',
    adapterFamily: 'openai_compatible_http', endpoint: 'https://api.deepseek.com', modelListPath: '/models', chatPath: '/chat/completions',
    authKind: 'bearer', authHeader: 'Authorization', authModes: ['api_key'], billingMode: 'payg_api',
    allowedUseCases: ['diagnostic_assistant'], requiresInteractive: false, requiresOfficialTool: false,
    entitlementEndpoint: '', termsVersion: '2026-10-02', dataRegion: 'mainland_cn', codingPlanModelIds: [], supportsStreaming: true,
    supportsVision: false, supportsTools: false,
    privacy: { region: 'mainland', retention: 'unknown', trainingUse: 'unknown', policyRef: 'https://api-docs.deepseek.com/' }, verifiedAt: '2026-10-02'
  },
  {
    schemaVersion: 1, providerId: 'qwen', displayName: '通义千问 / Qwen', market: 'mainland-cn',
    adapterFamily: 'openai_compatible_http', endpoint: 'https://dashscope.aliyuncs.com/compatible-mode/v1', modelListPath: '/models', chatPath: '/chat/completions',
    authKind: 'bearer', authHeader: 'Authorization', authModes: ['api_key'], billingMode: 'payg_api',
    allowedUseCases: ['diagnostic_assistant'], requiresInteractive: false, requiresOfficialTool: false,
    entitlementEndpoint: '', termsVersion: '2026-10-02', dataRegion: 'mainland_cn', codingPlanModelIds: [], supportsStreaming: true,
    supportsVision: true, supportsTools: true,
    privacy: { region: 'mainland', retention: 'unknown', trainingUse: 'unknown', policyRef: 'https://help.aliyun.com/zh/model-studio/' }, verifiedAt: ''
  },
  {
    schemaVersion: 1, providerId: 'zhipu', displayName: '智谱 GLM', market: 'mainland-cn',
    adapterFamily: 'openai_compatible_http', endpoint: 'https://open.bigmodel.cn/api/paas/v4', modelListPath: '/models', chatPath: '/chat/completions',
    authKind: 'bearer', authHeader: 'Authorization', authModes: ['api_key'], billingMode: 'payg_api',
    allowedUseCases: ['diagnostic_assistant'], requiresInteractive: false, requiresOfficialTool: false,
    entitlementEndpoint: '', termsVersion: '2026-10-02', dataRegion: 'mainland_cn', codingPlanModelIds: [], supportsStreaming: true,
    supportsVision: true, supportsTools: true,
    privacy: { region: 'mainland', retention: 'unknown', trainingUse: 'unknown', policyRef: 'https://open.bigmodel.cn/dev/api' }, verifiedAt: ''
  },
  {
    schemaVersion: 1, providerId: 'kimi', displayName: '月之暗面 / Kimi', market: 'mainland-cn',
    adapterFamily: 'openai_compatible_http', endpoint: 'https://api.moonshot.cn/v1', modelListPath: '/models', chatPath: '/chat/completions',
    authKind: 'bearer', authHeader: 'Authorization', authModes: ['api_key'], billingMode: 'payg_api',
    allowedUseCases: ['diagnostic_assistant'], requiresInteractive: false, requiresOfficialTool: false,
    entitlementEndpoint: '', termsVersion: '2026-10-02', dataRegion: 'mainland_cn', codingPlanModelIds: [], supportsStreaming: true,
    supportsVision: true, supportsTools: false,
    privacy: { region: 'mainland', retention: 'unknown', trainingUse: 'unknown', policyRef: 'https://platform.moonshot.cn/docs' }, verifiedAt: ''
  },
  {
    schemaVersion: 1, providerId: 'siliconflow', displayName: '硅基流动', market: 'mainland-cn',
    adapterFamily: 'openai_compatible_http', endpoint: 'https://api.siliconflow.cn/v1', modelListPath: '/models', chatPath: '/chat/completions',
    authKind: 'bearer', authHeader: 'Authorization', authModes: ['api_key'], billingMode: 'payg_api',
    allowedUseCases: ['diagnostic_assistant'], requiresInteractive: false, requiresOfficialTool: false,
    entitlementEndpoint: '', termsVersion: '2026-10-02', dataRegion: 'unknown', codingPlanModelIds: [], supportsStreaming: true,
    supportsVision: true, supportsTools: true,
    privacy: { region: 'unknown', retention: 'unknown', trainingUse: 'unknown', policyRef: 'https://docs.siliconflow.cn/' }, verifiedAt: ''
  },
  {
    schemaVersion: 1, providerId: 'ollama', displayName: 'Ollama（本机）', market: 'local',
    adapterFamily: 'ollama_local', endpoint: 'http://127.0.0.1:11434', modelListPath: '/api/tags', chatPath: '/api/chat',
    authKind: 'none', authHeader: '', authModes: ['none'], billingMode: 'local',
    allowedUseCases: ['diagnostic_assistant'], requiresInteractive: false, requiresOfficialTool: false,
    entitlementEndpoint: '', termsVersion: '2026-10-02', dataRegion: 'local', codingPlanModelIds: [], supportsStreaming: true,
    supportsVision: true, supportsTools: false,
    privacy: { region: 'device-local', retention: 'documented', trainingUse: 'off', policyRef: '' }, verifiedAt: ''
  },
  {
    schemaVersion: 1, providerId: HARMONY_LOCAL_PROVIDER_ID, displayName: '鸿蒙端侧小模型', market: 'local',
    adapterFamily: 'harmony_local_chat', endpoint: '', modelListPath: '', chatPath: '',
    authKind: 'none', authHeader: '', authModes: ['none'], billingMode: 'local',
    allowedUseCases: ['diagnostic_assistant'], requiresInteractive: false, requiresOfficialTool: false,
    entitlementEndpoint: '', termsVersion: '2026-10-02', dataRegion: 'local', codingPlanModelIds: [], supportsStreaming: true,
    supportsVision: false, supportsTools: false,
    privacy: {
      region: 'device-local', retention: 'unknown', trainingUse: 'unknown',
      policyRef: 'https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/dataaugmentation-localchatmodel-api'
    }, verifiedAt: '2026-10-02', supportedDeviceTypes: ['pc', '2in1']
  },
  {
    schemaVersion: 1, providerId: 'doubao', displayName: '字节豆包 / 火山引擎', market: 'mainland-cn',
    adapterFamily: 'vendor_native_http', endpoint: '', modelListPath: '', chatPath: '',
    authKind: 'api_key_header', authHeader: 'Authorization', authModes: ['unsupported'], billingMode: 'payg_api',
    allowedUseCases: [], requiresInteractive: false, requiresOfficialTool: false,
    entitlementEndpoint: '', termsVersion: '', dataRegion: 'mainland_cn', codingPlanModelIds: [], supportsStreaming: true,
    supportsVision: true, supportsTools: true,
    privacy: { region: 'mainland', retention: 'unknown', trainingUse: 'unknown', policyRef: '' }, verifiedAt: ''
  },
  {
    schemaVersion: 1, providerId: 'wenxin', displayName: '百度文心 / 千帆', market: 'mainland-cn',
    adapterFamily: 'vendor_native_http', endpoint: '', modelListPath: '', chatPath: '',
    authKind: 'api_key_header', authHeader: 'Authorization', authModes: ['unsupported'], billingMode: 'payg_api',
    allowedUseCases: [], requiresInteractive: false, requiresOfficialTool: false,
    entitlementEndpoint: '', termsVersion: '', dataRegion: 'mainland_cn', codingPlanModelIds: [], supportsStreaming: true,
    supportsVision: true, supportsTools: false,
    privacy: { region: 'mainland', retention: 'unknown', trainingUse: 'unknown', policyRef: '' }, verifiedAt: ''
  },
  {
    schemaVersion: 1, providerId: 'spark', displayName: '讯飞星火', market: 'mainland-cn',
    adapterFamily: 'vendor_native_websocket', endpoint: '', modelListPath: '', chatPath: '',
    authKind: 'custom_header', authHeader: '', authModes: ['unsupported'], billingMode: 'payg_api',
    allowedUseCases: [], requiresInteractive: false, requiresOfficialTool: false,
    entitlementEndpoint: '', termsVersion: '', dataRegion: 'mainland_cn', codingPlanModelIds: [], supportsStreaming: true,
    supportsVision: false, supportsTools: false,
    privacy: { region: 'mainland', retention: 'unknown', trainingUse: 'unknown', policyRef: '' }, verifiedAt: ''
  }
];

export function diagnosticAiProviderManifests(): DiagnosticAiProviderManifest[] {
  return PROVIDERS.map((value: DiagnosticAiProviderManifest): DiagnosticAiProviderManifest => cloneManifest(value));
}

function cloneManifest(value: DiagnosticAiProviderManifest): DiagnosticAiProviderManifest {
  return { schemaVersion: value.schemaVersion, providerId: value.providerId, displayName: value.displayName,
    market: value.market, adapterFamily: value.adapterFamily, endpoint: value.endpoint,
    modelListPath: value.modelListPath, chatPath: value.chatPath, authKind: value.authKind,
    authHeader: value.authHeader, authModes: value.authModes.slice(), billingMode: value.billingMode,
    allowedUseCases: value.allowedUseCases.slice(), requiresInteractive: value.requiresInteractive,
    requiresOfficialTool: value.requiresOfficialTool, entitlementEndpoint: value.entitlementEndpoint,
    termsVersion: value.termsVersion, dataRegion: value.dataRegion, codingPlanModelIds: value.codingPlanModelIds.slice(),
    supportsStreaming: value.supportsStreaming,
    supportsVision: value.supportsVision, supportsTools: value.supportsTools,
    privacy: { region: value.privacy.region, retention: value.privacy.retention,
      trainingUse: value.privacy.trainingUse, policyRef: value.privacy.policyRef }, verifiedAt: value.verifiedAt,
    supportedDeviceTypes: value.supportedDeviceTypes === undefined ? undefined : value.supportedDeviceTypes.slice() };
}

export function diagnosticAiProviderManifest(providerId: string): DiagnosticAiProviderManifest | null {
  const found = PROVIDERS.find((value: DiagnosticAiProviderManifest): boolean => value.providerId === providerId);
  return found === undefined ? null : cloneManifest(found);
}

export function diagnosticAiProviderIsDomestic(providerId: string): boolean {
  const found = diagnosticAiProviderManifest(providerId);
  return found !== null && found.market === 'mainland-cn';
}

/** External manifests stay hidden until their endpoint, terms and data region
 * have a dated verification record. Local providers do not need a remote
 * contract but still keep their data-region declaration explicit. */
export function diagnosticAiProviderManifestVerified(manifest: DiagnosticAiProviderManifest): boolean {
  if (manifest.market === 'local' || diagnosticAiProviderIsHarmonyLocal(manifest.providerId)) { return true; }
  return manifest.verifiedAt.trim() !== '' && manifest.dataRegion !== 'unknown' && manifest.privacy.region !== 'unknown';
}

export function diagnosticAiProviderIsHarmonyLocal(providerId: string): boolean {
  return providerId === HARMONY_LOCAL_PROVIDER_ID;
}

export function diagnosticAiHarmonyLocalDeviceSupported(deviceType: string): boolean {
  return deviceType === 'pc' || deviceType === '2in1';
}

export function diagnosticAiProviderSupportsDevice(manifest: DiagnosticAiProviderManifest,
  deviceType: string): boolean {
  if (manifest.supportedDeviceTypes === undefined || manifest.supportedDeviceTypes.length === 0) { return true; }
  return manifest.supportedDeviceTypes.indexOf(deviceType as DiagnosticAiDeviceType) >= 0;
}
