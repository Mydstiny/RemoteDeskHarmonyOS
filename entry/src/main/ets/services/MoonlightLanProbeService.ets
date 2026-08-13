/**
 * Bounded Sunshine/GameStream serverinfo probe used by the local add flow.
 * It deliberately performs no persistence and never treats an HTTP response
 * as certificate trust; pairing is the native mTLS boundary that follows it.
 */
import { http } from '@kit.NetworkKit';
import {
  MoonlightAddress,
  MoonlightAddressFamily,
  MoonlightHostType
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

/** Exact owner/operation-generation/candidate identity used by HostList writes. */
export class MoonlightHostOperationFence {
  ownerToken: number = 0;
  generation: number = 0;
  serverUuid: string = '';
  addressHost: string = '';
  addressFamily: MoonlightAddressFamily = 'hostname';
  addressPort: number = 0;
}

function endpoint(address: MoonlightAddress): string {
  const host: string = address.family === 'ipv6' ? '[' + address.host + ']' : address.host;
  const port: number = address.port > 0 ? address.port : MOONLIGHT_DEFAULT_CONTROL_PORT;
  return 'http://' + host + ':' + port.toString() + '/serverinfo';
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

function hostTypeFromServerInfo(gfeVersion: string): MoonlightHostType {
  return gfeVersion.trim() !== '' ? 'gamestream' : 'sunshine';
}

function validAddress(address: MoonlightAddress): boolean {
  const host: string | null = strictBoundedText(address.host, MAX_SERVER_NAME_LENGTH, false);
  return host !== null && host === address.host &&
    Number.isSafeInteger(address.port) && address.port >= 1 && address.port <= 65535;
}

export function createMoonlightHostOperationFence(
  ownerToken: number,
  generation: number,
  serverUuid: string,
  address: MoonlightAddress
): MoonlightHostOperationFence | null {
  const normalizedUuid: string | null = strictBoundedText(
    serverUuid, MAX_SERVER_UUID_LENGTH);
  if (!Number.isSafeInteger(ownerToken) || ownerToken <= 0 ||
      !Number.isSafeInteger(generation) || generation <= 0 ||
      normalizedUuid === null || !validAddress(address)) {
    return null;
  }
  const fence: MoonlightHostOperationFence = new MoonlightHostOperationFence();
  fence.ownerToken = ownerToken;
  fence.generation = generation;
  fence.serverUuid = normalizedUuid;
  fence.addressHost = address.host;
  fence.addressFamily = address.family;
  fence.addressPort = address.port;
  return fence;
}

export function cloneMoonlightHostOperationFence(
  source: MoonlightHostOperationFence
): MoonlightHostOperationFence {
  const clone: MoonlightHostOperationFence = new MoonlightHostOperationFence();
  clone.ownerToken = source.ownerToken;
  clone.generation = source.generation;
  clone.serverUuid = source.serverUuid;
  clone.addressHost = source.addressHost;
  clone.addressFamily = source.addressFamily;
  clone.addressPort = source.addressPort;
  return clone;
}

export function moonlightHostOperationFenceEquals(
  first: MoonlightHostOperationFence | null,
  second: MoonlightHostOperationFence | null
): boolean {
  return first !== null && second !== null &&
    first.ownerToken === second.ownerToken &&
    first.generation === second.generation &&
    first.serverUuid === second.serverUuid &&
    first.addressHost === second.addressHost &&
    first.addressFamily === second.addressFamily &&
    first.addressPort === second.addressPort;
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
    verification.address.port === fence.addressPort;
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
  const pairedText: string | null = strictBoundedText(serverInfoValue(body, 'paired'), 16);
  if (hostname === null || appVersion === null || gfeVersion === null ||
      state === null || pairedText === null) {
    return null;
  }
  return {
    serverUuid: uniqueId,
    serverName: hostname || address.host,
    hostType: hostTypeFromServerInfo(gfeVersion),
    version: appVersion || gfeVersion || state || 'unknown',
    address: { host: address.host, family: address.family, port: address.port },
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
      const response = await client.request(endpoint(address), {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        usingCache: false,
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
