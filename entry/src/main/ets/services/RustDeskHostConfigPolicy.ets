/**
 * RustDeskHostConfigPolicy — RustDesk host add/edit pure rules
 */
import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';
import { RustDeskRelayKeyMode, resolveRustDeskRelayKey } from './RustDeskRelayKeyPolicy';

export interface RustDeskHostEndpoint {
  host: string;
  port: number;
}

export interface RustDeskConnectionCheckInput {
  directEnabled: boolean;
  directHost: string;
  directPort: number;
  relayId: string;
  relayExists: boolean;
  relayHost: string;
  relayPort: number;
  relayKey: string;
  relayKeyMode?: RustDeskRelayKeyMode;
  proManaged: boolean;
}

export const RUSTDESK_ID_SERVER_PORT: number = 21116;
export const RUSTDESK_PEER_TCP_PORT: number = 21118;

/**
 * Validate a configured rendezvous credential.  Standard Ed25519 public
 * keys retain their strict 32-byte Base64 invariant; explicit/legacy shared
 * access keys are sent to hbbs/hbbr as the exact `licence_key` text.
 */
export function rustDeskServerKeyError(value: string, required: boolean = false,
  mode: RustDeskRelayKeyMode = 'auto'): string {
  // This compatibility wrapper is used on persisted connection records. A
  // legacy auto `1:` value can therefore still mean locked DataCrypto state.
  // Import/manual-entry flows call resolveRustDeskRelayKey directly, allowing
  // an administrator's literal shared `1:` Key.
  if (mode !== 'shared_access_key' && value.trimStart().startsWith('1:')) {
    return 'RustDesk 中继服务器密钥已加密且当前未解锁，请先解锁数据';
  }
  return resolveRustDeskRelayKey(value, mode, required).error;
}

/**
 * 连接前校验 RustDesk 的地址来源。
 * 非直连主机的 host 只是历史兼容字段，不能再作为 relay 绑定的替代品。
 * 普通 OSS 中继允许没有 server key；只有 Server Pro 托管主机必须提供 key。
 */
export function rustDeskConnectionError(input: RustDeskConnectionCheckInput): string {
  if (input.directEnabled) {
    if (input.directHost.trim().length === 0) {
      return 'RustDesk 直连地址为空';
    }
    if (input.directPort <= 0 || input.directPort > 65535) {
      return 'RustDesk 直连端口无效';
    }
    return '';
  }
  if (input.relayId.trim().length === 0) {
    return 'RustDesk 中继连接未绑定中继配置';
  }
  if (!input.relayExists) {
    return 'RustDesk 绑定的中继配置不存在，请重新选择';
  }
  if (input.relayHost.trim().length === 0) {
    return 'RustDesk 中继配置缺少 ID 服务器地址';
  }
  if (input.relayPort <= 0 || input.relayPort > 65535) {
    return 'RustDesk 中继 ID 服务器端口无效';
  }
  const serverKeyError: string = rustDeskServerKeyError(input.relayKey, input.proManaged,
    input.relayKeyMode ?? 'auto');
  if (serverKeyError !== '') {
    return serverKeyError;
  }
  return '';
}

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

export function shouldBindLegacyRustDeskHostToRelay(protocol: string, directEnabled: boolean,
  relayId: string, host: string, port: number, relayHost: string, relayPort: number): boolean {
  return protocol === 'rustdesk' && !directEnabled && relayId.trim().length === 0 &&
    host.trim().toLowerCase() === relayHost.trim().toLowerCase() &&
    normalizeRustDeskPort(port) === normalizeRustDeskPort(relayPort);
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
