import { common } from '@kit.AbilityKit';
import { RemoteHost } from '../../model/RemoteHost';
import { SshProxyProfileStore } from '../SshProxyProfileStore';
import { resolveSshProxyRuntimePlan } from '../SshProxyRuntimePolicy';
import { ProConnectionDescription, ProConnectionView } from './ProConnectionEnvelope';
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
