import { describe, it, expect } from '@ohos/hypium';
import {
  resolveRustDeskConnectionContext,
  rustDeskConnectionContextDiagnostic
} from '../main/ets/services/RustDeskConnectionContextPolicy';

export default function rustDeskConnectionContextPolicyTest(): void {
  describe('RustDeskConnectionContextPolicy', (): void => {
    it('never_projects_an_addressbook_token_to_oss_or_api_only_profiles', 0, (): void => {
      const oss = resolveRustDeskConnectionContext({
        direct: false, relayId: 'relay-1', profile: 'oss_key_only',
        keyMode: 'server_public_key', accountId: 'account-1',
        accountRelayId: 'relay-1', accountPresent: true,
        accountLoginStatus: 'logged_in', accessToken: 'secret-token',
        thirdPartyCapabilityVerified: false
      });
      expect(oss.ready).assertTrue();
      expect(oss.accessToken).assertEqual('');
      const apiOnly = resolveRustDeskConnectionContext({
        direct: false, relayId: 'relay-1', profile: 'third_party_api_only',
        keyMode: 'shared_access_key', accountId: 'account-1',
        accountRelayId: 'relay-1', accountPresent: true,
        accountLoginStatus: 'logged_in', accessToken: 'secret-token',
        thirdPartyCapabilityVerified: false
      });
      expect(apiOnly.ready).assertTrue();
      expect(apiOnly.profile).assertEqual('third_party_api_only');
      expect(apiOnly.accessToken).assertEqual('');
    });

    it('projects_official_tokens_by_profile_and_owner_binding_not_host_source', 0, (): void => {
      const result = resolveRustDeskConnectionContext({
        direct: false, relayId: 'relay-1', profile: 'official_server_pro_token',
        keyMode: 'server_public_key', accountId: 'account-1',
        accountRelayId: 'relay-1', accountPresent: true,
        accountLoginStatus: 'logged_in', accessToken: 'secret-token',
        thirdPartyCapabilityVerified: false
      });
      expect(result.ready).assertTrue();
      expect(result.accessToken).assertEqual('secret-token');
      expect(result.capabilitySource).assertEqual('official_server_pro');
    });

    it('fails_closed_for_unverified_third_party_control_planes', 0, (): void => {
      const result = resolveRustDeskConnectionContext({
        direct: false, relayId: 'relay-1', profile: 'third_party_control_plane',
        keyMode: 'server_public_key', accountId: 'account-1',
        accountRelayId: 'relay-1', accountPresent: true,
        accountLoginStatus: 'logged_in', accessToken: 'secret-token',
        thirdPartyCapabilityVerified: false
      });
      expect(result.ready).assertFalse();
      expect(result.code).assertEqual('capability_unverified');
      expect(result.accessToken).assertEqual('');
    });

    it('requires_reauthentication_only_for_a_profile_that_needs_an_account', 0, (): void => {
      const official = resolveRustDeskConnectionContext({
        direct: false, relayId: 'relay-1', profile: 'official_server_pro_token',
        keyMode: 'server_public_key', accountId: 'account-1',
        accountRelayId: 'relay-1', accountPresent: true,
        accountLoginStatus: 'logged_in', accessToken: '',
        thirdPartyCapabilityVerified: false
      });
      expect(official.ready).assertFalse();
      expect(official.code).assertEqual('reauthentication_required');
      const direct = resolveRustDeskConnectionContext({
        direct: true, relayId: '', profile: 'official_server_pro_token',
        keyMode: 'server_public_key', accountId: '',
        accountRelayId: '', accountPresent: false,
        accountLoginStatus: 'none', accessToken: 'secret-token',
        thirdPartyCapabilityVerified: false
      });
      expect(direct.ready).assertTrue();
      expect(direct.profile).assertEqual('direct_ip');
      expect(direct.accessToken).assertEqual('');
    });

    it('keeps_diagnostics_free_of_ids_and_token_values', 0, (): void => {
      const result = resolveRustDeskConnectionContext({
        direct: false, relayId: 'private-relay', profile: 'official_server_pro_token',
        keyMode: 'server_public_key', accountId: 'private-account',
        accountRelayId: 'private-relay', accountPresent: true,
        accountLoginStatus: 'logged_in', accessToken: 'private-token',
        thirdPartyCapabilityVerified: false
      });
      const diagnostic: string = rustDeskConnectionContextDiagnostic(result);
      expect(diagnostic.indexOf('private-relay')).assertEqual(-1);
      expect(diagnostic.indexOf('private-account')).assertEqual(-1);
      expect(diagnostic.indexOf('private-token')).assertEqual(-1);
      expect(diagnostic.indexOf('token=projected') >= 0).assertTrue();
    });
  });
}
