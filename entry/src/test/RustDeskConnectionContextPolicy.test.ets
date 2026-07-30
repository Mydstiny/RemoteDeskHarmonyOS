import { describe, it, expect } from '@ohos/hypium';
import {
  resolveRustDeskConnectionContext,
  rustDeskConnectionContextDiagnostic,
  RustDeskConnectionContextInput
} from '../main/ets/services/RustDeskConnectionContextPolicy';
import {
  issueRustDeskControlPlaneCapabilityProof,
  RustDeskControlPlaneCapabilityBinding
} from '../main/ets/services/RustDeskControlPlaneCapabilityPolicy';
import {
  RustDeskControlPlaneProfile
} from '../main/ets/services/RustDeskControlPlanePolicy';

function officialBinding(): RustDeskControlPlaneCapabilityBinding {
  return {
    source: 'official_server_pro',
    ownerScopeId: 'owner-1',
    accountId: 'account-1',
    relayId: 'relay-1',
    tokenGeneration: 7,
    accessTokenFingerprint: 'token-fingerprint',
    accountApiServer: 'https://rd.example.test:21114',
    configuredApiServer: 'https://rd.example.test:21114',
    idServer: 'rd.example.test',
    idServerPort: 21116,
    relayServer: 'rd.example.test',
    relayPort: 21117,
    serverKeyMode: 'server_public_key',
    serverKey: 'server-public-key'
  };
}

function input(
  profile: RustDeskControlPlaneProfile =
    'official_server_pro_token'
): RustDeskConnectionContextInput {
  const binding: RustDeskControlPlaneCapabilityBinding =
    officialBinding();
  return {
    direct: false,
    relayId: binding.relayId,
    profile,
    keyMode: binding.serverKeyMode,
    accountId: binding.accountId,
    accountRelayId: binding.relayId,
    accountPresent: true,
    accountLoginStatus: 'logged_in',
    accessToken: 'secret-token',
    accessTokenFingerprint: binding.accessTokenFingerprint,
    tokenGeneration: binding.tokenGeneration,
    ownerScopeId: binding.ownerScopeId,
    accountApiServer: binding.accountApiServer,
    configuredApiServer: binding.configuredApiServer,
    idServer: binding.idServer,
    idServerPort: binding.idServerPort,
    relayServer: binding.relayServer,
    relayPort: binding.relayPort,
    serverKeyMode: binding.serverKeyMode,
    serverKey: binding.serverKey,
    capabilityProof: undefined
  };
}

function verifiedOfficialInput(): RustDeskConnectionContextInput {
  const value: RustDeskConnectionContextInput = input();
  const issued = issueRustDeskControlPlaneCapabilityProof(
    officialBinding());
  expect(issued.ok).assertTrue();
  value.capabilityProof = issued.proof;
  return value;
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

    it('does_not_treat_an_official_profile_as_capability_proof',
      0, (): void => {
        const result = resolveRustDeskConnectionContext(input());
        expect(result.ready).assertFalse();
        expect(result.code).assertEqual('capability_unverified');
        expect(result.accessToken).assertEqual('');
      });

    it('projects_only_a_verified_official_binding',
      0, (): void => {
        const result = resolveRustDeskConnectionContext(
          verifiedOfficialInput());
        expect(result.ready).assertTrue();
        expect(result.accessToken).assertEqual('secret-token');
        expect(result.capabilitySource)
          .assertEqual('official_server_pro');
      });

    it('invalidates_proof_on_owner_token_api_endpoint_or_key_change',
      0, (): void => {
        const mutations: Array<
          (value: RustDeskConnectionContextInput) => void
        > = [
          (value: RustDeskConnectionContextInput): void => {
            value.ownerScopeId = 'owner-2';
          },
          (value: RustDeskConnectionContextInput): void => {
            value.tokenGeneration = 8;
          },
          (value: RustDeskConnectionContextInput): void => {
            value.configuredApiServer =
              'https://other.example.test:21114';
          },
          (value: RustDeskConnectionContextInput): void => {
            value.idServerPort = 21118;
          },
          (value: RustDeskConnectionContextInput): void => {
            value.relayServer = 'other.example.test';
          },
          (value: RustDeskConnectionContextInput): void => {
            value.serverKey = 'replacement-key';
          }
        ];
        for (let i = 0; i < mutations.length; i++) {
          const value: RustDeskConnectionContextInput =
            verifiedOfficialInput();
          mutations[i](value);
          const result =
            resolveRustDeskConnectionContext(value);
          expect(result.ready).assertFalse();
          expect(result.code)
            .assertEqual('capability_unverified');
          expect(result.accessToken).assertEqual('');
        }
      });

    it('fails_closed_for_unverified_third_party_control_planes',
      0, (): void => {
        const result = resolveRustDeskConnectionContext(
          input('third_party_control_plane'));
        expect(result.ready).assertFalse();
        expect(result.code).assertEqual('capability_unverified');
        expect(result.accessToken).assertEqual('');
      });

    it('requires_reauthentication_before_capability_validation',
      0, (): void => {
        const official: RustDeskConnectionContextInput =
          verifiedOfficialInput();
        official.accessToken = '';
        const result = resolveRustDeskConnectionContext(official);
        expect(result.ready).assertFalse();
        expect(result.code)
          .assertEqual('reauthentication_required');
        const direct: RustDeskConnectionContextInput = input();
        direct.direct = true;
        direct.accountId = '';
        direct.accountRelayId = '';
        direct.accountPresent = false;
        direct.accountLoginStatus = 'none';
        direct.accessToken = 'secret-token';
        direct.capabilityProof = undefined;
        const directResult =
          resolveRustDeskConnectionContext(direct);
        expect(directResult.ready).assertTrue();
        expect(directResult.profile).assertEqual('direct_ip');
        expect(directResult.accessToken).assertEqual('');
      });

    it('keeps_diagnostics_free_of_ids_and_token_values',
      0, (): void => {
        const result = resolveRustDeskConnectionContext(
          verifiedOfficialInput());
        const diagnostic: string =
          rustDeskConnectionContextDiagnostic(result);
        expect(diagnostic.indexOf('relay-1')).assertEqual(-1);
        expect(diagnostic.indexOf('account-1')).assertEqual(-1);
        expect(diagnostic.indexOf('secret-token')).assertEqual(-1);
        expect(diagnostic.indexOf('token=projected') >= 0)
          .assertTrue();
      });
  });
}
