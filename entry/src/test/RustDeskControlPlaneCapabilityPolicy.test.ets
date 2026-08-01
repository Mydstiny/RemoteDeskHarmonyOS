import { describe, expect, it } from '@ohos/hypium';
import {
  issueRustDeskControlPlaneCapabilityProof,
  rustDeskControlPlaneBindingIdentity,
  rustDeskControlPlaneCapabilityProofMatches,
  rustDeskControlPlaneCapabilitySourceForProof,
  RustDeskControlPlaneCapabilityAttestation,
  RustDeskControlPlaneCapabilityBinding
} from '../main/ets/services/RustDeskControlPlaneCapabilityPolicy';
import {
  RustDeskControlPlaneCapabilityProof
} from '../main/ets/model/RustDeskControlPlaneCapabilityModels';

function binding(): RustDeskControlPlaneCapabilityBinding {
  return {
    ownerScopeId: 'owner-private',
    accountId: 'account-private',
    relayId: 'relay-private',
    tokenGeneration: 4,
    accessTokenFingerprint: 'token-fingerprint',
    accountApiServer: 'https://api.example.test:21114/api/',
    configuredApiServer: 'https://api.example.test:21114',
    idServer: 'id.example.test',
    idServerPort: 21116,
    relayServer: 'relay.example.test',
    relayPort: 21117,
    serverKeyMode: 'server_public_key',
    serverKey: 'server-key-private'
  };
}

function locallyClaimedAttestation():
  RustDeskControlPlaneCapabilityAttestation {
  return {
    source: 'official_server_pro',
    issuerId: 'local-profile-selection',
    contractId: 'generic-api-login-and-address-book',
    evidenceFingerprint: 'locally-generated'
  };
}

function fabricatedProof(): RustDeskControlPlaneCapabilityProof {
  return {
    schemaVersion: 2,
    source: 'official_server_pro',
    attestationIssuerFingerprint: 'fabricated-issuer',
    attestationContractFingerprint: 'fabricated-contract',
    attestationEvidenceFingerprint: 'fabricated-evidence',
    ownerScopeFingerprint: 'fabricated-owner',
    accountIdFingerprint: 'fabricated-account',
    relayIdFingerprint: 'fabricated-relay',
    tokenGeneration: 4,
    accessTokenFingerprint: 'token-fingerprint',
    apiOriginFingerprint: 'fabricated-api',
    rendezvousEndpointFingerprint: 'fabricated-id',
    relayEndpointFingerprint: 'fabricated-hbbr',
    serverIdentityFingerprint: 'fabricated-key',
    verifiedAt: 1
  };
}

export default function rustDeskControlPlaneCapabilityPolicyTest():
  void {
  describe('RustDeskControlPlaneCapabilityPolicy', (): void => {
    it('does_not_mint_capability_from_profile_login_or_address_book',
      0, (): void => {
        const result = issueRustDeskControlPlaneCapabilityProof(
          binding(), locallyClaimedAttestation());
        expect(result.ok).assertFalse();
        expect(result.code).assertEqual('untrusted_attestation');
        expect(result.proof === undefined).assertTrue();
      });

    it('binds_api_id_and_relay_independently_not_by_same_host',
      0, (): void => {
        const source: RustDeskControlPlaneCapabilityBinding =
          binding();
        const identity = rustDeskControlPlaneBindingIdentity(source);
        expect(identity.ok).assertTrue();
        expect(identity.apiOriginFingerprint.length > 0).assertTrue();
        expect(identity.rendezvousEndpointFingerprint.length > 0)
          .assertTrue();
        expect(identity.relayEndpointFingerprint.length > 0)
          .assertTrue();
        expect(identity.apiOriginFingerprint ===
          identity.rendezvousEndpointFingerprint).assertFalse();
        expect(identity.rendezvousEndpointFingerprint ===
          identity.relayEndpointFingerprint).assertFalse();
        source.configuredApiServer = 'https://other-api.example.test';
        expect(rustDeskControlPlaneBindingIdentity(source).code)
          .assertEqual('identity_invalid');
        source.configuredApiServer = source.accountApiServer;
        source.idServerPort = 0;
        expect(rustDeskControlPlaneBindingIdentity(source).code)
          .assertEqual('endpoint_invalid');
      });

    it('rejects_fabricated_schema_v2_and_legacy_local_proofs',
      0, (): void => {
        const proof: RustDeskControlPlaneCapabilityProof =
          fabricatedProof();
        expect(rustDeskControlPlaneCapabilitySourceForProof(
          proof)).assertEqual('none');
        expect(rustDeskControlPlaneCapabilityProofMatches(
          proof, binding())).assertFalse();
        proof.schemaVersion = 1;
        expect(rustDeskControlPlaneCapabilitySourceForProof(
          proof)).assertEqual('none');
      });
  });
}
