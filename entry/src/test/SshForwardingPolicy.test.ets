import { describe, it, expect } from '@ohos/hypium';
import {
  SSH_FORWARDING_MAX_CONNECTIONS,
  SSH_FORWARDING_MAX_PROFILES,
  SshForwardingProfile,
  defaultSshForwardingProfile,
  validateSshForwardingProfile,
  validateSshForwardingProfiles
} from '../main/ets/services/SshForwardingPolicy';

function localProfile(): SshForwardingProfile {
  return {
    id: 'local-shell', mode: 'local', bindHost: '127.0.0.1', bindPort: 8022,
    targetHost: '10.0.0.8', targetPort: 22, maxConnections: 4,
    enabled: true, allowPublicBind: false
  };
}

export default function sshForwardingPolicyTest(): void {
  describe('SshForwardingPolicy', (): void => {
    it('defaults every listener to loopback', 0, (): void => {
      expect(defaultSshForwardingProfile('local').bindHost).assertEqual('127.0.0.1');
      expect(defaultSshForwardingProfile('remote').bindHost).assertEqual('127.0.0.1');
      expect(defaultSshForwardingProfile('dynamic').allowPublicBind).assertFalse();
      expect(defaultSshForwardingProfile('local').minBindPort).assertEqual(1);
      expect(defaultSshForwardingProfile('local').maxBindPort).assertEqual(65535);
      expect(defaultSshForwardingProfile('local').maxBytes).assertEqual(0);
    });

    it('validates local and dynamic mode contracts', 0, (): void => {
      expect(validateSshForwardingProfile(localProfile()).valid).assertTrue();
      const dynamic: SshForwardingProfile = defaultSshForwardingProfile('dynamic');
      dynamic.id = 'socks';
      dynamic.bindPort = 1080;
      expect(validateSshForwardingProfile(dynamic).valid).assertTrue();
      dynamic.targetHost = 'unexpected-target';
      expect(validateSshForwardingProfile(dynamic).code).assertEqual('E-SSH-FORWARD-DYNAMIC-TARGET');
    });

    it('rejects public listeners unless explicitly confirmed', 0, (): void => {
      const profile: SshForwardingProfile = localProfile();
      profile.bindHost = '0.0.0.0';
      expect(validateSshForwardingProfile(profile).code)
        .assertEqual('E-SSH-FORWARD-PUBLIC-BIND-CONFIRMATION');
      profile.allowPublicBind = true;
      expect(validateSshForwardingProfile(profile).valid).assertTrue();
    });

    it('bounds ports, connection count, profile count and IDs', 0, (): void => {
      const invalidPort: SshForwardingProfile = localProfile();
      invalidPort.bindPort = 65536;
      expect(validateSshForwardingProfile(invalidPort).code).assertEqual('E-SSH-FORWARD-BIND-PORT');
      const invalidLimit: SshForwardingProfile = localProfile();
      invalidLimit.maxConnections = SSH_FORWARDING_MAX_CONNECTIONS + 1;
      expect(validateSshForwardingProfile(invalidLimit).code)
        .assertEqual('E-SSH-FORWARD-CONNECTION-LIMIT');
      const invalidRange: SshForwardingProfile = localProfile();
      invalidRange.minBindPort = 9000;
      invalidRange.maxBindPort = 8000;
      expect(validateSshForwardingProfile(invalidRange).code)
        .assertEqual('E-SSH-FORWARD-PORT-RANGE');
      const invalidBytes: SshForwardingProfile = localProfile();
      invalidBytes.maxBytes = -1;
      expect(validateSshForwardingProfile(invalidBytes).code)
        .assertEqual('E-SSH-FORWARD-BYTE-LIMIT');
      const duplicate: SshForwardingProfile = localProfile();
      expect(validateSshForwardingProfiles([localProfile(), duplicate]).code)
        .assertEqual('E-SSH-FORWARD-DUPLICATE-ID');
      const tooMany: SshForwardingProfile[] = [];
      for (let index: number = 0; index <= SSH_FORWARDING_MAX_PROFILES; index++) {
        const profile: SshForwardingProfile = localProfile();
        profile.id = 'rule-' + index.toString();
        tooMany.push(profile);
      }
      expect(validateSshForwardingProfiles(tooMany).code).assertEqual('E-SSH-FORWARD-PROFILE-LIMIT');
    });
  });
}
