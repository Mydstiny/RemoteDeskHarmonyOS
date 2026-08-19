import {
  isValidSshSessionHandle,
  sameSshSessionHandle,
  SshSessionHandle
} from '../../SshSessionStore';

/**
 * A workspace reference is deliberately non-owning. SshSessionStore remains
 * the sole owner of native session identity and teardown.
 */
export interface SshWorkspaceRuntimeRef {
  tabId: string;
  hostId: string;
  sessionId: number;
  channelId: string;
  generation: number;
}

export interface SshWorkspaceRuntimeBindingResult {
  accepted: boolean;
  replaced: SshWorkspaceRuntimeRef | null;
  current: SshWorkspaceRuntimeRef | null;
  reason: string;
}

function validId(value: string): boolean {
  const normalized: string = value.trim();
  return normalized.length > 0 && normalized.length <= 96 &&
    /^[A-Za-z0-9._:-]+$/.test(normalized);
}

function cloneRef(ref: SshWorkspaceRuntimeRef): SshWorkspaceRuntimeRef {
  return {
    tabId: ref.tabId,
    hostId: ref.hostId,
    sessionId: ref.sessionId,
    channelId: ref.channelId,
    generation: ref.generation
  };
}

export function sshWorkspaceRuntimeRef(tabId: string, hostId: string,
  handle: SshSessionHandle): SshWorkspaceRuntimeRef | null {
  const normalizedTabId: string = tabId.trim();
  const normalizedHostId: string = hostId.trim();
  if (!validId(normalizedTabId) || !validId(normalizedHostId) ||
    !isValidSshSessionHandle(handle)) { return null; }
  return {
    tabId: normalizedTabId,
    hostId: normalizedHostId,
    sessionId: handle.sessionId,
    channelId: handle.channelId,
    generation: handle.generation
  };
}

export function sshWorkspaceRefHandle(ref: SshWorkspaceRuntimeRef): SshSessionHandle {
  return {
    sessionId: ref.sessionId,
    channelId: ref.channelId,
    generation: ref.generation
  };
}

/**
 * In-memory view binding only. Detach never closes or releases a session.
 */
export class SshWorkspaceRuntimeAdapter {
  private readonly refs: Map<string, SshWorkspaceRuntimeRef> =
    new Map<string, SshWorkspaceRuntimeRef>();

  bind(tabId: string, hostId: string,
    handle: SshSessionHandle): SshWorkspaceRuntimeBindingResult {
    const next: SshWorkspaceRuntimeRef | null =
      sshWorkspaceRuntimeRef(tabId, hostId, handle);
    if (next === null) {
      return { accepted: false, replaced: null, current: null, reason: '运行态引用无效' };
    }
    const existing: SshWorkspaceRuntimeRef | undefined = this.refs.get(next.tabId);
    if (existing !== undefined && existing.hostId !== next.hostId) {
      return {
        accepted: false,
        replaced: null,
        current: cloneRef(existing),
        reason: '标签已绑定到其他主机'
      };
    }
    if (existing !== undefined && existing.generation > next.generation) {
      return {
        accepted: false,
        replaced: null,
        current: cloneRef(existing),
        reason: '拒绝旧 generation 覆盖新会话'
      };
    }
    if (existing !== undefined && existing.generation === next.generation) {
      if (!sameSshSessionHandle(sshWorkspaceRefHandle(existing), handle)) {
        return {
          accepted: false,
          replaced: null,
          current: cloneRef(existing),
          reason: '拒绝同 generation 的不同会话覆盖当前绑定'
        };
      }
      return { accepted: true, replaced: null, current: cloneRef(existing), reason: '' };
    }
    const replaced: SshWorkspaceRuntimeRef | null = existing === undefined ? null : cloneRef(existing);
    this.refs.set(next.tabId, cloneRef(next));
    return { accepted: true, replaced, current: cloneRef(next), reason: '' };
  }

  detachIfCurrent(tabId: string, expectedHandle: SshSessionHandle): SshWorkspaceRuntimeRef | null {
    const normalizedTabId: string = tabId.trim();
    const existing: SshWorkspaceRuntimeRef | undefined = this.refs.get(normalizedTabId);
    if (existing === undefined || !isValidSshSessionHandle(expectedHandle) ||
      !sameSshSessionHandle(sshWorkspaceRefHandle(existing), expectedHandle)) { return null; }
    this.refs.delete(normalizedTabId);
    return cloneRef(existing);
  }

  get(tabId: string): SshWorkspaceRuntimeRef | null {
    const ref: SshWorkspaceRuntimeRef | undefined = this.refs.get(tabId.trim());
    return ref === undefined ? null : cloneRef(ref);
  }

  accepts(tabId: string, handle: SshSessionHandle): boolean {
    const ref: SshWorkspaceRuntimeRef | undefined = this.refs.get(tabId.trim());
    return ref !== undefined && sameSshSessionHandle(sshWorkspaceRefHandle(ref), handle);
  }

  refsForHost(hostId: string): Array<SshWorkspaceRuntimeRef> {
    const normalizedHostId: string = hostId.trim();
    const result: Array<SshWorkspaceRuntimeRef> = [];
    this.refs.forEach((ref: SshWorkspaceRuntimeRef): void => {
      if (ref.hostId === normalizedHostId) { result.push(cloneRef(ref)); }
    });
    return result;
  }

  size(): number {
    return this.refs.size;
  }

  clearViewBindings(): Array<SshWorkspaceRuntimeRef> {
    const detached: Array<SshWorkspaceRuntimeRef> = [];
    this.refs.forEach((ref: SshWorkspaceRuntimeRef): void => { detached.push(cloneRef(ref)); });
    this.refs.clear();
    return detached;
  }
}
