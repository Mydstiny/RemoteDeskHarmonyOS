/**
 * RustDesk direct-IP routing evidence.
 *
 * Direct connections are used for LAN addresses and for overlay networks such
 * as EasyTier/ZeroTier/Tailscale, where the overlay only provides a reachable
 * virtual address and RustDesk itself still speaks its direct-IP protocol on
 * the peer's TCP port. Overlay membership cannot be proven from an address,
 * so the source is recorded as how the endpoint was configured
 * (manual address vs. LAN discovery) and the address is reduced to a closed,
 * address-free class. Failures are split into input / TCP / login / first
 * frame stages from the native RDERR record so "direct failed" never collapses
 * into one generic code.
 */
import { RemoteHost } from '../model/RemoteHost';
import {
  EndpointAddress,
  EndpointAddressResult,
  endpointTransportHost,
  parseEndpointFields
} from './EndpointAddressPolicy';
import { RustDeskNativeErrorInfo, parseRustDeskNativeError } from './RustDeskProConnectionPreflightPolicy';

export type RustDeskDirectEndpointSource = 'relay' | 'manual_direct' | 'lan_discovery';

export type RustDeskDirectAddressClass =
  'invalid' | 'hostname' | 'ipv4_private' | 'ipv4_shared' | 'ipv4_loopback' |
  'ipv4_link_local' | 'ipv4_public' | 'ipv6_unique_local' | 'ipv6_link_local' |
  'ipv6_loopback' | 'ipv6_global' | 'not_applicable';

export type RustDeskDirectStage =
  'unknown' | 'validation' | 'input' | 'tcp_timeout' | 'tcp_refused' | 'tcp_unreachable' |
  'tcp_interrupted' | 'tcp_failed' | 'login_password' | 'login_rejected' | 'login_failed' |
  'first_frame' | 'cancelled' | 'connected';

const SOURCES: RustDeskDirectEndpointSource[] = ['relay', 'manual_direct', 'lan_discovery'];
const ADDRESS_CLASSES: RustDeskDirectAddressClass[] = [
  'invalid', 'hostname', 'ipv4_private', 'ipv4_shared', 'ipv4_loopback', 'ipv4_link_local',
  'ipv4_public', 'ipv6_unique_local', 'ipv6_link_local', 'ipv6_loopback', 'ipv6_global',
  'not_applicable'
];
const STAGES: RustDeskDirectStage[] = [
  'unknown', 'validation', 'input', 'tcp_timeout', 'tcp_refused', 'tcp_unreachable',
  'tcp_interrupted', 'tcp_failed', 'login_password', 'login_rejected', 'login_failed',
  'first_frame', 'cancelled', 'connected'
];

/** Stable numeric codes for the address-free diagnostic event. */
export function rustDeskDirectSourceCode(source: RustDeskDirectEndpointSource): number {
  return SOURCES.indexOf(source);
}

export function rustDeskDirectAddressClassCode(addressClass: RustDeskDirectAddressClass): number {
  return ADDRESS_CLASSES.indexOf(addressClass);
}

export function rustDeskDirectStageCode(stage: RustDeskDirectStage): number {
  return STAGES.indexOf(stage);
}

export function rustDeskDirectEndpointSource(host: RemoteHost): RustDeskDirectEndpointSource {
  if (!host.rustdeskDirectEnabled) { return 'relay'; }
  const discovered: boolean = host.lanDiscoveryIdentity.trim() !== '' &&
    (host.lanAddressMode === 'static' || host.lanAddressMode === 'dynamic');
  return discovered ? 'lan_discovery' : 'manual_direct';
}

function ipv4Octets(value: string): number[] {
  const parts: string[] = value.split('.');
  if (parts.length !== 4) { return []; }
  const result: number[] = [];
  for (let index: number = 0; index < parts.length; index++) {
    const octet: number = Number(parts[index]);
    if (!Number.isInteger(octet) || octet < 0 || octet > 255) { return []; }
    result.push(octet);
  }
  return result;
}

function ipv4Class(value: string): RustDeskDirectAddressClass {
  const o: number[] = ipv4Octets(value);
  if (o.length !== 4) { return 'invalid'; }
  if (o[0] === 127) { return 'ipv4_loopback'; }
  if (o[0] === 169 && o[1] === 254) { return 'ipv4_link_local'; }
  if (o[0] === 10 || (o[0] === 172 && o[1] >= 16 && o[1] <= 31) ||
    (o[0] === 192 && o[1] === 168)) { return 'ipv4_private'; }
  // 100.64.0.0/10 shared address space: carrier NAT and several overlays.
  if (o[0] === 100 && o[1] >= 64 && o[1] <= 127) { return 'ipv4_shared'; }
  return 'ipv4_public';
}

function ipv6Class(value: string): RustDeskDirectAddressClass {
  const lower: string = value.toLowerCase();
  if (lower === '::1') { return 'ipv6_loopback'; }
  const firstGroup: string = lower.split(':')[0];
  const first: number = firstGroup === '' ? 0 : parseInt(firstGroup, 16);
  if (!Number.isFinite(first)) { return 'invalid'; }
  if ((first & 0xffc0) === 0xfe80) { return 'ipv6_link_local'; }
  // fc00::/7 unique local: used by EasyTier/ZeroTier IPv6 virtual networks.
  if ((first & 0xfe00) === 0xfc00) { return 'ipv6_unique_local'; }
  return 'ipv6_global';
}

/** Address-free class of a configured direct endpoint. */
export function rustDeskDirectAddressClass(host: string, port: number): RustDeskDirectAddressClass {
  const parsed: EndpointAddressResult = parseEndpointFields(host, port > 0 ? port : 1);
  if (!parsed.ok) { return 'invalid'; }
  const endpoint: EndpointAddress = parsed.endpoint;
  if (endpoint.family === 'hostname') { return 'hostname'; }
  if (endpoint.family === 'ipv4') { return ipv4Class(endpoint.canonicalHost); }
  return endpoint.scope !== '' ? 'ipv6_link_local' : ipv6Class(endpoint.canonicalHost);
}

/** Splits a native RustDesk failure on the direct route into a closed stage. */
export function rustDeskDirectFailureStage(message: string): RustDeskDirectStage {
  const upper: string = message.toUpperCase();
  if (upper.indexOf('FIRST-FRAME') >= 0) { return 'first_frame'; }
  if (upper.indexOf('E-RUSTDESK-CANCELLED') >= 0) { return 'cancelled'; }
  const parsed: RustDeskNativeErrorInfo = parseRustDeskNativeError(message);
  if (!parsed.structured) { return 'unknown'; }
  if (parsed.code === 'cancelled') { return 'cancelled'; }
  // Authentication codes decide the stage whatever native state reported
  // them, so a password failure never shows a TCP/overlay hint.
  if (parsed.code === 'peer_password_rejected') { return 'login_password'; }
  if (parsed.code === 'peer_password_required' || parsed.code === 'approval_unavailable') {
    return 'login_rejected';
  }
  const detail: string = parsed.detail.toLowerCase();
  if (parsed.stage === 'peer_login') { return 'login_failed'; }
  if (parsed.stage === 'peer_channel' || parsed.code === 'direct_peer_connect_failed') {
    if (detail.indexOf('configuration is invalid') >= 0) { return 'input'; }
    if (detail.indexOf('timed out') >= 0) { return 'tcp_timeout'; }
    if (detail.indexOf('refused') >= 0) { return 'tcp_refused'; }
    if (detail.indexOf('unavailable') >= 0 || detail.indexOf('denied') >= 0) {
      return 'tcp_unreachable';
    }
    if (detail.indexOf('interrupted') >= 0) { return 'tcp_interrupted'; }
    return 'tcp_failed';
  }
  if (parsed.stage === 'config') { return 'input'; }
  return 'unknown';
}

/**
 * User-facing direct failure text. It names the layer that failed and, for
 * TCP failures, the overlay/peer settings that are the usual cause.
 */
export function rustDeskDirectFailureMessage(stage: RustDeskDirectStage, port: number): string {
  const portText: string = port > 0 ? port.toString() : '21118';
  switch (stage) {
    case 'input':
      return '直连地址无效：请填写局域网 IP、EasyTier 等虚拟网 IP 或域名，不要填写 RustDesk ID。';
    case 'tcp_timeout':
      return '连接对端端口 ' + portText + ' 超时：请确认两端在同一局域网或 EasyTier 虚拟网已互通，' +
        '并确认对端 RustDesk 已开启“允许 IP 直接访问”。';
    case 'tcp_refused':
      return '对端拒绝连接：对端 RustDesk 可能未开启“允许 IP 直接访问”，或直连端口不是 ' + portText + '。';
    case 'tcp_unreachable':
      return '本机没有到该地址的路由：请确认 EasyTier 等虚拟网正在运行，且本应用可以访问该虚拟网。';
    case 'tcp_interrupted':
      return '直连 TCP 已建立但被中断：请检查对端 RustDesk 版本和网络稳定性。';
    case 'tcp_failed':
      return '直连 TCP 连接失败：请检查地址、端口 ' + portText + ' 和网络连通性。';
    case 'login_password':
      return '已连到对端，但设备密码被拒绝：直连只支持设备密码。';
    case 'login_rejected':
      return '已连到对端，但对端不接受密码登录：直连无法请求对方批准，请在对端设置永久密码。';
    case 'login_failed':
      return '已连到对端，但登录握手失败：请确认对端是 RustDesk 且版本兼容。';
    case 'first_frame':
      return '已登录对端，但没有收到画面：问题在视频流或解码，与直连网络无关。';
    default:
      return '';
  }
}

/** Returns an error when the persisted host does not match the direct endpoint just entered. */
export function rustDeskDirectEndpointReadbackError(expected: RemoteHost,
  saved: RemoteHost | undefined): string {
  if (!expected.rustdeskDirectEnabled) { return ''; }
  if (saved === undefined) { return '直连主机保存后无法读回，请重试'; }
  const expectedEndpoint: EndpointAddressResult =
    parseEndpointFields(expected.rustdeskDirectHost, expected.rustdeskDirectPort);
  const savedEndpoint: EndpointAddressResult =
    parseEndpointFields(saved.rustdeskDirectHost, saved.rustdeskDirectPort);
  if (!saved.rustdeskDirectEnabled || !expectedEndpoint.ok || !savedEndpoint.ok ||
    endpointTransportHost(expectedEndpoint.endpoint) !== endpointTransportHost(savedEndpoint.endpoint) ||
    expectedEndpoint.endpoint.port !== savedEndpoint.endpoint.port ||
    saved.rustdeskRelayId !== '') {
    return '直连地址或端口保存后不一致，主机未保存，请重试';
  }
  return '';
}
