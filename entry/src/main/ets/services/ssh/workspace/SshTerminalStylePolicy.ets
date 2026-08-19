import {
  SshWorkspaceCapabilities,
  SshWorkspaceChromeTreatment,
  SshWorkspaceMotionLevel
} from './SshWorkspaceCapabilityPolicy';

export type SshTerminalThemeMode = 'light' | 'dark';
export type SshTerminalDensity = 'touch' | 'compact';
export type SshTerminalSurfaceTreatment = 'opaque';
export type SshWorkspaceFocusTreatment = 'outline_and_surface' | 'outline_high_contrast';

export interface SshTerminalStyleInput {
  theme: SshTerminalThemeMode;
  density: SshTerminalDensity;
  highContrast: boolean;
  reduceMotion: boolean;
  lowPowerMode: boolean;
  terminalHighOutput: boolean;
  capabilities: SshWorkspaceCapabilities;
}

export interface SshTerminalSemanticStyle {
  terminalSurface: SshTerminalSurfaceTreatment;
  chromeTreatment: SshWorkspaceChromeTreatment;
  floatingToolTreatment: SshWorkspaceChromeTreatment;
  focusTreatment: SshWorkspaceFocusTreatment;
  motionLevel: SshWorkspaceMotionLevel;
  chromeTitleToken: string;
  chromeBodyToken: string;
  terminalForegroundToken: string;
  terminalBackgroundToken: string;
  activePaneToken: string;
  dangerToken: string;
  successToken: string;
  visualControlSizeVp: number;
  hitControlSizeVp: number;
  tabHeightVp: number;
}

/**
 * Returns semantic tokens only. Concrete HarmonyOS 7 materials and official
 * color resources are resolved by an API-verified adapter, never guessed in
 * SSH business components.
 */
export function resolveSshTerminalSemanticStyle(
  input: SshTerminalStyleInput
): SshTerminalSemanticStyle {
  const forceStatic: boolean = input.highContrast || input.lowPowerMode ||
    input.capabilities.chromeTreatment !== 'system_material';
  const chromeTreatment: SshWorkspaceChromeTreatment =
    forceStatic ? 'solid' : 'system_material';
  let motionLevel: SshWorkspaceMotionLevel = input.capabilities.motionLevel;
  if (input.reduceMotion || input.lowPowerMode) { motionLevel = 'none'; }
  else if (input.terminalHighOutput && motionLevel === 'expressive') { motionLevel = 'structural'; }
  const compact: boolean = input.density === 'compact';
  return {
    terminalSurface: 'opaque',
    chromeTreatment,
    floatingToolTreatment: chromeTreatment,
    focusTreatment: input.highContrast ? 'outline_high_contrast' : 'outline_and_surface',
    motionLevel,
    chromeTitleToken: input.theme === 'dark' ? 'ssh.chrome.title.dark' : 'ssh.chrome.title.light',
    chromeBodyToken: input.theme === 'dark' ? 'ssh.chrome.body.dark' : 'ssh.chrome.body.light',
    terminalForegroundToken: input.theme === 'dark' ?
      'ssh.terminal.foreground.dark' : 'ssh.terminal.foreground.light',
    terminalBackgroundToken: input.theme === 'dark' ?
      'ssh.terminal.background.dark' : 'ssh.terminal.background.light',
    activePaneToken: input.highContrast ? 'ssh.pane.active.high_contrast' : 'ssh.pane.active',
    dangerToken: 'ssh.status.danger',
    successToken: 'ssh.status.success',
    visualControlSizeVp: compact ? 36 : 44,
    hitControlSizeVp: 48,
    tabHeightVp: compact ? 40 : 44
  };
}
