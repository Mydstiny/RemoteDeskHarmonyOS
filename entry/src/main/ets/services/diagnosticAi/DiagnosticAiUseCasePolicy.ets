import { DiagnosticAiAuthorizationStatus, DiagnosticAiProviderManifest, DiagnosticAiProviderProfile, DiagnosticAiUseCase } from './DiagnosticAiModels';
import { diagnosticAiAuthDecision } from './DiagnosticAiAuthPolicy';
import { diagnosticAiBillingDecision } from './DiagnosticAiBillingPolicy';

export interface DiagnosticAiUseCaseDecision { ok: boolean; code: string; message: string; }

function statusUsable(status: DiagnosticAiAuthorizationStatus): boolean {
  return status === 'connected';
}

/** Single fail-closed gate for every diagnostic/assistant Provider request. */
export function diagnosticAiUseCaseDecision(manifest: DiagnosticAiProviderManifest,
  profile: DiagnosticAiProviderProfile, useCase: DiagnosticAiUseCase = 'diagnostic_assistant'): DiagnosticAiUseCaseDecision {
  const auth = diagnosticAiAuthDecision(manifest, profile);
  if (!auth.ok) { return auth; }
  const billing = diagnosticAiBillingDecision(manifest, profile, useCase);
  if (!billing.ok) { return billing; }
  if (!statusUsable(profile.authorizationStatus)) {
    return { ok: false, code: 'AUTHORIZATION_NOT_ACTIVE', message: 'Provider 授权尚未处于可用状态，请重新授权或保存配置' };
  }
  if (manifest.dataRegion === 'unknown' || profile.dataRegion === 'unknown') {
    return { ok: false, code: 'DATA_REGION_UNKNOWN', message: 'Provider 数据处理地区尚未核验，暂不能发送诊断数据' };
  }
  if (profile.consentId.trim() === '' || profile.consentAt <= 0) {
    return { ok: false, code: 'CONSENT_REQUIRED', message: '发送诊断数据前必须记录当前用途确认' };
  }
  return { ok: true, code: '', message: '' };
}

export function diagnosticAiUseCaseError(decision: DiagnosticAiUseCaseDecision): Error {
  return new Error('DIAGNOSTIC_AI_POLICY_' + decision.code);
}
