import { describe, it, expect } from '@ohos/hypium';
import {
  resolveRustDeskConnectionContext,
  rustDeskConnectionContextDiagnostic,
  RustDeskConnectionContextInput
} from '../main/ets/services/RustDeskConnectionContextPolicy';
import {
  RustDeskControlPlaneProfile
} from '../main/ets/services/RustDeskControlPlanePolicy';
import {
  RustDeskControlPlaneCapabilityProof
} from '../main/ets/model/RustDeskControlPlaneCapabilityModels';

function input(
  profile: RustDeskControlPlaneProfile =
    'official_server_pro_token'
): RustDeskConnectionContextInput {
  return {
    direct: false,
    relayId: 'relay-1',
    profile,
    keyMode: 'server_public_key',
    accountId: 'account-1',
    accountRelayId: 'relay-1',
    accountPresent: true,
    accountLoginStatus: 'logged_in',
    accessToken: 'secret-token',
    accessTokenFingerprint: 'token-fingerprint',
    tokenGeneration: 7,
    ownerScopeId: 'owner-1',
    accountApiServer: 'https://api.example.test:21114',
    configuredApiServer: 'https://api.example.test:21114',
    idServer: 'id.example.test',
    idServerPort: 21116,
    relayServer: 'relay.example.test',
    relayPort: 21117,
    serverKeyMode: 'server_public_key',
    serverKey: 'server-public-key',
    capabilityProof: undefined
  };
}

function fabricatedProof(): RustDeskControlPlaneCapabilityProof {
  return {
    schemaVersion: 2,
    source: 'official_server_pro',
    attestationIssuerFingerprint: 'local-issuer',
    attestationContractFingerprint: 'local-contract',
    attestationEvidenceFingerprint: 'local-evidence',
    ownerScopeFingerprint: 'local-owner',
    accountIdFingerprint: 'local-account',
    relayIdFingerprint: 'local-relay',
    tokenGeneration: 7,
    accessTokenFingerprint: 'token-fingerprint',
    apiOriginFingerprint: 'local-api',
    rendezvousEndpointFingerprint: 'local-id',
    relayEndpointFingerprint: 'local-relay-endpoint',
    serverIdentityFingerprint: 'local-server',
    verifiedAt: 1
  };
}

export default function rustDeskConnectionContextPolicyTest(): void {
  describe('RustDeskConnectionContextPolicy', (): void => {
    it('never_projects_an_addressbook_token_to_oss_or_api_only_profiles',
      0, (): void => {
        const oss = resolveRustDeskConnectionContext(
          input('oss_key_only'));
        expect(oss.ready).assertTrue();
        expect(oss.accessToken).assertEqual('');
        const apiOnly = resolveRustDeskConnectionContext(
          input('third_party_api_only'));
        expect(apiOnly.ready).assertTrue();
        expect(apiOnly.profile)
          .assertEqual('third_party_api_only');
        expect(apiOnly.accessToken).assertEqual('');
      });

    it('projects_binding_verified_official_server_pro_token',
      0, (): void => {
        const result = resolveRustDeskConnectionContext(input());
        expect(result.ready).assertTrue();
        expect(result.code).assertEqual('ready');
        expect(result.profile).assertEqual('official_server_pro_token');
        expect(result.requiresAccount).assertTrue();
        expect(result.accessToken).assertEqual('secret-token');
        expect(result.capabilitySource)
          .assertEqual('official_server_pro');
      });

    it('accepts_only_trusted_proofs_but_keeps_binding_identity_path',
      0, (): void => {
        const value: RustDeskConnectionContextInput = input();
        value.capabilityProof = fabricatedProof();
        const result = resolveRustDeskConnectionContext(value);
        expect(result.ready).assertTrue();
        expect(result.code).assertEqual('ready');
        expect(result.accessToken).assertEqual('secret-token');
      });

    it('fails_closed_when_relay_api_origin_mismatches_account',
      0, (): void => {
        const value: RustDeskConnectionContextInput =
          input('third_party_control_plane');
        value.configuredApiServer = 'https://other.example.test:21114';
        const result = resolveRustDeskConnectionContext(value);
        expect(result.ready).assertFalse();
        expect(result.code).assertEqual('capability_unverified');
        expect(result.accessToken).assertEqual('');
      });

    it('projects_binding_verified_third_party_control_plane',
      0, (): void => {
        const result = resolveRustDeskConnectionContext(
          input('third_party_control_plane'));
        expect(result.ready).assertTrue();
        expect(result.code).assertEqual('ready');
        expect(result.profile).assertEqual('third_party_control_plane');
        expect(result.accessToken).assertEqual('secret-token');
        expect(result.capabilitySource)
          .assertEqual('verified_third_party');
      });

    it('keeps_direct_connections_independent_from_http_accounts',
      0, (): void => {
        const direct: RustDeskConnectionContextInput = input();
        direct.direct = true;
        direct.accountId = '';
        direct.accountRelayId = '';
        direct.accountPresent = false;
        direct.accountLoginStatus = 'none';
        direct.capabilityProof = fabricatedProof();
        const result = resolveRustDeskConnectionContext(direct);
        expect(result.ready).assertTrue();
        expect(result.profile).assertEqual('direct_ip');
        expect(result.accessToken).assertEqual('');
      });

    it('keeps_diagnostics_free_of_ids_and_token_values',
      0, (): void => {
        const result = resolveRustDeskConnectionContext(input());
        const diagnostic: string =
          rustDeskConnectionContextDiagnostic(result);
        expect(diagnostic.indexOf('relay-1')).assertEqual(-1);
        expect(diagnostic.indexOf('account-1')).assertEqual(-1);
        expect(diagnostic.indexOf('secret-token')).assertEqual(-1);
        expect(diagnostic.indexOf('token=withheld') >= 0)
          .assertTrue();
      });
  });
}
