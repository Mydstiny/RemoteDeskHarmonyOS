import { common } from '@kit.AbilityKit';
import { RemoteHost, normalizeRdpAuthMode, normalizeRdpCredentialParts,
  normalizeRdpCredentialStorageMode } from '../../model/RemoteHost';
import { HostSyncService } from '../HostSyncService';
import { SshProxyProfileStore } from '../SshProxyProfileStore';
import { resolveSshProxyRuntimePlan } from '../SshProxyRuntimePolicy';
import { VncHostService, VncHostView } from '../VncHostService';
import { VncGatewayService, VncGatewayView } from '../VncGatewayService';
import { projectVncHost, vncHostRecordIdFromUiId } from '../VncHostListProjectionPolicy';
import { ProConnectionDescription, ProConnectionProtocol, ProConnectionView, proReconnectOnlyProtocol,
  sameProConnectionEndpoint } from './ProConnectionEnvelope';
import { ProRdpConnectionIdentity, proRdpConnectionRouteMatches, copyProRdpConnectionIdentity,
  describeProRdpConnectionIdentity, sameProRdpConnectionIdentity } from './ProRdpConnectionIdentity';
// Initial continuation adapter is direct SSH. A proxy route must never silently become direct.
export function describeProSshConnection(host: RemoteHost, pane: string, directory: string,
  context: common.Context): ProConnectionDescription | null {
  if (host.protocol !== 'ssh' || host.id.length === 0 ||
      (directory !== '' && !directory.startsWith('/'))) { return null; }
  // A fresh read is intentional: page-owned stores cache their initial profile.
  // Unreadable/corrupt storage must not masquerade as a missing direct profile.
  const profiles = new SshProxyProfileStore();
  if (!profiles.init(context)) { return null; }
  const plan = resolveSshProxyRuntimePlan(host, profiles.load(host.id));
  if (!plan.valid || plan.route.type !== 'direct') { return null; }
  const view: ProConnectionView = { sshPane: pane === 'files' ? 'files' : 'terminal',
    sshDirectory: directory, monitor: 0, scale: 1, panX: 0, panY: 0, inputMode: 'direct' };
  return { protocol: 'ssh', label: host.label, host: host.host, port: host.port,
    username: host.username, hostReference: host.id, view };
}

// RustDesk/VNC continue by reconnecting the same synced host record on the target; only the host
// reference and a normalized, non-secret endpoint travel. Passwords stay with each device.
function proRemoteEndpoint(host: RemoteHost): string {
  const value: string = host.protocol === 'rustdesk' && host.rustdeskDirectEnabled && host.rustdeskDirectHost.trim() !== '' ?
    host.rustdeskDirectHost.trim() : host.host.trim();
  return value.length > 0 && value.length <= 253 && !/[\s/\\?#@]/.test(value) ? value : '';
}
function proRemotePort(host: RemoteHost): number {
  const port: number = host.protocol === 'rustdesk' && host.rustdeskDirectEnabled ? host.rustdeskDirectPort : host.port;
  if (Number.isInteger(port) && port >= 1 && port <= 65535) { return port; }
  return host.protocol === 'vnc' ? 5900 : 21116;
}

interface RustDeskContinuationRoute {
  relayId: string;
  accountId: string;
  direct: boolean;
  directHost: string;
  directPort: number;
  targetDevice: string;
  proAccountId: string;
  proPeerId: string;
  proManaged: boolean;
  customHostname: string;
  authMode: string;
  passwordMode: number;
}

interface VncContinuationGatewayRoute {
  transport: string;
  host: string;
  port: number;
  path: string;
  repeaterMode: string;
  targetId: string;
  tls: boolean;
  enabled: boolean;
}

interface VncContinuationRoute {
  transport: string;
  repeaterMode: string;
  gatewayId: string;
  tls: boolean;
  securityPolicy: string;
  gateway: VncContinuationGatewayRoute | null;
}

function rustDeskRouteKey(host: RemoteHost): string {
  const route: RustDeskContinuationRoute = {
    relayId: host.rustdeskRelayId.trim(), accountId: host.rustdeskAccountId.trim(),
    direct: host.rustdeskDirectEnabled, directHost: host.rustdeskDirectHost.trim(),
    directPort: host.rustdeskDirectPort, targetDevice: host.rustdeskTargetDevice,
    proAccountId: host.rustdeskProAccountId.trim(), proPeerId: host.rustdeskProPeerId.trim(),
    proManaged: host.rustdeskProManaged, customHostname: host.customHostname.trim(),
    authMode: host.rustdeskAuthMode, passwordMode: host.rustdeskPasswordMode
  };
  return JSON.stringify(route);
}

function vncRouteKey(host: VncHostView): string {
  const gateway: VncGatewayView | null = host.gatewayId.trim() === '' ? null :
    VncGatewayService.getInstance().find(host.gatewayId.trim());
  const gatewayRoute: VncContinuationGatewayRoute | null = gateway === null ? null : {
    transport: gateway.transport, host: gateway.host, port: gateway.port, path: gateway.path,
    repeaterMode: gateway.repeaterMode, targetId: gateway.targetId, tls: gateway.tls,
    enabled: gateway.enabled
  };
  const route: VncContinuationRoute = {
    transport: host.transport, repeaterMode: host.repeaterMode, gatewayId: host.gatewayId.trim(),
    tls: host.tls, securityPolicy: host.securityPolicy, gateway: gatewayRoute
  };
  return JSON.stringify(route);
}

/** Resolve the current account-owned host without treating VNC's separate
 * vncrecordv2 store as if it lived in remotehosts. */
export function resolveProContinuationHost(protocol: string, hostReference: string): RemoteHost | null {
  if (protocol === 'vnc') {
    const recordId: string = vncHostRecordIdFromUiId(hostReference);
    if (recordId === '') { return null; }
    const view: VncHostView | null = VncHostService.getInstance().find(recordId);
    return view === null ? null : projectVncHost(view);
  }
  const host: RemoteHost | undefined = HostSyncService.getInstance().getHost(hostReference);
  return host === undefined ? null : host;
}

export function proContinuationHostStoreReady(protocol: string): boolean {
  return protocol === 'vnc' ? VncHostService.getInstance().isReady() :
    HostSyncService.getInstance().isReady();
}

export function describeProRemoteConnection(host: RemoteHost): ProConnectionDescription | null {
  if (!proReconnectOnlyProtocol(host.protocol) || host.id.length === 0 || host.id.length > 128) { return null; }
  // Re-read VNC from its owning store. The RemoteHost-shaped projection is
  // only a routing view and must not become the source of truth for a
  // continuation after a cloud/account update.
  let source: RemoteHost = host;
  let vncView: VncHostView | null = null;
  if (host.protocol === 'vnc') {
    const recordId: string = vncHostRecordIdFromUiId(host.id);
    if (recordId === '') { return null; }
    vncView = VncHostService.getInstance().find(recordId);
    if (vncView === null) { return null; }
    source = projectVncHost(vncView);
  }
  const endpoint: string = proRemoteEndpoint(source);
  if (endpoint === '') { return null; }
  const label: string = (source.label.trim() !== '' ? source.label.trim() : endpoint).substring(0, 120);
  const view: ProConnectionView = { sshPane: 'terminal', sshDirectory: '', monitor: 0, scale: 1, panX: 0, panY: 0,
    inputMode: 'direct' };
  const routeKey: string = source.protocol === 'vnc' && vncView !== null ? vncRouteKey(vncView) :
    rustDeskRouteKey(source);
  return { protocol: source.protocol as ProConnectionProtocol, label, host: endpoint, port: proRemotePort(source),
    username: source.protocol === 'vnc' && vncView !== null ? vncView.username.substring(0, 256) : '',
    hostReference: host.id, view, routeKey };
}

/** RDP credentials are re-obtained locally. Only the already-authenticated
 * non-secret native identity and canonical transport may enter the wire model. */
export function describeProRdpConnection(host: RemoteHost, identity: ProRdpConnectionIdentity,
  view: ProConnectionView): ProConnectionDescription | null {
  if (!proRdpConnectionRouteMatches(host, identity)) { return null; }
  return { protocol: 'rdp', label: host.label, host: host.host, port: host.port,
    username: identity.username, hostReference: host.id, view,
    rdpIdentity: copyProRdpConnectionIdentity(identity) };
}

export function matchesProConnectionHost(description: ProConnectionDescription, host: RemoteHost,
  context: common.Context): boolean {
  if (description.protocol === 'ssh') {
    const local = describeProSshConnection(host, 'terminal', '', context);
    return local !== null && sameProConnectionEndpoint(local, description);
  }
  if (proReconnectOnlyProtocol(description.protocol)) {
    const local = describeProRemoteConnection(host);
    return local !== null && sameProConnectionEndpoint(local, description);
  }
  if (description.protocol !== 'rdp') { return false; }
  const expected = description.rdpIdentity;
  if (expected === undefined || host.id !== description.hostReference || host.host !== description.host ||
      host.port !== description.port || description.username !== expected.username ||
      !proRdpConnectionRouteMatches(host, expected)) { return false; }
  const passwordAuth = normalizeRdpAuthMode(host.rdpAuthMode) === 'password';
  if (passwordAuth && normalizeRdpCredentialStorageMode(host.rdpCredentialStorageMode) === 'connect_time') {
    // There is intentionally no stored username. The destination must match
    // its actual native identity before it can send a ready receipt.
    return true;
  }
  let username = host.username;
  if (passwordAuth && host.rdpCredentialId !== '') {
    const credential = HostSyncService.getInstance().getRdpCredential(host.rdpCredentialId);
    if (credential === undefined) { return false; }
    username = credential.username;
  }
  const local = describeProRdpConnectionIdentity(host,
    normalizeRdpCredentialParts(username, AppStorage.get<number>('rdpAuthIdentityMode') ?? 1));
  return local !== null && sameProRdpConnectionIdentity(local, expected);
}
