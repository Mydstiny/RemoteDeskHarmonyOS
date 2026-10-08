import rdpnapi, { AiTlsRequestOptions, AiTlsResponse, AiGeneratedIdentity } from 'librdpnapi.so';
import { util } from '@kit.ArkTS';
import { connection } from '@kit.NetworkKit';
import { parseEndpointHost } from '../EndpointAddressPolicy';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { AiHost, AiIdentity, AiEvent } from './AiModels';
import { AiEventDecoder, aiRecord, aiString } from './AiWirePolicy';

export function aiRandomId(): string {
  const data = cryptoFramework.createRandom().generateRandomSync(24).data;
  let id = '';
  for (const byte of data) { id += byte.toString(16).padStart(2, '0'); }
  return id;
}
export interface AiTransportPort {
  post(path: string, body: string): Promise<Record<string, Object>>;
  events(cursor: number, runtime: string, onEvent: (event: AiEvent) => void): Promise<void>;
  close(): void;
}
/** Native owns CA-only trust, SAN, TLS1.3 and HTTP framing on the same socket. */
export class AiTransport implements AiTransportPort {
  private static pending: Map<string, Promise<void>> = new Map();
  private static cancels: Map<string, () => void> = new Map();
  private requests: Set<string> = new Set();
  private closed: boolean = false;
  private streamId: string = '';
  private host: AiHost;
  private identity: AiIdentity | null;
  constructor(host: AiHost, identity: AiIdentity) {
    this.host = JSON.parse(JSON.stringify(host)) as AiHost;
    this.identity = JSON.parse(JSON.stringify(identity)) as AiIdentity;
  }
  static async generateIdentity(): Promise<AiGeneratedIdentity> {
    const id = aiRandomId();
    const operation = rdpnapi.aiGenerateIdentity({ id });
    AiTransport.pending.set(id, operation.then((): void => {}, (): void => {}));
    AiTransport.cancels.set(id, (): void => { rdpnapi.aiCancelRequest({ id }); });
    try { return await operation; } finally { AiTransport.pending.delete(id); AiTransport.cancels.delete(id); }
  }
  static cancelAll(): void {
    Array.from(AiTransport.cancels.values()).forEach((cancel: () => void): void => cancel());
  }
  static async drain(timeoutMs: number = 10000): Promise<boolean> {
    AiTransport.cancelAll();
    let timer: number = -1;
    const complete = Promise.all(Array.from(AiTransport.pending.values())).then((): boolean => true);
    const timeout = new Promise<boolean>((resolve): void => { timer = setTimeout((): void => resolve(false), timeoutMs); });
    try { return await Promise.race([complete, timeout]); }
    finally { if (timer !== -1) { clearTimeout(timer); } }
  }
  close(): void {
    this.closed = true;
    this.identity = null;
    this.requests.forEach((id: string): void => { AiTransport.cancels.get(id)?.(); });
  }
  stopEvents(): void {
    if (this.streamId !== '') { const id = this.streamId; this.streamId = ''; AiTransport.cancels.get(id)?.(); }
  }
  private options(path: string, body: string): AiTlsRequestOptions {
    if (this.closed || this.identity === null) { throw new Error('AI_CONNECTION_CLOSED'); }
    if (this.host.transport !== 'lan') { throw new Error('AI_TRANSPORT_UNAVAILABLE'); }
    return { id: aiRandomId(), address: this.host.address, serverName: this.host.serverName || this.host.address,
      port: this.host.port, ca: this.identity.ca, certificate: this.identity.certificate,
      privateKey: this.identity.privateKey, path, body, timeoutMs: 45000 };
  }
  private async resolveAddresses(address: string): Promise<string[]> {
    const parsed = parseEndpointHost(address, 'runtime');
    if (!parsed.ok) { throw new Error('AI_ENDPOINT_INVALID'); }
    if (parsed.endpoint.family !== 'hostname') { return [address]; }
    let timer: number = -1;
    const expired = new Promise<connection.NetAddress[]>((_resolve, reject): void => {
      timer = setTimeout((): void => { reject(new Error('AI_DNS_TIMEOUT')); }, 10000);
    });
    try {
      const addresses = await Promise.race([connection.getAddressesByName(address), expired]);
      if (this.closed) { throw new Error('AI_CONNECTION_CLOSED'); }
      const results: string[] = [];
      for (const item of addresses) {
        const check = parseEndpointHost(item.address, 'runtime');
        if (check.ok && check.endpoint.family !== 'hostname' && !results.includes(item.address)) {
          results.push(item.address);
        }
        if (results.length >= 8) { break; }
      }
      if (results.length === 0) { throw new Error('AI_HOST_NOT_FOUND'); }
      return results;
    } finally { if (timer !== -1) { clearTimeout(timer); } }
  }
  private async request(options: AiTlsRequestOptions,
    onChunk?: (data: ArrayBuffer) => void): Promise<AiTlsResponse> {
    if (this.closed) { throw new Error('AI_CONNECTION_CLOSED'); }
    this.requests.add(options.id);
    let cancelled = false;
    let rejectCancelled: (reason: Error) => void = (_reason: Error): void => {};
    const cancelSignal = new Promise<string[]>((_resolve, reject): void => { rejectCancelled = reject; });
    AiTransport.cancels.set(options.id, (): void => {
      cancelled = true; rejectCancelled(new Error('AI_REQUEST_CANCELLED'));
      rdpnapi.aiCancelRequest({ id: options.id });
    });
    const operation = (async (): Promise<AiTlsResponse> => {
      const addresses = await Promise.race([this.resolveAddresses(options.address), cancelSignal]);
      for (let index = 0; index < addresses.length; index++) {
        if (this.closed || cancelled || (options.path.startsWith('/v1/events?') && this.streamId !== options.id)) {
          throw new Error('AI_REQUEST_CANCELLED');
        }
        options.address = addresses[index];
        try { return await rdpnapi.aiTlsRequest(options, onChunk); }
        catch (error) {
          // Only pre-connect failures can try another address. A timeout or
          // post-handshake failure never replays a possibly dispatched write.
          const code = (error as Error).message;
          if (index + 1 >= addresses.length || !['AI_CONNECTION_FAILED', 'AI_HOST_NOT_FOUND'].includes(code)) {
            throw new Error(code);
          }
        }
      }
      throw new Error('AI_HOST_NOT_FOUND');
    })();
    AiTransport.pending.set(options.id, operation.then((): void => {}, (): void => {}));
    try {
      const response = await operation;
      if (this.closed || cancelled) { throw new Error('AI_REQUEST_CANCELLED'); }
      return response;
    } finally {
      options.privateKey = '';
      this.requests.delete(options.id); AiTransport.pending.delete(options.id); AiTransport.cancels.delete(options.id);
    }
  }
  /**
   * A compact invite's trust step: native takes the CA from the server's chain only when its SHA-256 is the
   * invite's and the server certificate verifies against it for this address. Nothing is sent to the server.
   */
  async trustedCa(caSha256: string): Promise<string> {
    const options = this.options('/v1/ca', '');
    options.ca = ''; options.certificate = ''; options.privateKey = ''; options.caSha256 = caSha256;
    const response = await this.request(options);
    const pem = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(new Uint8Array(response.body));
    if (response.status !== 200 || !pem.includes('-----BEGIN CERTIFICATE-----')) { throw new Error('AI_CA_INVALID'); }
    return pem;
  }
  async post(path: string, body: string): Promise<Record<string, Object>> {
    const response = await this.request(this.options(path, body));
    const text = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(new Uint8Array(response.body));
    const raw = aiRecord(JSON.parse(text));
    if (response.status !== 200 || typeof raw['error'] === 'string') {
      throw new Error(aiString(raw['error'], 'AI_HTTP_FAILURE'));
    }
    return raw;
  }
  async events(cursor: number, runtime: string, onEvent: (event: AiEvent) => void): Promise<void> {
    this.stopEvents();
    const options = this.options('/v1/events?cursor=' + cursor.toString() + '&runtime=' + encodeURIComponent(runtime), '');
    this.streamId = options.id;
    const decoder = util.TextDecoder.create('utf-8', { fatal: true });
    const parser = new AiEventDecoder(onEvent);
    let failure = '';
    try {
      const response = await this.request(options, (bytes: ArrayBuffer): void => {
        if (this.closed || this.streamId !== options.id || failure !== '') { return; }
        try { parser.feed(decoder.decodeToString(new Uint8Array(bytes), { stream: true })); }
        catch (_error) { failure = 'AI_STREAM_INVALID'; rdpnapi.aiCancelRequest({ id: options.id }); }
      });
      if (failure !== '') { throw new Error(failure); }
      if (response.status !== 200) {
        const raw = aiRecord(JSON.parse(decoder.decodeToString(new Uint8Array(response.body))));
        throw new Error(aiString(raw['error'], 'AI_STREAM_FAILED'));
      }
    } finally { if (this.streamId === options.id) { this.streamId = ''; } }
  }
}
