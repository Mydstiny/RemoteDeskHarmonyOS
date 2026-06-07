import { BusinessError } from '@kit.BasicServicesKit';
import {
  RemoteHost,
  SessionQuality,
  KeyboardMode,
  GatewayConfig,
  DisplayConfig,
  RedirectionConfig,
  createDefaultRemoteHost
} from '../models/RemoteHost';

export class HostSyncService {
  private static instance: HostSyncService;
  private hosts: Map<string, RemoteHost> = new Map();
  private cloudAvailable: boolean = false;

  static getInstance(): HostSyncService {
    if (!this.instance) {
      this.instance = new HostSyncService();
    }
    return this.instance;
  }

  async loadFromCloud(userId: string): Promise<RemoteHost[]> {
    try {
      const { clouddb } = await import('@hms.clouddb');
      const zone = clouddb.ZoneFactory.getZone('RemoteHost');
      const query = new clouddb.Query().equalTo('userId', userId);
      const snapshot = await zone.query(query);
      const results: RemoteHost[] = [];
      for (const row of snapshot.getRows()) {
        results.push(this.rowToHost(row));
      }
      this.cloudAvailable = true;
      console.info('HostSyncService loaded ' + results.length + ' hosts from cloud');
      return results;
    } catch (err) {
      this.cloudAvailable = false;
      console.warn('Cloud DB unavailable, loading from local cache');
      return this.loadFromLocal();
    }
  }

  async saveToCloud(host: RemoteHost): Promise<void> {
    this.hosts.set(host.id, host);
    if (!this.cloudAvailable) {
      this.saveToLocal(host);
      return;
    }
    try {
      const { clouddb } = await import('@hms.clouddb');
      const zone = clouddb.ZoneFactory.getZone('RemoteHost');
      const existing = await zone.query(
        new clouddb.Query().equalTo('id', host.id)
      );
      if (existing.getRows().length > 0) {
        const row = existing.getRows()[0];
        const serverVersion = row.getValue('syncVersion') ?? 0;
        if (host.syncVersion < serverVersion) {
          console.warn('Conflict detected, server version: ' + serverVersion
            + ', local version: ' + host.syncVersion);
          host.syncVersion = serverVersion;
        }
        host.syncVersion++;
        this.hostToRow(host, row);
        await zone.update(row);
      } else {
        host.syncVersion = 1;
        const row = zone.createRow();
        this.hostToRow(host, row);
        await zone.insert(row);
      }
      console.info('HostSyncService saved host: ' + host.label);
    } catch (err) {
      console.error('Failed to save to cloud: ' + err);
      this.saveToLocal(host);
    }
  }

  async deleteFromCloud(hostId: string): Promise<void> {
    this.hosts.delete(hostId);
    if (!this.cloudAvailable) {
      this.deleteFromLocal(hostId);
      return;
    }
    try {
      const { clouddb } = await import('@hms.clouddb');
      const zone = clouddb.ZoneFactory.getZone('RemoteHost');
      const existing = await zone.query(
        new clouddb.Query().equalTo('id', hostId)
      );
      if (existing.getRows().length > 0) {
        await zone.delete(existing.getRows()[0]);
      }
      console.info('HostSyncService deleted host: ' + hostId);
    } catch (err) {
      console.error('Failed to delete from cloud: ' + err);
      this.deleteFromLocal(hostId);
    }
  }

  async importFromJson(jsonData: string): Promise<RemoteHost[]> {
    try {
      const parsed = JSON.parse(jsonData);
      const hosts: RemoteHost[] = Array.isArray(parsed) ? parsed : parsed.hosts ?? [];
      const imported: RemoteHost[] = [];
      for (const item of hosts) {
        const host = this.normalizeImportedHost(item);
        await this.saveToCloud(host);
        imported.push(host);
      }
      console.info('HostSyncService imported ' + imported.length + ' hosts');
      return imported;
    } catch (err) {
      console.error('HostSyncService import failed: ' + err);
      return [];
    }
  }

  async exportToJson(hosts: RemoteHost[]): Promise<string> {
    const exportData = {
      version: 1,
      exportedAt: Date.now(),
      hosts: hosts.map((h) => this.sanitizeForExport(h))
    };
    return JSON.stringify(exportData, null, 2);
  }

  private sanitizeForExport(host: RemoteHost): Record<string, Object> {
    const safe: Record<string, Object> = {};
    for (const key of Object.keys(host)) {
      if (key === 'password') {
        safe[key] = '';
        continue;
      }
      safe[key] = (host as Record<string, Object>)[key];
    }
    return safe;
  }

  private normalizeImportedHost(item: Record<string, Object>): RemoteHost {
    const host = createDefaultRemoteHost(String(item.userId ?? ''));
    for (const key of Object.keys(host)) {
      if (key in item) {
        (host as Record<string, Object>)[key] = item[key];
      }
    }
    if (!host.id || host.id.length === 0) {
      host.id = 'import_' + Date.now() + '_' + Math.random().toString(36).slice(2, 8);
    }
    return host;
  }

  private rowToHost(row: Record<string, Object>): RemoteHost {
    return {
      id: String(row.getValue('id') ?? ''),
      userId: String(row.getValue('userId') ?? ''),
      label: String(row.getValue('label') ?? ''),
      protocol: String(row.getValue('protocol') ?? 'rdp'),
      host: String(row.getValue('host') ?? ''),
      port: Number(row.getValue('port') ?? 3389),
      username: String(row.getValue('username') ?? ''),
      password: String(row.getValue('password') ?? ''),
      locked: Boolean(row.getValue('locked') ?? false),
      lockType: String(row.getValue('lockType') ?? 'none'),
      syncVersion: Number(row.getValue('syncVersion') ?? 0),
      gateway: this.parseGateway(row.getValue('gateway')),
      sessionQuality: String(row.getValue('sessionQuality') ?? SessionQuality.AUTO) as SessionQuality,
      displayConfig: this.parseDisplayConfig(row.getValue('displayConfig')),
      redirection: this.parseRedirection(row.getValue('redirection')),
      keyboardMode: String(row.getValue('keyboardMode') ?? KeyboardMode.GENERIC) as KeyboardMode,
      thumbnail: String(row.getValue('thumbnail') ?? ''),
      lastConnected: Number(row.getValue('lastConnected') ?? 0),
      tags: this.parseJsonArray(row.getValue('tags')),
      workspaceId: String(row.getValue('workspaceId') ?? '')
    };
  }

  private hostToRow(host: RemoteHost, row: Record<string, Object>): void {
    const fields: Record<string, Object> = {
      id: host.id,
      userId: host.userId,
      label: host.label,
      protocol: host.protocol,
      host: host.host,
      port: host.port,
      username: host.username,
      password: host.password,
      locked: host.locked,
      lockType: host.lockType,
      syncVersion: host.syncVersion,
      gateway: host.gateway ? JSON.stringify(host.gateway) : '',
      sessionQuality: host.sessionQuality,
      displayConfig: JSON.stringify(host.displayConfig),
      redirection: JSON.stringify(host.redirection),
      keyboardMode: host.keyboardMode,
      thumbnail: host.thumbnail,
      lastConnected: host.lastConnected,
      tags: JSON.stringify(host.tags),
      workspaceId: host.workspaceId
    };
    for (const [key, value] of Object.entries(fields)) {
      row.setValue(key, value);
    }
  }

  private parseGateway(val: Object): GatewayConfig | null {
    if (!val || String(val).length === 0) return null;
    try {
      return JSON.parse(String(val)) as GatewayConfig;
    } catch {
      return null;
    }
  }

  private parseDisplayConfig(val: Object): DisplayConfig {
    if (!val || String(val).length === 0) {
      return { width: 1920, height: 1080, useAllMonitors: false, colorDepth: 32 };
    }
    try {
      return JSON.parse(String(val)) as DisplayConfig;
    } catch {
      return { width: 1920, height: 1080, useAllMonitors: false, colorDepth: 32 };
    }
  }

  private parseRedirection(val: Object): RedirectionConfig {
    if (!val || String(val).length === 0) {
      return {
        clipboard: true, printer: false, microphone: false,
        camera: false, folder: false, folderPath: '', smartcard: false
      };
    }
    try {
      return JSON.parse(String(val)) as RedirectionConfig;
    } catch {
      return {
        clipboard: true, printer: false, microphone: false,
        camera: false, folder: false, folderPath: '', smartcard: false
      };
    }
  }

  private parseJsonArray(val: Object): string[] {
    if (!val || String(val).length === 0) return [];
    try {
      const parsed = JSON.parse(String(val));
      return Array.isArray(parsed) ? parsed.map(String) : [];
    } catch {
      return [];
    }
  }

  private async loadFromLocal(): Promise<RemoteHost[]> {
    try {
      const storage = await import('@kit.PreferencesKit');
      const prefs = await storage.getPreferences(getContext(), 'hosts_cache');
      const json = prefs.get('hosts', '[]');
      const hosts: RemoteHost[] = JSON.parse(json);
      console.info('HostSyncService loaded ' + hosts.length + ' hosts from local');
      return hosts;
    } catch (err) {
      console.error('Failed to load local hosts: ' + err);
      return [];
    }
  }

  private async saveToLocal(host: RemoteHost): Promise<void> {
    try {
      const storage = await import('@kit.PreferencesKit');
      const prefs = await storage.getPreferences(getContext(), 'hosts_cache');
      const json = prefs.get('hosts', '[]');
      const hosts: RemoteHost[] = JSON.parse(json);
      const idx = hosts.findIndex((h) => h.id === host.id);
      if (idx >= 0) {
        hosts[idx] = host;
      } else {
        hosts.push(host);
      }
      await prefs.put('hosts', JSON.stringify(hosts));
      await prefs.flush();
    } catch (err) {
      console.error('Failed to save local hosts: ' + err);
    }
  }

  private async deleteFromLocal(hostId: string): Promise<void> {
    try {
      const storage = await import('@kit.PreferencesKit');
      const prefs = await storage.getPreferences(getContext(), 'hosts_cache');
      const json = prefs.get('hosts', '[]');
      const hosts: RemoteHost[] = JSON.parse(json);
      const filtered = hosts.filter((h) => h.id !== hostId);
      await prefs.put('hosts', JSON.stringify(filtered));
      await prefs.flush();
    } catch (err) {
      console.error('Failed to delete local host: ' + err);
    }
  }

  isCloudAvailable(): boolean {
    return this.cloudAvailable;
  }
}
