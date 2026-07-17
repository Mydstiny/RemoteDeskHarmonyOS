import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export interface VncRelayJSON {
  id: string
  name: string
  host: string
  port: number
  targetId: string
  createdAt: number
  updatedAt: number
}

/** Local UltraVNC Repeater configuration, kept separate from RustDesk cloud records. */
export class VncRelayConfig {
  id: string = '';
  name: string = '';
  host: string = '';
  port: number = 5901;
  targetId: string = '';
  createdAt: number = Date.now();
  updatedAt: number = 0;

  displayName(): string {
    return this.name.trim().length > 0 ? this.name.trim() : this.host;
  }

  toJSON(): VncRelayJSON {
    return {
      id: this.id,
      name: this.name,
      host: this.host,
      port: this.port,
      targetId: this.targetId,
      createdAt: this.createdAt,
      updatedAt: this.updatedAt
    };
  }

  static fromJSON(json: VncRelayJSON): VncRelayConfig {
    const relay = new VncRelayConfig();
    if (json.id) { relay.id = json.id; }
    if (json.name) { relay.name = json.name; }
    if (json.host) { relay.host = json.host; }
    if (json.port) { relay.port = json.port; }
    if (json.targetId) { relay.targetId = json.targetId; }
    if (json.createdAt) { relay.createdAt = json.createdAt; }
    if (json.updatedAt) { relay.updatedAt = json.updatedAt; }
    return relay;
  }

  static generateId(): string {
    const random = cryptoFramework.createRandom().generateRandomSync(6).data;
    const bytes = new Uint8Array(random);
    let hex: string = '';
    for (let i = 0; i < bytes.length; i++) { hex += bytes[i].toString(16).padStart(2, '0'); }
    return 'vncrelay_' + Date.now().toString(36) + '_' + hex;
  }
}
