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
  const billing = diagnosticAiBillingDecision(manifest, profile, diagnosticAiEffectiveUseCase(manifest, useCase));
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

/**
 * 聊天模式 is interactive chat. Pay-as-you-go APIs and local models carry no use restriction, so chat is allowed
 * wherever the assistant is; a subscription (Coding Plan and the like) must declare interactive_chat itself.
 */
export function diagnosticAiEffectiveUseCase(manifest: DiagnosticAiProviderManifest, useCase: DiagnosticAiUseCase): DiagnosticAiUseCase {
  if (useCase === 'interactive_chat' && (manifest.billingMode === 'payg_api' || manifest.billingMode === 'local') &&
    manifest.allowedUseCases.indexOf('interactive_chat') < 0) {
    return 'diagnostic_assistant';
  }
  return useCase;
}

export function diagnosticAiUseCaseError(decision: DiagnosticAiUseCaseDecision): Error {
  return new Error('DIAGNOSTIC_AI_POLICY_' + decision.code);
}
