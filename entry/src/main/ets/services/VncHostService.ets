import { common } from '@kit.AbilityKit';
import { AuthService } from './AuthService';
import { CloudStore } from './CloudStore';
import { VncRecord } from '../model/VncRecord';
import { DataCrypto } from './DataCrypto';
import {
  VncHostValues, VncTransport, VncRepeaterMode, VncScalingMode, VncSecurityPolicy,
  defaultVncSettings, validateVncHost, vncHostPayload, finalizeVncRecord
} from './VncModelPolicy';
import { VncCloudSyncService } from './VncCloudSyncService';
import { VncSecretService } from './VncSecretService';

export interface VncHostView extends VncHostValues {
  id: string;
  userId: string;
  createdAt: number;
  updatedAt: number;
  syncVersion: number;
  passwordConfigured: boolean;
}

export interface VncHostSaveResult {
  ok: boolean;
  message: string;
  id: string;
}

/** VNC host owner. It never uses RemoteHost or the mixed remotehosts table. */
export class VncHostService {
  private static instance: VncHostService;
  private readonly cloud: CloudStore = CloudStore.getInstance();
  private readonly secrets: VncSecretService = VncSecretService.getInstance();
  private userId: string = 'local';
  private initialized: boolean = false;
  private listenerBound: boolean = false;
  private listeners: Array<() => void> = [];

  static getInstance(): VncHostService {
    if (!VncHostService.instance) { VncHostService.instance = new VncHostService(); }
    return VncHostService.instance;
  }

  init(context: common.Context): void {
    this.userId = this.currentUserId();
    VncCloudSyncService.getInstance().init(context);
    if (!this.listenerBound) {
      this.listenerBound = true;
      this.cloud.onCloudChange((): void => { this.emitChange(); });
    }
    this.initialized = true;
  }

  isReady(): boolean { return this.initialized && this.cloud.isReady(); }

  currentUserId(): string {
    const unionId: string = AuthService.getInstance().getUnionId();
    return unionId.trim() === '' ? 'local' : unionId.trim();
  }

  getUserId(): string { this.userId = this.currentUserId(); return this.userId; }

  onChange(listener: () => void): () => void {
    if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener); }
    return (): void => {
      const index: number = this.listeners.indexOf(listener);
      if (index >= 0) { this.listeners.splice(index, 1); }
    };
  }

  list(): VncHostView[] {
    const result: VncHostView[] = [];
    const records: VncRecord[] = this.cloud.loadVncRecords(this.getUserId());
    for (let i = 0; i < records.length; i++) {
      if (records[i].recordType === 'host' && records[i].deletedAt <= 0) {
        result.push(this.toView(records[i]));
      }
    }
    return result;
  }

  find(id: string): VncHostView | null {
    const values: VncHostView[] = this.list();
    for (let i = 0; i < values.length; i++) { if (values[i].id === id) { return values[i]; } }
    return null;
  }

  save(values: VncHostValues, id: string = '', password: string = ''): VncHostSaveResult {
    const result: VncHostSaveResult = { ok: false, message: '', id };
    const errors: string[] = validateVncHost(values);
    if (errors.length > 0) { result.message = errors[0]; return result; }
    if (password.length > 0 && !DataCrypto.getInstance().isReady()) {
      result.message = '请先解锁应用加密，再保存 VNC 密码';
      return result;
    }
    const currentRecord: VncRecord | null = id === '' ? null : this.findActiveRecord(id);
    const current: VncHostView | null = currentRecord === null ? null : this.toView(currentRecord);
    const record: VncRecord = new VncRecord();
    const now: number = Date.now();
    record.id = id === '' ? VncRecord.generateId('vnchost') : id;
    record.userId = this.getUserId();
    record.recordType = 'host';
    record.ownerId = record.userId;
    record.ownerType = 'account';
    record.secretKind = '';
    record.payload = vncHostPayload(values);
    record.createdAt = current === null ? now : current.createdAt;
    record.updatedAt = now;
    record.syncVersion = current === null ? 1 : current.syncVersion + 1;
    finalizeVncRecord(record);
    if (!this.cloud.upsertVncRecord(record)) {
      result.message = this.cloud.getLastMutationResult().message || 'VNC 主机保存失败';
      return result;
    }
    result.id = record.id;
    if (password.length > 0) {
      const secretResult = this.secrets.save(record.userId, record.id, 'host', 'vnc_password', password,
        values.label);
      if (!secretResult.ok) {
        const rolledBack: boolean = currentRecord === null
          ? this.cloud.deleteVncRecord(record.userId, record.id)
          : this.cloud.upsertVncRecord(currentRecord);
        result.message = rolledBack
          ? secretResult.message + '；主机配置已回滚'
          : secretResult.message + '；主机配置回滚失败，请检查 VNC 数据状态';
        return result;
      }
    }
    result.ok = true;
    this.emitChange();
    return result;
  }

  remove(id: string): boolean {
    const removed: boolean = this.cloud.deleteVncRecord(this.getUserId(), id);
    if (removed) {
      this.secrets.remove(this.getUserId(), id, 'vnc_password');
      this.emitChange();
    }
    return removed;
  }

  passwordFor(id: string): string {
    return this.secrets.load(this.getUserId(), id, 'vnc_password');
  }

  private toView(record: VncRecord): VncHostView {
    const values: VncHostValues = this.parsePayload(record.payload);
    const view: VncHostView = {
      id: record.id,
      userId: record.userId,
      label: values.label,
      host: values.host,
      port: values.port,
      username: values.username,
      gatewayId: values.gatewayId,
      transport: values.transport,
      repeaterMode: values.repeaterMode,
      viewOnly: values.viewOnly,
      scalingMode: values.scalingMode,
      clipboardEnabled: values.clipboardEnabled,
      securityPolicy: values.securityPolicy,
      tls: values.tls,
      createdAt: record.createdAt,
      updatedAt: record.updatedAt,
      syncVersion: record.syncVersion,
      passwordConfigured: this.secrets.load(record.userId, record.id, 'vnc_password').length > 0
    };
    return view;
  }

  private parsePayload(payload: string): VncHostValues {
    const defaults = defaultVncSettings();
    const result: VncHostValues = {
      label: '', host: '', port: defaults.defaultPort, username: '', gatewayId: '',
      transport: defaults.defaultTransport, repeaterMode: defaults.repeaterMode,
      viewOnly: defaults.viewOnly, scalingMode: defaults.scalingMode,
      clipboardEnabled: defaults.clipboardEnabled,
      securityPolicy: defaults.securityPolicy, tls: false
    };
    try {
      const parsed: Object = JSON.parse(payload) as Object;
      const values: Record<string, Object> = parsed as Record<string, Object>;
      if (typeof values['label'] === 'string') { result.label = values['label'] as string; }
      if (typeof values['host'] === 'string') { result.host = values['host'] as string; }
      if (typeof values['port'] === 'number') { result.port = values['port'] as number; }
      if (typeof values['username'] === 'string') { result.username = values['username'] as string; }
      if (typeof values['gatewayId'] === 'string') { result.gatewayId = values['gatewayId'] as string; }
      if (typeof values['transport'] === 'string') { result.transport = values['transport'] as VncTransport; }
      if (typeof values['repeaterMode'] === 'string') { result.repeaterMode = values['repeaterMode'] as VncRepeaterMode; }
      if (typeof values['viewOnly'] === 'boolean') { result.viewOnly = values['viewOnly'] as boolean; }
      if (typeof values['scalingMode'] === 'string') { result.scalingMode = values['scalingMode'] as VncScalingMode; }
      if (typeof values['clipboardEnabled'] === 'boolean') { result.clipboardEnabled = values['clipboardEnabled'] as boolean; }
      if (typeof values['securityPolicy'] === 'string') { result.securityPolicy = values['securityPolicy'] as VncSecurityPolicy; }
      if (typeof values['tls'] === 'boolean') { result.tls = values['tls'] as boolean; }
    } catch (_e) {}
    return result;
  }

  private findActiveRecord(id: string): VncRecord | null {
    const records: VncRecord[] = this.cloud.loadVncRecords(this.getUserId(), true);
    for (let i = 0; i < records.length; i++) {
      if (records[i].id === id && records[i].recordType === 'host' && records[i].deletedAt <= 0) {
        return records[i];
      }
    }
    return null;
  }

  private emitChange(): void {
    const callbacks: Array<() => void> = this.listeners.slice();
    for (let i = 0; i < callbacks.length; i++) { try { callbacks[i](); } catch (_e) {} }
  }
}
