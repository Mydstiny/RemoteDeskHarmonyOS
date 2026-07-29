import { common } from '@kit.AbilityKit';
import { VncRecordType } from '../model/VncRecord';
import { CloudSyncCoordinator, CloudSyncOperationResult } from './CloudSyncCoordinator';
import { VncCloudSyncSelectionStore } from './VncCloudSyncSelectionStore';
import { VncCloudSyncScope } from './VncCloudSyncSelectionPolicy';

/** VNC sync facade. The coordinator still serializes the shared RDB transfer. */
export class VncCloudSyncService {
  private static instance: VncCloudSyncService;
  private readonly selection: VncCloudSyncSelectionStore =
    VncCloudSyncSelectionStore.getInstance();
  private context: common.Context | null = null;

  static getInstance(): VncCloudSyncService {
    if (!VncCloudSyncService.instance) {
      VncCloudSyncService.instance = new VncCloudSyncService();
    }
    return VncCloudSyncService.instance;
  }

  init(context: common.Context): void {
    this.context = context;
  }

  /**
   * Persist the VNC-only logical selection. Reconciliation is deliberately
   * performed by the owning service after this call so the selector and the
   * RDB transaction always have an explicit ordering.
   */
  replaceSelectedScopes(scopes: string[]): boolean {
    if (this.context === null) { return false; }
    return this.selection.replaceSelectedScopes(this.context, scopes);
  }

  stageSelectedScopes(scopes: string[]): void {
    this.selection.stageSelectedScopes(scopes);
  }

  persistSelectedScopes(): boolean {
    if (this.context === null) { return false; }
    return this.selection.persistSelectedScopes(this.context);
  }

  selectedScopes(): VncCloudSyncScope[] { return this.selection.selectedScopes(); }

  isRecordTypeSelected(recordType: VncRecordType): boolean {
    return this.selection.isRecordTypeSelected(recordType);
  }

  secretsAllowed(cryptoReady: boolean = false): boolean {
    return this.selection.secretsAllowed(cryptoReady);
  }

  requestManualUpload(): Promise<CloudSyncOperationResult> {
    return CloudSyncCoordinator.getInstance().requestVncManualUpload();
  }

  requestManualDownload(): Promise<CloudSyncOperationResult> {
    return CloudSyncCoordinator.getInstance().requestVncManualDownload();
  }

  requestAutomaticPush(recordType: VncRecordType): Promise<CloudSyncOperationResult> {
    return CloudSyncCoordinator.getInstance().requestVncAutomaticPush(recordType);
  }

  requestSelectionReconcile(): Promise<CloudSyncOperationResult> {
    return CloudSyncCoordinator.getInstance().requestVncSelectionReconcile();
  }
}
