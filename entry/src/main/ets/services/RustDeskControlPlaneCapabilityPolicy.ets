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

function normalizedEndpointHost(value: string): string {
  let host: string = value.trim().toLowerCase();
  const scheme: number = host.indexOf('://');
  if (scheme >= 0) { host = host.substring(scheme + 3); }
  const slash: number = host.indexOf('/');
  if (slash >= 0) { host = host.substring(0, slash); }
  if (host.indexOf('@') >= 0) { return ''; }
  if (host.startsWith('[')) {
    const closing: number = host.indexOf(']');
    return closing > 1 ? host.substring(0, closing + 1) : '';
  }
  const colon: number = host.lastIndexOf(':');
  if (colon > 0) {
    const port: string = host.substring(colon + 1);
    if (/^[0-9]+$/.test(port)) { host = host.substring(0, colon); }
  }
  while (host.endsWith('.')) { host = host.substring(0, host.length - 1); }
  return host;
}

function canonicalApiOrigin(value: string): string {
  try {
    return normalizeRustDeskProServerUrl(value).toLowerCase();
  } catch (_err) {
    return '';
  }
}

function endpointFingerprint(kind: string, host: string, port: number): string {
  const normalizedHost: string = normalizedEndpointHost(host);
  if (normalizedHost === '' || !Number.isInteger(port) ||
    port <= 0 || port > 65535) {
    return '';
  }
  return sha256Fingerprint(kind,
    normalizedHost + ':' + port.toString());
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
  const accountApiOrigin: string =
    canonicalApiOrigin(binding.accountApiServer);
  const configuredApiOrigin: string =
    canonicalApiOrigin(binding.configuredApiServer);
  const apiOrigin: string = accountApiOrigin === configuredApiOrigin
    ? accountApiOrigin : '';
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
  if (binding.ownerScopeId.trim() === '' ||
    binding.accountId.trim() === '' || binding.relayId.trim() === '') {
    result.code = 'owner_binding_missing';
    result.message = '账号数据域尚未就绪，无法绑定控制面能力。';
    return result;
  }
  if (apiOrigin === '' ||
    normalizedEndpointHost(binding.idServer) === '' ||
    normalizedEndpointHost(binding.relayServer) === '') {
    result.code = 'identity_invalid';
    result.message =
      '登录 API 与当前中继 API 配置不一致，控制面令牌保持禁用。';
    return result;
  }
  if (binding.tokenGeneration <= 0 ||
    binding.accessTokenFingerprint.trim() === '') {
    result.code = 'token_binding_missing';
    result.message = '登录令牌身份不完整，控制面令牌保持禁用。';
    return result;
  }
  if (binding.serverKey.trim() === '' ||
    binding.serverKeyMode.trim() === '') {
    result.code = 'server_identity_missing';
    result.message = '服务器公钥／共享 Key 尚未确认，控制面令牌保持禁用。';
    return result;
  }
  const rendezvousFingerprint: string = endpointFingerprint(
    'rendezvous', binding.idServer, binding.idServerPort);
  const relayFingerprint: string = endpointFingerprint(
    'relay', binding.relayServer, binding.relayPort);
  if (rendezvousFingerprint === '' || relayFingerprint === '') {
    result.code = 'endpoint_invalid';
    result.message = 'ID 或 Relay 端点无效，控制面令牌保持禁用。';
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
    ownerScopeFingerprint: sha256Fingerprint(
      'owner', binding.ownerScopeId.trim()),
    accountIdFingerprint: sha256Fingerprint(
      'account', binding.accountId.trim()),
    relayIdFingerprint: sha256Fingerprint(
      'relay-id', binding.relayId.trim()),
    tokenGeneration: binding.tokenGeneration,
    accessTokenFingerprint: binding.accessTokenFingerprint,
    apiOriginFingerprint: sha256Fingerprint('api-origin', apiOrigin),
    rendezvousEndpointFingerprint: rendezvousFingerprint,
    relayEndpointFingerprint: relayFingerprint,
    serverIdentityFingerprint: sha256Fingerprint(
      'server-identity',
      binding.serverKeyMode.trim() + '\u001f' + binding.serverKey.trim()),
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
  const accountApiOrigin: string =
    canonicalApiOrigin(binding.accountApiServer);
  const configuredApiOrigin: string =
    canonicalApiOrigin(binding.configuredApiServer);
  const apiOrigin: string =
    accountApiOrigin === configuredApiOrigin
      ? accountApiOrigin : '';
  const rendezvousFingerprint: string = endpointFingerprint(
    'rendezvous', binding.idServer, binding.idServerPort);
  const relayFingerprint: string = endpointFingerprint(
    'relay', binding.relayServer, binding.relayPort);
  if (apiOrigin === '' || rendezvousFingerprint === '' ||
    relayFingerprint === '') {
    return false;
  }
  return proof.ownerScopeFingerprint === sha256Fingerprint(
      'owner', binding.ownerScopeId.trim()) &&
    proof.accountIdFingerprint ===
      sha256Fingerprint('account', binding.accountId.trim()) &&
    proof.relayIdFingerprint ===
      sha256Fingerprint('relay-id', binding.relayId.trim()) &&
    proof.apiOriginFingerprint ===
      sha256Fingerprint('api-origin', apiOrigin) &&
    proof.rendezvousEndpointFingerprint ===
      rendezvousFingerprint &&
    proof.relayEndpointFingerprint ===
      relayFingerprint &&
    proof.serverIdentityFingerprint ===
      sha256Fingerprint(
        'server-identity',
        binding.serverKeyMode.trim() + '\u001f' +
        binding.serverKey.trim());
}

export function rustDeskRelayCapabilityIdentityChanged(
  previous: RustDeskRelayConfig,
  next: RustDeskRelayConfig
): boolean {
  return previous.controlPlaneProfile !== next.controlPlaneProfile ||
    canonicalApiOrigin(previous.apiServer) !==
      canonicalApiOrigin(next.apiServer) ||
    normalizedEndpointHost(previous.idServer) !==
      normalizedEndpointHost(next.idServer) ||
    previous.idServerPort !== next.idServerPort ||
    normalizedEndpointHost(previous.relayServer) !==
      normalizedEndpointHost(next.relayServer) ||
    previous.relayPort !== next.relayPort ||
    previous.keyMode !== next.keyMode ||
    previous.key !== next.key;
}
