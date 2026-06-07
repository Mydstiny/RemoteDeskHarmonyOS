import { RemoteHost, SessionQuality, KeyboardMode, GatewayConfig } from '../models/RemoteHost';

export interface RdpFileField {
  key: string;
  value: string;
}

export class RdpFileService {
  private static instance: RdpFileService;

  static getInstance(): RdpFileService {
    if (!this.instance) {
      this.instance = new RdpFileService();
    }
    return this.instance;
  }

  parseRdpFile(content: string): RemoteHost {
    const host = this.createPlaceholderHost();
    const lines = content.split(/\r?\n/);
    const fields: Map<string, string> = new Map();

    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed.length === 0 || trimmed.startsWith(';') || trimmed.startsWith('#')) {
        continue;
      }
      const eqIdx = trimmed.indexOf('=');
      if (eqIdx < 0) continue;
      const key = trimmed.slice(0, eqIdx).trim().toLowerCase();
      const value = trimmed.slice(eqIdx + 1).trim();
      fields.set(key, value);
    }

    host.host = this.parseHost(fields);
    host.port = this.parsePort(fields);
    host.username = fields.get('username') ?? fields.get('full address')?.split(':')[0] ?? '';
    host.label = fields.get('full address')?.split(':')[0] ?? host.host;
    host.protocol = 'rdp';
    host.displayConfig = this.parseDisplayConfig(fields);
    host.redirection = this.parseRedirectionConfig(fields);
    host.sessionQuality = this.parseSessionQuality(fields);
    host.gateway = this.parseGatewayConfig(fields);
    host.keyboardMode = this.parseKeyboardMode(fields);
    host.workspaceId = fields.get('workspaceid') ?? fields.get('remotefeed') ?? '';

    return host;
  }

  generateRdpFile(host: RemoteHost): string {
    const lines: string[] = [
      '; 由 RemoteDesk HarmonyOS 导出',
      '; RDP 文件格式 10.0',
      '',
      `full address:s:${host.host}:${host.port}`,
      `username:s:${host.username}`,
      `screen mode id:i:${host.displayConfig.useAllMonitors ? 2 : 1}`,
      `desktopwidth:i:${host.displayConfig.width}`,
      `desktopheight:i:${host.displayConfig.height}`,
      `session bpp:i:${host.displayConfig.colorDepth}`,
      '',
      '; 重定向设置',
      `redirectclipboard:i:${host.redirection.clipboard ? 1 : 0}`,
      `redirectprinters:i:${host.redirection.printer ? 1 : 0}`,
      `redirectmicrophone:i:${host.redirection.microphone ? 1 : 0}`,
      `redirectcamera:i:${host.redirection.camera ? 1 : 0}`,
      `redirectsmartcards:i:${host.redirection.smartcard ? 1 : 0}`,
      `devicestoredirect:s:*`,
      `drivestoredirect:s:${host.redirection.folder ? host.redirection.folderPath : ''}`,
      '',
      '; 体验设置',
      `connection type:i:${this.sessionQualityToRdp(host.sessionQuality)}`,
      `networkautodetect:i:${host.sessionQuality === SessionQuality.AUTO ? 1 : 0}`,
      '',
      '; 网关设置',
    ];

    if (host.gateway && host.gateway.host.length > 0) {
      lines.push(
        `gatewayhostname:s:${host.gateway.host}`,
        `gatewayusagemethod:i:${host.gateway.bypassLocal ? 4 : 2}`,
        `gatewaycredentialssource:i:0`,
        `gatewayprofileusagemethod:i:0`,
      );
    } else {
      lines.push('gatewayhostname:s:');
    }

    lines.push(
      '',
      '; 键盘设置',
      `keyboardhook:i:${this.keyboardModeToRdp(host.keyboardMode)}`,
      '',
      '; 身份验证',
      'authentication level:i:2',
      'prompt for credentials:i:1',
      'enablecredsspsupport:i:1',
      '',
      '; 其他',
      'audiomode:i:0',
      'audiocapturemode:i:1',
      'videoplaybackmode:i:1',
      'disable fullscreen optimization:i:0',
      'allow font smoothing:i:1',
      'allow desktop composition:i:1',
    );

    return lines.join('\r\n');
  }

  private createPlaceholderHost(): RemoteHost {
    return {
      id: 'rdp_import_' + Date.now(),
      userId: '',
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
      displayConfig: { width: 1920, height: 1080, useAllMonitors: false, colorDepth: 32 },
      redirection: {
        clipboard: true, printer: false, microphone: false,
        camera: false, folder: false, folderPath: '', smartcard: false
      },
      keyboardMode: KeyboardMode.GENERIC,
      thumbnail: '',
      lastConnected: 0,
      tags: [],
      workspaceId: ''
    };
  }

  private parseHost(fields: Map<string, string>): string {
    const fullAddress = fields.get('full address');
    if (fullAddress) {
      const parts = fullAddress.split(':');
      return parts[0];
    }
    return fields.get('server') ?? '';
  }

  private parsePort(fields: Map<string, string>): number {
    const fullAddress = fields.get('full address');
    if (fullAddress) {
      const parts = fullAddress.split(':');
      if (parts.length > 1) {
        const port = parseInt(parts[parts.length - 1], 10);
        if (!isNaN(port)) return port;
      }
    }
    const serverPort = fields.get('server port');
    if (serverPort) {
      const port = parseInt(serverPort, 10);
      if (!isNaN(port)) return port;
    }
    return 3389;
  }

  private parseDisplayConfig(fields: Map<string, string>): { width: number; height: number; useAllMonitors: boolean; colorDepth: number } {
    const screenMode = parseInt(fields.get('screen mode id') ?? '1', 10);
    return {
      width: parseInt(fields.get('desktopwidth') ?? '1920', 10),
      height: parseInt(fields.get('desktopheight') ?? '1080', 10),
      useAllMonitors: screenMode === 2,
      colorDepth: parseInt(fields.get('session bpp') ?? '32', 10)
    };
  }

  private parseRedirectionConfig(fields: Map<string, string>): RemoteHost['redirection'] {
    return {
      clipboard: fields.get('redirectclipboard') !== '0',
      printer: fields.get('redirectprinters') === '1',
      microphone: fields.get('redirectmicrophone') === '1',
      camera: fields.get('redirectcamera') === '1',
      folder: (fields.get('drivestoredirect')?.length ?? 0) > 0,
      folderPath: fields.get('drivestoredirect') ?? '',
      smartcard: fields.get('redirectsmartcards') === '1'
    };
  }

  private parseSessionQuality(fields: Map<string, string>): SessionQuality {
    const connType = fields.get('connection type');
    if (connType === '3' || connType === '6') return SessionQuality.BEST_PERFORMANCE;
    if (connType === '1' || connType === '2') return SessionQuality.BEST_QUALITY;
    return SessionQuality.AUTO;
  }

  private parseGatewayConfig(fields: Map<string, string>): GatewayConfig | null {
    const host = fields.get('gatewayhostname');
    if (!host || host.length === 0) return null;
    const usageMethod = parseInt(fields.get('gatewayusagemethod') ?? '0', 10);
    return {
      host: host,
      port: parseInt(fields.get('gatewayport') ?? '443', 10),
      username: fields.get('gatewayusername') ?? '',
      password: '',
      bypassLocal: usageMethod === 4
    };
  }

  private parseKeyboardMode(fields: Map<string, string>): KeyboardMode {
    const hook = parseInt(fields.get('keyboardhook') ?? '0', 10);
    if (hook === 1) return KeyboardMode.WINDOWS;
    if (hook === 2) return KeyboardMode.MACOS;
    return KeyboardMode.GENERIC;
  }

  private sessionQualityToRdp(quality: SessionQuality): number {
    switch (quality) {
      case SessionQuality.BEST_QUALITY: return 1;
      case SessionQuality.BEST_PERFORMANCE: return 3;
      case SessionQuality.AUTO:
      default: return 7;
    }
  }

  private keyboardModeToRdp(mode: KeyboardMode): number {
    switch (mode) {
      case KeyboardMode.MACOS: return 2;
      case KeyboardMode.WINDOWS: return 1;
      case KeyboardMode.GENERIC:
      default: return 0;
    }
  }
}
