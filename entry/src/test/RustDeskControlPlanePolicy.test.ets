import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeRustDeskControlPlaneProfile,
  rustDeskControlPlaneAllowsToken,
  rustDeskControlPlaneProfileMetadataKey,
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
    });

    it('sends_tokens_only_for_explicit_control_plane_profiles', 0, (): void => {
      expect(rustDeskControlPlaneAllowsToken('oss_key_only')).assertFalse();
      expect(rustDeskControlPlaneAllowsToken('addressbook_only_custom')).assertFalse();
      expect(rustDeskControlPlaneAllowsToken('official_server_pro_token')).assertTrue();
      expect(rustDeskControlPlaneAllowsToken('custom_control_plane')).assertTrue();
      expect(rustDeskControlPlaneRequiresAccount('addressbook_only_custom')).assertFalse();
      expect(rustDeskControlPlaneRequiresAccount('official_server_pro_token')).assertTrue();
    });

    it('keeps_advanced_custom_relay_key_only_until_token_compatibility_is_explicit', 0, (): void => {
      expect(rustDeskControlPlaneProfileForRelayKind('oss')).assertEqual('oss_key_only');
      expect(rustDeskControlPlaneProfileForRelayKind('advanced')).assertEqual('oss_key_only');
      expect(rustDeskControlPlaneProfileForRelayKind('pro')).assertEqual('official_server_pro_token');
    });

    it('never_sends_a_pro_token_on_oss_or_direct_connections', 0, (): void => {
      expect(rustDeskControlPlaneTokenForConnection('oss_key_only', false, 'token-a'))
        .assertEqual('');
      expect(rustDeskControlPlaneTokenForConnection('addressbook_only_custom', false, 'token-b'))
        .assertEqual('');
      expect(rustDeskControlPlaneTokenForConnection('official_server_pro_token', true, 'token-c'))
        .assertEqual('');
    });

    it('passes_a_token_only_when_the_profile_and_route_allow_it', 0, (): void => {
      expect(rustDeskControlPlaneTokenForConnection(
        'official_server_pro_token', false, 'token-value')).assertEqual('token-value');
      expect(rustDeskControlPlaneTokenForConnection(
        'custom_control_plane', false, 'token-value')).assertEqual('token-value');
      expect(rustDeskControlPlaneTokenForConnection(
        'official_server_pro_token', false, '   ')).assertEqual('');
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
