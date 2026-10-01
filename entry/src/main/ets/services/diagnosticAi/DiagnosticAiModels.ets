/**
 * Local, user-owned Provider configuration for the Pro diagnostic assistant.
 * This model is deliberately separate from the remote Codex/DSH host model.
 */
export type DiagnosticAiMarket = 'mainland-cn' | 'local' | 'international' | 'custom';
export type DiagnosticAiAdapterFamily =
  'openai_compatible_http' | 'vendor_native_http' | 'vendor_native_websocket' | 'ollama_local';
export type DiagnosticAiAuthKind = 'bearer' | 'api_key_header' | 'custom_header' | 'none';
export type DiagnosticAiPrivacyValue = 'mainland' | 'cross-border' | 'device-local' | 'unknown';
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
  supportsStreaming: boolean;
  supportsVision: boolean;
  supportsTools: boolean;
  privacy: DiagnosticAiPrivacyInfo;
  verifiedAt: string;
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

export interface DiagnosticAiSettings {
  selectedProviderId: string;
  selectedModelId: string;
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
  knowledgeVersion: string;
  createdAt: number;
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
    selectedProviderId: '', selectedModelId: '', showOrbOnHostPage: false,
    reducedMotion: false, retentionDays: 7
  };
}

export function cloneDiagnosticAiPrivacy(value: DiagnosticAiPrivacyInfo): DiagnosticAiPrivacyInfo {
  return { region: value.region, retention: value.retention,
    trainingUse: value.trainingUse, policyRef: value.policyRef };
}

export function cloneDiagnosticAiProfile(value: DiagnosticAiProviderProfile): DiagnosticAiProviderProfile {
  return {
    id: value.id, owner: value.owner, providerId: value.providerId,
    displayName: value.displayName, endpoint: value.endpoint, modelId: value.modelId,
    authKind: value.authKind, authHeader: value.authHeader, secretRef: value.secretRef,
    secretFingerprint: value.secretFingerprint, manifestVersion: value.manifestVersion,
    privacy: cloneDiagnosticAiPrivacy(value.privacy), showOrbOnHostPage: value.showOrbOnHostPage,
    revision: value.revision, updatedAt: value.updatedAt
  };
}
