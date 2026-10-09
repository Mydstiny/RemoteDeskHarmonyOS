/**
 * 主机健康中心 (Pro, plan 2026-10-09 §1): why a host can or cannot be reached, from the probes the host list already
 * runs, in plain words; and the short local history kept per host. Pure policy: no ArkUI, storage or native calls.
 *
 * The probes each report in their own terms (RDP certificate preflight codes, the VNC certificate probe's category,
 * the SSH host-key probe's codes, RustDesk peer presence, Moonlight server info). Every one of them maps to one of
 * eight states and a code from a fixed list; anything unrecognised is `unknown`, never a guess.
 */

export type HostHealthStatus = 'reachable' | 'route_unavailable' | 'timeout' | 'trust_required' |
  'remote_rejected' | 'peer_offline' | 'capability_unsupported' | 'unknown';

export type HostHealthRoute = 'direct' | 'gateway' | 'relay' | 'proxy' | 'unknown';

export type HostHealthAddressFamily = 'ipv4' | 'ipv6' | 'unknown';

/** What to offer next to a state: one plain button, or none. */
export type HostHealthAction = 'none' | 'retry' | 'check_network' | 'edit_host' | 'confirm_certificate' |
  'review_fingerprint' | 'check_relay' | 'pair_moonlight';

/** Where an observation came from: a health check, or a real connection attempt. */
export type HostHealthSource = 'probe' | 'connect';

export const HOST_HEALTH_SCHEMA_VERSION: number = 1;
/** Observations kept per host, newest first. */
export const HOST_HEALTH_HISTORY_LIMIT: number = 20;
/** Older than this, a result is shown greyed as 「待刷新」 rather than as the current state. */
export const HOST_HEALTH_STALE_AFTER_MS: number = 60 * 60 * 1000;

export interface HostHealthVerdict {
  status: HostHealthStatus;
  /** One of HOST_HEALTH_CODES. */
  code: string;
}

export interface HostHealthObservation {
  schemaVersion: number;
  hostId: string;
  protocol: string;
  observedAt: number;
  status: HostHealthStatus;
  code: string;
  /** Round-trip of the check; -1 when it did not complete. */
  latencyMs: number;
  route: HostHealthRoute;
  addressFamily: HostHealthAddressFamily;
  source: HostHealthSource;
}

/** The only codes an observation may carry (they reach exports and the AI, so they are a closed list). */
export const HOST_HEALTH_CODES: string[] = [
  'OK',
  'I-CERT-UNCONFIRMED',
  'I-SSH-HOSTKEY-UNSAVED',
  'E-ENDPOINT-INVALID',
  'E-DNS',
  'E-TCP',
  'E-TIMEOUT',
  'E-NETWORK-CHANGED',
  'E-NEGOTIATION',
  'E-TLS',
  'E-CERT',
  'E-CERT-CHANGED',
  'E-HOSTKEY-CHANGED',
  'E-HANDSHAKE',
  'E-ROUTE-UNSUPPORTED',
  'E-GATEWAY-DNS',
  'E-GATEWAY-TLS',
  'E-GATEWAY-CERT',
  'E-GATEWAY-AUTH-REQUIRED',
  'E-PEER-OFFLINE',
  'E-PRESENCE-UNSUPPORTED',
  'E-MOONLIGHT-UNPAIRED',
  'E-UNKNOWN'
];

function verdict(status: HostHealthStatus, code: string): HostHealthVerdict {
  return { status, code: HOST_HEALTH_CODES.indexOf(code) >= 0 ? code : 'E-UNKNOWN' };
}

function normalizedFingerprint(value: string): string {
  return (value ?? '').trim().toUpperCase();
}

/**
 * A reachable TLS endpoint: trusted by a root and named right, or already confirmed by the user (its fingerprint
 * saved) — reachable; a saved fingerprint that changed — trust_required; never confirmed — reachable, with a note
 * that the first connection will ask to confirm the certificate.
 */
function certificateVerdict(rootTrusted: boolean, hostMismatch: boolean, fingerprint: string,
  savedFingerprint: string): HostHealthVerdict {
  const seen: string = normalizedFingerprint(fingerprint);
  const saved: string = normalizedFingerprint(savedFingerprint);
  if (saved.length > 0 && seen.length > 0 && saved !== seen) { return verdict('trust_required', 'E-CERT-CHANGED'); }
  if (saved.length > 0 && saved === seen) { return verdict('reachable', 'OK'); }
  if (rootTrusted && !hostMismatch) { return verdict('reachable', 'OK'); }
  return verdict('reachable', 'I-CERT-UNCONFIRMED');
}

export interface RdpProbeOutcome {
  ok: boolean;
  /** RdpCertificateInfo.errorCode: the native preflight's stage (-11 DNS, -12 TCP, -14 timeout …). */
  errorCode: number;
  rootTrusted: boolean;
  hostMismatch: boolean;
  fingerprintSha256: string;
  /** The certificate the user confirmed for this host before; '' when none. */
  savedFingerprintSha256: string;
}

/** The native direct-RDP preflight code (freerdp_adapter directRdpPreflightErrorCode) as a health verdict. */
export function rdpProbeHealth(outcome: RdpProbeOutcome): HostHealthVerdict {
  if (outcome.ok) {
    return certificateVerdict(outcome.rootTrusted, outcome.hostMismatch, outcome.fingerprintSha256,
      outcome.savedFingerprintSha256);
  }
  switch (outcome.errorCode) {
    case -10: return verdict('unknown', 'E-ENDPOINT-INVALID');
    case -11: return verdict('route_unavailable', 'E-DNS');
    case -12: return verdict('route_unavailable', 'E-TCP');
    case -14: return verdict('timeout', 'E-TIMEOUT');
    case -39: return verdict('unknown', 'E-NETWORK-CHANGED');
    case -13: case -18: case -19: case -20: case -21: return verdict('remote_rejected', 'E-NEGOTIATION');
    case -15: case -16: case -22: case -23: case -24: return verdict('remote_rejected', 'E-TLS');
    case -17: case -25: return verdict('trust_required', 'E-CERT');
    default: return verdict('unknown', 'E-UNKNOWN');
  }
}

/** The RD Gateway route preflight's string codes (RdpRouteCertificateProbeResult.errorCode). */
export function rdpGatewayProbeHealth(errorCode: string): HostHealthVerdict {
  switch (errorCode) {
    case '': return verdict('reachable', 'OK');
    case 'E-RDP-GATEWAY-DNS': return verdict('route_unavailable', 'E-GATEWAY-DNS');
    case 'E-RDP-GATEWAY-TLS': return verdict('remote_rejected', 'E-GATEWAY-TLS');
    case 'E-RDP-GATEWAY-CERT': return verdict('trust_required', 'E-GATEWAY-CERT');
    case 'E-RDP-TARGET-CERT': return verdict('trust_required', 'E-CERT');
    case 'E-RDP-GATEWAY-AUTH-REQUIRED': return verdict('capability_unsupported', 'E-GATEWAY-AUTH-REQUIRED');
    case 'E-RDP-NEGOTIATION': return verdict('remote_rejected', 'E-NEGOTIATION');
    case 'E-RDP-TARGET-DNS': return verdict('route_unavailable', 'E-DNS');
    case 'E-RDP-TARGET-TCP': return verdict('route_unavailable', 'E-TCP');
    case 'E-RDP-TARGET-TIMEOUT': return verdict('timeout', 'E-TIMEOUT');
    case 'E-RDP-TARGET-TLS': return verdict('remote_rejected', 'E-TLS');
    case 'E-RDP-NETWORK-CHANGED': return verdict('unknown', 'E-NETWORK-CHANGED');
    default: return verdict('unknown', 'E-UNKNOWN');
  }
}

export interface VncProbeOutcome {
  ok: boolean;
  /** VncCertificateInfo.errorMessageCategory (vncCertificateProbeErrorCategory). */
  errorCategory: string;
  rootTrusted: boolean;
  hostMismatch: boolean;
  fingerprintSha256: string;
  savedFingerprintSha256: string;
}

export function vncProbeHealth(outcome: VncProbeOutcome): HostHealthVerdict {
  if (outcome.ok) {
    return certificateVerdict(outcome.rootTrusted, outcome.hostMismatch, outcome.fingerprintSha256,
      outcome.savedFingerprintSha256);
  }
  switch (outcome.errorCategory) {
    case 'invalid_input': return verdict('unknown', 'E-ENDPOINT-INVALID');
    case 'resolve_failed': return verdict('route_unavailable', 'E-DNS');
    case 'connect_failed': return verdict('route_unavailable', 'E-TCP');
    case 'resolve_timeout': case 'connect_timeout': case 'tls_timeout': return verdict('timeout', 'E-TIMEOUT');
    case 'tls_handshake_failed': case 'tls_version_rejected': case 'tls_context_failed':
      return verdict('remote_rejected', 'E-TLS');
    case 'no_certificate': case 'fingerprint_failed': case 'metadata_failed': case 'certificate_chain_too_deep':
      return verdict('trust_required', 'E-CERT');
    default: return verdict('unknown', 'E-UNKNOWN');
  }
}

export interface SshProbeOutcome {
  ok: boolean;
  /** SshHostKeyInfo.errorCode: -1 connect, -2 session, -3 key exchange, -4 host key, -5 route unsupported. */
  errorCode: number;
  errorMessage: string;
  fingerprintSha256: string;
  /** RemoteHost.sshHostKeyFingerprintSha256 (the key the user trusted); '' when none yet. */
  savedFingerprintSha256: string;
}

export function sshProbeHealth(outcome: SshProbeOutcome): HostHealthVerdict {
  if (outcome.ok) {
    const seen: string = normalizedFingerprint(outcome.fingerprintSha256);
    const saved: string = normalizedFingerprint(outcome.savedFingerprintSha256);
    if (saved.length > 0 && seen.length > 0 && saved !== seen) {
      return verdict('trust_required', 'E-HOSTKEY-CHANGED');
    }
    return verdict('reachable', saved.length > 0 ? 'OK' : 'I-SSH-HOSTKEY-UNSAVED');
  }
  switch (outcome.errorCode) {
    case -1: {
      const message: string = (outcome.errorMessage ?? '').toLowerCase();
      return message.includes('timed out') || message.includes('timeout') ?
        verdict('timeout', 'E-TIMEOUT') : verdict('route_unavailable', 'E-TCP');
    }
    case -3: return verdict('remote_rejected', 'E-HANDSHAKE');
    case -4: return verdict('remote_rejected', 'E-HANDSHAKE');
    case -5: return verdict('capability_unsupported', 'E-ROUTE-UNSUPPORTED');
    default: return verdict('unknown', 'E-UNKNOWN');
  }
}

/** RustDesk peer presence as the host list reads it: 1 online, 2 offline, anything else unknown. */
export function rustDeskPresenceHealth(state: number, directMode: boolean, timedOut: boolean): HostHealthVerdict {
  if (directMode) { return verdict('capability_unsupported', 'E-PRESENCE-UNSUPPORTED'); }
  if (timedOut) { return verdict('timeout', 'E-TIMEOUT'); }
  if (state === 1) { return verdict('reachable', 'OK'); }
  if (state === 2) { return verdict('peer_offline', 'E-PEER-OFFLINE'); }
  return verdict('unknown', 'E-UNKNOWN');
}

/** Moonlight server info: answered and paired, answered but not paired, or not answering. */
export function moonlightPresenceHealth(answered: boolean, paired: boolean, timedOut: boolean): HostHealthVerdict {
  if (answered && paired) { return verdict('reachable', 'OK'); }
  if (answered) { return verdict('trust_required', 'E-MOONLIGHT-UNPAIRED'); }
  if (timedOut) { return verdict('timeout', 'E-TIMEOUT'); }
  return verdict('peer_offline', 'E-PEER-OFFLINE');
}

/** The address a probe reached, as IPv4 or IPv6. */
export function healthAddressFamily(address: string): HostHealthAddressFamily {
  const value: string = (address ?? '').trim();
  if (value.length === 0) { return 'unknown'; }
  if (value.indexOf(':') >= 0) { return 'ipv6'; }
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(value) ? 'ipv4' : 'unknown';
}

/** The state in plain words, as the card and the 「健康」 page show it. */
export function hostHealthStatusLabel(status: HostHealthStatus): string {
  switch (status) {
    case 'reachable': return '可以连接';
    case 'route_unavailable': return '找不到主机或网络不通';
    case 'timeout': return '连接超时';
    case 'trust_required': return '需要确认';
    case 'remote_rejected': return '远端拒绝了连接';
    case 'peer_offline': return '对端不在线';
    case 'capability_unsupported': return '这台主机不支持检测';
    default: return '无法判断';
  }
}

/** What the code means, one sentence; '' when the label already says it. */
export function hostHealthCodeDetail(code: string): string {
  switch (code) {
    case 'I-CERT-UNCONFIRMED': return '证书还没有确认过，第一次连接时会请你确认。';
    case 'I-SSH-HOSTKEY-UNSAVED': return '还没有保存这台主机的指纹，第一次连接时会请你确认。';
    case 'E-ENDPOINT-INVALID': return '主机地址或端口填写有误。';
    case 'E-DNS': return '找不到这个主机名，检查地址拼写或 DNS。';
    case 'E-TCP': return '能找到主机，但端口没有响应：服务没开、端口不对，或被防火墙挡住。';
    case 'E-TIMEOUT': return '等了很久没有回应，网络可能不稳定，或中间有设备丢弃了连接。';
    case 'E-NETWORK-CHANGED': return '检测过程中网络切换了，请重试。';
    case 'E-NEGOTIATION': return '远端不接受这种连接方式，例如只允许某种安全层。';
    case 'E-TLS': return '加密握手失败，远端的加密设置和本机不兼容。';
    case 'E-CERT': return '证书有问题，需要你确认后才能连接。';
    case 'E-CERT-CHANGED': return '证书和你之前确认的不一样了，请确认是不是正常更换。';
    case 'E-HOSTKEY-CHANGED': return '主机指纹和之前保存的不一样了，请确认是不是重装或更换了服务器。';
    case 'E-HANDSHAKE': return 'SSH 握手失败，远端的加密算法和本机不兼容。';
    case 'E-ROUTE-UNSUPPORTED': return '这种连接方式（代理或跳板）暂不支持检测。';
    case 'E-GATEWAY-DNS': return '找不到 RD 网关。';
    case 'E-GATEWAY-TLS': return '和 RD 网关的加密握手失败。';
    case 'E-GATEWAY-CERT': return 'RD 网关的证书需要确认。';
    case 'E-GATEWAY-AUTH-REQUIRED': return 'RD 网关需要登录后才能继续检测。';
    case 'E-PEER-OFFLINE': return '对端设备现在不在线。';
    case 'E-PRESENCE-UNSUPPORTED': return '直连模式的 RustDesk 主机无法检测在线状态。';
    case 'E-MOONLIGHT-UNPAIRED': return '电脑在线，但还没有和本机配对。';
    default: return '';
  }
}

/** The one thing to offer next to a verdict (a RustDesk peer that is offline may be a relay problem). */
export function hostHealthAction(v: HostHealthVerdict, protocol: string): HostHealthAction {
  switch (v.code) {
    case 'E-CERT': case 'E-CERT-CHANGED': case 'E-GATEWAY-CERT': return 'confirm_certificate';
    case 'E-HOSTKEY-CHANGED': return 'review_fingerprint';
    case 'E-ENDPOINT-INVALID': case 'E-DNS': case 'E-GATEWAY-DNS': return 'edit_host';
    case 'E-TCP': case 'E-TIMEOUT': return 'check_network';
    case 'E-PEER-OFFLINE': return protocol === 'rustdesk' ? 'check_relay' : 'retry';
    case 'E-MOONLIGHT-UNPAIRED': return 'pair_moonlight';
    case 'E-NETWORK-CHANGED': case 'E-UNKNOWN': return 'retry';
    default: return 'none';
  }
}

export function isHostHealthStatus(value: string): boolean {
  return value === 'reachable' || value === 'route_unavailable' || value === 'timeout' ||
    value === 'trust_required' || value === 'remote_rejected' || value === 'peer_offline' ||
    value === 'capability_unsupported' || value === 'unknown';
}

function isRoute(value: string): boolean {
  return value === 'direct' || value === 'gateway' || value === 'relay' || value === 'proxy' || value === 'unknown';
}

function isAddressFamily(value: string): boolean {
  return value === 'ipv4' || value === 'ipv6' || value === 'unknown';
}

/** A stored observation, checked field by field: anything malformed is dropped rather than shown. */
export function normalizeHostHealthObservation(raw: Object | null | undefined): HostHealthObservation | null {
  if (raw === null || raw === undefined || typeof raw !== 'object') { return null; }
  const value: Record<string, Object> = raw as Record<string, Object>;
  const hostId: Object = value['hostId'];
  const protocol: Object = value['protocol'];
  const observedAt: Object = value['observedAt'];
  const status: Object = value['status'];
  const code: Object = value['code'];
  const latencyMs: Object = value['latencyMs'];
  const route: Object = value['route'];
  const family: Object = value['addressFamily'];
  const source: Object = value['source'];
  if (value['schemaVersion'] !== HOST_HEALTH_SCHEMA_VERSION || typeof hostId !== 'string' ||
    (hostId as string).length === 0 ||
    typeof protocol !== 'string' || typeof observedAt !== 'number' || !Number.isFinite(observedAt as number) ||
    (observedAt as number) <= 0 || typeof status !== 'string' || !isHostHealthStatus(status as string) ||
    typeof code !== 'string' || HOST_HEALTH_CODES.indexOf(code as string) < 0 || typeof latencyMs !== 'number' ||
    !Number.isFinite(latencyMs as number) || typeof route !== 'string' || !isRoute(route as string) ||
    typeof family !== 'string' || !isAddressFamily(family as string) ||
    (source !== 'probe' && source !== 'connect')) {
    return null;
  }
  return {
    schemaVersion: HOST_HEALTH_SCHEMA_VERSION,
    hostId: hostId as string,
    protocol: protocol as string,
    observedAt: Math.floor(observedAt as number),
    status: status as HostHealthStatus,
    code: code as string,
    latencyMs: (latencyMs as number) >= 0 ? Math.min(600000, Math.round(latencyMs as number)) : -1,
    route: route as HostHealthRoute,
    addressFamily: family as HostHealthAddressFamily,
    source: source as HostHealthSource
  };
}

/** The history with `observation` added: newest first, one host only, at most HOST_HEALTH_HISTORY_LIMIT. */
export function appendHostHealthObservation(history: HostHealthObservation[],
  observation: HostHealthObservation): HostHealthObservation[] {
  const kept: HostHealthObservation[] = history.filter((item: HostHealthObservation): boolean =>
    item.hostId === observation.hostId && item.observedAt !== observation.observedAt);
  kept.push(observation);
  kept.sort((a: HostHealthObservation, b: HostHealthObservation): number => b.observedAt - a.observedAt);
  return kept.slice(0, HOST_HEALTH_HISTORY_LIMIT);
}

/** Too old to show as the current state. A time in the future (clock moved back) also counts as stale. */
export function isHostHealthStale(observedAt: number, now: number,
  maxAgeMs: number = HOST_HEALTH_STALE_AFTER_MS): boolean {
  if (!Number.isFinite(observedAt) || observedAt <= 0) { return true; }
  return now - observedAt > maxAgeMs || observedAt > now + 60000;
}

/** 「刚刚」「3 分钟前」「2 小时前」「昨天」「3 天前」 next to the health dot. */
export function hostHealthAgeLabel(observedAt: number, now: number): string {
  const age: number = Math.max(0, now - observedAt);
  const minutes: number = Math.floor(age / 60000);
  if (minutes < 1) { return '刚刚'; }
  if (minutes < 60) { return minutes.toString() + ' 分钟前'; }
  const hours: number = Math.floor(minutes / 60);
  if (hours < 24) { return hours.toString() + ' 小时前'; }
  const days: number = Math.floor(hours / 24);
  return days === 1 ? '昨天' : days.toString() + ' 天前';
}
