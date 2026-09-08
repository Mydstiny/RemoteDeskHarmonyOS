import { common } from '@kit.AbilityKit';
import { RemoteHost, normalizeRdpAuthMode, normalizeRdpCredentialParts,
  normalizeRdpCredentialStorageMode } from '../../model/RemoteHost';
import { HostSyncService } from '../HostSyncService';
import { SshProxyProfileStore } from '../SshProxyProfileStore';
import { resolveSshProxyRuntimePlan } from '../SshProxyRuntimePolicy';
import { ProConnectionDescription, ProConnectionView, sameProConnectionEndpoint } from './ProConnectionEnvelope';
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
