import { ExtensionLoader } from './ExtensionLoader';
import { ClipboardLease } from './ClipboardCoordinator';
import { SessionRemoteDirectory, SessionTransferAuthentication, SessionTransferResult,
  SessionTransferStatus } from '../types/rdpnapi';

/** Bounded control jobs share the immutable file-session owner, never desktop authentication. */
export class RustDeskTransferClient {
  private loader: ExtensionLoader;
  private lease: ClipboardLease;
  private isCurrent: () => boolean;
  private onAuthentication: (snapshot: SessionTransferAuthentication) => void;
  constructor(loader: ExtensionLoader, lease: ClipboardLease, isCurrent: () => boolean,
    onAuthentication: (snapshot: SessionTransferAuthentication) => void) {
    this.loader = loader; this.lease = lease; this.isCurrent = isCurrent; this.onAuthentication = onAuthentication;
  }

  private async pause(): Promise<void> {
    await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 200); });
  }
  private status(id: number): SessionTransferStatus {
    return this.loader.getSessionFileTransfer(this.lease.sessionId, this.lease.nativeGeneration, id);
  }
  async cancelAndDrain(id: number): Promise<boolean> {
    this.loader.cancelSessionFileTransfer(this.lease.sessionId, this.lease.nativeGeneration, id);
    const deadline: number = Date.now() + 5000;
    while (Date.now() < deadline) {
      const status: SessionTransferStatus = this.status(id);
      if (status.transferId !== id || status.rustdeskTransferState === 0) { return false; }
      if ([3, 4, 5, 6].indexOf(status.rustdeskTransferState) >= 0) { return true; }
      await this.pause();
    }
    return false;
  }
  private async wait(id: number): Promise<SessionTransferStatus | null> {
    const deadline: number = Date.now() + 120000;
    while (this.isCurrent() && Date.now() < deadline) {
      const status: SessionTransferStatus = this.status(id);
      if (status.transferId !== id || status.rustdeskTransferState === 0) { return null; }
      this.onAuthentication(this.loader.getSessionTransferAuthentication(this.lease.sessionId, this.lease.nativeGeneration, id));
      if ([3, 4, 5, 6].indexOf(status.rustdeskTransferState) >= 0) { return status; }
      await this.pause();
    }
    return null;
  }
  async list(path: string): Promise<SessionRemoteDirectory | null> {
    if (!this.isCurrent()) { return null; }
    const id: number = this.loader.requestSessionRemoteDirectory(this.lease.sessionId, this.lease.nativeGeneration, path);
    if (id <= 0) { return null; }
    let drained: boolean = false;
    try {
      const status: SessionTransferStatus | null = await this.wait(id);
      drained = status !== null;
      if (!this.isCurrent() || status === null || [3, 6].indexOf(status.rustdeskTransferState) < 0) { return null; }
      return this.loader.getSessionRemoteDirectory(this.lease.sessionId, this.lease.nativeGeneration, id);
    } finally {
      if (!drained) { drained = await this.cancelAndDrain(id); }
      if (drained) { this.loader.releaseSessionFileTransfer(this.lease.sessionId, this.lease.nativeGeneration, id); }
    }
  }
  async mkdir(path: string): Promise<boolean> {
    if (!this.isCurrent()) { return false; }
    const id: number = this.loader.createSessionRemoteDirectory(this.lease.sessionId, this.lease.nativeGeneration, path);
    if (id <= 0) { return false; }
    let drained: boolean = false;
    try {
      const status: SessionTransferStatus | null = await this.wait(id);
      drained = status !== null;
      if (!this.isCurrent() || status === null || [3, 6].indexOf(status.rustdeskTransferState) < 0) { return false; }
      const result: SessionTransferResult = this.loader.getSessionTransferResult(this.lease.sessionId, this.lease.nativeGeneration, id);
      return result.operationKind === 4 && result.remoteOperationAcknowledged;
    } finally {
      if (!drained) { drained = await this.cancelAndDrain(id); }
      if (drained) { this.loader.releaseSessionFileTransfer(this.lease.sessionId, this.lease.nativeGeneration, id); }
    }
  }
}
