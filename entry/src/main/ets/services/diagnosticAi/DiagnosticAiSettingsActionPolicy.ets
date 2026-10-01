import { DiagnosticAiSettingProposal } from './DiagnosticAiModels';

const ALLOWED_SETTINGS: string[] = [
  'rdp.showDiagnostics', 'rustdesk.showDiagnostics', 'ai.showOrbOnHostPage'
];

export function diagnosticAiSettingIdAllowed(settingId: string): boolean {
  return ALLOWED_SETTINGS.indexOf(settingId) >= 0;
}

export function diagnosticAiProposalIsSafe(proposal: DiagnosticAiSettingProposal): boolean {
  return diagnosticAiSettingIdAllowed(proposal.settingId) && proposal.currentValue.length <= 256 &&
    proposal.proposedValue.length <= 256 && proposal.reason.length <= 2000 &&
    proposal.rollbackValue.length <= 256 && proposal.requiresUserConfirmation;
}

function normalizedBoolean(value: string): boolean | null {
  const normalized: string = value.trim().toLowerCase();
  if (normalized === 'true' || normalized === 'on' || normalized === '开启' || normalized === '打开') { return true; }
  if (normalized === 'false' || normalized === 'off' || normalized === '关闭') { return false; }
  return null;
}

/** Apply only simple, reversible, user-confirmed boolean settings. */
export function diagnosticAiApplyProposal(proposal: DiagnosticAiSettingProposal): boolean {
  const value: boolean | null = normalizedBoolean(proposal.proposedValue);
  const current: boolean | null = normalizedBoolean(proposal.currentValue);
  if (!diagnosticAiProposalIsSafe(proposal) || proposal.risk === 'high' || value === null ||
      (current !== null && current === value)) { return false; }
  switch (proposal.settingId) {
    case 'rdp.showDiagnostics': AppStorage.setOrCreate('rdpShowDiagnostics', value as boolean); return true;
    case 'rustdesk.showDiagnostics': AppStorage.setOrCreate('rustdeskShowDiagnostics', value as boolean); return true;
    case 'ai.showOrbOnHostPage': AppStorage.setOrCreate('diagnosticAiOrbEnabled', value as boolean); return true;
    default: return false;
  }
}

export function diagnosticAiSettingActionText(settingId: string): string {
  switch (settingId) {
    case 'rdp.showDiagnostics': return 'RDP 诊断信息';
    case 'rustdesk.showDiagnostics': return 'RustDesk 诊断信息';
    case 'vnc.showDiagnostics': return 'VNC 诊断信息';
    case 'moonlight.showDiagnostics': return 'Moonlight 诊断信息';
    case 'remoteSession.portraitDisplay': return '远程画面竖屏显示';
    case 'remoteSession.wheelDirection': return '远程滚轮方向';
    case 'diagnostic.captureModules': return '诊断捕获模组';
    case 'diagnostic.captureDuration': return '诊断捕获时长';
    case 'ai.showOrbOnHostPage': return '远程主机页 AI 入口';
    default: return '应用设置';
  }
}
