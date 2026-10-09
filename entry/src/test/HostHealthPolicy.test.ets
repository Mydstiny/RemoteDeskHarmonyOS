import { describe, it, expect } from '@ohos/hypium';
import {
  HostHealthObservation,
  HostHealthVerdict,
  appendHostHealthObservation,
  hostHealthAction,
  isHostHealthStale,
  normalizeHostHealthObservation,
  rdpProbeHealth,
  sshProbeHealth,
  vncProbeHealth
} from '../main/ets/services/pro/health/HostHealthPolicy';

export default function hostHealthPolicyTest() {
  describe('HostHealthPolicy', () => {
    it('maps_probe_stages_to_plain_states', 0, () => {
      const dns: HostHealthVerdict = rdpProbeHealth({
        ok: false, errorCode: -11, rootTrusted: false, hostMismatch: false,
        fingerprintSha256: '', savedFingerprintSha256: ''
      });
      expect(dns.status).assertEqual('route_unavailable');
      const changed: HostHealthVerdict = sshProbeHealth({
        ok: true, errorCode: 0, errorMessage: '', fingerprintSha256: 'SHA256:a', savedFingerprintSha256: 'SHA256:b'
      });
      expect(changed.code).assertEqual('E-HOSTKEY-CHANGED');
      expect(hostHealthAction(changed, 'ssh')).assertEqual('review_fingerprint');
      const timeout: HostHealthVerdict = vncProbeHealth({
        ok: false, errorCategory: 'connect_timeout', rootTrusted: false, hostMismatch: false,
        fingerprintSha256: '', savedFingerprintSha256: ''
      });
      expect(timeout.status).assertEqual('timeout');
    });

    it('keeps_a_bounded_valid_history', 0, () => {
      let history: HostHealthObservation[] = [];
      for (let i = 1; i <= 22; i++) {
        const stored: HostHealthObservation = {
          schemaVersion: 1, hostId: 'h1', protocol: 'rdp', observedAt: i * 1000, status: 'reachable', code: 'OK',
          latencyMs: 9, route: 'direct', addressFamily: 'ipv4', source: 'probe'
        };
        const observation: HostHealthObservation | null = normalizeHostHealthObservation(stored);
        if (observation !== null) { history = appendHostHealthObservation(history, observation); }
      }
      expect(history.length).assertEqual(20);
      expect(history[0].observedAt).assertEqual(22000);
      expect(isHostHealthStale(1000, 1000 + 2 * 3600000)).assertTrue();
    });
  });
}
