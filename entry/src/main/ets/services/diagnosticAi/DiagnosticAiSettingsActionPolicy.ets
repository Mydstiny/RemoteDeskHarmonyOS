import { DiagnosticAiSettingProposal } from './DiagnosticAiModels';

const ALLOWED_SETTINGS: string[] = [
  'rdp.audioEnabled', 'rdp.clipboardEnabled', 'rdp.driveEnabled', 'rdp.showDiagnostics',
  'rustdesk.audioEnabled', 'rustdesk.clipboardEnabled', 'rustdesk.filePasteEnabled',
  'rustdesk.showDiagnostics', 'rustdesk.privacyMode', 'rustdesk.lanDiscovery',
  'rustdesk.remoteAppTouchScaleEnabled', 'rustdesk.showLocalCursor', 'rustdesk.relativeMouseMode',
  'rustdesk.swapMouseButtons', 'rustdesk.presenceDetectionEnabled',
  'ui.ambientLightEffect', 'ui.gripAlignment', 'ui.liveViewEnabled', 'ui.followSystem', 'ui.groupedHostCards',
  'remote.rdpPinchZoom', 'remote.rustdeskPinchZoom', 'remote.sshPinchZoom', 'remote.vncPinchZoom',
  'remote.moonlightPinchZoom', 'remote.rdpReverseWheel', 'remote.rustdeskReverseWheel',
  'remote.sshReverseWheel', 'remote.vncReverseWheel', 'remote.moonlightReverseWheel',
  'ai.showOrbOnHostPage'
];

export function diagnosticAiSettingCatalog(): string {
  return ALLOWED_SETTINGS.map((settingId: string): string => settingId + '|' + diagnosticAiSettingActionText(settingId)).join('\n');
}

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

function applyBooleanSetting(proposal: DiagnosticAiSettingProposal, storageKey: string): boolean {
  const value: boolean | null = normalizedBoolean(proposal.proposedValue);
  const current: boolean | null = normalizedBoolean(proposal.currentValue);
  if (!diagnosticAiProposalIsSafe(proposal) || proposal.risk === 'high' || value === null ||
      (current !== null && current === value)) { return false; }
  const stored: boolean | undefined = AppStorage.get<boolean>(storageKey);
  // The model's currentValue is advisory. If the live value is available, reject stale proposals rather than
  // silently overwriting a newer user choice made outside the assistant.
  if (stored !== undefined && current !== null && stored !== current) { return false; }
  AppStorage.setOrCreate<boolean>(storageKey, value as boolean);
  return true;
}

/** Apply only simple, reversible, user-confirmed boolean settings. */
export function diagnosticAiApplyProposal(proposal: DiagnosticAiSettingProposal): boolean {
  switch (proposal.settingId) {
    case 'rdp.audioEnabled': return applyBooleanSetting(proposal, 'rdpAudioEnabled');
    case 'rdp.clipboardEnabled': return applyBooleanSetting(proposal, 'rdpClipboardEnabled');
    case 'rdp.driveEnabled': return applyBooleanSetting(proposal, 'rdpDriveEnabled');
    case 'rdp.showDiagnostics': return applyBooleanSetting(proposal, 'rdpShowDiagnostics');
    case 'rustdesk.audioEnabled': return applyBooleanSetting(proposal, 'rustdeskAudioEnabled');
    case 'rustdesk.clipboardEnabled': return applyBooleanSetting(proposal, 'rustdeskClipboardEnabled');
    case 'rustdesk.filePasteEnabled': return applyBooleanSetting(proposal, 'rustdeskFilePasteEnabled');
    case 'rustdesk.showDiagnostics': return applyBooleanSetting(proposal, 'rustdeskShowDiagnostics');
    case 'rustdesk.privacyMode': return applyBooleanSetting(proposal, 'rustdeskPrivacyMode');
    case 'rustdesk.lanDiscovery': return applyBooleanSetting(proposal, 'rustdeskLanDiscovery');
    case 'rustdesk.remoteAppTouchScaleEnabled': return applyBooleanSetting(proposal, 'rustdeskRemoteAppTouchScaleEnabled');
    case 'rustdesk.showLocalCursor': return applyBooleanSetting(proposal, 'rustdeskShowLocalCursor');
    case 'rustdesk.relativeMouseMode': return applyBooleanSetting(proposal, 'rustdeskRelativeMouseMode');
    case 'rustdesk.swapMouseButtons': return applyBooleanSetting(proposal, 'rustdeskSwapMouseButtons');
    case 'rustdesk.presenceDetectionEnabled': return applyBooleanSetting(proposal, 'rustdeskPresenceDetectionEnabled');
    case 'ui.ambientLightEffect': return applyBooleanSetting(proposal, 'ambientLightEffectEnabled');
    case 'ui.gripAlignment': return applyBooleanSetting(proposal, 'gripAlignmentEnabled');
    case 'ui.liveViewEnabled': return applyBooleanSetting(proposal, 'liveViewEnabled');
    case 'ui.followSystem': return applyBooleanSetting(proposal, 'followSystem');
    case 'ui.groupedHostCards': return applyBooleanSetting(proposal, 'groupedHostCards');
    case 'remote.rdpPinchZoom': return applyBooleanSetting(proposal, 'rdpPinchZoomEnabled');
    case 'remote.rustdeskPinchZoom': return applyBooleanSetting(proposal, 'rustdeskPinchZoomEnabled');
    case 'remote.sshPinchZoom': return applyBooleanSetting(proposal, 'sshPinchZoomEnabled');
    case 'remote.vncPinchZoom': return applyBooleanSetting(proposal, 'vncPinchZoomEnabled');
    case 'remote.moonlightPinchZoom': return applyBooleanSetting(proposal, 'moonlightPinchZoomEnabled');
    case 'remote.rdpReverseWheel': return applyBooleanSetting(proposal, 'rdpReverseWheel');
    case 'remote.rustdeskReverseWheel': return applyBooleanSetting(proposal, 'rustdeskReverseWheel');
    case 'remote.sshReverseWheel': return applyBooleanSetting(proposal, 'sshReverseWheel');
    case 'remote.vncReverseWheel': return applyBooleanSetting(proposal, 'vncReverseWheel');
    case 'remote.moonlightReverseWheel': return applyBooleanSetting(proposal, 'moonlightReverseWheel');
    case 'ai.showOrbOnHostPage': return applyBooleanSetting(proposal, 'diagnosticAiOrbEnabled');
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
    case 'rdp.audioEnabled': return 'RDP 远程音频';
    case 'rdp.clipboardEnabled': return 'RDP 剪贴板';
    case 'rdp.driveEnabled': return 'RDP 驱动器映射';
    case 'rustdesk.audioEnabled': return 'RustDesk 远程音频';
    case 'rustdesk.clipboardEnabled': return 'RustDesk 剪贴板';
    case 'rustdesk.filePasteEnabled': return 'RustDesk 文件粘贴';
    case 'rustdesk.privacyMode': return 'RustDesk 隐私模式';
    case 'rustdesk.lanDiscovery': return 'RustDesk 局域网发现';
    case 'rustdesk.remoteAppTouchScaleEnabled': return 'RustDesk 远端触控缩放';
    case 'rustdesk.showLocalCursor': return 'RustDesk 显示本地光标';
    case 'rustdesk.relativeMouseMode': return 'RustDesk 相对鼠标';
    case 'rustdesk.swapMouseButtons': return 'RustDesk 交换鼠标按键';
    case 'rustdesk.presenceDetectionEnabled': return 'RustDesk 在线检测';
    case 'ui.ambientLightEffect': return '沉浸光感';
    case 'ui.gripAlignment': return '握姿对齐';
    case 'ui.liveViewEnabled': return '实时视图';
    case 'ui.followSystem': return '跟随系统主题';
    case 'ui.groupedHostCards': return '主机分组卡片';
    case 'remote.rdpPinchZoom': return 'RDP 双指缩放';
    case 'remote.rustdeskPinchZoom': return 'RustDesk 双指缩放';
    case 'remote.sshPinchZoom': return 'SSH 双指缩放';
    case 'remote.vncPinchZoom': return 'VNC 双指缩放';
    case 'remote.moonlightPinchZoom': return 'Moonlight 双指缩放';
    case 'remote.rdpReverseWheel': return 'RDP 反向滚轮';
    case 'remote.rustdeskReverseWheel': return 'RustDesk 反向滚轮';
    case 'remote.sshReverseWheel': return 'SSH 反向滚轮';
    case 'remote.vncReverseWheel': return 'VNC 反向滚轮';
    case 'remote.moonlightReverseWheel': return 'Moonlight 反向滚轮';
    default: return '应用设置';
  }
}
