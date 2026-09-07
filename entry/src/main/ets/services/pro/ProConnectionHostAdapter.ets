import { RemoteHost } from '../../model/RemoteHost';
import { ProConnectionDescription, ProConnectionView } from './ProConnectionEnvelope';
// Initial continuation adapter is direct SSH. A proxy route must never silently become direct.
export function describeProSshConnection(host: RemoteHost, pane: string, directory: string): ProConnectionDescription | null {
  if (host.protocol !== 'ssh' || host.sshProxyType !== 'direct' || host.proxyHost.trim() !== '' ||
      host.id.length === 0 || (directory !== '' && !directory.startsWith('/'))) { return null; }
  const view: ProConnectionView = { sshPane: pane === 'files' ? 'files' : 'terminal',
    sshDirectory: directory, monitor: 0, scale: 1, panX: 0, panY: 0, inputMode: 'direct' };
  return { protocol: 'ssh', label: host.label, host: host.host, port: host.port,
    username: host.username, hostReference: host.id, view };
}
