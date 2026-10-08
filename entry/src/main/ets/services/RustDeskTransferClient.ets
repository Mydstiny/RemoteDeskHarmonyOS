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
  // Each job's state, authentication and diagnostic code as they change: the file session is its own connection to
  // the peer (connect, authenticate, permission), and a failed listing otherwise leaves no trace of where it stopped.
  private log: (message: string) => void;
  /** Why the last list/mkdir did not succeed: the job's diagnostic, or a client-side code. */
  lastFailure: string = '';
  constructor(loader: ExtensionLoader, lease: ClipboardLease, isCurrent: () => boolean,
    onAuthentication: (snapshot: SessionTransferAuthentication) => void,
    log: (message: string) => void = (_message: string): void => {}) {
    this.loader = loader; this.lease = lease; this.isCurrent = isCurrent; this.onAuthentication = onAuthentication;
    this.log = log;
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
    // 120 seconds without progress: a long job (removing a large folder) keeps going while it advances.
    let deadline: number = Date.now() + 120000;
    let progressed: number = -1;
    let seen: string = '';
    while (this.isCurrent() && Date.now() < deadline) {
      const status: SessionTransferStatus = this.status(id);
      if (status.transferredBytes !== progressed) { progressed = status.transferredBytes; deadline = Date.now() + 120000; }
      if (status.transferId !== id || status.rustdeskTransferState === 0) {
        this.log('transfer id=' + id.toString() + ' lost state=' + status.rustdeskTransferState.toString() +
          ' reported=' + status.transferId.toString());
        return null;
      }
      const auth: SessionTransferAuthentication =
        this.loader.getSessionTransferAuthentication(this.lease.sessionId, this.lease.nativeGeneration, id);
      this.onAuthentication(auth);
      const signature: string = status.rustdeskTransferState.toString() + '|' + (status.diagnosticCode ?? '') + '|' +
        (auth.kind ?? 0).toString() + '|' + (auth.state ?? 0).toString() + '|' + (auth.diagnosticCode ?? 0).toString();
      if (signature !== seen) {
        seen = signature;
        this.log('transfer id=' + id.toString() + ' state=' + status.rustdeskTransferState.toString() +
          ' diag=' + (status.diagnosticCode ?? '') + ' authKind=' + (auth.kind ?? 0).toString() +
          ' authState=' + (auth.state ?? 0).toString() + ' authDiag=' + (auth.diagnosticCode ?? 0).toString() +
          ' authAttempts=' + (auth.attemptsRemaining ?? 0).toString());
      }
      if ([3, 4, 5, 6].indexOf(status.rustdeskTransferState) >= 0) { return status; }
      await this.pause();
    }
    this.log('transfer id=' + id.toString() + ' wait ended current=' + (this.isCurrent() ? '1' : '0') +
      ' last=' + seen);
    return null;
  }
  async list(path: string, includeHidden: boolean = false): Promise<SessionRemoteDirectory | null> {
    if (!this.isCurrent()) { return null; }
    const id: number = this.loader.requestSessionRemoteListing(this.lease.sessionId, this.lease.nativeGeneration, path,
      includeHidden);
    this.log('list request id=' + id.toString() + ' session=' + this.lease.sessionId.toString() +
      ' generation=' + this.lease.nativeGeneration.toString() + ' pathLength=' + path.length.toString());
    if (id <= 0) { this.lastFailure = 'enqueue_failed'; return null; }
    let drained: boolean = false;
    try {
      const status: SessionTransferStatus | null = await this.wait(id);
      drained = status !== null;
      if (!this.isCurrent() || status === null || [3, 6].indexOf(status.rustdeskTransferState) < 0) {
        this.lastFailure = status !== null ? (status.diagnosticCode ?? '') : 'lost';
        return null;
      }
      this.lastFailure = '';
      return this.loader.getSessionRemoteDirectory(this.lease.sessionId, this.lease.nativeGeneration, id);
    } finally {
      if (!drained) { drained = await this.cancelAndDrain(id); }
      if (drained) { this.loader.releaseSessionFileTransfer(this.lease.sessionId, this.lease.nativeGeneration, id); }
    }
  }
  /** Every file below `path`, names relative to it ('/' separated); folders without files are not listed. */
  async tree(path: string, includeHidden: boolean = true): Promise<SessionRemoteDirectory | null> {
    if (!this.isCurrent()) { return null; }
    const id: number = this.loader.requestSessionRemoteTree(this.lease.sessionId, this.lease.nativeGeneration, path,
      includeHidden);
    return await this.collectDirectory(id, 7);
  }
  /** Removes a file, or a folder with everything in it. */
  async remove(path: string, directory: boolean): Promise<boolean> {
    if (!this.isCurrent()) { return false; }
    return await this.acknowledged(
      this.loader.removeSessionRemotePath(this.lease.sessionId, this.lease.nativeGeneration, path, directory), 5);
  }
  /** Renames the file or folder at `path` to `newName` in the same folder. */
  async rename(path: string, newName: string): Promise<boolean> {
    if (!this.isCurrent()) { return false; }
    return await this.acknowledged(
      this.loader.renameSessionRemotePath(this.lease.sessionId, this.lease.nativeGeneration, path, newName), 6);
  }
  private async collectDirectory(id: number, operationKind: number): Promise<SessionRemoteDirectory | null> {
    if (id <= 0) { this.lastFailure = 'enqueue_failed'; return null; }
    let drained: boolean = false;
    try {
      const status: SessionTransferStatus | null = await this.wait(id);
      drained = status !== null;
      if (!this.isCurrent() || status === null || [3, 6].indexOf(status.rustdeskTransferState) < 0) {
        this.lastFailure = status !== null ? (status.diagnosticCode ?? '') : 'lost';
        return null;
      }
      const result: SessionTransferResult = this.loader.getSessionTransferResult(this.lease.sessionId,
        this.lease.nativeGeneration, id);
      if (result.operationKind !== operationKind) { this.lastFailure = 'lost'; return null; }
      this.lastFailure = '';
      return this.loader.getSessionRemoteDirectory(this.lease.sessionId, this.lease.nativeGeneration, id);
    } finally {
      if (!drained) { drained = await this.cancelAndDrain(id); }
      if (drained) { this.loader.releaseSessionFileTransfer(this.lease.sessionId, this.lease.nativeGeneration, id); }
    }
  }
  private async acknowledged(id: number, operationKind: number): Promise<boolean> {
    if (id <= 0) { this.lastFailure = 'enqueue_failed'; return false; }
    let drained: boolean = false;
    try {
      const status: SessionTransferStatus | null = await this.wait(id);
      drained = status !== null;
      if (!this.isCurrent() || status === null || [3, 6].indexOf(status.rustdeskTransferState) < 0) {
        this.lastFailure = status !== null ? (status.diagnosticCode ?? '') : 'lost';
        return false;
      }
      const result: SessionTransferResult = this.loader.getSessionTransferResult(this.lease.sessionId,
        this.lease.nativeGeneration, id);
      this.lastFailure = '';
      return result.operationKind === operationKind && result.remoteOperationAcknowledged;
    } finally {
      if (!drained) { drained = await this.cancelAndDrain(id); }
      if (drained) { this.loader.releaseSessionFileTransfer(this.lease.sessionId, this.lease.nativeGeneration, id); }
    }
  }
  async mkdir(path: string): Promise<boolean> {
    if (!this.isCurrent()) { return false; }
    const id: number = this.loader.createSessionRemoteDirectory(this.lease.sessionId, this.lease.nativeGeneration, path);
    if (id <= 0) { this.lastFailure = 'enqueue_failed'; return false; }
    let drained: boolean = false;
    try {
      const status: SessionTransferStatus | null = await this.wait(id);
      drained = status !== null;
      if (!this.isCurrent() || status === null || [3, 6].indexOf(status.rustdeskTransferState) < 0) {
        this.lastFailure = status !== null ? (status.diagnosticCode ?? '') : 'lost';
        return false;
      }
      const result: SessionTransferResult = this.loader.getSessionTransferResult(this.lease.sessionId, this.lease.nativeGeneration, id);
      return result.operationKind === 4 && result.remoteOperationAcknowledged;
    } finally {
      if (!drained) { drained = await this.cancelAndDrain(id); }
      if (drained) { this.loader.releaseSessionFileTransfer(this.lease.sessionId, this.lease.nativeGeneration, id); }
    }
  }
}
