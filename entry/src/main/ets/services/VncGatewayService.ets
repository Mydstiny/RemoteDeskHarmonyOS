import { common } from '@kit.AbilityKit';
import { AccountSessionCoordinator } from './AccountSessionCoordinator';
import { CloudStore } from './CloudStore';
import { VncRecord } from '../model/VncRecord';
import {
  VncGatewayValues, VncTransport, VncRepeaterMode, defaultVncSettings,
  validateVncGateway, vncGatewayPayload, finalizeVncRecord,
  vncGatewayRequiresLocalStorage
} from './VncModelPolicy';
import { VncCloudSyncService } from './VncCloudSyncService';
import { VncSecretService } from './VncSecretService';
import { vncGatewayAvailability } from './VncGatewayProtocolPolicy';
import { VncTrustService } from './VncTrustService';
import { vncGatewayTrustEndpointChanged } from './VncTrustInvalidationPolicy';
import { recordDiagnosticEvent } from './DiagnosticCaptureRuntime';

export interface VncGatewayView extends VncGatewayValues {
  id: string;
  userId: string;
  createdAt: number;
  updatedAt: number;
  syncVersion: number;
  tokenConfigured: boolean;
}

export interface VncGatewaySaveResult {
  ok: boolean;
  message: string;
  id: string;
}

/** VNC gateway/repeater owner, separate from RustDesk relay configuration. */
export class VncGatewayService {
  private static instance: VncGatewayService;
  private readonly cloud: CloudStore = CloudStore.getInstance();
  private readonly secrets: VncSecretService = VncSecretService.getInstance();
  private readonly trust: VncTrustService = VncTrustService.getInstance();
  private userId: string = 'device-local';
  private initialized: boolean = false;
  private listenerBound: boolean = false;
  private listeners: Array<() => void> = [];

  private diagnosticSaveResult(result: VncGatewaySaveResult): VncGatewaySaveResult {
    recordDiagnosticEvent('network.routing', 'routing_vnc_gateway',
      result.ok ? 'succeeded' : 'failed', 0, 0, result.ok ? 0 : -1);
    return result;
  }

  static getInstance(): VncGatewayService {
    if (!VncGatewayService.instance) { VncGatewayService.instance = new VncGatewayService(); }
    return VncGatewayService.instance;
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

  private getUserId(): string { this.userId = this.currentUserId(); return this.userId; }

  onChange(listener: () => void): () => void {
    if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener); }
    return (): void => {
      const index: number = this.listeners.indexOf(listener);
      if (index >= 0) { this.listeners.splice(index, 1); }
    };
  }

  list(): VncGatewayView[] {
    const result: VncGatewayView[] = [];
    const records: VncRecord[] = this.cloud.loadVncRecords(this.getUserId());
    for (let i = 0; i < records.length; i++) {
      if (records[i].recordType === 'gateway' && records[i].deletedAt <= 0) {
        result.push(this.toView(records[i]));
      }
    }
    return result;
  }

  find(id: string): VncGatewayView | null {
    const values: VncGatewayView[] = this.list();
    for (let i = 0; i < values.length; i++) { if (values[i].id === id) { return values[i]; } }
    return null;
  }

  save(values: VncGatewayValues, id: string = '', accessToken: string = '',
    allowPlaintext: boolean = false): VncGatewaySaveResult {
    recordDiagnosticEvent('network.routing', 'routing_vnc_gateway', 'started');
    const result: VncGatewaySaveResult = { ok: false, message: '', id };
    const errors: string[] = validateVncGateway(values);
    if (errors.length > 0) {
      result.message = errors[0];
      return this.diagnosticSaveResult(result);
    }
    const currentRecord: VncRecord | null = id === '' ? null : this.findActiveRecord(id);
    const current: VncGatewayView | null = currentRecord === null ? null : this.toView(currentRecord);
    const localOnly: boolean = vncGatewayRequiresLocalStorage(values);
    const previousLocalOnly: boolean = currentRecord !== null &&
      vncGatewayRequiresLocalStorage(this.parsePayload(currentRecord.payload));
    if (currentRecord !== null && localOnly !== previousLocalOnly) {
      result.message = 'VNC 网关不能用同一 ID 在云同步地址与本机网卡作用域地址之间转换，请新建网关';
      return this.diagnosticSaveResult(result);
    }
    const record: VncRecord = new VncRecord();
    const now: number = Date.now();
    record.id = id === '' ? VncRecord.generateId('vncgw') : id;
    record.userId = this.getUserId();
    record.recordType = 'gateway';
    record.ownerId = record.userId;
    record.ownerType = 'account';
    record.secretKind = '';
    // Unsupported transports and repeater roles may remain as visible
    // configuration for future migration, but they can never be persisted as
    // an enabled/connectable gateway before their native contract is shipped.
    const availability = vncGatewayAvailability(values.transport, values.tls, accessToken.length > 0,
      values.repeaterMode);
    const persistedValues: VncGatewayValues = {
      label: values.label, transport: values.transport, host: values.host, port: values.port,
      path: values.path, repeaterMode: values.repeaterMode, targetId: values.targetId, tls: values.tls,
      enabled: values.enabled && availability.enabled
    };
    record.payload = vncGatewayPayload(persistedValues);
    record.createdAt = current === null ? now : current.createdAt;
    record.updatedAt = now;
    record.syncVersion = current === null ? 1 : current.syncVersion + 1;
    finalizeVncRecord(record);
    if (!this.cloud.upsertVncRecord(record, localOnly)) {
      result.message = this.cloud.getLastMutationResult().message || 'VNC 网关保存失败';
      return this.diagnosticSaveResult(result);
    }
    result.id = record.id;
    if (current !== null && vncGatewayTrustEndpointChanged(current, values)) {
      // Invalidate before touching the gateway token. A persistence failure
      // therefore rejects the endpoint mutation before secret state changes.
      const invalidation = this.trust.invalidateOwner('gateway', record.id);
      if (!invalidation.ok) {
        const rolledBack: boolean = currentRecord === null
          ? this.cloud.discardVncRecordAfterFailedCreate(record.userId, record.id)
          : this.cloud.upsertVncRecord(currentRecord, previousLocalOnly);
        result.message = rolledBack
          ? invalidation.message + '；网关配置已回滚'
          : invalidation.message + '；网关配置回滚失败，请检查 VNC 数据状态';
        return this.diagnosticSaveResult(result);
      }
    }
    if (accessToken.length > 0) {
      const secretResult = this.secrets.save(record.userId, record.id, 'gateway', 'gateway_token',
        accessToken, values.label, allowPlaintext, localOnly);
      if (!secretResult.ok) {
        // The gateway row and its token are one logical mutation even though
        // they occupy two rows in the single VNC table. Restore the previous
        // row, or tombstone a newly-created row, if encryption/secret storage
        // fails after the gateway payload was written.
        const rolledBack: boolean = currentRecord === null
          ? this.cloud.discardVncRecordAfterFailedCreate(record.userId, record.id)
          : this.cloud.upsertVncRecord(currentRecord, previousLocalOnly);
        result.message = rolledBack
          ? secretResult.message + '；网关配置已回滚'
          : secretResult.message + '；网关配置回滚失败，请检查 VNC 数据状态';
        return this.diagnosticSaveResult(result);
      }
    }
    result.ok = true;
    this.emitChange();
    return this.diagnosticSaveResult(result);
  }

  remove(id: string): boolean {
    recordDiagnosticEvent('network.routing', 'routing_vnc_gateway', 'started');
    const previousRecord: VncRecord | null = this.findActiveRecord(id);
    const previousLocalOnly: boolean = previousRecord !== null &&
      vncGatewayRequiresLocalStorage(this.parsePayload(previousRecord.payload));
    const ok: boolean = this.cloud.deleteVncRecord(
      this.getUserId(), id, previousLocalOnly);
    if (ok) {
      const invalidation = this.trust.invalidateOwner('gateway', id);
      if (!invalidation.ok) {
        if (previousRecord !== null) {
          this.cloud.upsertVncRecord(previousRecord, previousLocalOnly);
        }
        recordDiagnosticEvent('network.routing', 'routing_vnc_gateway', 'failed', 0, 0, -1);
        return false;
      }
      this.secrets.remove(this.getUserId(), id, 'gateway_token', previousLocalOnly);
      this.emitChange();
    }
    recordDiagnosticEvent('network.routing', 'routing_vnc_gateway',
      ok ? 'succeeded' : 'failed', 0, 0, ok ? 0 : -1);
    return ok;
  }

  /** Materializes a gateway token only for a short-lived connection path. */
  tokenFor(id: string): string {
    return this.secrets.load(this.getUserId(), id, 'gateway_token');
  }

  private toView(record: VncRecord): VncGatewayView {
    const values: VncGatewayValues = this.parsePayload(record.payload);
    return {
      id: record.id, userId: record.userId, label: values.label, transport: values.transport,
      host: values.host, port: values.port, path: values.path, repeaterMode: values.repeaterMode,
      targetId: values.targetId, tls: values.tls, enabled: values.enabled,
      tokenConfigured: this.secrets.has(record.userId, record.id, 'gateway_token'),
      createdAt: record.createdAt, updatedAt: record.updatedAt, syncVersion: record.syncVersion
    };
  }

  private parsePayload(payload: string): VncGatewayValues {
    const defaults = defaultVncSettings();
    const result: VncGatewayValues = {
      label: '', transport: 'ultravnc_repeater', host: '', port: 5901, path: '/vnc',
      repeaterMode: defaults.repeaterMode, targetId: '', tls: false, enabled: true
    };
    try {
      const parsed: Object = JSON.parse(payload) as Object;
      const values: Record<string, Object> = parsed as Record<string, Object>;
      if (typeof values['label'] === 'string') { result.label = values['label'] as string; }
      if (typeof values['transport'] === 'string') { result.transport = values['transport'] as VncTransport; }
      if (typeof values['host'] === 'string') { result.host = values['host'] as string; }
      if (typeof values['port'] === 'number') { result.port = values['port'] as number; }
      if (typeof values['path'] === 'string') { result.path = values['path'] as string; }
      if (typeof values['repeaterMode'] === 'string') { result.repeaterMode = values['repeaterMode'] as VncRepeaterMode; }
      if (typeof values['targetId'] === 'string') { result.targetId = values['targetId'] as string; }
      if (typeof values['tls'] === 'boolean') { result.tls = values['tls'] as boolean; }
      if (typeof values['enabled'] === 'boolean') { result.enabled = values['enabled'] as boolean; }
    } catch (_e) {}
    return result;
  }

  private findActiveRecord(id: string): VncRecord | null {
    const records: VncRecord[] = this.cloud.loadVncRecords(this.getUserId(), true);
    for (let i = 0; i < records.length; i++) {
      if (records[i].id === id && records[i].recordType === 'gateway' && records[i].deletedAt <= 0) {
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
