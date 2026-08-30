import { common } from '@kit.AbilityKit';
import { AccountSessionCoordinator } from './AccountSessionCoordinator';
import { CloudStore } from './CloudStore';
import { VncRecord } from '../model/VncRecord';
import {
  VncHostValues, VncTransport, VncRepeaterMode, VncScalingMode, VncSecurityPolicy,
  defaultVncSettings, validateVncHost, vncHostPayload, finalizeVncRecord,
  vncHostRequiresLocalStorage
} from './VncModelPolicy';
import { VncCloudSyncService } from './VncCloudSyncService';
import { VncSecretLoadResult, VncSecretSaveResult, VncSecretService } from './VncSecretService';
import { VncTrustService } from './VncTrustService';
import { vncHostTrustEndpointChanged } from './VncTrustInvalidationPolicy';
import { SecretEditMutationKind } from './SecretEditMutationPolicy';
import { vncSecretBindingUnchanged } from './VncSecretEditPolicy';
import {
  applyVncHostLocalPersonalization,
  vncHostCloudValuesForSave,
  vncHostLocalPersonalizationPayload
} from './HostLocalPersonalizationPolicy';

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
  private readonly trust: VncTrustService = VncTrustService.getInstance();
  private userId: string = 'device-local';
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
    this.secrets.init(context);
    if (!this.listenerBound) {
      this.listenerBound = true;
      this.cloud.onCloudChange((): void => { this.emitChange(); });
      AccountSessionCoordinator.getInstance().onChange((): void => {
        this.userId = this.currentUserId();
        this.emitChange();
      });
    }
    this.initialized = true;
  }

  isReady(): boolean { return this.initialized && this.cloud.isReady(); }

  currentUserId(): string {
    return AccountSessionCoordinator.getInstance().currentScope().ownerScopeId;
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

  save(values: VncHostValues, id: string = '', password: string = '',
    allowPlaintext: boolean = false,
    passwordMutation: SecretEditMutationKind = 'keep'): VncHostSaveResult {
    const result: VncHostSaveResult = { ok: false, message: '', id };
    const errors: string[] = validateVncHost(values);
    if (errors.length > 0) { result.message = errors[0]; return result; }
    const currentRecord: VncRecord | null = id === '' ? null : this.findActiveRecord(id);
    const current: VncHostView | null = currentRecord === null ? null : this.toView(currentRecord);
    const previousCloudValues: VncHostValues | null = currentRecord === null ? null :
      this.parsePayload(currentRecord.payload);
    const localOnly: boolean = vncHostRequiresLocalStorage(values);
    const previousLocalOnly: boolean = previousCloudValues !== null &&
      vncHostRequiresLocalStorage(previousCloudValues);
    if (currentRecord !== null && localOnly !== previousLocalOnly) {
      result.message = 'VNC 主机不能用同一 ID 在云同步地址与本机网卡作用域地址之间转换，请新建主机';
      return result;
    }
    const record: VncRecord = new VncRecord();
    const now: number = Date.now();
    record.id = id === '' ? VncRecord.generateId('vnchost') : id;
    record.userId = this.getUserId();
    record.recordType = 'host';
    record.ownerId = record.userId;
    record.ownerType = 'account';
    record.secretKind = '';
    record.payload = vncHostPayload(vncHostCloudValuesForSave(values, previousCloudValues));
    record.createdAt = current === null ? now : current.createdAt;
    record.updatedAt = now;
    record.syncVersion = current === null ? 1 : current.syncVersion + 1;
    finalizeVncRecord(record);
    const previousLocalPayload: string =
      this.cloud.loadVncHostLocalPersonalization(record.id);
    if (!this.cloud.saveVncHostLocalPersonalization(
      record.id, vncHostLocalPersonalizationPayload(values))) {
      result.message = 'VNC 本机个性化设置保存失败';
      return result;
    }
    const cloudBaseChanged: boolean = currentRecord === null ||
      currentRecord.payload !== record.payload;
    if (cloudBaseChanged && !this.cloud.upsertVncRecord(record, localOnly)) {
      this.restoreLocalPersonalization(record.id, previousLocalPayload);
      result.message = this.cloud.getLastMutationResult().message || 'VNC 主机保存失败';
      return result;
    }
    result.id = record.id;
    if (current !== null && vncHostTrustEndpointChanged(current, values)) {
      // Invalidate before touching the password so a failed marker write can
      // roll the configuration back without a second secret mutation.
      const invalidation = this.trust.invalidateOwner('host', record.id);
      if (!invalidation.ok) {
        const rolledBack: boolean = !cloudBaseChanged ? true : currentRecord === null
          ? this.cloud.discardVncRecordAfterFailedCreate(record.userId, record.id)
          : this.cloud.upsertVncRecord(currentRecord, previousLocalOnly);
        this.restoreLocalPersonalization(record.id, previousLocalPayload);
        result.message = rolledBack
          ? invalidation.message + '；主机配置已回滚'
          : invalidation.message + '；主机配置回滚失败，请检查 VNC 数据状态';
        return result;
      }
    }
    const existingSecret: boolean = currentRecord !== null &&
      this.secrets.has(record.userId, record.id, 'vnc_password');
    let effectivePasswordMutation: SecretEditMutationKind = values.rememberPassword ?
      passwordMutation : 'clear';
    if (current !== null && effectivePasswordMutation === 'keep' &&
      !vncSecretBindingUnchanged(current, values)) {
      effectivePasswordMutation = 'clear';
    }
    if (effectivePasswordMutation === 'replace' && password.length > 0) {
      const secretResult = this.secrets.save(record.userId, record.id, 'host', 'vnc_password', password,
        values.label, allowPlaintext, localOnly);
      if (!secretResult.ok) {
        const rolledBack: boolean = !cloudBaseChanged ? true : currentRecord === null
          ? this.cloud.discardVncRecordAfterFailedCreate(record.userId, record.id)
          : this.cloud.upsertVncRecord(currentRecord, previousLocalOnly);
        this.restoreLocalPersonalization(record.id, previousLocalPayload);
        result.message = rolledBack
          ? secretResult.message + '；主机配置已回滚'
          : secretResult.message + '；主机配置回滚失败，请检查 VNC 数据状态';
        return result;
      }
    } else if ((effectivePasswordMutation === 'clear' ||
      effectivePasswordMutation === 'replace') && existingSecret) {
      if (!this.secrets.remove(record.userId, record.id, 'vnc_password', localOnly)) {
        const rolledBack: boolean = !cloudBaseChanged ? true : currentRecord === null
          ? this.cloud.deleteVncRecord(record.userId, record.id, localOnly)
          : this.cloud.upsertVncRecord(currentRecord, previousLocalOnly);
        this.restoreLocalPersonalization(record.id, previousLocalPayload);
        result.message = rolledBack ? 'VNC 密码删除失败，主机配置已回滚' :
          'VNC 密码删除失败且主机配置回滚失败，请检查 VNC 数据状态';
        return result;
      }
    }
    result.ok = true;
    this.emitChange();
    return result;
  }

  remove(id: string): boolean {
    const previousRecord: VncRecord | null = this.findActiveRecord(id);
    const previousLocalOnly: boolean = previousRecord !== null &&
      vncHostRequiresLocalStorage(this.parsePayload(previousRecord.payload));
    const removed: boolean = this.cloud.deleteVncRecord(
      this.getUserId(), id, previousLocalOnly);
    if (removed) {
      const invalidation = this.trust.invalidateOwner('host', id);
      if (!invalidation.ok) {
        if (previousRecord !== null) {
          this.cloud.upsertVncRecord(previousRecord, previousLocalOnly);
        }
        return false;
      }
      this.secrets.remove(this.getUserId(), id, 'vnc_password', previousLocalOnly);
      this.cloud.deleteVncHostLocalPersonalization(id);
      this.emitChange();
    }
    return removed;
  }

  passwordFor(id: string): string {
    return this.secrets.load(this.getUserId(), id, 'vnc_password');
  }

  passwordStateFor(id: string): VncSecretLoadResult {
    return this.secrets.loadResult(this.getUserId(), id, 'vnc_password');
  }

  savePassword(id: string, password: string, remember: boolean,
    allowPlaintext: boolean = false): VncSecretSaveResult {
    const current: VncHostView | null = this.find(id);
    const localOnly: boolean = current !== null && vncHostRequiresLocalStorage(current);
    if (!remember) {
      const removed: boolean = this.secrets.remove(this.getUserId(), id, 'vnc_password', localOnly);
      return {
        ok: removed, recordId: 'vncsecret_vnc_password_' + id, code: removed ? 'none' : 'remove_failed',
        message: removed ? '' : (this.cloud.getLastMutationResult().message || 'VNC 密码删除失败')
      };
    }
    return this.secrets.save(
      this.getUserId(), id, 'host', 'vnc_password', password, '', allowPlaintext, localOnly);
  }

  grantPlaintextPasswordConsent(id: string): boolean {
    return this.secrets.grantPlaintextConsent(this.getUserId(), id, 'vnc_password');
  }

  private toView(record: VncRecord): VncHostView {
    const cloudValues: VncHostValues = this.parsePayload(record.payload);
    const localPayload: string = this.cloud.loadVncHostLocalPersonalization(record.id);
    if (localPayload === '') {
      // Old installations inherit legacy presentation without any migration
      // write. Password intent is always derived from this device's secret.
      cloudValues.rememberPassword =
        this.secrets.has(record.userId, record.id, 'vnc_password');
    }
    const values: VncHostValues =
      applyVncHostLocalPersonalization(cloudValues, localPayload);
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
      rememberPassword: values.rememberPassword || this.secrets.has(record.userId, record.id, 'vnc_password'),
      viewOnly: values.viewOnly,
      displayOverrideEnabled: values.displayOverrideEnabled,
      scalingMode: values.scalingMode,
      clipboardEnabled: values.clipboardEnabled,
      securityPolicy: values.securityPolicy,
      tls: values.tls,
      locked: values.locked,
      lockType: values.lockType,
      createdAt: record.createdAt,
      updatedAt: record.updatedAt,
      syncVersion: record.syncVersion,
      // Presence is deliberately independent from decryption readiness.  An
      // encrypted secret can be present while the app key is locked; the
      // editor must still report that the host has a saved password instead
      // of presenting it as missing and tempting the user to overwrite it.
      passwordConfigured: this.secrets.has(record.userId, record.id, 'vnc_password')
    };
    return view;
  }

  private parsePayload(payload: string): VncHostValues {
    const defaults = defaultVncSettings();
    const result: VncHostValues = {
      label: '', host: '', port: defaults.defaultPort, username: '', gatewayId: '',
      transport: defaults.defaultTransport, repeaterMode: defaults.repeaterMode,
      rememberPassword: false,
      viewOnly: defaults.viewOnly,
      // Missing means a legacy record. Preserve its saved scaling choice.
      displayOverrideEnabled: true, scalingMode: defaults.scalingMode,
      clipboardEnabled: defaults.clipboardEnabled,
      securityPolicy: defaults.securityPolicy, tls: false,
      locked: false, lockType: 0
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
      if (typeof values['rememberPassword'] === 'boolean') {
        result.rememberPassword = values['rememberPassword'] as boolean;
      }
      if (typeof values['viewOnly'] === 'boolean') { result.viewOnly = values['viewOnly'] as boolean; }
      if (typeof values['displayOverrideEnabled'] === 'boolean') {
        result.displayOverrideEnabled = values['displayOverrideEnabled'] as boolean;
      }
      if (typeof values['scalingMode'] === 'string') { result.scalingMode = values['scalingMode'] as VncScalingMode; }
      if (typeof values['clipboardEnabled'] === 'boolean') { result.clipboardEnabled = values['clipboardEnabled'] as boolean; }
      if (typeof values['securityPolicy'] === 'string') { result.securityPolicy = values['securityPolicy'] as VncSecurityPolicy; }
      if (typeof values['tls'] === 'boolean') { result.tls = values['tls'] as boolean; }
      if (typeof values['locked'] === 'boolean') { result.locked = values['locked'] as boolean; }
      if (typeof values['lockType'] === 'number' && Number.isInteger(values['lockType'] as number) &&
        (values['lockType'] as number) >= 0 && (values['lockType'] as number) <= 3) {
        result.lockType = values['lockType'] as number;
      }
    } catch (_e) {}
    return result;
  }

  /** Persist the host-card lock without crossing into HostSyncService. */
  updateLock(id: string, locked: boolean, lockType: number = locked ? 1 : 0): boolean {
    const current: VncHostView | null = this.find(id);
    if (current === null) { return false; }
    const values: VncHostValues = {
      label: current.label, host: current.host, port: current.port, username: current.username,
      gatewayId: current.gatewayId, transport: current.transport, repeaterMode: current.repeaterMode,
      rememberPassword: current.rememberPassword, viewOnly: current.viewOnly,
      displayOverrideEnabled: current.displayOverrideEnabled,
      scalingMode: current.scalingMode, clipboardEnabled: current.clipboardEnabled,
      securityPolicy: current.securityPolicy, tls: current.tls,
      locked, lockType: locked ? lockType : 0
    };
    return this.save(values, id, '', false).ok;
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

  private restoreLocalPersonalization(id: string, previousPayload: string): void {
    if (previousPayload === '') {
      this.cloud.deleteVncHostLocalPersonalization(id);
      return;
    }
    this.cloud.saveVncHostLocalPersonalization(id, previousPayload);
  }

  private emitChange(): void {
    const callbacks: Array<() => void> = this.listeners.slice();
    for (let i = 0; i < callbacks.length; i++) { try { callbacks[i](); } catch (_e) {} }
  }
}
