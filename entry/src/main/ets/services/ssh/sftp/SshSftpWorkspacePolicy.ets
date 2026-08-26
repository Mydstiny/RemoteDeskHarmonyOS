/** Pure state and validation policy for the M3 SFTP workbench surface. */

export type SshSftpPaneMode = 'single' | 'dual';
export type SshSftpPresentation = 'sheet' | 'workspace';
export type SshSftpWorkspaceSurface = 'terminal' | 'sftp';
export type SshSftpDropTarget = 'local' | 'ssh';

export interface SshSftpWorkspaceTabState {
  open: boolean;
  activeSurface: SshSftpWorkspaceSurface;
  ownerHostId: string;
  tabId: string;
}

export interface SshSftpPaneLayout {
  mode: SshSftpPaneMode;
  localPaneVisible: boolean;
  remotePaneVisible: boolean;
  dividerVisible: boolean;
  transferCenterOverlay: boolean;
}

export interface SshSftpDropItem {
  uri: string;
  name: string;
  size: number;
  isDirectory: boolean;
  isSymbolicLink: boolean;
  isSpecialFile: boolean;
  readable: boolean;
}

export interface SshSftpDropLimits {
  maxItems: number;
  maxSingleFileBytes: number;
  maxTotalBytes: number;
}

export type SshSftpDropRejectReason =
  | ''
  | 'empty'
  | 'too-many-items'
  | 'invalid-uri'
  | 'permission-denied'
  | 'unsupported-file-type'
  | 'invalid-size'
  | 'single-file-limit'
  | 'total-size-limit'
  | 'target-unavailable';

export interface SshSftpDropPlan {
  accepted: boolean;
  reason: SshSftpDropRejectReason;
  target: SshSftpDropTarget;
  itemCount: number;
  totalBytes: number;
  containsDirectory: boolean;
  requiresConflictConfirmation: boolean;
  actionLabel: string;
}

function boundedHostId(hostId: string): string {
  return hostId.trim().substring(0, 160);
}

/** Stable UI identity. Native session identity remains owned by the existing session store. */
export function sshSftpWorkspaceTabId(hostId: string): string {
  const normalized: string = boundedHostId(hostId);
  if (normalized.length === 0) { return ''; }
  let hash: number = 2166136261;
  for (let index: number = 0; index < normalized.length; index++) {
    hash ^= normalized.charCodeAt(index);
    hash = Math.imul(hash, 16777619) >>> 0;
  }
  return 'sftp:' + hash.toString(16);
}

export function createSshSftpWorkspaceTabState(): SshSftpWorkspaceTabState {
  return { open: false, activeSurface: 'terminal', ownerHostId: '', tabId: '' };
}

export function openSshSftpWorkspaceTab(current: SshSftpWorkspaceTabState,
  hostId: string): SshSftpWorkspaceTabState {
  const ownerHostId: string = boundedHostId(hostId);
  const tabId: string = sshSftpWorkspaceTabId(ownerHostId);
  if (ownerHostId.length === 0 || tabId.length === 0) { return current; }
  return { open: true, activeSurface: 'sftp', ownerHostId, tabId };
}

export function activateSshTerminalSurface(current: SshSftpWorkspaceTabState):
  SshSftpWorkspaceTabState {
  if (!current.open || current.activeSurface === 'terminal') { return current; }
  return {
    open: true,
    activeSurface: 'terminal',
    ownerHostId: current.ownerHostId,
    tabId: current.tabId
  };
}

export function activateSshSftpSurface(current: SshSftpWorkspaceTabState,
  currentHostId: string): SshSftpWorkspaceTabState {
  const hostId: string = boundedHostId(currentHostId);
  if (!current.open || hostId.length === 0 || current.ownerHostId !== hostId) { return current; }
  if (current.activeSurface === 'sftp') { return current; }
  return {
    open: true,
    activeSurface: 'sftp',
    ownerHostId: current.ownerHostId,
    tabId: current.tabId
  };
}

export function closeSshSftpWorkspaceTab(_current: SshSftpWorkspaceTabState):
  SshSftpWorkspaceTabState {
  return createSshSftpWorkspaceTabState();
}

/** PC keeps SFTP as a modal tool window; workbench tabs remain for touch devices. */
export function resolveSshSftpPresentation(workbenchEnabled: boolean,
  desktop: boolean): SshSftpPresentation {
  if (desktop) { return 'sheet'; }
  return workbenchEnabled ? 'workspace' : 'sheet';
}

/** Container width wins over device class so a 360vp PC window degrades safely. */
export function resolveSshSftpPaneLayout(containerWidthVp: number,
  deviceClass: 'phone' | 'pad' | 'pc'): SshSftpPaneLayout {
  const width: number = Number.isFinite(containerWidthVp) ? Math.max(0, containerWidthVp) : 0;
  const dual: boolean = deviceClass !== 'phone' && width >= 720;
  return {
    mode: dual ? 'dual' : 'single',
    localPaneVisible: true,
    remotePaneVisible: true,
    dividerVisible: dual,
    transferCenterOverlay: width < 980
  };
}

function rejectedDrop(reason: SshSftpDropRejectReason,
  target: SshSftpDropTarget): SshSftpDropPlan {
  return {
    accepted: false,
    reason,
    target,
    itemCount: 0,
    totalBytes: 0,
    containsDirectory: false,
    requiresConflictConfirmation: false,
    actionLabel: ''
  };
}

/** Cheap admission check used before a drop adapter opens any external URI. */
export function sshSftpDropRecordCountAllowed(recordCount: number, maxItems: number): boolean {
  const count: number = Number.isFinite(recordCount) ? Math.max(0, Math.floor(recordCount)) : 0;
  const limit: number = Number.isFinite(maxItems) ? Math.max(1, Math.floor(maxItems)) : 1;
  return count <= limit;
}

/**
 * Validate UDMF/Core File Kit metadata before any payload reaches the existing
 * transfer engine. Symlinks and special files fail closed; conflict handling
 * remains an explicit confirmation owned by the existing batch policy.
 */
export function planSshSftpExternalDrop(items: Array<SshSftpDropItem>,
  target: SshSftpDropTarget, targetAvailable: boolean, targetHasConflict: boolean,
  limits: SshSftpDropLimits): SshSftpDropPlan {
  if (!targetAvailable) { return rejectedDrop('target-unavailable', target); }
  if (items.length === 0) { return rejectedDrop('empty', target); }
  const maxSingle: number = Number.isFinite(limits.maxSingleFileBytes) ?
    Math.max(0, Math.floor(limits.maxSingleFileBytes)) : 0;
  const maxTotal: number = Number.isFinite(limits.maxTotalBytes) ?
    Math.max(0, Math.floor(limits.maxTotalBytes)) : 0;
  if (!sshSftpDropRecordCountAllowed(items.length, limits.maxItems)) {
    return rejectedDrop('too-many-items', target);
  }
  let totalBytes: number = 0;
  let containsDirectory: boolean = false;
  for (let index: number = 0; index < items.length; index++) {
    const item: SshSftpDropItem = items[index];
    if (item.uri.trim().length === 0 || item.name.trim().length === 0) {
      return rejectedDrop('invalid-uri', target);
    }
    if (!item.readable) { return rejectedDrop('permission-denied', target); }
    if (item.isSymbolicLink || item.isSpecialFile) {
      return rejectedDrop('unsupported-file-type', target);
    }
    if (!Number.isFinite(item.size) || item.size < 0) {
      return rejectedDrop('invalid-size', target);
    }
    if (!item.isDirectory && item.size > maxSingle) {
      return rejectedDrop('single-file-limit', target);
    }
    containsDirectory = containsDirectory || item.isDirectory;
    totalBytes += item.isDirectory ? 0 : Math.floor(item.size);
    if (!Number.isSafeInteger(totalBytes) || totalBytes > maxTotal) {
      return rejectedDrop('total-size-limit', target);
    }
  }
  return {
    accepted: true,
    reason: '',
    target,
    itemCount: items.length,
    totalBytes,
    containsDirectory,
    requiresConflictConfirmation: targetHasConflict,
    actionLabel: target === 'ssh' ? '上传到远端目录' : '导入到本机传输箱'
  };
}
