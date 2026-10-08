import { HostSyncService } from '../../HostSyncService';
import { SshProxyProfileStore } from '../../SshProxyProfileStore';
import { SshProxyProfileV1 } from '../../SshProxyProfilePolicy';
import { SshProxyRuntimePlan, resolveSshProxyRuntimePlan } from '../../SshProxyRuntimePolicy';
import { SshHostKeyRouteBinding, sshHostKeyRouteBinding } from '../../SshHostKeyTrustPolicy';
import { RemoteHost } from '../../../model/RemoteHost';
import { SshAuthPromptRequest, SshJumpHop } from '../../../types/rdpnapi';

export function persistSshHostKeyTrust(prompt: SshAuthPromptRequest,
  srv: HostSyncService, profiles: SshProxyProfileStore): boolean {
    const ownerId: string = prompt.trustHostId.trim();
    const endpointHost: string = prompt.endpointHost.trim();
    const fingerprint: string = prompt.hostKeyFingerprintSha256.trim();
    const rawBase64: string = prompt.hostKeyRawBase64.trim();
    if (prompt.kind !== 'host_key' || ownerId.length === 0 || endpointHost.length === 0 ||
      prompt.endpointPort <= 0 || prompt.endpointPort > 65535 ||
      fingerprint.indexOf('SHA256:') !== 0 || rawBase64.length === 0) {
      return false;
    }
    const current: RemoteHost | undefined = srv.getHost(ownerId);
    if (current === undefined || current.protocol !== 'ssh') { return false; }
    const plan: SshProxyRuntimePlan = resolveSshProxyRuntimePlan(current, profiles.load(current.id));
    const binding: SshHostKeyRouteBinding = sshHostKeyRouteBinding(current, plan);
    if (!binding.ok || prompt.routeIdentity !== binding.identity) { return false; }
    const trustedAt: number = Date.now();
    if (prompt.hostKeyHopIndex < 0) {
      if (plan.route.endpointHost.trim() !== endpointHost ||
        plan.route.endpointPort !== prompt.endpointPort) { return false; }
      const updated: RemoteHost = current.runtimeClone();
      updated.sshHostKeyAlgorithm = prompt.hostKeyAlgorithm.trim();
      updated.sshHostKeyFingerprintSha256 = fingerprint;
      updated.sshHostKeyRawBase64 = rawBase64;
      updated.sshHostKeyTrustedAt = trustedAt;
      updated.sshHostKeyTrustMode = 1;
      updated.sshHostKeyRouteIdentity = binding.identity;
      return srv.updateHost(updated);
}
    const hopIndex: number = prompt.hostKeyHopIndex;
    const previousProfile: SshProxyProfileV1 | null = profiles.load(ownerId);
    let profileUpdated: boolean = false;
    if (previousProfile !== null) {
      if (previousProfile.route.type !== 'ssh_jump' || hopIndex >= previousProfile.route.hops.length) {
        return false;
      }
      const hop: SshJumpHop = previousProfile.route.hops[hopIndex];
      if (hop.host.trim() !== endpointHost || hop.port !== prompt.endpointPort) { return false; }
      const nextProfile: SshProxyProfileV1 | null = profiles.load(ownerId);
      if (nextProfile === null) { return false; }
      nextProfile.route.hops[hopIndex].expectedHostKeyRawBase64 = rawBase64;
      nextProfile.route.hops[hopIndex].expectedHostKeyFingerprintSha256 = fingerprint;
      nextProfile.updatedAtMs = trustedAt;
      if (!profiles.upsert(nextProfile)) { return false; }
      profileUpdated = true;
    } else if (hopIndex !== 0 || current.proxyHost.trim() !== endpointHost ||
      current.proxyPort !== prompt.endpointPort) {
      return false;
    }

    // The canonical profile is authoritative. Mirror the first hop into the
    // legacy fields only when both routes name the same endpoint, so SFTP and
    // older entry points keep the same strict binding without cross-endpoint trust.
    if (hopIndex === 0 && current.proxyHost.trim() === endpointHost &&
      current.proxyPort === prompt.endpointPort) {
      const updated: RemoteHost = current.runtimeClone();
      updated.sshJumpHostKeyAlgorithm = prompt.hostKeyAlgorithm.trim();
      updated.sshJumpHostKeyFingerprintSha256 = fingerprint;
      updated.sshJumpHostKeyRawBase64 = rawBase64;
      updated.sshJumpHostKeyTrustedAt = trustedAt;
      updated.sshJumpHostKeyTrustMode = 1;
      if (!srv.updateHost(updated)) {
        if (profileUpdated && previousProfile !== null) {
          profiles.upsert(previousProfile);
        }
        return false;
      }
    }
    return true;
  }
