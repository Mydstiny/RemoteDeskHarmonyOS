import { RustDeskRelayConfig } from '../model/RustDeskRelayConfig';
import { DataMutationResult } from './DataMutationResult';
import { HostSyncService } from './HostSyncService';
import {
  RustDeskControlPlaneProfile,
  RUSTDESK_CONTROL_PLANE_DEFAULT
} from './RustDeskControlPlanePolicy';
import {
  RustDeskRelayKeyMode,
  resolveRustDeskRelayKey
} from './RustDeskRelayKeyPolicy';
import { RustDeskRelaySaveResult } from './RustDeskRelaySavePolicy';

export class RustDeskRelaySetupDraft {
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

export class RustDeskRelaySetupCoordinator {
  private static instance: RustDeskRelaySetupCoordinator;
  private hosts: HostSyncService = HostSyncService.getInstance();
  private attemptSequence: number = 0;

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

  save(
    draft: RustDeskRelaySetupDraft,
    existing: RustDeskRelayConfig | null = null,
    attemptId: string = ''
  ): RustDeskRelaySaveResult {
    const resolvedAttemptId: string = attemptId.trim().length > 0
      ? attemptId : this.nextAttemptId();
    if (draft.relayId.trim().length === 0) {
      draft.relayId = this.nextDraftId();
    }
    const relayId: string = draft.relayId;
    const idServer: string = draft.idServer.trim();
    if (idServer.length === 0) {
      return this.validationFailure(
        resolvedAttemptId, relayId, 'ID 服务器地址不能为空');
    }
    if (!this.validPort(draft.idServerPort) ||
      !this.validPort(draft.relayPort)) {
      return this.validationFailure(
        resolvedAttemptId, relayId, '服务器端口必须在 1–65535 之间');
    }
    if (draft.controlPlaneProfile === 'official_server_pro_token' &&
      draft.apiServer.trim().length === 0) {
      return this.validationFailure(
        resolvedAttemptId, relayId,
        'Server Pro 必须填写 API 地址；也可以先选择 OSS Key-only 保存');
    }
    const key = resolveRustDeskRelayKey(
      draft.key, draft.keyMode, false);
    if (!key.ok) {
      return this.validationFailure(
        resolvedAttemptId, relayId, key.error);
    }

    const relay = new RustDeskRelayConfig();
    relay.id = relayId;
    relay.idServer = idServer;
    relay.idServerPort = draft.idServerPort;
    relay.relayServer = draft.relayServer.trim().length === 0
      ? idServer : draft.relayServer.trim();
    relay.relayPort = draft.relayPort;
    relay.apiServer = draft.apiServer.trim();
    relay.key = key.value;
    relay.keyMode = key.mode;
    relay.controlPlaneProfile = draft.controlPlaneProfile;
    if (existing !== null) {
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
      return this.hosts.updateRelayResult(relay, resolvedAttemptId);
    }
    return this.hosts.addRelayResult(relay, resolvedAttemptId);
  }

  private validPort(port: number): boolean {
    return Number.isInteger(port) && port > 0 && port <= 65535;
  }
}
