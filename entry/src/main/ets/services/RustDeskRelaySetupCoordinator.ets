import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';
import {
  DataMutationResult,
  DataMutationStage
} from './DataMutationResult';
import { HostSyncService } from './HostSyncService';
import {
  RustDeskControlPlaneProfile,
  RUSTDESK_CONTROL_PLANE_DEFAULT,
  rustDeskControlPlaneProfileForKeyMode
} from './RustDeskControlPlanePolicy';
import {
  RustDeskRelayKeyMode,
  resolveRustDeskRelayKey
} from './RustDeskRelayKeyPolicy';
import {
  RustDeskRelayCloudSyncState,
  RustDeskRelaySaveResult
} from './RustDeskRelaySavePolicy';
import { recordDiagnosticEvent } from './DiagnosticCaptureRuntime';
import {
  EndpointAddressResult,
  endpointTransportHost,
  parseEndpointFields
} from './EndpointAddressPolicy';

export type RustDeskRelaySaveOperation =
  'create' | 'update';

export class RustDeskRelaySetupDraft {
  operation: RustDeskRelaySaveOperation = 'create';
  editingRelayId: string = '';
  relayId: string = '';
  idServer: string = '';
  idServerPort: number = 21116;
  relayServer: string = '';
  relayPort: number = 21117;
  apiServer: string = '';
  key: string = '';
  keyMode: RustDeskRelayKeyMode = 'server_public_key';
  controlPlaneProfile: RustDeskControlPlaneProfile =
    RUSTDESK_CONTROL_PLANE_DEFAULT;
}

class RustDeskRelayPreparedSave {
  relay: RustDeskRelayConfig | null = null;
  failure: RustDeskRelaySaveResult | null = null;
}

export class RustDeskRelaySetupCoordinator {
  private static instance: RustDeskRelaySetupCoordinator;
  private hosts: HostSyncService =
    HostSyncService.getInstance();
  private attemptSequence: number = 0;

  private diagnosticResult(result: RustDeskRelaySaveResult): RustDeskRelaySaveResult {
    recordDiagnosticEvent('network.routing', 'routing_rustdesk_relay',
      result.ok ? 'succeeded' : 'failed', 0, 0, result.ok ? 0 : -1,
      0, result.localCommitted ? 1 : 0);
    return result;
  }

  static getInstance(): RustDeskRelaySetupCoordinator {
    if (!RustDeskRelaySetupCoordinator.instance) {
      RustDeskRelaySetupCoordinator.instance =
        new RustDeskRelaySetupCoordinator();
    }
    return RustDeskRelaySetupCoordinator.instance;
  }

  nextDraftId(): string {
    return RustDeskRelayConfig.generateId();
  }

  private nextAttemptId(): string {
    this.attemptSequence++;
    return 'relay-save-' + Date.now().toString(36) + '-' +
      this.attemptSequence.toString(36);
  }

  private validationFailure(
    attemptId: string,
    relayId: string,
    message: string
  ): RustDeskRelaySaveResult {
    return RustDeskRelaySaveResult.fromMutation(
      attemptId, relayId,
      DataMutationResult.failure(
        relayId, 'invalid_data', message, 'validating'));
  }

  private prepare(
    draft: RustDeskRelaySetupDraft,
    existing: RustDeskRelayConfig | null,
    resolvedAttemptId: string
  ): RustDeskRelayPreparedSave {
    const prepared = new RustDeskRelayPreparedSave();
    const isUpdate: boolean =
      draft.operation === 'update';
    if (isUpdate) {
      const editingId: string =
        draft.editingRelayId.trim();
      if (editingId === '' || existing === null ||
        existing.id !== editingId) {
        prepared.failure =
          RustDeskRelaySaveResult.fromMutation(
            resolvedAttemptId, editingId,
            DataMutationResult.failure(
              editingId, 'not_found',
              '要编辑的服务器已不存在，请重新载入列表',
              'validating'));
        return prepared;
      }
      draft.relayId = editingId;
    } else if (draft.relayId.trim().length === 0) {
      draft.relayId = this.nextDraftId();
    }

    const relayId: string = draft.relayId;
    const idEndpoint: EndpointAddressResult =
      parseEndpointFields(draft.idServer, draft.idServerPort);
    if (!idEndpoint.ok) {
      prepared.failure = this.validationFailure(
        resolvedAttemptId, relayId,
        idEndpoint.error === 'invalid_port' ? '服务器端口必须在 1–65535 之间' :
          'ID 服务器必须是有效的域名、IPv4 或 IPv6 地址');
      return prepared;
    }
    if (idEndpoint.endpoint.scope !== '') {
      prepared.failure = this.validationFailure(
        resolvedAttemptId, relayId,
        'RustDesk 链路本地 IPv6 尚未完成网卡作用域验证，请先使用全局 IPv6 地址');
      return prepared;
    }
    const relayInput: string = draft.relayServer === '' ?
      endpointTransportHost(idEndpoint.endpoint) : draft.relayServer;
    const relayEndpoint: EndpointAddressResult =
      parseEndpointFields(relayInput, draft.relayPort);
    if (!relayEndpoint.ok) {
      prepared.failure = this.validationFailure(
        resolvedAttemptId, relayId,
        relayEndpoint.error === 'invalid_port' ? '服务器端口必须在 1–65535 之间' :
          'Relay 服务器必须是有效的域名、IPv4 或 IPv6 地址');
      return prepared;
    }
    if (relayEndpoint.endpoint.scope !== '') {
      prepared.failure = this.validationFailure(
        resolvedAttemptId, relayId,
        'RustDesk 链路本地 IPv6 尚未完成网卡作用域验证，请先使用全局 IPv6 地址');
      return prepared;
    }
    if (draft.controlPlaneProfile ===
      'official_server_pro_token' &&
      draft.apiServer.trim().length === 0) {
      prepared.failure = this.validationFailure(
        resolvedAttemptId, relayId,
        'Server Pro 必须填写 API 地址；也可以先选择 OSS Key-only 保存');
      return prepared;
    }
    const key = resolveRustDeskRelayKey(
      draft.key, draft.keyMode, false);
    if (!key.ok) {
      prepared.failure = this.validationFailure(
        resolvedAttemptId, relayId, key.error);
      return prepared;
    }
    const controlPlaneProfile:
      RustDeskControlPlaneProfile =
      rustDeskControlPlaneProfileForKeyMode(
        draft.controlPlaneProfile, key.mode);
    if (controlPlaneProfile === 'direct_ip') {
      prepared.failure = this.validationFailure(
        resolvedAttemptId, relayId,
        'Direct IP 是主机连接方式，不能保存为中继控制面配置');
      return prepared;
    }

    const relay = new RustDeskRelayConfig();
    relay.id = relayId;
    relay.idServer = endpointTransportHost(idEndpoint.endpoint);
    relay.idServerPort = draft.idServerPort;
    relay.relayServer = endpointTransportHost(relayEndpoint.endpoint);
    relay.relayPort = draft.relayPort;
    relay.apiServer = draft.apiServer.trim();
    relay.key = key.value;
    relay.keyMode = key.mode;
    relay.controlPlaneProfile = controlPlaneProfile;
    if (isUpdate && existing !== null) {
      relay.userId = existing.userId;
      relay.accounts = existing.accounts;
      relay.apiUsername = existing.apiUsername;
      relay.apiPassword = existing.apiPassword;
      relay.healthStatus = existing.healthStatus;
      relay.healthLatency = existing.healthLatency;
      relay.healthCheckedAt = existing.healthCheckedAt;
      relay.apiLoginStatus = existing.apiLoginStatus;
      relay.syncVersion = existing.syncVersion;
      relay.createdAt = existing.createdAt;
      relay.updatedAt = existing.updatedAt;
    }
    prepared.relay = relay;
    return prepared;
  }

  save(
    draft: RustDeskRelaySetupDraft,
    existing: RustDeskRelayConfig | null = null,
    attemptId: string = ''
  ): RustDeskRelaySaveResult {
    const resolvedAttemptId: string =
      attemptId.trim().length > 0
        ? attemptId : this.nextAttemptId();
    const prepared: RustDeskRelayPreparedSave =
      this.prepare(
        draft, existing, resolvedAttemptId);
    if (prepared.failure !== null) {
      return this.diagnosticResult(prepared.failure);
    }
    const relay: RustDeskRelayConfig =
      prepared.relay as RustDeskRelayConfig;
    const result: RustDeskRelaySaveResult =
      draft.operation === 'update'
        ? this.hosts.updateRelayResult(
          relay, resolvedAttemptId)
        : this.hosts.addRelayResult(
          relay, resolvedAttemptId);
    if (result.ok) {
      void this.hosts.retryRelayCloudSync();
    }
    return this.diagnosticResult(result);
  }

  async saveAsync(
    draft: RustDeskRelaySetupDraft,
    existing: RustDeskRelayConfig | null = null,
    attemptId: string = '',
    onStage:
      ((stage: DataMutationStage) => void) | null = null,
    onCloudState:
      ((state: RustDeskRelayCloudSyncState,
        failureKind: string) => void) | null = null
  ): Promise<RustDeskRelaySaveResult> {
    const resolvedAttemptId: string =
      attemptId.trim().length > 0
        ? attemptId : this.nextAttemptId();
    if (onStage !== null) { onStage('validating'); }
    await new Promise<void>(
      (resolve: () => void): void => {
        setTimeout(resolve, 0);
      });
    const prepared: RustDeskRelayPreparedSave =
      this.prepare(
        draft, existing, resolvedAttemptId);
    if (prepared.failure !== null) {
      if (onStage !== null) {
        onStage(prepared.failure.stage);
      }
      return this.diagnosticResult(prepared.failure);
    }
    const relay: RustDeskRelayConfig =
      prepared.relay as RustDeskRelayConfig;
    const result: RustDeskRelaySaveResult =
      draft.operation === 'update'
        ? await this.hosts.updateRelayResultAsync(
          relay, resolvedAttemptId,
          onStage, onCloudState)
        : await this.hosts.addRelayResultAsync(
          relay, resolvedAttemptId,
          onStage, onCloudState);
    if (onStage !== null) {
      onStage(result.stage);
    }
    return this.diagnosticResult(result);
  }
}
