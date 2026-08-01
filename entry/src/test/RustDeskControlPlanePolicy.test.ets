import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeRustDeskControlPlaneProfile,
  rustDeskControlPlaneAllowsToken,
  rustDeskControlPlaneProfileMetadataKey,
  rustDeskControlPlaneProfileForKeyMode,
  rustDeskControlPlaneProfileForRelayKind,
  rustDeskControlPlaneRequiresAccount,
  rustDeskControlPlaneTokenForConnection,
  RUSTDESK_CONTROL_PLANE_PROFILE_METADATA_PREFIX,
  RUSTDESK_CONTROL_PLANE_DEFAULT
} from '../main/ets/services/RustDeskControlPlanePolicy';
import { RustDeskRelayConfig } from '../main/ets/model/RustDeskRelayConfig';

export default function rustDeskControlPlanePolicyTest(): void {
  describe('RustDeskControlPlanePolicy', (): void => {
    it('defaults_legacy_and_unknown_profiles_to_oss_key_only', 0, (): void => {
      expect(normalizeRustDeskControlPlaneProfile(undefined)).assertEqual(
        RUSTDESK_CONTROL_PLANE_DEFAULT);
      expect(normalizeRustDeskControlPlaneProfile('unknown')).assertEqual(
        RUSTDESK_CONTROL_PLANE_DEFAULT);
      expect(normalizeRustDeskControlPlaneProfile('addressbook_only_custom'))
        .assertEqual('third_party_api_only');
      expect(normalizeRustDeskControlPlaneProfile('custom_control_plane'))
        .assertEqual('third_party_api_only');
    });

    it('sends_tokens_only_for_profiles_with_matching_capability_evidence', 0, (): void => {
      expect(rustDeskControlPlaneAllowsToken('oss_key_only')).assertFalse();
      expect(rustDeskControlPlaneAllowsToken('oss_shared_access_key')).assertFalse();
      expect(rustDeskControlPlaneAllowsToken('third_party_api_only')).assertFalse();
      expect(rustDeskControlPlaneAllowsToken(
        'official_server_pro_token', 'official_server_pro')).assertTrue();
      expect(rustDeskControlPlaneAllowsToken(
        'third_party_control_plane', 'none')).assertFalse();
      expect(rustDeskControlPlaneAllowsToken(
        'third_party_control_plane', 'verified_third_party')).assertTrue();
      expect(rustDeskControlPlaneRequiresAccount('third_party_api_only')).assertFalse();
      expect(rustDeskControlPlaneRequiresAccount('official_server_pro_token')).assertTrue();
    });

    it('keeps_key_mode_and_control_plane_profiles_distinct', 0, (): void => {
      expect(rustDeskControlPlaneProfileForRelayKind('oss')).assertEqual('oss_key_only');
      expect(rustDeskControlPlaneProfileForRelayKind('advanced')).assertEqual('third_party_api_only');
      expect(rustDeskControlPlaneProfileForRelayKind('pro')).assertEqual('official_server_pro_token');
      expect(rustDeskControlPlaneProfileForKeyMode(
        'oss_key_only', 'shared_access_key')).assertEqual('oss_shared_access_key');
      expect(rustDeskControlPlaneProfileForKeyMode(
        'oss_shared_access_key', 'server_public_key')).assertEqual('oss_key_only');
      expect(rustDeskControlPlaneProfileForKeyMode(
        'third_party_api_only', 'shared_access_key')).assertEqual('third_party_api_only');
    });

    it('never_sends_a_pro_token_on_oss_or_direct_connections', 0, (): void => {
      expect(rustDeskControlPlaneTokenForConnection('oss_key_only', false, 'token-a'))
        .assertEqual('');
      expect(rustDeskControlPlaneTokenForConnection('third_party_api_only', false, 'token-b'))
        .assertEqual('');
      expect(rustDeskControlPlaneTokenForConnection(
        'official_server_pro_token', true, 'token-c', 'official_server_pro'))
        .assertEqual('');
    });

    it('passes_a_token_only_when_the_profile_and_route_allow_it', 0, (): void => {
      expect(rustDeskControlPlaneTokenForConnection(
        'official_server_pro_token', false, 'token-value', 'official_server_pro'))
        .assertEqual('token-value');
      expect(rustDeskControlPlaneTokenForConnection(
        'third_party_control_plane', false, 'token-value', 'none')).assertEqual('');
      expect(rustDeskControlPlaneTokenForConnection(
        'third_party_control_plane', false, 'token-value', 'verified_third_party'))
        .assertEqual('token-value');
      expect(rustDeskControlPlaneTokenForConnection(
        'official_server_pro_token', false, '   ', 'official_server_pro')).assertEqual('');
    });

    it('keeps_profile_authorization_out_of_cloud_serialization', 0, (): void => {
      const relay = new RustDeskRelayConfig();
      relay.id = 'relay-1';
      relay.controlPlaneProfile = 'official_server_pro_token';
      const cloud = relay.toCloudJSON();
      expect(Object.prototype.hasOwnProperty.call(cloud, 'controlPlaneProfile')).assertFalse();
      expect(rustDeskControlPlaneProfileMetadataKey(relay.id)).assertEqual(
        RUSTDESK_CONTROL_PLANE_PROFILE_METADATA_PREFIX + relay.id);
      expect(rustDeskControlPlaneProfileMetadataKey('')).assertEqual('');
    });
  });
}
