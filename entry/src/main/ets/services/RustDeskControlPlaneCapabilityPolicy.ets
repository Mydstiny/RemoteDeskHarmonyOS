import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';
import {
  RustDeskControlPlaneCapabilityProof
} from '../model/RustDeskControlPlaneCapabilityModels';
import {
  RustDeskProAccountState,
  rustDeskProTokenGeneration
} from '../model/RustDeskProModels';
import {
  RustDeskControlPlaneCapabilitySource
} from './RustDeskControlPlanePolicy';
import { normalizeRustDeskProServerUrl } from './RustDeskProApiPolicy';
import {
  EndpointAddressResult,
  formatEndpointHostPort,
  parseEndpointFields
} from './EndpointAddressPolicy';

const CAPABILITY_SCHEMA_VERSION: number = 2;
const CAPABILITY_HASH_DOMAIN: string =
  'RemoteDeskHarmonyOS:rustdesk-control-plane-capability:v1:';

export interface RustDeskControlPlaneCapabilityBinding {
  ownerScopeId: string
  accountId: string
  relayId: string
  tokenGeneration: number
  accessTokenFingerprint: string
  accountApiServer: string
  configuredApiServer: string
  idServer: string
  idServerPort: number
  relayServer: string
  relayPort: number
  serverKeyMode: string
  serverKey: string
}

/**
 * An attestation is supplied by a versioned adapter after it has verified a
 * server capability contract. A profile choice, successful /api/login, or a
 * compatible address-book response is never an attestation.
 *
 * No issuer is registered in this release because RustDesk Server Pro does
 * not publish a capability response/signature contract that this independent
 * client can safely verify. Keeping the registry empty is intentional:
 * address-book sync works, while rendezvous token projection fails closed.
 */
export interface RustDeskControlPlaneCapabilityAttestation {
  source: RustDeskControlPlaneCapabilitySource
  issuerId: string
  contractId: string
  evidenceFingerprint: string
}

interface RustDeskTrustedCapabilityContract {
  source: RustDeskControlPlaneCapabilitySource
  issuerFingerprint: string
  contractFingerprint: string
}

const TRUSTED_CAPABILITY_CONTRACTS:
  RustDeskTrustedCapabilityContract[] = [];

export class RustDeskControlPlaneCapabilityIssueResult {
  ok: boolean = false;
  code: string = 'capability_unverified';
  message: string = '';
  proof: RustDeskControlPlaneCapabilityProof | undefined = undefined;
}

/**
 * Fingerprinted structural identity for one control-plane binding.
 *
 * API identity is checked only against the account that obtained the HTTP
 * token. ID and Relay are deliberately independent endpoints: a valid
 * deployment may place all three services on different hosts.
 */
export class RustDeskControlPlaneBindingIdentityResult {
  ok: boolean = false;
  code: string = 'identity_invalid';
  ownerScopeFingerprint: string = '';
  accountIdFingerprint: string = '';
  relayIdFingerprint: string = '';
  apiOriginFingerprint: string = '';
  rendezvousEndpointFingerprint: string = '';
  relayEndpointFingerprint: string = '';
  serverIdentityFingerprint: string = '';
}

function sha256Fingerprint(kind: string, value: string): string {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: new util.TextEncoder().encode(
    CAPABILITY_HASH_DOMAIN + kind + ':' + value) });
  const bytes: Uint8Array = new Uint8Array(md.digestSync().data);
  let result: string = '';
  for (let i = 0; i < bytes.length; i++) {
    result += bytes[i].toString(16).padStart(2, '0');
  }
  return result;
}

function canonicalApiOrigin(value: string): string {
  try {
    return normalizeRustDeskProServerUrl(value).toLowerCase();
  } catch (_err) {
    return '';
  }
}

function endpointFingerprint(kind: string, host: string, port: number): string {
  const parsed: EndpointAddressResult = parseEndpointFields(host, port);
  if (!parsed.ok || parsed.endpoint.scope !== '') {
    return '';
  }
  return sha256Fingerprint(kind, formatEndpointHostPort(parsed.endpoint));
}

function endpointComparisonKey(host: string, port: number): string {
  const parsed: EndpointAddressResult = parseEndpointFields(host, port);
  if (!parsed.ok || parsed.endpoint.scope !== '') {
    return 'invalid\u001f' + host + '\u001f' + port.toString();
  }
  return formatEndpointHostPort(parsed.endpoint);
}

export function rustDeskControlPlaneBindingIdentity(
  binding: RustDeskControlPlaneCapabilityBinding
): RustDeskControlPlaneBindingIdentityResult {
  const result = new RustDeskControlPlaneBindingIdentityResult();
  if (binding.ownerScopeId.trim() === '' ||
    binding.accountId.trim() === '' || binding.relayId.trim() === '') {
    result.code = 'owner_binding_missing';
    return result;
  }
  const accountApiOrigin: string =
    canonicalApiOrigin(binding.accountApiServer);
  const configuredApiOrigin: string =
    canonicalApiOrigin(binding.configuredApiServer);
  if (accountApiOrigin === '' ||
    accountApiOrigin !== configuredApiOrigin) {
    result.code = 'identity_invalid';
    return result;
  }
  if (binding.tokenGeneration <= 0 ||
    binding.accessTokenFingerprint.trim() === '') {
    result.code = 'token_binding_missing';
    return result;
  }
  if (binding.serverKey.trim() === '' ||
    binding.serverKeyMode.trim() === '') {
    result.code = 'server_identity_missing';
    return result;
  }
  const rendezvousFingerprint: string = endpointFingerprint(
    'rendezvous', binding.idServer, binding.idServerPort);
  const relayFingerprint: string = endpointFingerprint(
    'relay', binding.relayServer, binding.relayPort);
  if (rendezvousFingerprint === '' || relayFingerprint === '') {
    result.code = 'endpoint_invalid';
    return result;
  }
  result.ok = true;
  result.code = 'verified';
  result.ownerScopeFingerprint = sha256Fingerprint(
    'owner', binding.ownerScopeId.trim());
  result.accountIdFingerprint = sha256Fingerprint(
    'account', binding.accountId.trim());
  result.relayIdFingerprint = sha256Fingerprint(
    'relay-id', binding.relayId.trim());
  result.apiOriginFingerprint = sha256Fingerprint(
    'api-origin', accountApiOrigin);
  result.rendezvousEndpointFingerprint = rendezvousFingerprint;
  result.relayEndpointFingerprint = relayFingerprint;
  result.serverIdentityFingerprint = sha256Fingerprint(
    'server-identity',
    binding.serverKeyMode.trim() + '\u001f' + binding.serverKey.trim());
  return result;
}

export function rustDeskControlPlaneBinding(
  ownerScopeId: string,
  account: RustDeskProAccountState,
  relay: RustDeskRelayConfig
): RustDeskControlPlaneCapabilityBinding {
  return {
    ownerScopeId,
    accountId: account.id,
    relayId: relay.id,
    tokenGeneration: rustDeskProTokenGeneration(account),
    accessTokenFingerprint: account.accessTokenFingerprint,
    accountApiServer: account.serverUrl,
    configuredApiServer: relay.apiServer,
    idServer: relay.idServer,
    idServerPort: relay.idServerPort,
    relayServer: relay.relayServer,
    relayPort: relay.relayPort,
    serverKeyMode: relay.keyMode,
    serverKey: relay.key
  };
}

function attestationIsTrusted(
  attestation: RustDeskControlPlaneCapabilityAttestation
): boolean {
  // Register a provider here only after its versioned contract, server
  // evidence and revocation behavior have passed real-endpoint acceptance.
  const issuerFingerprint: string = sha256Fingerprint(
    'attestation-issuer', attestation.issuerId.trim());
  const contractFingerprint: string = sha256Fingerprint(
    'attestation-contract', attestation.contractId.trim());
  return TRUSTED_CAPABILITY_CONTRACTS.some(
    (contract: RustDeskTrustedCapabilityContract): boolean =>
      contract.source === attestation.source &&
      contract.issuerFingerprint === issuerFingerprint &&
      contract.contractFingerprint === contractFingerprint);
}

export function rustDeskControlPlaneCapabilitySourceForProof(
  proof: RustDeskControlPlaneCapabilityProof | undefined
): RustDeskControlPlaneCapabilitySource {
  if (proof === undefined ||
    proof.schemaVersion !== CAPABILITY_SCHEMA_VERSION ||
    proof.attestationEvidenceFingerprint.trim() === '') {
    return 'none';
  }
  const source: RustDeskControlPlaneCapabilitySource =
    proof.source === 'official_server_pro'
      ? 'official_server_pro'
      : (proof.source === 'verified_third_party'
        ? 'verified_third_party' : 'none');
  if (source === 'none') { return 'none'; }
  const trusted: boolean = TRUSTED_CAPABILITY_CONTRACTS.some(
    (contract: RustDeskTrustedCapabilityContract): boolean =>
      contract.source === source &&
      contract.issuerFingerprint ===
        proof.attestationIssuerFingerprint &&
      contract.contractFingerprint ===
        proof.attestationContractFingerprint);
  return trusted ? source : 'none';
}

export function issueRustDeskControlPlaneCapabilityProof(
  binding: RustDeskControlPlaneCapabilityBinding,
  attestation: RustDeskControlPlaneCapabilityAttestation
): RustDeskControlPlaneCapabilityIssueResult {
  const result = new RustDeskControlPlaneCapabilityIssueResult();
  if (attestation.source === 'none') {
    result.code = 'unsupported_source';
    result.message = '该地址簿来源没有已验证的控制面协议能力。';
    return result;
  }
  if (!attestationIsTrusted(attestation)) {
    result.code = 'untrusted_attestation';
    result.message =
      '地址簿已同步；当前没有可验证的控制面能力提供方，连接按 API-only 处理。';
    return result;
  }
  const identity: RustDeskControlPlaneBindingIdentityResult =
    rustDeskControlPlaneBindingIdentity(binding);
  if (!identity.ok) {
    result.code = identity.code;
    switch (identity.code) {
      case 'owner_binding_missing':
        result.message = '账号数据域尚未就绪，无法绑定控制面能力。';
        break;
      case 'token_binding_missing':
        result.message = '登录令牌身份不完整，控制面令牌保持禁用。';
        break;
      case 'server_identity_missing':
        result.message =
          '服务器公钥／共享 Key 尚未确认，控制面令牌保持禁用。';
        break;
      case 'endpoint_invalid':
        result.message = 'ID 或 Relay 端点无效，控制面令牌保持禁用。';
        break;
      default:
        result.message =
          '登录 API 与当前中继 API 配置不一致，控制面令牌保持禁用。';
        break;
    }
    return result;
  }
  result.ok = true;
  result.code = 'verified';
  result.message = '';
  result.proof = {
    schemaVersion: CAPABILITY_SCHEMA_VERSION,
    source: attestation.source,
    attestationIssuerFingerprint: sha256Fingerprint(
      'attestation-issuer', attestation.issuerId.trim()),
    attestationContractFingerprint: sha256Fingerprint(
      'attestation-contract', attestation.contractId.trim()),
    attestationEvidenceFingerprint: attestation.evidenceFingerprint,
    ownerScopeFingerprint: identity.ownerScopeFingerprint,
    accountIdFingerprint: identity.accountIdFingerprint,
    relayIdFingerprint: identity.relayIdFingerprint,
    tokenGeneration: binding.tokenGeneration,
    accessTokenFingerprint: binding.accessTokenFingerprint,
    apiOriginFingerprint: identity.apiOriginFingerprint,
    rendezvousEndpointFingerprint:
      identity.rendezvousEndpointFingerprint,
    relayEndpointFingerprint: identity.relayEndpointFingerprint,
    serverIdentityFingerprint: identity.serverIdentityFingerprint,
    verifiedAt: Date.now()
  };
  return result;
}

export function rustDeskControlPlaneCapabilityProofMatches(
  proof: RustDeskControlPlaneCapabilityProof | undefined,
  binding: RustDeskControlPlaneCapabilityBinding
): boolean {
  if (proof === undefined ||
    proof.schemaVersion !== CAPABILITY_SCHEMA_VERSION ||
    proof.tokenGeneration !== binding.tokenGeneration ||
    proof.accessTokenFingerprint !== binding.accessTokenFingerprint) {
    return false;
  }
  // This release has no registered capability issuer. Old locally minted
  // schema-v1 proofs and any fabricated schema-v2 proof are rejected.
  if (rustDeskControlPlaneCapabilitySourceForProof(proof) === 'none') {
    return false;
  }
  const identity: RustDeskControlPlaneBindingIdentityResult =
    rustDeskControlPlaneBindingIdentity(binding);
  if (!identity.ok) {
    return false;
  }
  return proof.ownerScopeFingerprint === identity.ownerScopeFingerprint &&
    proof.accountIdFingerprint === identity.accountIdFingerprint &&
    proof.relayIdFingerprint === identity.relayIdFingerprint &&
    proof.apiOriginFingerprint === identity.apiOriginFingerprint &&
    proof.rendezvousEndpointFingerprint ===
      identity.rendezvousEndpointFingerprint &&
    proof.relayEndpointFingerprint ===
      identity.relayEndpointFingerprint &&
    proof.serverIdentityFingerprint ===
      identity.serverIdentityFingerprint;
}

export function rustDeskRelayCapabilityIdentityChanged(
  previous: RustDeskRelayConfig,
  next: RustDeskRelayConfig
): boolean {
  return previous.controlPlaneProfile !== next.controlPlaneProfile ||
    canonicalApiOrigin(previous.apiServer) !==
      canonicalApiOrigin(next.apiServer) ||
    endpointComparisonKey(previous.idServer, previous.idServerPort) !==
      endpointComparisonKey(next.idServer, next.idServerPort) ||
    endpointComparisonKey(previous.relayServer, previous.relayPort) !==
      endpointComparisonKey(next.relayServer, next.relayPort) ||
    previous.keyMode !== next.keyMode ||
    previous.key !== next.key;
}
