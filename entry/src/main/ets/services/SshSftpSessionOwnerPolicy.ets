export interface SshSftpEngineSession {
  hostId: string;
  sessionId: number;
  generation: number;
}

/** Live SFTP session identity owned by one recovered native transport. */
export interface SshSftpTrackedSession extends SshSftpEngineSession {
  recoveryEpoch: number;
}

/**
 * Object-identity fence for active SFTP transports.
 *
 * A recovered transport deliberately receives a new object even when native
 * keeps the same sessionId/generation. Async callbacks retain the old object,
 * so they cannot invalidate the recovered owner after it is attached.
 */
export class SshSftpSessionOwnerPolicy {
  private readonly active: Map<string, SshSftpTrackedSession> =
    new Map<string, SshSftpTrackedSession>();
  private readonly lost: Map<string, SshSftpTrackedSession> =
    new Map<string, SshSftpTrackedSession>();

  attach(hostId: string, sessionId: number, generation: number,
    recoveryEpoch: number): SshSftpTrackedSession {
    const owner: string = hostId.trim();
    const current: SshSftpTrackedSession | undefined = this.active.get(owner);
    if (current !== undefined && current.sessionId === sessionId &&
      current.generation === generation && current.recoveryEpoch >= recoveryEpoch &&
      !this.lost.has(owner)) {
      return current;
    }
    const next: SshSftpTrackedSession = {
      hostId: owner,
      sessionId,
      generation,
      recoveryEpoch: Math.max(recoveryEpoch,
        current === undefined ? 0 : current.recoveryEpoch)
    };
    this.active.set(owner, next);
    this.lost.delete(owner);
    return next;
  }

  current(hostId: string): SshSftpTrackedSession | null {
    return this.active.get(hostId.trim()) || null;
  }

  detach(hostId: string, sessionId: number): boolean {
    const owner: string = hostId.trim();
    const current: SshSftpTrackedSession | undefined = this.active.get(owner);
    if (current === undefined || current.sessionId !== sessionId) { return false; }
    this.active.delete(owner);
    return true;
  }

  markTransportLost(session: SshSftpTrackedSession): boolean {
    const current: SshSftpTrackedSession | undefined = this.active.get(session.hostId);
    const priorLost: SshSftpTrackedSession | undefined = this.lost.get(session.hostId);
    if ((current !== undefined && current !== session) ||
      (current === undefined && priorLost !== undefined && priorLost !== session)) {
      return false;
    }
    this.lost.set(session.hostId, session);
    if (current === session) { this.active.delete(session.hostId); }
    return true;
  }

  isCurrent(hostId: string, session: SshSftpTrackedSession): boolean {
    return this.active.get(hostId.trim()) === session &&
      this.lost.get(hostId.trim()) !== session;
  }

  discardIfCurrent(hostId: string, session: SshSftpTrackedSession): void {
    const owner: string = hostId.trim();
    if (this.active.get(owner) === session) { this.active.delete(owner); }
  }
}
