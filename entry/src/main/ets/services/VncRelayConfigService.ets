import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { VncRelayConfig, VncRelayJSON } from '../model/VncRelayConfig';
import { VncGatewayService } from './VncGatewayService';
import { VncGatewayValues } from './VncModelPolicy';

const STORE_NAME: string = 'VncRelayConfigs';
const RELAYS_KEY: string = 'relays';

/**
 * Compatibility facade for the pre-v2 VNC repeater Preferences store.
 *
 * The old store is migration input only. New VNC code must use
 * VncGatewayService and the single vncrecord table; this class intentionally
 * exposes no mutable relay collection after migration.
 */
export class VncRelayConfigService {
  private static instance: VncRelayConfigService;
  private context: common.Context | null = null;
  private migrated: boolean = false;
  private listeners: Array<() => void> = [];

  static getInstance(): VncRelayConfigService {
    if (!VncRelayConfigService.instance) { VncRelayConfigService.instance = new VncRelayConfigService(); }
    return VncRelayConfigService.instance;
  }

  init(context: common.Context): void {
    this.context = context;
    if (!this.migrated) { this.migrateOnce(); }
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

  private readLegacy(): VncRelayConfig[] {
    const result: VncRelayConfig[] = [];
    if (!this.context) { return result; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: STORE_NAME });
      const raw = prefs.getSync(RELAYS_KEY, '') as string;
      if (raw.length === 0) { return result; }
      const rows = JSON.parse(raw) as VncRelayJSON[];
      if (!Array.isArray(rows)) { return result; }
      for (let i = 0; i < rows.length; i++) {
        result.push(VncRelayConfig.fromJSON(rows[i]));
      }
    } catch (_err) {
      return [];
    }
    return result;
  }

  private migrateOnce(): void {
    this.migrated = true;
    const legacy: VncRelayConfig[] = this.readLegacy();
    if (legacy.length === 0 || !this.context) { return; }
    const gateways = VncGatewayService.getInstance();
    gateways.init(this.context);
    let migratedCount: number = 0;
    for (let i = 0; i < legacy.length; i++) {
      const relay: VncRelayConfig = legacy[i];
      const values: VncGatewayValues = {
        label: relay.displayName(),
        transport: 'ultravnc_repeater',
        host: relay.host,
        port: relay.port,
        path: '/vnc',
        repeaterMode: 'mode12',
        targetId: relay.targetId,
        tls: false,
        enabled: true
      };
      const result = gateways.save(values, relay.id);
      if (result.ok) { migratedCount += 1; }
    }
    if (migratedCount === legacy.length) {
      try {
        const prefs = preferences.getPreferencesSync(this.context, { name: STORE_NAME });
        prefs.deleteSync(RELAYS_KEY);
        prefs.putSync('migrationVersion', 1);
        prefs.flushSync();
      } catch (_err) {
        // Leave input intact when clearing the old store fails. The gateway
        // owner remains the canonical copy and the next init is idempotent.
      }
    }
    this.emitDataChange();
  }

  /** Legacy callers receive an immutable snapshot only; no new writes. */
  getAll(): VncRelayConfig[] {
    return [];
  }

  save(_relay: VncRelayConfig): void {
    throw new Error('VNC relay Preferences 已迁移，请使用 VncGatewayService');
  }

  remove(_id: string): void {
    throw new Error('VNC relay Preferences 已迁移，请使用 VncGatewayService');
  }

  /** Kept for old callers that only used the service as a lifecycle signal. */
  private persist(): void {
    if (!this.context) { return; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: STORE_NAME });
      prefs.flushSync();
    } catch (_err) { /* retain the in-memory copy */ }
  }
}
