/**
 * Bounded Sunshine/GameStream serverinfo probe used by the local add flow.
 * It deliberately performs no persistence and never treats an HTTP response
 * as certificate trust; pairing is the native mTLS boundary that follows it.
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import {
  MoonlightAddress,
  MoonlightAddressFamily,
  MoonlightHostType,
  MOONLIGHT_DEFAULT_HTTPS_PORT,
  moonlightAddressIsValid
} from '../model/MoonlightModels';
import {
  MoonlightHostAddVerification,
  MOONLIGHT_DEFAULT_CONTROL_PORT
} from './MoonlightHostAddFlowPolicy';

const REQUEST_TIMEOUT_MS: number = 3500;
const MAX_RESPONSE_BYTES: number = 128 * 1024;
const MAX_SERVER_UUID_LENGTH: number = 256;
const MAX_SERVER_NAME_LENGTH: number = 256;
const MAX_VERSION_LENGTH: number = 128;
const MOONLIGHT_PROTOCOL_UNIQUE_ID: string = '0123456789ABCDEF';

/** Exact owner/operation-generation/candidate identity used by HostList writes. */
export class MoonlightHostOperationFence {
  ownerToken: number = 0;
  generation: number = 0;
  ownerScopeId: string = '';
  accountGeneration: number = 0;
  serverUuid: string = '';
  addressHost: string = '';
  addressFamily: MoonlightAddressFamily = 'hostname';
  addressPort: number = 0;
  addressScope: string = '';
}

function validRequestUuid(value: string): boolean {
  return /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(
    value);
}

export function moonlightServerInfoProbeEndpoint(
  address: MoonlightAddress,
  requestUuid: string
): string {
  if (!validAddress(address) || !validRequestUuid(requestUuid)) {
    return '';
  }
  const scope: string = address.scope === undefined ? '' : address.scope;
  const scopedHost: string = address.host + (scope === '' ? '' : '%25' + scope);
  const host: string = address.family === 'ipv6' ? '[' + scopedHost + ']' : scopedHost;
  const port: number = address.port > 0 ? address.port : MOONLIGHT_DEFAULT_CONTROL_PORT;
  return 'http://' + host + ':' + port.toString() + '/serverinfo?uniqueid=' +
    MOONLIGHT_PROTOCOL_UNIQUE_ID + '&uuid=' + encodeURIComponent(requestUuid);
}

function xmlAttribute(xml: string, name: string): string {
  const pattern: RegExp = new RegExp(
    "(?:^|\\s)" + name + "\\s*=\\s*[\"']([^\"']*)[\"']", 'i');
  const match: RegExpMatchArray | null = xml.match(pattern);
  return match === null || match.length < 2 ? '' : decodeXmlText(match[1]);
}

function xmlElement(xml: string, name: string): string {
  const pattern: RegExp = new RegExp(
    '<' + name + '(?:\\s[^>]*)?>([^<]*)</' + name + '>', 'i');
  const match: RegExpMatchArray | null = xml.match(pattern);
  return match === null || match.length < 2 ? '' : decodeXmlText(match[1]);
}

function decodeXmlText(value: string): string {
  return value.replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');
}

function serverInfoValue(xml: string, name: string): string {
  const element: string = xmlElement(xml, name);
  return element === '' ? xmlAttribute(xml, name) : element;
}

function boolAttribute(value: string): boolean {
  return value === '1' || value.toLowerCase() === 'true' || value.toLowerCase() === 'yes';
}

function advertisedHttpsPort(xml: string): number | null {
  const raw: string = serverInfoValue(xml, 'HttpsPort').trim();
  if (raw === '') { return MOONLIGHT_DEFAULT_HTTPS_PORT; }
  if (!/^[0-9]{1,5}$/.test(raw)) { return null; }
  const value: number = Number(raw);
  return Number.isSafeInteger(value) && value >= 1 && value <= 65535
    ? value : null;
}

function hasControlCharacter(value: string): boolean {
  for (let index = 0; index < value.length; index++) {
    const code: number = value.charCodeAt(index);
    if (code < 0x20 || code >= 0x7f && code <= 0x9f) {
      return true;
    }
  }
  return false;
}

function strictBoundedText(
  value: string,
  maximum: number,
  allowEmpty: boolean = true
): string | null {
  // Numeric XML entities are rejected instead of being left as an alternate
  // spelling for a control character (for example, "&#10;").
  if (hasControlCharacter(value) || /&#(?:[xX][0-9a-fA-F]+|[0-9]+);?/.test(value)) {
    return null;
  }
  const trimmed: string = value.trim();
  if (trimmed.length > maximum || !allowEmpty && trimmed.length === 0) {
    return null;
  }
  return trimmed;
}

function hostTypeFromServerInfo(gfeVersion: string, state: string): MoonlightHostType {
  // Sunshine advertises a compatibility GfeVersion too. Its state value is
  // therefore the stronger discriminator and prevents persisting/UI-labeling
  // a real Sunshine host as legacy GameStream.
  if (state.trim().toUpperCase().startsWith('SUNSHINE_')) {
    return 'sunshine';
  }
  return gfeVersion.trim() !== '' ? 'gamestream' : 'sunshine';
}

function validAddress(address: MoonlightAddress): boolean {
  const host: string | null = strictBoundedText(address.host, MAX_SERVER_NAME_LENGTH, false);
  return host !== null && host === address.host &&
    Number.isSafeInteger(address.port) && address.port >= 1 && address.port <= 65535 &&
    moonlightAddressIsValid(address);
}

/**
 * mDNS hosts without a UUID use their canonical address as the scan-local
 * candidate key. That key identifies the row, but it is not an authoritative
 * server UUID and must not be compared with serverinfo's uniqueid.
 */
export function moonlightVerificationUuidHint(
  address: MoonlightAddress,
  candidateIdentity: string
): string {
  const normalizedIdentity: string | null = strictBoundedText(
    candidateIdentity, MAX_SERVER_UUID_LENGTH);
  if (normalizedIdentity === null || !validAddress(address)) {
    return candidateIdentity;
  }
  const scope: string = address.scope === undefined ? '' : address.scope;
  const scopedHost: string = address.host + (scope === '' ? '' : '%' + scope);
  const host: string = address.family === 'ipv6' ? '[' + scopedHost + ']' : scopedHost;
  const addressFallback: string = host + ':' + address.port.toString();
  return normalizedIdentity === addressFallback ? '' : normalizedIdentity;
}

export function createMoonlightHostOperationFence(
  ownerToken: number,
  generation: number,
  ownerScopeId: string,
  accountGeneration: number,
  serverUuid: string,
  address: MoonlightAddress
): MoonlightHostOperationFence | null {
  const normalizedUuid: string | null = strictBoundedText(
    serverUuid, MAX_SERVER_UUID_LENGTH);
  const normalizedOwnerScopeId: string | null = strictBoundedText(
    ownerScopeId, MAX_SERVER_NAME_LENGTH, false);
  if (!Number.isSafeInteger(ownerToken) || ownerToken <= 0 ||
      !Number.isSafeInteger(generation) || generation <= 0 ||
      normalizedOwnerScopeId === null ||
      !Number.isSafeInteger(accountGeneration) || accountGeneration <= 0 ||
      normalizedUuid === null || !validAddress(address)) {
    return null;
  }
  const fence: MoonlightHostOperationFence = new MoonlightHostOperationFence();
  fence.ownerToken = ownerToken;
  fence.generation = generation;
  fence.ownerScopeId = normalizedOwnerScopeId;
  fence.accountGeneration = accountGeneration;
  fence.serverUuid = normalizedUuid;
  fence.addressHost = address.host;
  fence.addressFamily = address.family;
  fence.addressPort = address.port;
  fence.addressScope = address.scope === undefined ? '' : address.scope;
  return fence;
}

export function cloneMoonlightHostOperationFence(
  source: MoonlightHostOperationFence
): MoonlightHostOperationFence {
  const clone: MoonlightHostOperationFence = new MoonlightHostOperationFence();
  clone.ownerToken = source.ownerToken;
  clone.generation = source.generation;
  clone.ownerScopeId = source.ownerScopeId;
  clone.accountGeneration = source.accountGeneration;
  clone.serverUuid = source.serverUuid;
  clone.addressHost = source.addressHost;
  clone.addressFamily = source.addressFamily;
  clone.addressPort = source.addressPort;
  clone.addressScope = source.addressScope;
  return clone;
}

export function moonlightHostOperationFenceEquals(
  first: MoonlightHostOperationFence | null,
  second: MoonlightHostOperationFence | null
): boolean {
  return first !== null && second !== null &&
    first.ownerToken === second.ownerToken &&
    first.generation === second.generation &&
    first.ownerScopeId === second.ownerScopeId &&
    first.accountGeneration === second.accountGeneration &&
    first.serverUuid === second.serverUuid &&
    first.addressHost === second.addressHost &&
    first.addressFamily === second.addressFamily &&
    first.addressPort === second.addressPort &&
    first.addressScope === second.addressScope;
}

export function moonlightVerificationMatchesFence(
  verification: MoonlightHostAddVerification,
  fence: MoonlightHostOperationFence
): boolean {
  const serverUuid: string | null = strictBoundedText(
    verification.serverUuid, MAX_SERVER_UUID_LENGTH, false);
  return serverUuid !== null &&
    (fence.serverUuid === '' || serverUuid === fence.serverUuid) &&
    verification.address.host === fence.addressHost &&
    verification.address.family === fence.addressFamily &&
    verification.address.port === fence.addressPort &&
    (verification.address.scope === undefined ? '' : verification.address.scope) ===
      fence.addressScope;
}

/** Pure parser kept separate from the network request for bounded policy tests. */
export function parseMoonlightServerInfo(
  body: string,
  address: MoonlightAddress,
  selectedServerUuid: string = ''
): MoonlightHostAddVerification | null {
  if (body.length === 0 || body.length > MAX_RESPONSE_BYTES || body.indexOf('<') < 0 ||
      !validAddress(address)) {
    return null;
  }
  const rootStatus: string | null = strictBoundedText(xmlAttribute(body, 'status_code'), 16);
  if (rootStatus === null || rootStatus !== '' && rootStatus !== '200') {
    return null;
  }
  const advertisedUuid: string | null = strictBoundedText(
    selectedServerUuid, MAX_SERVER_UUID_LENGTH);
  const serverInfoUuid: string | null = strictBoundedText(
    serverInfoValue(body, 'uniqueid'), MAX_SERVER_UUID_LENGTH);
  if (advertisedUuid === null || serverInfoUuid === null ||
      advertisedUuid !== '' && serverInfoUuid !== '' && advertisedUuid !== serverInfoUuid) {
    return null;
  }
  const uniqueId: string = serverInfoUuid !== '' ? serverInfoUuid : advertisedUuid;
  if (uniqueId === '') { return null; }

  const hostname: string | null = strictBoundedText(
    serverInfoValue(body, 'hostname'), MAX_SERVER_NAME_LENGTH);
  const appVersion: string | null = strictBoundedText(
    serverInfoValue(body, 'appversion'), MAX_VERSION_LENGTH);
  const gfeVersion: string | null = strictBoundedText(
    serverInfoValue(body, 'GfeVersion'), MAX_VERSION_LENGTH);
  const state: string | null = strictBoundedText(
    serverInfoValue(body, 'state'), MAX_VERSION_LENGTH);
  // GameStream serverinfo exposes PairStatus. The lowercase "paired" field
  // belongs to pairing-stage responses, but is retained as a compatibility
  // fallback for older/non-standard hosts.
  const pairStatusValue: string = serverInfoValue(body, 'PairStatus');
  const pairedText: string | null = strictBoundedText(
    pairStatusValue !== '' ? pairStatusValue : serverInfoValue(body, 'paired'), 16);
  const httpsPort: number | null = advertisedHttpsPort(body);
  if (hostname === null || appVersion === null || gfeVersion === null ||
      state === null || pairedText === null || httpsPort === null) {
    return null;
  }
  return {
    serverUuid: uniqueId,
    serverName: hostname || address.host,
    hostType: hostTypeFromServerInfo(gfeVersion, state),
    version: appVersion || gfeVersion || state || 'unknown',
    address: {
      host: address.host, family: address.family, port: address.port,
      scope: address.scope
    },
    httpsPort: httpsPort,
    paired: boolAttribute(pairedText),
    // The native pairing result fills this with the exact leaf SHA-256.
    fingerprintSha256: '',
    certificateChanged: false,
    udpVerified: false,
    duplicateHostId: ''
  };
}

export class MoonlightLanProbeService {
  async verify(address: MoonlightAddress,
    selectedServerUuid: string = ''): Promise<MoonlightHostAddVerification | null> {
    if (!validAddress(address) ||
        strictBoundedText(selectedServerUuid, MAX_SERVER_UUID_LENGTH) === null) {
      return null;
    }
    const client: http.HttpRequest = http.createHttp();
    try {
      const requestEndpoint: string = moonlightServerInfoProbeEndpoint(
        address, util.generateRandomUUID());
      if (requestEndpoint === '') {
        return null;
      }
      const response = await client.request(requestEndpoint, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
        usingProxy: false,
        maxRedirects: 0,
        maxLimit: MAX_RESPONSE_BYTES,
        connectTimeout: REQUEST_TIMEOUT_MS,
        readTimeout: REQUEST_TIMEOUT_MS,
        header: { 'Accept': 'application/xml,text/xml' }
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        return null;
      }
      const body: string = typeof response.result === 'string' ? response.result :
        String(response.result);
      return parseMoonlightServerInfo(body, address, selectedServerUuid);
    } catch (_error) {
      return null;
    } finally {
      try { client.destroy(); } catch (_error) {}
    }
  }
}
