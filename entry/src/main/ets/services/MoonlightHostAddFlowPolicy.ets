import {
  MoonlightAddress,
  MoonlightAddressFamily,
  MoonlightHostType
} from '../model/MoonlightModels';

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
  return { host: value.host, family: value.family, port: value.port };
}

function cloneVerification(
  value: MoonlightHostAddVerification | null
): MoonlightHostAddVerification | null {
  if (value === null) { return null; }
  return {
    serverUuid: value.serverUuid,
    serverName: value.serverName,
    hostType: value.hostType,
    version: value.version,
    address: cloneAddress(value.address),
    httpsPort: value.httpsPort,
    paired: value.paired,
    fingerprintSha256: value.fingerprintSha256,
    certificateChanged: value.certificateChanged,
    udpVerified: value.udpVerified,
    duplicateHostId: value.duplicateHostId
  };
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

function parsePort(value: string): number {
  if (!/^[0-9]{1,5}$/.test(value)) { return 0; }
  const parsed: number = Number(value);
  return validPort(parsed) ? parsed : 0;
}

function ipv4IsValid(value: string): boolean {
  const parts: string[] = value.split('.');
  if (parts.length !== 4) { return false; }
  for (let index = 0; index < parts.length; index++) {
    if (!/^(0|[1-9][0-9]{0,2})$/.test(parts[index])) { return false; }
    const part: number = Number(parts[index]);
    if (part < 0 || part > 255) { return false; }
  }
  return true;
}

function ipv6IsValid(value: string): boolean {
  if (value.length < 2 || value.length > 45 || value.indexOf(':') < 0 ||
      value.indexOf(':::') >= 0 || !/^[0-9a-fA-F:.]+$/.test(value)) {
    return false;
  }
  const doubleColon: number = value.indexOf('::');
  if (doubleColon >= 0 && value.indexOf('::', doubleColon + 2) >= 0) { return false; }
  const parts: string[] = value.split(':');
  let groups: number = 0;
  for (let index = 0; index < parts.length; index++) {
    const part: string = parts[index];
    if (part === '') { continue; }
    if (part.indexOf('.') >= 0) {
      if (index !== parts.length - 1 || !ipv4IsValid(part)) { return false; }
      groups += 2;
    } else {
      if (!/^[0-9a-fA-F]{1,4}$/.test(part)) { return false; }
      groups += 1;
    }
  }
  return doubleColon >= 0 ? groups < 8 : groups === 8;
}

function hostnameIsValid(value: string): boolean {
  if (value.length < 1 || value.length > 253 || value.startsWith('.') ||
      value.endsWith('.') || value.indexOf('..') >= 0) {
    return false;
  }
  const labels: string[] = value.split('.');
  for (let index = 0; index < labels.length; index++) {
    const label: string = labels[index];
    if (label.length < 1 || label.length > 63 || label.startsWith('-') ||
        label.endsWith('-') || !/^[A-Za-z0-9-]+$/.test(label)) {
      return false;
    }
  }
  return true;
}

function addressResult(errorText: string): MoonlightHostAddAddressResult {
  return { ok: false, address: emptyMoonlightAddress(), canonical: '', errorText: errorText };
}

export function parseMoonlightHostAddAddress(
  input: string,
  customPortText: string = MOONLIGHT_DEFAULT_CONTROL_PORT.toString()
): MoonlightHostAddAddressResult {
  const source: string = input.trim();
  if (source === '') { return addressResult('请输入主机地址'); }
  if (source.indexOf('://') >= 0 || source.indexOf('/') >= 0 ||
      source.indexOf('@') >= 0 || /\s/.test(source)) {
    return addressResult('请输入域名、IPv4 或带方括号的 IPv6 地址');
  }
  let host: string = source;
  let port: number = parsePort(customPortText.trim());
  if (port === 0) { return addressResult('端口必须在 1-65535 之间'); }
  let family: MoonlightAddressFamily = 'hostname';
  if (source.startsWith('[')) {
    const close: number = source.indexOf(']');
    if (close <= 1) { return addressResult('IPv6 地址格式不正确'); }
    host = source.substring(1, close);
    const suffix: string = source.substring(close + 1);
    if (suffix !== '') {
      if (!suffix.startsWith(':')) { return addressResult('IPv6 地址格式不正确'); }
      port = parsePort(suffix.substring(1));
      if (port === 0) { return addressResult('端口必须在 1-65535 之间'); }
    }
    if (!ipv6IsValid(host)) { return addressResult('IPv6 地址格式不正确'); }
    family = 'ipv6';
  } else if (ipv4IsValid(source)) {
    family = 'ipv4';
  } else {
    const colon: number = source.lastIndexOf(':');
    if (colon > 0 && source.indexOf(':') === colon) {
      const suffixPort: number = parsePort(source.substring(colon + 1));
      if (suffixPort === 0) { return addressResult('端口必须在 1-65535 之间'); }
      host = source.substring(0, colon);
      port = suffixPort;
    }
    if (ipv4IsValid(host)) {
      family = 'ipv4';
    } else if (ipv6IsValid(host)) {
      family = 'ipv6';
    } else if (/^[0-9.]+$/.test(host) && host.indexOf('.') >= 0) {
      return addressResult('IPv4 地址格式不正确');
    } else if (hostnameIsValid(host)) {
      family = 'hostname';
    } else {
      return addressResult('主机地址格式不正确');
    }
  }
  const normalizedHost: string = host.toLowerCase();
  const canonical: string = family === 'ipv6' ?
    '[' + normalizedHost + ']:' + port.toString() :
    normalizedHost + ':' + port.toString();
  return {
    ok: true,
    address: { host: normalizedHost, family: family, port: port },
    canonical: canonical,
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
