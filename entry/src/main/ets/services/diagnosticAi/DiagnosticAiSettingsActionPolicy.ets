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

/** Apply only simple, reversible, user-confirmed boolean settings. */
export function diagnosticAiApplyProposal(proposal: DiagnosticAiSettingProposal): boolean {
  if (!diagnosticAiProposalIsSafe(proposal) || proposal.risk === 'high' ||
      proposal.currentValue === proposal.proposedValue) { return false; }
  const next: string = proposal.proposedValue.trim().toLowerCase();
  if (next !== 'true' && next !== 'false') { return false; }
  const value: boolean = next === 'true';
  switch (proposal.settingId) {
    case 'rdp.showDiagnostics': AppStorage.setOrCreate('rdpShowDiagnostics', value); return true;
    case 'rustdesk.showDiagnostics': AppStorage.setOrCreate('rustdeskShowDiagnostics', value); return true;
    case 'vnc.showDiagnostics': AppStorage.setOrCreate('vncShowDiagnostics', value); return true;
    case 'moonlight.showDiagnostics': AppStorage.setOrCreate('moonlightShowDiagnostics', value); return true;
    case 'ai.showOrbOnHostPage': AppStorage.setOrCreate('diagnosticAiOrbEnabled', value); return true;
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
