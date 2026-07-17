/**
 * RustDeskHostConfigPolicy — RustDesk host add/edit pure rules
 */
import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';

export interface RustDeskHostEndpoint {
  host: string;
  port: number;
}

export const RUSTDESK_ID_SERVER_PORT: number = 21116;
export const RUSTDESK_PEER_TCP_PORT: number = 21118;

/**
 * 直连没有 ID/中继批准通道，只能使用被控端设备密码。
 * 统一在表单保存和连接参数生成处调用，兼容旧版本已保存的组合。
 */
export function rustDeskAuthModeForConnection(directEnabled: boolean, requestedMode: string): string {
  if (directEnabled) {
    return 'password';
  }
  return requestedMode === 'request_approval' ? 'request_approval' : 'password';
}

export function normalizeRustDeskPort(port: number, fallback: number = RUSTDESK_ID_SERVER_PORT): number {
  return port > 0 && port <= 65535 ? port : fallback;
}

export function rustDeskCardEndpoint(directEnabled: boolean, directHost: string, directPort: number,
  host: string, port: number): string {
  const displayHost: string = directEnabled ? directHost.trim() : host.trim();
  const displayPort: number = directEnabled ?
    normalizeRustDeskPort(directPort, RUSTDESK_PEER_TCP_PORT) : port;
  return displayHost + ':' + displayPort;
}

export function shouldAdoptRustDeskDirectPort(directEnabled: boolean, hostDirectPort: number,
  previousDefaultPort: number): boolean {
  return directEnabled && hostDirectPort === previousDefaultPort;
}

export function resolveRustDeskHostEndpoint(relay: RustDeskRelayConfig | null, fallbackHost: string,
  directEnabled: boolean, directHost: string, directPort: number): RustDeskHostEndpoint {
  if (directEnabled) {
    return {
      host: directHost.trim(),
      port: normalizeRustDeskPort(directPort, RUSTDESK_PEER_TCP_PORT)
    };
  }
  if (relay !== null) {
    return {
      host: relay.idServer.trim(),
      port: normalizeRustDeskPort(relay.idServerPort)
    };
  }
  return {
    host: fallbackHost.trim(),
    port: RUSTDESK_ID_SERVER_PORT
  };
}
