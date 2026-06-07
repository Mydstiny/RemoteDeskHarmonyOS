export enum SessionQuality {
  AUTO = 'auto',
  BEST_QUALITY = 'quality',
  BEST_PERFORMANCE = 'speed'
}

export enum KeyboardMode {
  MACOS = 'macOS',
  WINDOWS = 'Windows',
  GENERIC = 'generic'
}

export enum LockType {
  NONE = 'none',
  BIOMETRIC = 'biometric',
  PIN = 'pin',
  PASSWORD = 'password'
}

export interface GatewayConfig {
  host: string;
  port: number;
  username: string;
  password: string;
  bypassLocal: boolean;
}

export interface DisplayConfig {
  width: number;
  height: number;
  useAllMonitors: boolean;
  colorDepth: number;
}

export interface RedirectionConfig {
  clipboard: boolean;
  printer: boolean;
  microphone: boolean;
  camera: boolean;
  folder: boolean;
  folderPath: string;
  smartcard: boolean;
}

export interface RemoteHost {
  id: string;
  userId: string;
  label: string;
  protocol: string;
  host: string;
  port: number;
  username: string;
  password: string;
  locked: boolean;
  lockType: string;
  syncVersion: number;
  gateway: GatewayConfig | null;
  sessionQuality: SessionQuality;
  displayConfig: DisplayConfig;
  redirection: RedirectionConfig;
  keyboardMode: KeyboardMode;
  thumbnail: string;
  lastConnected: number;
  tags: string[];
  workspaceId: string;
}

export interface ConnectionGroup {
  id: string;
  name: string;
  hosts: string[];
}

export function createDefaultRemoteHost(userId: string): RemoteHost {
  return {
    id: '',
    userId: userId,
    label: '',
    protocol: 'rdp',
    host: '',
    port: 3389,
    username: '',
    password: '',
    locked: false,
    lockType: 'none',
    syncVersion: 0,
    gateway: null,
    sessionQuality: SessionQuality.AUTO,
    displayConfig: {
      width: 1920,
      height: 1080,
      useAllMonitors: false,
      colorDepth: 32
    },
    redirection: {
      clipboard: true,
      printer: false,
      microphone: false,
      camera: false,
      folder: false,
      folderPath: '',
      smartcard: false
    },
    keyboardMode: KeyboardMode.GENERIC,
    thumbnail: '',
    lastConnected: 0,
    tags: [],
    workspaceId: ''
  };
}
