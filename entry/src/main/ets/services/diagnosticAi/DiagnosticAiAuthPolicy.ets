import { DiagnosticAiAuthMode, DiagnosticAiProviderManifest, DiagnosticAiProviderProfile } from './DiagnosticAiModels';

const KNOWN_AUTH_MODES: DiagnosticAiAuthMode[] = ['api_key', 'oauth_pkce', 'device_authorization',
  'coding_plan_key', 'official_cli_bridge', 'none', 'unsupported'];

export function diagnosticAiAuthModeKnown(mode: string): boolean {
  return KNOWN_AUTH_MODES.indexOf(mode as DiagnosticAiAuthMode) >= 0;
}

export function diagnosticAiAuthModeAllowed(manifest: DiagnosticAiProviderManifest, mode: DiagnosticAiAuthMode): boolean {
  return Array.isArray(manifest.authModes) && manifest.authModes.indexOf(mode) >= 0 &&
    mode !== 'unsupported';
}

/** Legacy API-key profiles are migrated to the explicit P0 mode. */
export function diagnosticAiProfileAuthMode(profile: DiagnosticAiProviderProfile): DiagnosticAiAuthMode {
  if (diagnosticAiAuthModeKnown(profile.authMode)) { return profile.authMode; }
  if (profile.authKind === 'none') { return 'none'; }
  return 'api_key';
}

export interface DiagnosticAiAuthDecision { ok: boolean; code: string; message: string; }

export function diagnosticAiAuthDecision(manifest: DiagnosticAiProviderManifest,
  profile: DiagnosticAiProviderProfile): DiagnosticAiAuthDecision {
  const mode: DiagnosticAiAuthMode = diagnosticAiProfileAuthMode(profile);
  if (!diagnosticAiAuthModeAllowed(manifest, mode)) {
    return { ok: false, code: 'AUTH_MODE_UNSUPPORTED', message: '当前 Provider 未声明允许该认证方式' };
  }
  if (mode === 'oauth_pkce' || mode === 'device_authorization' || mode === 'official_cli_bridge') {
    return { ok: false, code: 'AUTH_FLOW_NOT_IMPLEMENTED', message: '该官方授权流程尚未完成接入，暂不能发送请求' };
  }
  if (mode === 'coding_plan_key' && manifest.codingPlanModelIds.length === 0) {
    return { ok: false, code: 'CODING_PLAN_MODEL_LIST_REQUIRED', message: 'Coding Plan 尚未登记模型白名单' };
  }
  return { ok: true, code: '', message: '' };
}
