/**
 * KeyVaultService.ets — 密钥保险库服务 (CloudStore RDB + 端云自动同步)
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SshKey } from '../model/SshKey';
import { TotpEntry } from '../model/TotpEntry';
import { CloudStore } from './CloudStore';
import { shouldPublishSnapshot } from './DataSnapshotRevisionPolicy';

export interface TotpBatchAddResult {
  savedIds: string[]
  failedCount: number
}

export class KeyVaultService {
  private static instance: KeyVaultService;
  private sshKeys: Map<string, SshKey> = new Map();
  private totpEntries: Map<string, TotpEntry> = new Map();
  private cloud: CloudStore = CloudStore.getInstance();
  private ready: boolean = false;
  private initPromise: Promise<void> | null = null;
  private dataChangeListeners: Array<() => void> = [];
  private localSshKeyObservationAt: Map<string, number> = new Map();
  private localTotpObservationAt: Map<string, number> = new Map();
  private deletedSshKeyAt: Map<string, number> = new Map();
  private deletedTotpAt: Map<string, number> = new Map();
  private lastCloudSnapshotLoadedAt: number = 0;
  private lastPublishedSnapshotSignature: string = '';
  private hasPublishedSnapshot: boolean = false;

  static getInstance(): KeyVaultService {
    if (!KeyVaultService.instance) {
      KeyVaultService.instance = new KeyVaultService();
    }
    return KeyVaultService.instance;
  }

  /** 初始化: 从 CloudStore RDB 恢复数据 */
  async init(context: common.Context): Promise<void> {
    if (this.ready) { return; }
    if (this.initPromise) {
      await this.initPromise;
      return;
    }
    this.initPromise = this.doInit(context);
    await this.initPromise;
  }

  private async doInit(context: common.Context): Promise<void> {
    try {
      await this.cloud.init(context);
      this.cloud.onCloudChange(() => { this.loadFromCloud(); });
      this.cloud.onCryptoReset(() => {
        this.sshKeys.clear();
        this.totpEntries.clear();
        this.localSshKeyObservationAt.clear();
        this.localTotpObservationAt.clear();
        this.deletedSshKeyAt.clear();
        this.deletedTotpAt.clear();
        this.lastCloudSnapshotLoadedAt = 0;
        this.emitDataChange();
        hilog.info(0x0001, 'CloudSync', 'KeyVaultService: 收到加密重置通知, 内存数据已清空');
      });
      this.ready = true;
      // 先恢复本地持久化缓存；云服务关闭/失败时也不能把 UI 变成空列表。
      this.loadFromCloud();
    } catch (err) {
      this.initPromise = null;
      hilog.error(0x0001, 'CloudSync', "KeyVaultService init 失败: " + JSON.stringify(err));
    }
  }

  private loadFromCloud(): void {
    if (!this.cloud.isReady()) { return; }
    try {
      const previousSnapshotAt: number = this.lastCloudSnapshotLoadedAt;
      const previousKeys: Map<string, SshKey> = new Map();
      this.sshKeys.forEach((key: SshKey, keyId: string): void => { previousKeys.set(keyId, key); });
      const keys: SshKey[] = this.cloud.loadAllSshKeys();
      hilog.info(0x0001, 'CloudSync', "loadFromCloud: SSH密钥=" + keys.length.toString() + "条");
      this.sshKeys.clear();
      const loadedKeyIds: Set<string> = new Set<string>();
      let normalized: boolean = false;
      for (let i = 0; i < keys.length; i++) {
        const cloudKey: SshKey = keys[i];
        const deletedAt: number = this.deletedSshKeyAt.get(cloudKey.id) ?? 0;
        if (deletedAt > previousSnapshotAt) { continue; }
        const localKey: SshKey | undefined = previousKeys.get(cloudKey.id);
        const observedAt: number = this.localSshKeyObservationAt.get(cloudKey.id) ?? 0;
        const next: SshKey = localKey !== undefined && observedAt > previousSnapshotAt
          ? SshKey.fromJSON(localKey.toJSON()) : cloudKey;
        const beforeVersion: number = next.formatVersion;
        next.normalizeFormatMetadata();
        this.sshKeys.set(next.id, next);
        loadedKeyIds.add(next.id);
        if (beforeVersion !== next.formatVersion && this.ready) {
          if (this.cloud.updateSshKey(next)) { normalized = true; }
        }
      }
      previousKeys.forEach((key: SshKey, keyId: string): void => {
        const observedAt: number = this.localSshKeyObservationAt.get(keyId) ?? 0;
        const deletedAt: number = this.deletedSshKeyAt.get(keyId) ?? 0;
        if (!loadedKeyIds.has(keyId) && observedAt > previousSnapshotAt && deletedAt <= previousSnapshotAt) {
          this.sshKeys.set(keyId, SshKey.fromJSON(key.toJSON()));
        }
      });
      if (normalized) { this.cloud.pushTable('sshkeys'); }

      const previousEntries: Map<string, TotpEntry> = new Map();
      this.totpEntries.forEach((entry: TotpEntry, entryId: string): void => {
        previousEntries.set(entryId, entry);
      });
      const entries: TotpEntry[] = this.cloud.loadAllTotpEntries();
      hilog.info(0x0001, 'CloudSync', "loadFromCloud: TOTP=" + entries.length.toString() + "条");
      this.totpEntries.clear();
      const loadedEntryIds: Set<string> = new Set<string>();
      for (let i = 0; i < entries.length; i++) {
        const cloudEntry: TotpEntry = entries[i];
        const deletedAt: number = this.deletedTotpAt.get(cloudEntry.id) ?? 0;
        if (deletedAt > previousSnapshotAt) { continue; }
        const localEntry: TotpEntry | undefined = previousEntries.get(cloudEntry.id);
        const observedAt: number = this.localTotpObservationAt.get(cloudEntry.id) ?? 0;
        const next: TotpEntry = localEntry !== undefined && observedAt > previousSnapshotAt
          ? TotpEntry.fromJSON(localEntry.toJSON()) : cloudEntry;
        this.totpEntries.set(next.id, next);
        loadedEntryIds.add(next.id);
      }
      previousEntries.forEach((entry: TotpEntry, entryId: string): void => {
        const observedAt: number = this.localTotpObservationAt.get(entryId) ?? 0;
        const deletedAt: number = this.deletedTotpAt.get(entryId) ?? 0;
        if (!loadedEntryIds.has(entryId) && observedAt > previousSnapshotAt && deletedAt <= previousSnapshotAt) {
          this.totpEntries.set(entryId, TotpEntry.fromJSON(entry.toJSON()));
        }
      });
      this.lastCloudSnapshotLoadedAt = Date.now();
    } catch (err) {
      hilog.error(0x0001, 'CloudSync', "loadFromCloud 失败: " + JSON.stringify(err));
    }
    this.emitDataChange();
  }

  isReady(): boolean {
    return this.ready;
  }

  async whenReady(): Promise<void> {
    if (this.ready) { return; }
    if (this.initPromise) {
      await this.initPromise;
    }
  }

  onDataChange(callback: () => void): () => void {
    if (this.dataChangeListeners.indexOf(callback) < 0) {
      this.dataChangeListeners.push(callback);
    }
    return (): void => {
      const index: number = this.dataChangeListeners.indexOf(callback);
      if (index >= 0) { this.dataChangeListeners.splice(index, 1); }
    };
  }

  private visibleDataSignature(): string {
    const keys: string[] = [];
    const entries: string[] = [];
    this.sshKeys.forEach((key: SshKey): void => { keys.push(JSON.stringify(key.toJSON())); });
    this.totpEntries.forEach((entry: TotpEntry): void => { entries.push(JSON.stringify(entry.toJSON())); });
    keys.sort();
    entries.sort();
    return keys.join('\n') + '\n--totp--\n' + entries.join('\n');
  }

  private emitDataChange(force: boolean = false): void {
    const nextSignature: string = this.visibleDataSignature();
    if (!force && !shouldPublishSnapshot(
      this.hasPublishedSnapshot, this.lastPublishedSnapshotSignature, nextSignature)) {
      hilog.info(0x0001, 'CloudSync', 'KeyVaultService: visible snapshot unchanged');
      return;
    }
    this.lastPublishedSnapshotSignature = nextSignature;
    this.hasPublishedSnapshot = true;
    const listeners: Array<() => void> = this.dataChangeListeners.slice();
    for (let i = 0; i < listeners.length; i++) {
      try {
        listeners[i]();
      } catch (err) {
        hilog.warn(0x0001, 'CloudSync', 'KeyVaultService listener failed: ' + JSON.stringify(err));
      }
    }
  }

  // ==================== SSH 密钥 CRUD ====================

  getAllSshKeys(): SshKey[] {
    const result: SshKey[] = [];
    this.sshKeys.forEach((k: SshKey) => { result.push(k); });
    result.sort((a: SshKey, b: SshKey) => b.createdAt - a.createdAt);
    return result;
  }

  getSshKey(id: string): SshKey | undefined { return this.sshKeys.get(id); }

  addSshKey(key: SshKey): boolean {
    if (!key.id) { key.id = SshKey.generateId(); }
    key.createdAt = Date.now();
    if (this.ready && !this.cloud.insertSshKey(key)) { return false; }
    this.sshKeys.set(key.id, key);
    this.localSshKeyObservationAt.set(key.id, Date.now());
    this.deletedSshKeyAt.delete(key.id);
    if (this.ready) { this.cloud.pushTable('sshkeys'); hilog.info(0x0001, 'CloudSync', "SSH密钥已写入: " + key.label); }
    this.emitDataChange();
    return true;
  }

  updateSshKey(key: SshKey): boolean {
    if (!this.sshKeys.has(key.id)) { return false; }
    if (this.ready && !this.cloud.updateSshKey(key)) { return false; }
    this.sshKeys.set(key.id, key);
    this.localSshKeyObservationAt.set(key.id, Date.now());
    this.deletedSshKeyAt.delete(key.id);
    if (this.ready) { this.cloud.pushTable('sshkeys'); }
    this.emitDataChange();
    return true;
  }

  removeSshKey(id: string): boolean {
    if (!this.sshKeys.has(id)) { return false; }
    if (this.ready && !this.cloud.deleteSshKey(id)) { return false; }
    const ok: boolean = this.sshKeys.delete(id);
    if (ok) {
      this.localSshKeyObservationAt.delete(id);
      this.deletedSshKeyAt.set(id, Date.now());
    }
    if (ok && this.ready) { this.cloud.pushTable('sshkeys'); }
    if (ok) { this.emitDataChange(); }
    return ok;
  }

  removeSshKeys(ids: string[]): number {
    const uniqueIds: Set<string> = new Set<string>();
    ids.forEach((id: string): void => { if (id !== '') { uniqueIds.add(id); } });
    let removed: number = 0;
    for (const id of uniqueIds) {
      if (!this.sshKeys.has(id)) { continue; }
      if (this.ready && !this.cloud.deleteSshKey(id)) {
        hilog.warn(0x0001, 'CloudSync', 'KeyVaultService.removeSshKeys: cloud delete failed');
        continue;
      }
      if (this.sshKeys.delete(id)) { removed++; }
      if (removed > 0) {
        this.localSshKeyObservationAt.delete(id);
        this.deletedSshKeyAt.set(id, Date.now());
      }
    }
    if (removed > 0 && this.ready) { this.cloud.pushTable('sshkeys'); }
    if (removed > 0) { this.emitDataChange(); }
    return removed;
  }

  getSshKeyCount(): number { return this.sshKeys.size; }

  // ==================== TOTP 条目 CRUD ====================

  getAllTotpEntries(): TotpEntry[] {
    const result: TotpEntry[] = [];
    this.totpEntries.forEach((e: TotpEntry) => { result.push(e); });
    result.sort((a: TotpEntry, b: TotpEntry) => b.createdAt - a.createdAt);
    return result;
  }

  getTotpEntry(id: string): TotpEntry | undefined { return this.totpEntries.get(id); }

  addTotpEntry(entry: TotpEntry): boolean {
    if (!entry.id) { entry.id = TotpEntry.generateId(); }
    entry.createdAt = Date.now();
    if (this.ready && !this.cloud.insertTotpEntry(entry)) { return false; }
    this.totpEntries.set(entry.id, entry);
    this.localTotpObservationAt.set(entry.id, Date.now());
    this.deletedTotpAt.delete(entry.id);
    if (this.ready) { this.cloud.pushTable('totpentries'); hilog.info(0x0001, 'CloudSync', "TOTP已写入: " + entry.issuer); }
    this.emitDataChange();
    return true;
  }

  /** Batch import with one observer notification and one cloud upload trigger. */
  addTotpEntries(entries: TotpEntry[]): TotpBatchAddResult {
    const savedIds: string[] = [];
    let failedCount = 0;
    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i];
      if (!entry.id) { entry.id = TotpEntry.generateId(); }
      entry.createdAt = Date.now();
      if (this.ready && !this.cloud.insertTotpEntry(entry)) { failedCount++; continue; }
      this.totpEntries.set(entry.id, entry);
      this.localTotpObservationAt.set(entry.id, Date.now());
      this.deletedTotpAt.delete(entry.id);
      savedIds.push(entry.id);
    }
    if (savedIds.length > 0 && this.ready) { this.cloud.pushTable('totpentries'); }
    if (savedIds.length > 0) { this.emitDataChange(); }
    return { savedIds, failedCount };
  }

  updateTotpEntry(entry: TotpEntry): boolean {
    if (!this.totpEntries.has(entry.id)) { return false; }
    if (this.ready && !this.cloud.updateTotpEntry(entry)) { return false; }
    this.totpEntries.set(entry.id, entry);
    this.localTotpObservationAt.set(entry.id, Date.now());
    this.deletedTotpAt.delete(entry.id);
    if (this.ready) { this.cloud.pushTable('totpentries'); }
    this.emitDataChange();
    return true;
  }

  removeTotpEntry(id: string): boolean {
    if (!this.totpEntries.has(id)) { return false; }
    if (this.ready && !this.cloud.deleteTotpEntry(id)) { return false; }
    const ok: boolean = this.totpEntries.delete(id);
    if (ok) {
      this.localTotpObservationAt.delete(id);
      this.deletedTotpAt.set(id, Date.now());
    }
    if (ok && this.ready) { this.cloud.pushTable('totpentries'); }
    if (ok) { this.emitDataChange(); }
    return ok;
  }

  removeTotpEntries(ids: string[]): number {
    const uniqueIds: Set<string> = new Set<string>();
    ids.forEach((id: string): void => { if (id !== '') { uniqueIds.add(id); } });
    let removed: number = 0;
    for (const id of uniqueIds) {
      if (!this.totpEntries.has(id)) { continue; }
      if (this.ready && !this.cloud.deleteTotpEntry(id)) {
        hilog.warn(0x0001, 'CloudSync', 'KeyVaultService.removeTotpEntries: cloud delete failed');
        continue;
      }
      if (this.totpEntries.delete(id)) { removed++; }
      if (removed > 0) {
        this.localTotpObservationAt.delete(id);
        this.deletedTotpAt.set(id, Date.now());
      }
    }
    if (removed > 0 && this.ready) { this.cloud.pushTable('totpentries'); }
    if (removed > 0) { this.emitDataChange(); }
    return removed;
  }

  getTotpCount(): number { return this.totpEntries.size; }

}
