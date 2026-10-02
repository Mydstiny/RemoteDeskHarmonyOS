import { DiagnosticAiBillingMode, DiagnosticAiProviderManifest, DiagnosticAiProviderProfile, DiagnosticAiUseCase } from './DiagnosticAiModels';
import { diagnosticAiProfileAuthMode } from './DiagnosticAiAuthPolicy';

const KNOWN_BILLING_MODES: DiagnosticAiBillingMode[] = ['payg_api', 'token_plan', 'coding_plan', 'subscription_chat', 'local'];

export function diagnosticAiBillingModeKnown(mode: string): boolean {
  return KNOWN_BILLING_MODES.indexOf(mode as DiagnosticAiBillingMode) >= 0;
}

export interface DiagnosticAiBillingDecision { ok: boolean; code: string; message: string; }

/**
 * Billing and use-case declarations are checked together. A request result
 * cannot be used as evidence that a subscription permits third-party use.
 */
export function diagnosticAiBillingDecision(manifest: DiagnosticAiProviderManifest,
  profile: DiagnosticAiProviderProfile, useCase: DiagnosticAiUseCase): DiagnosticAiBillingDecision {
  if (!diagnosticAiBillingModeKnown(manifest.billingMode) || profile.billingMode !== manifest.billingMode) {
    return { ok: false, code: 'BILLING_MODE_UNKNOWN', message: 'Provider 的计费模式未完成登记' };
  }
  if (manifest.allowedUseCases.indexOf(useCase) < 0 || profile.allowedUseCases.indexOf(useCase) < 0) {
    return { ok: false, code: 'USE_CASE_NOT_ALLOWED', message: '当前套餐未声明允许诊断助手用途' };
  }
  if (manifest.requiresOfficialTool || profile.requiresOfficialTool) {
    return { ok: false, code: 'OFFICIAL_TOOL_ONLY', message: '该套餐只允许供应商指定的官方工具' };
  }
  if (manifest.requiresInteractive || profile.requiresInteractive) {
    return { ok: false, code: 'INTERACTIVE_SESSION_REQUIRED', message: '该套餐需要官方交互式会话，当前助手不能代替该会话' };
  }
  if (manifest.billingMode === 'coding_plan' && diagnosticAiProfileAuthMode(profile) !== 'coding_plan_key') {
    return { ok: false, code: 'CODING_PLAN_AUTH_REQUIRED', message: 'Coding Plan 必须使用供应商登记的专用认证方式' };
  }
  if (manifest.termsVersion.trim() === '' || profile.termsVersion !== manifest.termsVersion) {
    return { ok: false, code: 'TERMS_REVIEW_REQUIRED', message: 'Provider 条款版本尚未核验，暂不能用于诊断助手' };
  }
  return { ok: true, code: '', message: '' };
}
