export type SshWorkspaceLayoutEngine = 'static' | 'dynamic_layout';
export type SshWorkspaceContainerEngine = 'window_breakpoint' | 'container_reader';
export type SshWorkspaceChromeTreatment = 'solid' | 'system_material';
export type SshWorkspaceMotionLevel = 'none' | 'structural' | 'expressive';

export interface SshWorkspacePlatformFacts {
  protocol: string;
  apiVersion: number;
  featureFlagEnabled: boolean;
  dynamicLayoutDeclared: boolean;
  containerReaderDeclared: boolean;
  uiDesignKitDeclared: boolean;
  multiWindowDeclared: boolean;
  keyboardShortcutDeclared: boolean;
  highContrast: boolean;
  reduceMotion: boolean;
  lowPowerMode: boolean;
  terminalHighOutput: boolean;
}

export interface SshWorkspaceCapabilities {
  workbenchEnabled: boolean;
  layoutEngine: SshWorkspaceLayoutEngine;
  containerEngine: SshWorkspaceContainerEngine;
  chromeTreatment: SshWorkspaceChromeTreatment;
  detachedWindowEnabled: boolean;
  keyboardShortcutEnabled: boolean;
  motionLevel: SshWorkspaceMotionLevel;
  reason: string;
}

export const SSH_WORKBENCH_V2_FLAG_KEY: string = 'sshWorkbenchV2';
export const SSH_WORKBENCH_V2_DEFAULT_ENABLED: boolean = false;
export const SSH_DYNAMIC_LAYOUT_MIN_API: number = 24;
export const SSH_UI_DESIGN_TARGET_API: number = 26;

/**
 * The retained multi-pane compositor is a desktop workspace capability.
 * Phone and Pad keep the mature single-visible-surface xterm runtime so IME,
 * caret animation and touch focus are not routed through desktop Pane chrome.
 */
export function sshPersistentPaneWorkspaceEnabled(workbenchEnabled: boolean,
  workspaceReady: boolean, desktop: boolean): boolean {
  return workbenchEnabled && workspaceReady && desktop;
}

export function defaultSshWorkspacePlatformFacts(): SshWorkspacePlatformFacts {
  return {
    protocol: 'ssh',
    apiVersion: 23,
    featureFlagEnabled: SSH_WORKBENCH_V2_DEFAULT_ENABLED,
    dynamicLayoutDeclared: false,
    containerReaderDeclared: false,
    uiDesignKitDeclared: false,
    multiWindowDeclared: false,
    keyboardShortcutDeclared: true,
    highContrast: false,
    reduceMotion: false,
    lowPowerMode: false,
    terminalHighOutput: false
  };
}

/**
 * Pure capability selection. Product code must not import an API 26 symbol
 * until the installed SDK has proven the corresponding declaration.
 */
export function resolveSshWorkspaceCapabilities(
  facts: SshWorkspacePlatformFacts
): SshWorkspaceCapabilities {
  const apiVersion: number = Number.isFinite(facts.apiVersion) ?
    Math.max(1, Math.floor(facts.apiVersion)) : 1;
  const protocol: string = typeof facts.protocol === 'string' ?
    facts.protocol.trim().toLowerCase() : '';
  const protocolEligible: boolean = protocol === 'ssh';
  const enabled: boolean = protocolEligible && facts.featureFlagEnabled === true;
  const dynamicLayout: boolean = enabled && apiVersion >= SSH_DYNAMIC_LAYOUT_MIN_API &&
    facts.dynamicLayoutDeclared === true;
  const containerReader: boolean = enabled && apiVersion >= SSH_UI_DESIGN_TARGET_API &&
    facts.containerReaderDeclared === true;
  const material: boolean = enabled && apiVersion >= SSH_UI_DESIGN_TARGET_API &&
    facts.uiDesignKitDeclared === true && !facts.highContrast && !facts.lowPowerMode;
  let motionLevel: SshWorkspaceMotionLevel = 'expressive';
  if (!enabled || facts.reduceMotion || facts.lowPowerMode) {
    motionLevel = 'none';
  } else if (facts.terminalHighOutput || !material) {
    motionLevel = 'structural';
  }
  let reason: string = '';
  if (!protocolEligible) {
    reason = 'SSH 工作台能力不适用于非 SSH 协议';
  } else if (!enabled) {
    reason = 'sshWorkbenchV2 默认关闭，继续使用现有 SSH 页面';
  } else if (!dynamicLayout) {
    reason = 'DynamicLayout 未经当前 SDK 证明，使用静态语义布局';
  } else if (!containerReader) {
    reason = 'ContainerReader 未经 API 26 SDK 证明，组件尺寸沿用窗口断点输入';
  }
  return {
    workbenchEnabled: enabled,
    layoutEngine: dynamicLayout ? 'dynamic_layout' : 'static',
    containerEngine: containerReader ? 'container_reader' : 'window_breakpoint',
    chromeTreatment: material ? 'system_material' : 'solid',
    detachedWindowEnabled: enabled && facts.multiWindowDeclared === true,
    keyboardShortcutEnabled: enabled && facts.keyboardShortcutDeclared === true,
    motionLevel,
    reason
  };
}
