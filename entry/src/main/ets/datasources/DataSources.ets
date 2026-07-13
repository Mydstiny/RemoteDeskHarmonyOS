/**
 * DataSources.ets — LazyForEach 数据源
 *
 * 将 ForEach 替换为 LazyForEach, 按需加载列表项, 提升大列表渲染性能。
 */
import { RemoteHost } from '../model/RemoteHost';
import { SshKey } from '../model/SshKey';
import { TotpEntry } from '../model/TotpEntry';

// ==================== 主机列表数据源 ====================
export class HostDataSource implements IDataSource {
  private dataArray: RemoteHost[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number { return this.dataArray.length; }

  getData(index: number): RemoteHost {
    return this.dataArray[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) { this.listeners.splice(pos, 1); }
  }

  /** 全量替换数据 (搜索/筛选变更时调用) */
  replaceAll(hosts: RemoteHost[]): void {
    this.dataArray = hosts;
    this.notifyDataReload();
  }

  /** 删除单个主机: 先通知 LazyForEach (此时索引对应未变数据), 再 splice */
  removeItem(index: number): void {
    this.notifyDataDelete(index);
    this.dataArray.splice(index, 1);
  }

  getItem(index: number): RemoteHost { return this.dataArray[index]; }

  private notifyDataReload(): void {
    this.listeners.forEach((listener: DataChangeListener) => { listener.onDataReloaded(); });
  }

  private notifyDataDelete(index: number): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataDelete(index);
    });
  }
}

// ==================== SSH 密钥列表数据源 ====================
export class SshKeyDataSource implements IDataSource {
  private dataArray: SshKey[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number { return this.dataArray.length; }

  getData(index: number): SshKey {
    return this.dataArray[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) { this.listeners.splice(pos, 1); }
  }

  replaceAll(keys: SshKey[]): void {
    this.dataArray = keys;
    this.notifyDataReload();
  }

  removeItem(index: number): void {
    this.notifyDataDelete(index);
    this.dataArray.splice(index, 1);
  }

  getItem(index: number): SshKey { return this.dataArray[index]; }

  private notifyDataReload(): void {
    this.listeners.forEach((listener: DataChangeListener) => { listener.onDataReloaded(); });
  }

  private notifyDataDelete(index: number): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataDelete(index);
    });
  }
}

// ==================== TOTP 条目列表数据源 ====================
export class TotpEntryDataSource implements IDataSource {
  private dataArray: TotpEntry[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number { return this.dataArray.length; }

  getData(index: number): TotpEntry {
    return this.dataArray[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) { this.listeners.splice(pos, 1); }
  }

  replaceAll(entries: TotpEntry[]): void {
    this.dataArray = entries;
    this.notifyDataReload();
  }

  removeItem(index: number): void {
    this.notifyDataDelete(index);
    this.dataArray.splice(index, 1);
  }

  getItem(index: number): TotpEntry { return this.dataArray[index]; }

  private notifyDataReload(): void {
    this.listeners.forEach((listener: DataChangeListener) => { listener.onDataReloaded(); });
  }

  private notifyDataDelete(index: number): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataDelete(index);
    });
  }
}
