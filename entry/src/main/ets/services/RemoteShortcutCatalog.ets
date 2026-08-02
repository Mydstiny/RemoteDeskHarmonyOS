/** Semantic shortcut catalog shared by every remote protocol surface. */

export type RemoteShortcutProtocol = 'rdp' | 'rustdesk' | 'vnc' | 'ssh';
export type RemoteShortcutId =
  'copy' | 'cut' | 'pasteShortcut' | 'pasteLocalText' |
  'terminalCtrlC' | 'terminalCtrlV' | 'terminalCtrlX' | 'terminalCopySelection' |
  'altTab' | 'altF4' | 'winRun' | 'winDesktop' | 'ctrlShiftEsc' | 'winExplorer' |
  'ctrlAltDel';
export type RemoteKeyboardLayout = 'ctrl' | 'command' | 'unknown';
export type RemoteShortcutKind = 'remote-chord' | 'terminal-byte' | 'local' | 'local-text';
export type RemoteShortcutKey = 'C' | 'X' | 'V';

export interface RemoteShortcutChord {
  modifier: 'ctrl' | 'command';
  key: RemoteShortcutKey;
}

export interface RemoteShortcutContext {
  protocol: RemoteShortcutProtocol;
  sessionId: number;
  generation: number;
  connected: boolean;
  viewOnly: boolean;
  canSendKeys: boolean;
  canSendText: boolean;
  clipboardEnabled: boolean;
  remotePlatform?: string;
  peerInfoPlatform?: string;
  proHintPlatform?: string;
  sessionLayout?: string;
  hostLayout?: string;
  sessionChoice?: string;
  isPreconnect?: boolean;
  browseMode?: boolean;
  bracketedPaste?: boolean;
  pasteTextBytes?: number;
}

export interface RemoteShortcutAction {
  id: RemoteShortcutId;
  label: string;
  subtitle: string;
  accessibilityText: string;
  kind: RemoteShortcutKind;
  chord: RemoteShortcutChord | null;
  terminalByte: number;
  layout: RemoteKeyboardLayout;
  enabled: boolean;
  reason: string;
  /** Transport sequence owned by the catalog; surfaces never carry raw key arrays. */
  keyCodes: Array<number>;
}

export function defaultRemoteShortcutContext(protocol: RemoteShortcutProtocol): RemoteShortcutContext {
  return {
    protocol,
    sessionId: -1,
    generation: 0,
    connected: false,
    viewOnly: false,
    canSendKeys: false,
    canSendText: false,
    clipboardEnabled: false,
    remotePlatform: 'unknown',
    sessionLayout: 'unknown',
    hostLayout: 'unknown',
    isPreconnect: false,
    browseMode: false,
    bracketedPaste: false,
    pasteTextBytes: 0
  };
}

export function formatRemoteShortcut(chord: RemoteShortcutChord | null,
  layout: RemoteKeyboardLayout): string {
  if (chord === null) { return ''; }
  const modifier: string = layout === 'command' || chord.modifier === 'command' ? 'Command' : 'Ctrl';
  return modifier + '+' + chord.key;
}
