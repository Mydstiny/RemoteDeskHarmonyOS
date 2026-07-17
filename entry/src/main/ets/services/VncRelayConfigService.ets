import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { VncRelayConfig, VncRelayJSON } from '../model/VncRelayConfig';

const STORE_NAME: string = 'VncRelayConfigs';
const RELAYS_KEY: string = 'relays';

/** Device-local store until the VNC connection engine and a compatible cloud schema are available. */
export class VncRelayConfigService {
  private static instance: VncRelayConfigService;
  private context: common.Context | null = null;
  private relays: VncRelayConfig[] = [];
  private loaded: boolean = false;
  private listeners: Array<() => void> = [];

  static getInstance(): VncRelayConfigService {
    if (!VncRelayConfigService.instance) { VncRelayConfigService.instance = new VncRelayConfigService(); }
    return VncRelayConfigService.instance;
  }

  init(context: common.Context): void {
    this.context = context;
    if (!this.loaded) { this.load(); }
  }

  onDataChange(callback: () => void): () => void {
    if (this.listeners.indexOf(callback) < 0) { this.listeners.push(callback); }
    return (): void => {
      const index = this.listeners.indexOf(callback);
      if (index >= 0) { this.listeners.splice(index, 1); }
    };
  }

  private emitDataChange(): void {
    const listeners = this.listeners.slice();
    for (let i = 0; i < listeners.length; i++) {
      try { listeners[i](); } catch (_err) { /* keep remaining listeners live */ }
    }
  }

  private load(): void {
    this.loaded = true;
    if (!this.context) { return; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: STORE_NAME });
      const raw = prefs.getSync(RELAYS_KEY, '') as string;
      if (raw.length === 0) { return; }
      const rows = JSON.parse(raw) as VncRelayJSON[];
      if (!Array.isArray(rows)) { return; }
      this.relays = rows.map((row: VncRelayJSON): VncRelayConfig => VncRelayConfig.fromJSON(row));
    } catch (_err) {
      this.relays = [];
    }
  }

  private persist(): void {
    if (!this.context) { return; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: STORE_NAME });
      prefs.putSync(RELAYS_KEY, JSON.stringify(this.relays.map((relay: VncRelayConfig): VncRelayJSON => relay.toJSON())));
      prefs.flushSync();
    } catch (_err) { /* retain the in-memory copy */ }
  }

  getAll(): VncRelayConfig[] {
    return this.relays.map((relay: VncRelayConfig): VncRelayConfig => VncRelayConfig.fromJSON(relay.toJSON()));
  }

  save(relay: VncRelayConfig): void {
    const copy = VncRelayConfig.fromJSON(relay.toJSON());
    const index = this.relays.findIndex((item: VncRelayConfig): boolean => item.id === copy.id);
    if (index >= 0) { this.relays[index] = copy; } else { this.relays.push(copy); }
    this.persist();
    this.emitDataChange();
  }

  remove(id: string): void {
    this.relays = this.relays.filter((relay: VncRelayConfig): boolean => relay.id !== id);
    this.persist();
    this.emitDataChange();
  }
}
