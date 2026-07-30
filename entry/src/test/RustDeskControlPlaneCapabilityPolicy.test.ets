import { describe, expect, it } from '@ohos/hypium';
import {
  issueRustDeskControlPlaneCapabilityProof,
  rustDeskControlPlaneCapabilityProofMatches,
  RustDeskControlPlaneCapabilityBinding
} from '../main/ets/services/RustDeskControlPlaneCapabilityPolicy';

function binding(): RustDeskControlPlaneCapabilityBinding {
  return {
    source: 'official_server_pro',
    ownerScopeId: 'owner-private',
    accountId: 'account-private',
    relayId: 'relay-private',
    tokenGeneration: 4,
    accessTokenFingerprint: 'token-fingerprint',
    accountApiServer: 'https://rd.example.test:21114/api/',
    configuredApiServer: 'https://rd.example.test:21114',
    idServer: 'rd.example.test',
    idServerPort: 21116,
    relayServer: 'RD.EXAMPLE.TEST.',
    relayPort: 21117,
    serverKeyMode: 'server_public_key',
    serverKey: 'server-key-private'
  };
}

export default function rustDeskControlPlaneCapabilityPolicyTest():
  void {
  describe('RustDeskControlPlaneCapabilityPolicy', (): void => {
    it('issues_only_fingerprints_for_one_authenticated_identity',
      0, (): void => {
        const source: RustDeskControlPlaneCapabilityBinding =
          binding();
        const result =
          issueRustDeskControlPlaneCapabilityProof(source);
        expect(result.ok).assertTrue();
        expect(result.proof !== undefined).assertTrue();
        const raw: string = JSON.stringify(result.proof);
        expect(raw.indexOf(source.ownerScopeId)).assertEqual(-1);
        expect(raw.indexOf(source.accountId)).assertEqual(-1);
        expect(raw.indexOf(source.relayId)).assertEqual(-1);
        expect(raw.indexOf(source.accountApiServer)).assertEqual(-1);
        expect(raw.indexOf(source.idServer)).assertEqual(-1);
        expect(raw.indexOf(source.serverKey)).assertEqual(-1);
        expect(rustDeskControlPlaneCapabilityProofMatches(
          result.proof, source)).assertTrue();
      });

    it('rejects_profile_only_or_cross_origin_bindings',
      0, (): void => {
        const source: RustDeskControlPlaneCapabilityBinding =
          binding();
        source.configuredApiServer =
          'https://panel.example.test:21114';
        const apiMismatch =
          issueRustDeskControlPlaneCapabilityProof(source);
        expect(apiMismatch.ok).assertFalse();
        source.configuredApiServer =
          'https://rd.example.test:21114';
        source.relayServer = 'relay.example.test';
        const endpointMismatch =
          issueRustDeskControlPlaneCapabilityProof(source);
        expect(endpointMismatch.ok).assertFalse();
      });

    it('invalidates_a_persisted_proof_after_any_identity_change',
      0, (): void => {
        const source: RustDeskControlPlaneCapabilityBinding =
          binding();
        const issued =
          issueRustDeskControlPlaneCapabilityProof(source);
        expect(issued.ok).assertTrue();
        source.serverKey = 'rotated-key';
        expect(rustDeskControlPlaneCapabilityProofMatches(
          issued.proof, source)).assertFalse();
      });
  });
}
