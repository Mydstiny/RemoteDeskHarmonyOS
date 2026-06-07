import { BusinessError } from '@kit.BasicServicesKit';

interface NativeProtocolBridge {
  connect(configJson: string, surfaceId: string): number;
  disconnect(sessionId: number): void;
  sendKey(sessionId: number, scancode: number, pressed: boolean): void;
  sendMouse(sessionId: number, x: number, y: number, button: number, pressed: boolean): void;
  sendText(sessionId: number, text: string): void;
  getProtocols(): string;
  getDefaultPort(protocol: string): number;
}

const nativeBridge: NativeProtocolBridge | null = (() => {
  try {
    const native = requireNapi('librdpnapi') as NativeProtocolBridge;
    console.info('ProtocolBridge native module loaded');
    return native;
  } catch (err) {
    console.error('ProtocolBridge failed to load librdpnapi: ' + err);
    return null;
  }
})();

export interface ConnectionConfig {
  protocol: string;
  host: string;
  port: number;
  username: string;
  password: string;
  width: number;
  height: number;
  fps: number;
}

export class ProtocolBridge {
  private sessionId: number = -1;
  private config: ConnectionConfig | null = null;

  async connect(config: ConnectionConfig, surfaceId: string): Promise<number> {
    this.config = config;
    if (!nativeBridge) {
      console.warn('ProtocolBridge native not available, using stub');
      this.sessionId = 1;
      return 1;
    }
    try {
      const configJson = JSON.stringify(config);
      const sid = nativeBridge.connect(configJson, surfaceId);
      this.sessionId = sid;
      console.info('ProtocolBridge connected, sessionId: ' + sid);
      return sid;
    } catch (err) {
      console.error('ProtocolBridge connect failed: ' + err);
      throw err;
    }
  }

  disconnect(): void {
    if (!nativeBridge || this.sessionId < 0) return;
    try {
      nativeBridge.disconnect(this.sessionId);
      this.sessionId = -1;
      console.info('ProtocolBridge disconnected');
    } catch (err) {
      console.error('ProtocolBridge disconnect failed: ' + err);
    }
  }

  sendKey(scancode: number, pressed: boolean): void {
    if (!nativeBridge || this.sessionId < 0) return;
    nativeBridge.sendKey(this.sessionId, scancode, pressed);
  }

  sendMouse(x: number, y: number, button: number, pressed: boolean): void {
    if (!nativeBridge || this.sessionId < 0) return;
    nativeBridge.sendMouse(this.sessionId, x, y, button, pressed);
  }

  sendText(text: string): void {
    if (!nativeBridge || this.sessionId < 0) return;
    nativeBridge.sendText(this.sessionId, text);
  }

  getProtocols(): string[] {
    if (!nativeBridge) return ['rdp', 'rustdesk'];
    try {
      const json = nativeBridge.getProtocols();
      return JSON.parse(json) as string[];
    } catch (err) {
      console.error('ProtocolBridge getProtocols failed: ' + err);
      return ['rdp', 'rustdesk'];
    }
  }

  getDefaultPort(protocol: string): number {
    if (!nativeBridge) {
      return protocol === 'rdp' ? 3389 : 21116;
    }
    try {
      return nativeBridge.getDefaultPort(protocol);
    } catch (err) {
      console.error('ProtocolBridge getDefaultPort failed: ' + err);
      return protocol === 'rdp' ? 3389 : 21116;
    }
  }

  isConnected(): boolean {
    return this.sessionId >= 0;
  }

  getSessionId(): number {
    return this.sessionId;
  }
}
