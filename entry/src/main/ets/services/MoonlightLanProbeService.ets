/**
 * Bounded Sunshine/GameStream serverinfo probe used by the local add flow.
 * It deliberately performs no persistence and never treats an HTTP response
 * as certificate trust; pairing is the native mTLS boundary that follows it.
 */
import { http } from '@kit.NetworkKit';
import { MoonlightAddress, MoonlightHostType } from '../model/MoonlightModels';
import {
  MoonlightHostAddVerification,
  MOONLIGHT_DEFAULT_CONTROL_PORT
} from './MoonlightHostAddFlowPolicy';

const REQUEST_TIMEOUT_MS: number = 3500;
const MAX_RESPONSE_BYTES: number = 128 * 1024;

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
    .replace(/&amp;/g, '&').trim();
}

function serverInfoValue(xml: string, name: string): string {
  const element: string = xmlElement(xml, name);
  return element === '' ? xmlAttribute(xml, name) : element;
}

function boolAttribute(value: string): boolean {
  return value === '1' || value.toLowerCase() === 'true' || value.toLowerCase() === 'yes';
}

function boundedText(value: string, maximum: number): string {
  const trimmed: string = value.trim();
  return trimmed.length > maximum ? trimmed.substring(0, maximum) : trimmed;
}

function hostTypeFromServerInfo(gfeVersion: string): MoonlightHostType {
  return gfeVersion.trim() !== '' ? 'gamestream' : 'sunshine';
}

export class MoonlightLanProbeService {
  async verify(address: MoonlightAddress,
    selectedServerUuid: string = ''): Promise<MoonlightHostAddVerification | null> {
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
      if (body.length === 0 || body.length > MAX_RESPONSE_BYTES ||
          body.indexOf('<') < 0) {
        return null;
      }
      const rootStatus: string = xmlAttribute(body, 'status_code');
      if (rootStatus !== '' && rootStatus !== '200') { return null; }
      const uniqueId: string = boundedText(serverInfoValue(body, 'uniqueid'), 256) ||
        boundedText(selectedServerUuid, 256);
      if (uniqueId === '') { return null; }
      const hostname: string = boundedText(serverInfoValue(body, 'hostname'), 256);
      const appVersion: string = boundedText(serverInfoValue(body, 'appversion'), 128);
      const gfeVersion: string = boundedText(serverInfoValue(body, 'GfeVersion'), 128);
      const state: string = boundedText(serverInfoValue(body, 'state'), 128);
      const paired: boolean = boolAttribute(serverInfoValue(body, 'paired'));
      const serverName: string = hostname || address.host;
      return {
        serverUuid: uniqueId,
        serverName: serverName,
        hostType: hostTypeFromServerInfo(gfeVersion),
        version: appVersion || gfeVersion || state || 'unknown',
        address: { host: address.host, family: address.family, port: address.port },
        paired: paired,
        // The native pairing result fills this with the exact leaf SHA-256.
        fingerprintSha256: '',
        certificateChanged: false,
        udpVerified: false,
        duplicateHostId: ''
      };
    } catch (_error) {
      return null;
    } finally {
      try { client.destroy(); } catch (_error) {}
    }
  }
}
