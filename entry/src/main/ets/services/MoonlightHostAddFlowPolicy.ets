import {
  MoonlightAddress,
  MoonlightAddressFamily,
  MoonlightHostType,
  canonicalMoonlightAddress,
  moonlightAddressIsValid,
  moonlightAddressKey
} from '../model/MoonlightModels';
import {
  EndpointAddressResult,
  formatEndpointHostPort,
  parseEndpointAuthority,
  parseEndpointPortText
} from './EndpointAddressPolicy';

export type MoonlightHostAddStep = 1 | 2 | 3 | 4;
export type MoonlightHostAddMode = 'automatic' | 'manual';
export type MoonlightHostAddOperation =
  'none' | 'discovery' | 'verify' | 'pair' | 'trust' | 'catalog' | 'save';
export type MoonlightHostAddTrustState =
  'unknown' | 'pending' | 'trusted' | 'changed' | 'rejected';
export type MoonlightHostAddDismissDecision = 'close' | 'confirm_discard';

export const MOONLIGHT_DEFAULT_CONTROL_PORT: number = 47989;

export interface MoonlightHostAddCandidate {
  serverUuid: string;
  displayName: string;
  address: MoonlightAddress;
  addresses?: MoonlightAddress[];
  paired: boolean;
  reachable: boolean;
  lastSeenAt: number;
}

export interface MoonlightHostAddVerification {
  serverUuid: string;
  serverName: string;
  hostType: MoonlightHostType;
  version: string;
  address: MoonlightAddress;
  candidateAddresses?: MoonlightAddress[];
  /** serverinfo/HttpsPort; absent only for legacy in-memory test/state data. */
  httpsPort?: number;
  paired: boolean;
  fingerprintSha256: string;
  certificateChanged: boolean;
  udpVerified: boolean;
  duplicateHostId: string;
}

export interface MoonlightHostAddCatalogSummary {
  appCount: number;
  titles: string[];
  stale: boolean;
  errorText: string;
}

export interface MoonlightHostAddAddressResult {
  ok: boolean;
  address: MoonlightAddress;
  canonical: string;
  errorText: string;
}

export interface MoonlightHostAddNativeAddress {
  value: string;
  family: 'unspecified' | 'ipv4' | 'ipv6';
  scope?: string;
}

const MOONLIGHT_MAX_NATIVE_ADDRESSES: number = 8;
const MOONLIGHT_MAX_PERSISTED_ADDRESSES: number = 16;

export function moonlightHostAddNativeAddress(
  address: MoonlightAddress
): MoonlightHostAddNativeAddress {
  const result: MoonlightHostAddNativeAddress = {
    value: address.host,
    family: address.family === 'ipv4' ? 'ipv4' :
      address.family === 'ipv6' ? 'ipv6' : 'unspecified'
  };
  if (address.scope !== undefined && address.scope !== '') {
    result.scope = address.scope;
  }
  return result;
}

/**
 * Native serverName is a TLS/HTTP identity, not Sunshine's display hostname.
 * The latter may contain spaces or non-DNS text and remains UI-only.
 */
export function moonlightHostAddServerIdentity(address: MoonlightAddress): string {
  return canonicalMoonlightAddress(address).host;
}

export function moonlightMergeCandidateAddresses(
  selected: MoonlightAddress,
  candidates: MoonlightAddress[] | undefined,
  maximum: number = MOONLIGHT_MAX_PERSISTED_ADDRESSES
): MoonlightAddress[] {
  if (!moonlightAddressIsValid(selected)) { return []; }
  const limit: number = Number.isInteger(maximum) && maximum > 0 ?
    Math.min(maximum, MOONLIGHT_MAX_PERSISTED_ADDRESSES) :
    MOONLIGHT_MAX_PERSISTED_ADDRESSES;
  const selectedAddress: MoonlightAddress = canonicalMoonlightAddress(selected);
  const keys: string[] = [moonlightAddressKey(selectedAddress)];
  const ipv4: MoonlightAddress[] = [];
  const ipv6: MoonlightAddress[] = [];
  const hostnames: MoonlightAddress[] = [];
  const source: MoonlightAddress[] = candidates === undefined ? [] : candidates;
  // Candidate arrays can originate from discovery callbacks or legacy rows.
  // Bound normalization work even when an in-memory caller bypasses model
  // validation; four full persisted sets still leave room to find both
  // families after a long same-family prefix.
  const scanLimit: number = Math.min(
    source.length, MOONLIGHT_MAX_PERSISTED_ADDRESSES * 4);
  for (let index: number = 0; index < scanLimit; index++) {
    if (!moonlightAddressIsValid(source[index]) || source[index].port !== selected.port) {
      continue;
    }
    const normalized: MoonlightAddress = canonicalMoonlightAddress(source[index]);
    const key: string = moonlightAddressKey(normalized);
    if (keys.indexOf(key) >= 0) { continue; }
    if (normalized.family === 'ipv4' && ipv4.length < limit) {
      ipv4.push(normalized);
    } else if (normalized.family === 'ipv6' &&
      ipv6.length < limit) {
      ipv6.push(normalized);
    } else if (normalized.family === 'hostname' &&
      hostnames.length < limit) {
      hostnames.push(normalized);
    } else {
      continue;
    }
    keys.push(key);
  }
  const buckets: MoonlightAddress[][] = selectedAddress.family === 'ipv6'
    ? [ipv4, ipv6, hostnames]
    : selectedAddress.family === 'ipv4' ? [ipv6, ipv4, hostnames] :
      [ipv6, ipv4, hostnames];
  const ordered: MoonlightAddress[] = [selectedAddress];
  let added: boolean = true;
  while (ordered.length < limit && added) {
    added = false;
    for (let bucket: number = 0;
      bucket < buckets.length && ordered.length < limit;
      bucket++) {
      if (buckets[bucket].length > 0) {
        ordered.push(buckets[bucket].shift() as MoonlightAddress);
        added = true;
      }
    }
  }
  return ordered;
}

export function moonlightHostAddNativeAddresses(
  selected: MoonlightAddress,
  candidates: MoonlightAddress[] | undefined
): MoonlightHostAddNativeAddress[] {
  const ordered: MoonlightAddress[] = moonlightMergeCandidateAddresses(
    selected, candidates, MOONLIGHT_MAX_NATIVE_ADDRESSES);
  const result: MoonlightHostAddNativeAddress[] = [];
  for (let index: number = 0; index < ordered.length; index++) {
    result.push(moonlightHostAddNativeAddress(ordered[index]));
  }
  return result;
}

export class MoonlightHostAddOperationKey {
  ownerToken: number = 0;
  generation: number = 0;
  operation: MoonlightHostAddOperation = 'none';
}

export class MoonlightHostAddDiscoveryKey {
  ownerToken: number = 0;
  generation: number = 0;
}

export class MoonlightHostAddState {
  ownerToken: number = 0;
  generation: number = 0;
  discoveryGeneration: number = 0;
  discoveryActive: boolean = false;
  step: MoonlightHostAddStep = 1;
  mode: MoonlightHostAddMode = 'automatic';
  activeOperation: MoonlightHostAddOperation = 'none';
  selectedServerUuid: string = '';
  selectedAddress: MoonlightAddress = emptyMoonlightAddress();
  candidateAddresses: MoonlightAddress[] = [];
  manualAddressText: string = '';
  manualPortText: string = MOONLIGHT_DEFAULT_CONTROL_PORT.toString();
  verification: MoonlightHostAddVerification | null = null;
  displayName: string = '';
  displayNameEdited: boolean = false;
  temporaryIdentityCreated: boolean = false;
  pairingPin: string = '';
  pairingPinExpiresAt: number = 0;
  paired: boolean = false;
  trustState: MoonlightHostAddTrustState = 'unknown';
  catalog: MoonlightHostAddCatalogSummary | null = null;
  savedLocally: boolean = false;
  saveRecoveryRequired: boolean = false;
  errorText: string = '';
}

export interface MoonlightHostAddBeginResult {
  state: MoonlightHostAddState;
  key: MoonlightHostAddOperationKey;
}

export interface MoonlightHostAddDiscoveryBeginResult {
  state: MoonlightHostAddState;
  key: MoonlightHostAddDiscoveryKey;
}

export interface MoonlightHostAddTransitionResult {
  ok: boolean;
  state: MoonlightHostAddState;
  errorText: string;
}

function emptyMoonlightAddress(): MoonlightAddress {
  return { host: '', family: 'hostname', port: MOONLIGHT_DEFAULT_CONTROL_PORT };
}

function cloneAddress(value: MoonlightAddress): MoonlightAddress {
  return {
    host: value.host, family: value.family, port: value.port,
    scope: value.scope
  };
}

function cloneAddresses(values: MoonlightAddress[] | undefined): MoonlightAddress[] {
  if (values === undefined) { return []; }
  return values.slice(0, 16).map(
    (value: MoonlightAddress): MoonlightAddress => cloneAddress(value));
}

export function cloneMoonlightHostAddVerification(
  value: MoonlightHostAddVerification
): MoonlightHostAddVerification {
  return {
    serverUuid: value.serverUuid,
    serverName: value.serverName,
    hostType: value.hostType,
    version: value.version,
    address: cloneAddress(value.address),
    candidateAddresses: cloneAddresses(value.candidateAddresses),
    httpsPort: value.httpsPort,
    paired: value.paired,
    fingerprintSha256: value.fingerprintSha256,
    certificateChanged: value.certificateChanged,
    udpVerified: value.udpVerified,
    duplicateHostId: value.duplicateHostId
  };
}

function cloneVerification(
  value: MoonlightHostAddVerification | null
): MoonlightHostAddVerification | null {
  return value === null ? null : cloneMoonlightHostAddVerification(value);
}

function cloneCatalog(
  value: MoonlightHostAddCatalogSummary | null
): MoonlightHostAddCatalogSummary | null {
  if (value === null) { return null; }
  return {
    appCount: value.appCount,
    titles: value.titles.slice(),
    stale: value.stale,
    errorText: value.errorText
  };
}

export function cloneMoonlightHostAddState(
  value: MoonlightHostAddState
): MoonlightHostAddState {
  const result = new MoonlightHostAddState();
  result.ownerToken = value.ownerToken;
  result.generation = value.generation;
  result.discoveryGeneration = value.discoveryGeneration;
  result.discoveryActive = value.discoveryActive;
  result.step = value.step;
  result.mode = value.mode;
  result.activeOperation = value.activeOperation;
  result.selectedServerUuid = value.selectedServerUuid;
  result.selectedAddress = cloneAddress(value.selectedAddress);
  result.candidateAddresses = cloneAddresses(value.candidateAddresses);
  result.manualAddressText = value.manualAddressText;
  result.manualPortText = value.manualPortText;
  result.verification = cloneVerification(value.verification);
  result.displayName = value.displayName;
  result.displayNameEdited = value.displayNameEdited;
  result.temporaryIdentityCreated = value.temporaryIdentityCreated;
  result.pairingPin = value.pairingPin;
  result.pairingPinExpiresAt = value.pairingPinExpiresAt;
  result.paired = value.paired;
  result.trustState = value.trustState;
  result.catalog = cloneCatalog(value.catalog);
  result.savedLocally = value.savedLocally;
  result.saveRecoveryRequired = value.saveRecoveryRequired;
  result.errorText = value.errorText;
  return result;
}

export function createMoonlightHostAddState(ownerToken: number): MoonlightHostAddState {
  const result = new MoonlightHostAddState();
  result.ownerToken = Number.isSafeInteger(ownerToken) && ownerToken > 0 ? ownerToken : 0;
  return result;
}

function validPort(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 1 && value <= 65535;
}

function fingerprintIsValid(value: string): boolean {
  return /^[0-9a-fA-F]{64}$/.test(value);
}

function addressResult(errorText: string): MoonlightHostAddAddressResult {
  return { ok: false, address: emptyMoonlightAddress(), canonical: '', errorText: errorText };
}

export function parseMoonlightHostAddAddress(
  input: string,
  customPortText: string = MOONLIGHT_DEFAULT_CONTROL_PORT.toString()
): MoonlightHostAddAddressResult {
  if (input === '') { return addressResult('请输入主机地址'); }
  const defaultPort: number = parseEndpointPortText(customPortText);
  if (defaultPort === 0) { return addressResult('端口必须在 1-65535 之间'); }
  const parsed: EndpointAddressResult = parseEndpointAuthority(input, defaultPort);
  if (!parsed.ok) {
    if (parsed.error === 'invalid_port') { return addressResult('端口必须在 1-65535 之间'); }
    if (parsed.error === 'invalid_ipv4') { return addressResult('IPv4 地址格式不正确'); }
    if (parsed.error === 'invalid_ipv6') { return addressResult('IPv6 地址格式不正确'); }
    return addressResult('请输入有效的域名、IPv4 或带方括号的 IPv6 地址');
  }
  const family: MoonlightAddressFamily = parsed.endpoint.family;
  return {
    ok: true,
    address: {
      host: parsed.endpoint.canonicalHost,
      family: family,
      port: parsed.endpoint.port,
      scope: parsed.endpoint.scope === '' ? undefined : parsed.endpoint.scope
    },
    canonical: formatEndpointHostPort(parsed.endpoint),
    errorText: ''
  };
}

export function selectMoonlightHostAddCandidate(
  state: MoonlightHostAddState,
  candidate: MoonlightHostAddCandidate
): MoonlightHostAddState {
  const next: MoonlightHostAddState = cloneMoonlightHostAddState(state);
  next.mode = 'automatic';
  next.selectedServerUuid = candidate.serverUuid;
  next.selectedAddress = cloneAddress(candidate.address);
  next.candidateAddresses = cloneAddresses(candidate.addresses);
  if (next.candidateAddresses.length === 0) {
    next.candidateAddresses = [cloneAddress(candidate.address)];
  }
  next.errorText = '';
  return next;
}

export function updateMoonlightHostAddManualAddress(
  state: MoonlightHostAddState,
  addressText: string,
  portText: string
): MoonlightHostAddState {
  const next: MoonlightHostAddState = cloneMoonlightHostAddState(state);
  next.mode = 'manual';
  next.manualAddressText = addressText;
  next.manualPortText = portText;
  next.candidateAddresses = [];
  next.errorText = '';
  return next;
}

export function beginMoonlightHostAddOperation(
  state: MoonlightHostAddState,
  operation: MoonlightHostAddOperation
): MoonlightHostAddBeginResult {
  const next: MoonlightHostAddState = cloneMoonlightHostAddState(state);
  next.generation += 1;
  next.activeOperation = operation;
  next.errorText = '';
  const key = new MoonlightHostAddOperationKey();
  key.ownerToken = next.ownerToken;
  key.generation = next.generation;
  key.operation = operation;
  return { state: next, key: key };
}

export function beginMoonlightHostAddDiscovery(
  state: MoonlightHostAddState
): MoonlightHostAddDiscoveryBeginResult {
  const next: MoonlightHostAddState = cloneMoonlightHostAddState(state);
  next.discoveryGeneration += 1;
  next.discoveryActive = true;
  const key = new MoonlightHostAddDiscoveryKey();
  key.ownerToken = next.ownerToken;
  key.generation = next.discoveryGeneration;
  return { state: next, key: key };
}

export function moonlightHostAddDiscoveryIsCurrent(
  state: MoonlightHostAddState,
  key: MoonlightHostAddDiscoveryKey
): boolean {
  return state.ownerToken > 0 && state.discoveryActive &&
    key.ownerToken === state.ownerToken && key.generation === state.discoveryGeneration;
}

export function cancelMoonlightHostAddDiscovery(
  state: MoonlightHostAddState
): MoonlightHostAddState {
  const next: MoonlightHostAddState = cloneMoonlightHostAddState(state);
  next.discoveryGeneration += 1;
  next.discoveryActive = false;
  return next;
}

export function moonlightHostAddOperationIsCurrent(
  state: MoonlightHostAddState,
  key: MoonlightHostAddOperationKey
): boolean {
  return state.ownerToken > 0 && key.ownerToken === state.ownerToken &&
    key.generation === state.generation && key.operation === state.activeOperation &&
    key.operation !== 'none';
}

export function cancelMoonlightHostAddOperation(
  state: MoonlightHostAddState
): MoonlightHostAddState {
  const next: MoonlightHostAddState = cloneMoonlightHostAddState(state);
  next.generation += 1;
  next.activeOperation = 'none';
  next.pairingPin = '';
  next.pairingPinExpiresAt = 0;
  next.errorText = '';
  return next;
}

export function applyMoonlightHostAddVerification(
  state: MoonlightHostAddState,
  key: MoonlightHostAddOperationKey,
  verification: MoonlightHostAddVerification
): MoonlightHostAddState {
  if (!moonlightHostAddOperationIsCurrent(state, key) || key.operation !== 'verify') {
    return cloneMoonlightHostAddState(state);
  }
  const next: MoonlightHostAddState = cloneMoonlightHostAddState(state);
  next.activeOperation = 'none';
  next.verification = cloneVerification(verification);
  if (next.verification !== null &&
      (next.verification.candidateAddresses === undefined ||
       next.verification.candidateAddresses.length === 0)) {
    next.verification.candidateAddresses = cloneAddresses(next.candidateAddresses);
  }
  next.selectedServerUuid = verification.serverUuid;
  next.selectedAddress = cloneAddress(verification.address);
  next.paired = verification.paired;
  next.trustState = verification.certificateChanged ? 'changed' :
    (fingerprintIsValid(verification.fingerprintSha256) ? 'pending' : 'unknown');
  if (!next.displayNameEdited) { next.displayName = verification.serverName; }
  next.step = 2;
  next.errorText = '';
  return next;
}

export function setMoonlightHostAddPairingPin(
  state: MoonlightHostAddState,
  key: MoonlightHostAddOperationKey,
  pin: string,
  expiresAt: number,
  nowMs: number
): MoonlightHostAddState {
  if (!moonlightHostAddOperationIsCurrent(state, key) || key.operation !== 'pair' ||
      !/^[0-9]{4}$/.test(pin) || !Number.isSafeInteger(expiresAt) || expiresAt <= nowMs) {
    return cloneMoonlightHostAddState(state);
  }
  const next: MoonlightHostAddState = cloneMoonlightHostAddState(state);
  next.temporaryIdentityCreated = true;
  next.pairingPin = pin;
  next.pairingPinExpiresAt = expiresAt;
  next.errorText = '';
  return next;
}

export function expireMoonlightHostAddPairingPin(
  state: MoonlightHostAddState,
  nowMs: number
): MoonlightHostAddState {
  if (state.pairingPin === '' || nowMs < state.pairingPinExpiresAt) {
    return cloneMoonlightHostAddState(state);
  }
  const next: MoonlightHostAddState = cloneMoonlightHostAddState(state);
  next.generation += 1;
  next.activeOperation = 'none';
  next.pairingPin = '';
  next.pairingPinExpiresAt = 0;
  next.errorText = '配对码已失效，请重新生成';
  return next;
}

export function completeMoonlightHostAddPairing(
  state: MoonlightHostAddState,
  key: MoonlightHostAddOperationKey,
  paired: boolean,
  nowMs: number,
  errorText: string = ''
): MoonlightHostAddState {
  if (!moonlightHostAddOperationIsCurrent(state, key) || key.operation !== 'pair') {
    return cloneMoonlightHostAddState(state);
  }
  if (state.pairingPin !== '' && nowMs >= state.pairingPinExpiresAt) {
    return expireMoonlightHostAddPairingPin(state, nowMs);
  }
  const next: MoonlightHostAddState = cloneMoonlightHostAddState(state);
  next.activeOperation = 'none';
  next.pairingPin = '';
  next.pairingPinExpiresAt = 0;
  next.paired = paired;
  next.trustState = next.verification !== null && next.verification.certificateChanged ?
    'changed' : (paired && next.verification !== null &&
      fingerprintIsValid(next.verification.fingerprintSha256) ? 'pending' : 'unknown');
  next.errorText = paired ? '' : (errorText === '' ? '主机尚未确认配对' : errorText);
  return next;
}

export function completeMoonlightHostAddTrust(
  state: MoonlightHostAddState,
  key: MoonlightHostAddOperationKey,
  accepted: boolean
): MoonlightHostAddState {
  if (!moonlightHostAddOperationIsCurrent(state, key) || key.operation !== 'trust') {
    return cloneMoonlightHostAddState(state);
  }
  const next: MoonlightHostAddState = cloneMoonlightHostAddState(state);
  next.activeOperation = 'none';
  if (!accepted) {
    next.paired = false;
    next.temporaryIdentityCreated = false;
    next.pairingPin = '';
    next.pairingPinExpiresAt = 0;
    next.trustState = 'rejected';
    next.errorText = '已拒绝该主机身份，请重新配对后再继续';
    return next;
  }
  const trustEvidenceValid: boolean = next.paired && next.verification !== null &&
    !next.verification.certificateChanged &&
    fingerprintIsValid(next.verification.fingerprintSha256);
  next.trustState = trustEvidenceValid ? 'trusted' : 'unknown';
  next.errorText = trustEvidenceValid ? '' : '主机证书指纹不可用，请重新验证';
  return next;
}

export function failMoonlightHostAddTrust(
  state: MoonlightHostAddState,
  key: MoonlightHostAddOperationKey,
  errorText: string = '无法保存主机信任，请重试'
): MoonlightHostAddState {
  if (!moonlightHostAddOperationIsCurrent(state, key) || key.operation !== 'trust') {
    return cloneMoonlightHostAddState(state);
  }
  const next: MoonlightHostAddState = cloneMoonlightHostAddState(state);
  next.activeOperation = 'none';
  next.trustState = next.verification !== null && next.verification.certificateChanged ?
    'changed' : 'pending';
  next.errorText = errorText;
  return next;
}

export function completeMoonlightHostAddCatalog(
  state: MoonlightHostAddState,
  key: MoonlightHostAddOperationKey,
  catalog: MoonlightHostAddCatalogSummary
): MoonlightHostAddState {
  if (!moonlightHostAddOperationIsCurrent(state, key) || key.operation !== 'catalog') {
    return cloneMoonlightHostAddState(state);
  }
  const next: MoonlightHostAddState = cloneMoonlightHostAddState(state);
  next.activeOperation = 'none';
  next.catalog = cloneCatalog(catalog);
  return next;
}

export function completeMoonlightHostAddSave(
  state: MoonlightHostAddState,
  key: MoonlightHostAddOperationKey,
  localCommitted: boolean,
  errorText: string = '',
  commitState: 'committed' | 'not_committed' | 'partial' | 'uncertain' =
    localCommitted ? 'committed' : 'not_committed'
): MoonlightHostAddState {
  if (!moonlightHostAddOperationIsCurrent(state, key) || key.operation !== 'save') {
    return cloneMoonlightHostAddState(state);
  }
  const next: MoonlightHostAddState = cloneMoonlightHostAddState(state);
  next.activeOperation = 'none';
  next.savedLocally = localCommitted && commitState === 'committed';
  next.saveRecoveryRequired = commitState === 'partial' || commitState === 'uncertain';
  next.errorText = next.savedLocally ? errorText :
    (errorText === '' ? '本地主机保存失败，请重试' : errorText);
  return next;
}

/**
 * A post-save route may carry only the stable ID returned by the successful
 * local repository commit. A queued/requested write or an object snapshot is
 * never sufficient to open a destination page.
 */
export function committedMoonlightHostAddId(
  localCommitted: boolean,
  hostId: string
): string {
  return localCommitted ? hostId.trim() : '';
}

export function moonlightHostAddSaveCanBegin(
  state: MoonlightHostAddState
): boolean {
  return state.step === 4 && state.paired && state.trustState === 'trusted' &&
    state.activeOperation === 'none' && !state.savedLocally && !state.saveRecoveryRequired;
}

export function setMoonlightHostAddDisplayName(
  state: MoonlightHostAddState,
  displayName: string
): MoonlightHostAddState {
  const next: MoonlightHostAddState = cloneMoonlightHostAddState(state);
  next.displayName = displayName;
  next.displayNameEdited = true;
  next.errorText = '';
  return next;
}

function transitionError(
  state: MoonlightHostAddState,
  errorText: string
): MoonlightHostAddTransitionResult {
  const next: MoonlightHostAddState = cloneMoonlightHostAddState(state);
  next.errorText = errorText;
  return { ok: false, state: next, errorText: errorText };
}

export function advanceMoonlightHostAddStep(
  state: MoonlightHostAddState
): MoonlightHostAddTransitionResult {
  const next: MoonlightHostAddState = cloneMoonlightHostAddState(state);
  if (state.step === 1) {
    if (state.mode === 'automatic') {
      if (state.selectedServerUuid === '' || state.selectedAddress.host === '') {
        return transitionError(state, '请选择一台已发现的主机');
      }
    } else {
      const parsed: MoonlightHostAddAddressResult = parseMoonlightHostAddAddress(
        state.manualAddressText, state.manualPortText);
      if (!parsed.ok) { return transitionError(state, parsed.errorText); }
      next.selectedAddress = cloneAddress(parsed.address);
      next.candidateAddresses = [cloneAddress(parsed.address)];
      next.selectedServerUuid = '';
    }
    next.errorText = '';
    return { ok: true, state: next, errorText: '' };
  }
  if (state.step === 2) {
    if (state.verification === null) {
      return transitionError(state, '请先完成主机验证');
    }
    if (state.verification.duplicateHostId !== '') {
      return transitionError(state, '这台主机已存在，请查看或更新已有主机');
    }
    if (state.verification.certificateChanged || state.trustState === 'changed') {
      return transitionError(state, '主机证书已变化，请先重新验证');
    }
    if (state.displayName.trim() === '') {
      return transitionError(state, '请输入主机显示名称');
    }
    next.step = 3;
    next.errorText = '';
    return { ok: true, state: next, errorText: '' };
  }
  if (state.step === 3) {
    if (!state.paired) { return transitionError(state, '请先完成主机配对'); }
    if (state.trustState === 'changed') {
      return transitionError(state, '主机证书已变化，请先重新验证');
    }
    if (state.trustState !== 'trusted') {
      return transitionError(state, '请确认并信任主机身份');
    }
    if (state.verification === null ||
        !fingerprintIsValid(state.verification.fingerprintSha256)) {
      return transitionError(state, '主机证书指纹不可用，请重新验证');
    }
    next.step = 4;
    next.errorText = '';
    return { ok: true, state: next, errorText: '' };
  }
  return transitionError(state, '当前已是最后一步');
}

export function backMoonlightHostAddStep(
  state: MoonlightHostAddState
): MoonlightHostAddState {
  if (state.step === 1) { return cloneMoonlightHostAddState(state); }
  const next: MoonlightHostAddState = cancelMoonlightHostAddOperation(state);
  next.step = (state.step - 1) as MoonlightHostAddStep;
  return next;
}

export function moonlightHostAddDraftIsDirty(state: MoonlightHostAddState): boolean {
  return state.manualAddressText.trim() !== '' || state.selectedServerUuid !== '' ||
    state.temporaryIdentityCreated;
}

export function moonlightHostAddDismissDecision(
  state: MoonlightHostAddState
): MoonlightHostAddDismissDecision {
  return moonlightHostAddDraftIsDirty(state) ? 'confirm_discard' : 'close';
}

export function moonlightHostAddPinDigits(state: MoonlightHostAddState): string[] {
  if (!/^[0-9]{4}$/.test(state.pairingPin)) { return []; }
  return [
    state.pairingPin.charAt(0), state.pairingPin.charAt(1),
    state.pairingPin.charAt(2), state.pairingPin.charAt(3)
  ];
}
