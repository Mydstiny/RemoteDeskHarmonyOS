/**
 * Local, user-owned Provider configuration for the Pro diagnostic assistant.
 * This model is deliberately separate from the remote Codex/DSH host model.
 */
export type DiagnosticAiMarket = 'mainland-cn' | 'local' | 'international' | 'custom';
export type DiagnosticAiAdapterFamily =
  'openai_compatible_http' | 'vendor_native_http' | 'vendor_native_websocket' | 'ollama_local' | 'harmony_local_chat';
export type DiagnosticAiAuthKind = 'bearer' | 'api_key_header' | 'custom_header' | 'none';
/** User-facing authentication capabilities declared by a Provider manifest. */
export type DiagnosticAiAuthMode = 'api_key' | 'oauth_pkce' | 'device_authorization' |
  'coding_plan_key' | 'official_cli_bridge' | 'none' | 'unsupported';
export type DiagnosticAiBillingMode = 'payg_api' | 'token_plan' | 'coding_plan' | 'subscription_chat' | 'local';
export type DiagnosticAiUseCase = 'diagnostic_assistant' | 'coding_agent' | 'interactive_chat' | 'batch';
export type DiagnosticAiDataRegion = 'mainland_cn' | 'other' | 'local' | 'unknown';
export type DiagnosticAiAuthorizationStatus = 'unconfigured' | 'connected' | 'pending' | 'review_required' | 'revoked' | 'expired';
export type DiagnosticAiPrivacyValue = 'mainland' | 'cross-border' | 'device-local' | 'unknown';
export type DiagnosticAiDeviceType = 'phone' | 'tablet' | 'pc' | '2in1' | 'unknown';
export type DiagnosticAiCaptureState = 'idle' | 'arming' | 'capturing' | 'ready' | 'error';
export type DiagnosticAiOrbState = 'hidden' | 'idle' | 'opening' | 'open' | 'thinking' |
  'capturePreparing' | 'capturing' | 'result' | 'waitingConfirmation' | 'error';

export interface DiagnosticAiPrivacyInfo {
  region: DiagnosticAiPrivacyValue;
  retention: 'documented' | 'unknown';
  trainingUse: 'off' | 'opt-out' | 'unknown';
  policyRef: string;
}

export interface DiagnosticAiProviderManifest {
  schemaVersion: number;
  providerId: string;
  displayName: string;
  market: DiagnosticAiMarket;
  adapterFamily: DiagnosticAiAdapterFamily;
  endpoint: string;
  modelListPath: string;
  chatPath: string;
  authKind: DiagnosticAiAuthKind;
  authHeader: string;
  authModes: DiagnosticAiAuthMode[];
  billingMode: DiagnosticAiBillingMode;
  allowedUseCases: DiagnosticAiUseCase[];
  requiresInteractive: boolean;
  requiresOfficialTool: boolean;
  entitlementEndpoint: string;
  termsVersion: string;
  dataRegion: DiagnosticAiDataRegion;
  codingPlanModelIds: string[];
  supportsStreaming: boolean;
  supportsVision: boolean;
  supportsTools: boolean;
  privacy: DiagnosticAiPrivacyInfo;
  verifiedAt: string;
  /** Optional physical device allowlist. An unsupported local provider remains visible but disabled. */
  supportedDeviceTypes?: DiagnosticAiDeviceType[];
}

export interface DiagnosticAiProviderProfile {
  id: string;
  owner: string;
  providerId: string;
  displayName: string;
  endpoint: string;
  modelId: string;
  authKind: DiagnosticAiAuthKind;
  authHeader: string;
  authMode: DiagnosticAiAuthMode;
  billingMode: DiagnosticAiBillingMode;
  allowedUseCases: DiagnosticAiUseCase[];
  requiresInteractive: boolean;
  requiresOfficialTool: boolean;
  entitlementEndpoint: string;
  termsVersion: string;
  dataRegion: DiagnosticAiDataRegion;
  authorizationStatus: DiagnosticAiAuthorizationStatus;
  consentId: string;
  consentAt: number;
  secretRef: string;
  secretFingerprint: string;
  manifestVersion: number;
  privacy: DiagnosticAiPrivacyInfo;
  showOrbOnHostPage: boolean;
  revision: number;
  updatedAt: number;
}

export interface DiagnosticAiModelInfo {
  id: string;
  displayName: string;
  providerId: string;
  supportsStreaming: boolean;
  supportsVision: boolean;
  supportsTools: boolean;
  fetchedAt: number;
  stale: boolean;
}

/** Token counts returned by an OpenAI-compatible Provider. These are usage facts,
 * not a billing receipt; the local model catalog is used for the estimate. */
export interface DiagnosticAiUsageMetadata {
  promptTokens: number;
  completionTokens: number;
  cachedTokens: number;
  /** The provider returned no usage: these are local estimates of what was sent and received. */
  estimated?: boolean;
}

/** Locally maintained model pricing in CNY per million tokens. A negative value
 * means the provider did not publish a usable price in the model-list response. */
export interface DiagnosticAiModelPriceEntry {
  providerId: string;
  modelId: string;
  displayName: string;
  inputCnyPerMillion: number;
  outputCnyPerMillion: number;
  cachedInputCnyPerMillion: number;
  source: string;
  sourceKind: 'maintained' | 'provider';
  updatedAt: number;
}

export interface DiagnosticAiSettings {
  selectedProviderId: string;
  selectedModelId: string;
  /** Explicitly binds the next request to one provider authentication profile. */
  selectedAuthMode: DiagnosticAiAuthMode | '';
  showOrbOnHostPage: boolean;
  reducedMotion: boolean;
  retentionDays: number;
}

export interface DiagnosticAiEvidenceRef {
  captureId: string;
  sequence: number;
  moduleId: string;
  eventCode: string;
}

export interface DiagnosticAiResult {
  summary: string;
  severity: 'info' | 'low' | 'medium' | 'high' | 'unknown';
  confidence: number;
  evidenceRefs: DiagnosticAiEvidenceRef[];
  hypotheses: string[];
  recommendedReadOnlySteps: string[];
  unknowns: string[];
  settingProposals: DiagnosticAiSettingProposal[];
  /** Explicit typed action IDs returned by a Provider; unknown IDs are discarded at parse time. */
  appActions: string[];
  knowledgeVersion: string;
  createdAt: number;
  usage?: DiagnosticAiUsageMetadata;
  /** The technical reading (event codes, error codes, timeline): for the developer mail only, not the answer. */
  developerNotes?: string;
  /** The model's plan for a log capture, when it judged logs are needed to tell what is wrong. */
  capturePlan?: DiagnosticAiCapturePlanProposal;
  /** Questions to ask before capturing, when the app's own question bank had none for this problem. */
  clarifyQuestions?: DiagnosticAiClarifyQuestion[];
}

/** One tap-to-answer question the AI wants answered before a capture. */
export interface DiagnosticAiClarifyQuestion {
  question: string;
  options: string[];
}

/** Which 日志子模块 to capture, for how long, and what the user should do meanwhile. */
export interface DiagnosticAiCapturePlanProposal {
  focus: string[];
  durationMinutes: number;
  steps: string[];
  reason: string;
}

export interface DiagnosticAiSettingProposal {
  settingId: string;
  currentValue: string;
  proposedValue: string;
  reason: string;
  evidenceRefs: DiagnosticAiEvidenceRef[];
  risk: 'low' | 'medium' | 'high';
  requiresUserConfirmation: boolean;
  rollbackValue: string;
}

export function defaultDiagnosticAiSettings(): DiagnosticAiSettings {
  return {
    selectedProviderId: '', selectedModelId: '', selectedAuthMode: '', showOrbOnHostPage: false,
    reducedMotion: false, retentionDays: 7
  };
}

export function cloneDiagnosticAiPrivacy(value: DiagnosticAiPrivacyInfo): DiagnosticAiPrivacyInfo {
  return { region: value.region, retention: value.retention,
    trainingUse: value.trainingUse, policyRef: value.policyRef };
}

export function cloneDiagnosticAiProfile(value: DiagnosticAiProviderProfile): DiagnosticAiProviderProfile {
  const allowedUseCases: DiagnosticAiUseCase[] = Array.isArray(value.allowedUseCases) ? value.allowedUseCases.slice() : [];
  return {
    id: value.id, owner: value.owner, providerId: value.providerId,
    displayName: value.displayName, endpoint: value.endpoint, modelId: value.modelId,
    authKind: value.authKind, authHeader: value.authHeader, authMode: value.authMode,
    billingMode: value.billingMode ?? 'payg_api', allowedUseCases,
    requiresInteractive: value.requiresInteractive === true, requiresOfficialTool: value.requiresOfficialTool === true,
    entitlementEndpoint: value.entitlementEndpoint ?? '', termsVersion: value.termsVersion ?? '', dataRegion: value.dataRegion ?? 'unknown',
    authorizationStatus: value.authorizationStatus ?? 'unconfigured', consentId: value.consentId ?? '', consentAt: Number(value.consentAt) || 0,
    secretRef: value.secretRef,
    secretFingerprint: value.secretFingerprint, manifestVersion: value.manifestVersion,
    privacy: cloneDiagnosticAiPrivacy(value.privacy), showOrbOnHostPage: value.showOrbOnHostPage,
    revision: value.revision, updatedAt: value.updatedAt
  };
}
