import { describe, it, expect } from '@ohos/hypium';
import {
  SSH_FORWARDING_MAX_CONNECTIONS,
  SSH_FORWARDING_MAX_PROFILES,
  SshForwardingProfile,
  SshForwardingStartPolicy,
  defaultSshForwardingProfile,
  resolveSshForwardingEditorSheetLayout,
  resolveSshForwardingSheetLayout,
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
      expect(defaultSshForwardingProfile('local').startPolicy).assertEqual('manual');
    });

    it('adapts_phone_and_pad_tunnel_sheets_to_content_and_viewport', 0, (): void => {
      const emptyPhone = resolveSshForwardingSheetLayout(360, 780, 0, true);
      expect(emptyPhone.bottomAnchored).assertTrue();
      expect(emptyPhone.widthVp).assertEqual(360);
      expect(emptyPhone.heightVp).assertEqual(320);

      const phoneWithRules = resolveSshForwardingSheetLayout(360, 780, 2, true);
      expect(phoneWithRules.heightVp).assertEqual(500);
      const phoneLandscape = resolveSshForwardingSheetLayout(780, 360, 2, true);
      expect(phoneLandscape.heightVp).assertEqual(336);

      const padWithRules = resolveSshForwardingSheetLayout(1024, 720, 2, false);
      expect(padWithRules.bottomAnchored).assertFalse();
      expect(padWithRules.widthVp).assertEqual(660);
      expect(padWithRules.heightVp).assertEqual(460);

      const compactPad = resolveSshForwardingSheetLayout(520, 360, 2, false);
      expect(compactPad.widthVp).assertEqual(480);
      expect(compactPad.heightVp).assertEqual(312);
    });

    it('keeps_the_rule_editor_scrollable_inside_short_phone_and_pad_windows', 0,
      (): void => {
        const phone = resolveSshForwardingEditorSheetLayout(360, 780, true);
        expect(phone.bottomAnchored).assertTrue();
        expect(phone.heightVp).assertEqual(680);
        expect(phone.widthVp).assertEqual(360);

        const phoneLandscape = resolveSshForwardingEditorSheetLayout(780, 360, true);
        expect(phoneLandscape.heightVp).assertEqual(336);

        const pad = resolveSshForwardingEditorSheetLayout(1024, 720, false);
        expect(pad.bottomAnchored).assertFalse();
        expect(pad.heightVp).assertEqual(672);
        expect(pad.widthVp).assertEqual(560);
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

      profile.allowPublicBind = false;
      profile.bindHost = '127.example.com';
      expect(validateSshForwardingProfile(profile).code)
        .assertEqual('E-SSH-FORWARD-PUBLIC-BIND-CONFIRMATION');
      profile.bindHost = '127.0.0.2';
      expect(validateSshForwardingProfile(profile).valid).assertTrue();
    });

    it('normalizes_endpoint_v2_hosts_and_rejects_truncation_or_authorities', 0, (): void => {
      const ipv6: SshForwardingProfile = localProfile();
      ipv6.bindHost = '[::1]';
      ipv6.targetHost = '[2001:0DB8:0:0::20]';
      const normalized = validateSshForwardingProfile(ipv6);
      expect(normalized.valid).assertTrue();
      expect(normalized.profile.bindHost).assertEqual('::1');
      expect(normalized.profile.targetHost).assertEqual('2001:db8::20');

      const scoped: SshForwardingProfile = localProfile();
      scoped.targetHost = 'fe80::20%wlan0';
      expect(validateSshForwardingProfile(scoped).code)
        .assertEqual('E-SSH-FORWARD-TARGET-HOST');
      scoped.mode = 'remote';
      expect(validateSshForwardingProfile(scoped).profile.targetHost)
        .assertEqual('fe80::20%wlan0');
      scoped.bindHost = 'fe80::10%wlan0';
      scoped.allowPublicBind = true;
      expect(validateSshForwardingProfile(scoped).code)
        .assertEqual('E-SSH-FORWARD-BIND-HOST');
      scoped.mode = 'local';
      scoped.targetHost = '2001:db8::20';
      expect(validateSshForwardingProfile(scoped).valid).assertTrue();
      scoped.targetHost = 'fe80::20%12';
      expect(validateSshForwardingProfile(scoped).code)
        .assertEqual('E-SSH-FORWARD-TARGET-HOST');

      const malformed: SshForwardingProfile = localProfile();
      malformed.targetHost = 'target.example:22';
      expect(validateSshForwardingProfile(malformed).code)
        .assertEqual('E-SSH-FORWARD-TARGET-HOST');
      malformed.targetHost = 'a'.repeat(256);
      expect(validateSshForwardingProfile(malformed).code)
        .assertEqual('E-SSH-FORWARD-TARGET-HOST');
      malformed.id = 'i'.repeat(97);
      expect(validateSshForwardingProfile(malformed).code)
        .assertEqual('E-SSH-FORWARD-ID');
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
      const invalidStartPolicy: SshForwardingProfile = localProfile();
      invalidStartPolicy.startPolicy = 'unexpected' as SshForwardingStartPolicy;
      expect(validateSshForwardingProfile(invalidStartPolicy).code)
        .assertEqual('E-SSH-FORWARD-START-POLICY');
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
