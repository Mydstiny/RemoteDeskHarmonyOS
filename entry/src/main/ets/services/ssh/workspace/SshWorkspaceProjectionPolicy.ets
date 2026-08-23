import {
  cloneSshWorkspaceSnapshot,
  createEmptySshWorkspace,
  reduceSshWorkspace,
  SshPaneNodeV1,
  SshWorkspaceReduceResult,
  SshWorkspaceSnapshotV1,
  SshWorkspaceTabV1,
  sshWorkspaceVisiblePaneCount
} from './SshWorkspacePolicy';

export interface SshWorkspaceRuntimeTabProjection {
  tabId: string;
  hostId: string;
  title: string;
  profileId: string;
  pinned: boolean;
  active: boolean;
}

function tabIndex(snapshot: SshWorkspaceSnapshotV1, tabId: string): number {
  for (let index: number = 0; index < snapshot.tabs.length; index++) {
    if (snapshot.tabs[index].tabId === tabId) { return index; }
  }
  return -1;
}

function leafForTab(node: SshPaneNodeV1 | null, tabId: string): SshPaneNodeV1 | null {
  if (node === null) { return null; }
  if (node.kind === 'leaf') { return node.tabId === tabId ? node : null; }
  const first: SshPaneNodeV1 | null = leafForTab(node.first, tabId);
  return first === null ? leafForTab(node.second, tabId) : first;
}

function applyChanged(snapshot: SshWorkspaceSnapshotV1,
  result: SshWorkspaceReduceResult): SshWorkspaceSnapshotV1 {
  return result.changed && result.error === null ? result.snapshot : snapshot;
}

/**
 * A saved split tree is historical UI state, not permission to reopen several
 * work surfaces. Keep every tab, but start a new window with the selected tab
 * in one Pane; split commands in the live window remain unaffected.
 */
export function collapseRestoredSshWorkspacePanes(snapshot: SshWorkspaceSnapshotV1,
  nowMs: number): SshWorkspaceSnapshotV1 {
  if (sshWorkspaceVisiblePaneCount(snapshot.paneRoot) <= 1 ||
    snapshot.activeTabId.length === 0 || snapshot.activePaneId.length === 0) {
    return snapshot;
  }
  const next: SshWorkspaceSnapshotV1 = cloneSshWorkspaceSnapshot(snapshot);
  next.paneRoot = {
    nodeId: snapshot.activePaneId,
    kind: 'leaf',
    tabId: snapshot.activeTabId,
    direction: 'horizontal',
    ratio: 0.5,
    first: null,
    second: null
  };
  next.revision = snapshot.revision + 1;
  next.updatedAt = Number.isFinite(nowMs) && nowMs >= snapshot.updatedAt ?
    Math.floor(nowMs) : snapshot.updatedAt + 1;
  return next;
}

/**
 * Adds live page tabs to a durable workspace without deleting restored
 * placeholders. The caller still owns authentication and connection; this
 * projection never opens a native session or requests automatic reconnect.
 */
export function reconcileSshWorkspaceRuntimeTabs(
  restored: SshWorkspaceSnapshotV1 | null,
  runtimeTabs: Array<SshWorkspaceRuntimeTabProjection>,
  activeHostId: string,
  nowMs: number,
  workspaceId: string = 'ssh-default'
): SshWorkspaceSnapshotV1 {
  let snapshot: SshWorkspaceSnapshotV1 = restored === null ?
    createEmptySshWorkspace(workspaceId, 'SSH 工作区', nowMs) : restored;
  for (let index: number = 0; index < runtimeTabs.length; index++) {
    const runtime: SshWorkspaceRuntimeTabProjection = runtimeTabs[index];
    const existingIndex: number = tabIndex(snapshot, runtime.tabId);
    if (existingIndex < 0) {
      const tab: SshWorkspaceTabV1 = {
        tabId: runtime.tabId,
        kind: 'terminal',
        hostId: runtime.hostId,
        titleOverride: runtime.title.trim().substring(0, 160),
        profileId: runtime.profileId.trim().substring(0, 96),
        pinned: runtime.pinned
      };
      snapshot = applyChanged(snapshot, reduceSshWorkspace(snapshot, {
        kind: 'open_tab',
        tab,
        paneId: snapshot.paneRoot === null ? 'ssh-pane-root' : undefined,
        nowMs: nowMs + index
      }));
      continue;
    }
    if (snapshot.tabs[existingIndex].pinned !== runtime.pinned) {
      snapshot = applyChanged(snapshot, reduceSshWorkspace(snapshot, {
        kind: 'set_tab_pinned', tabId: runtime.tabId, pinned: runtime.pinned,
        nowMs: nowMs + index
      }));
    }
  }
  const activeHost: string = activeHostId.trim();
  if (activeHost.length === 0) { return snapshot; }
  let activeTabId: string = '';
  for (let index: number = 0; index < runtimeTabs.length; index++) {
    if (runtimeTabs[index].hostId.trim() === activeHost) {
      activeTabId = runtimeTabs[index].tabId;
      break;
    }
  }
  if (activeTabId.length === 0 || activeTabId === snapshot.activeTabId) { return snapshot; }
  const visibleLeaf: SshPaneNodeV1 | null = leafForTab(snapshot.paneRoot, activeTabId);
  if (visibleLeaf !== null) {
    return applyChanged(snapshot, reduceSshWorkspace(snapshot, {
      kind: 'focus_pane', paneId: visibleLeaf.nodeId, nowMs: nowMs + runtimeTabs.length
    }));
  }
  return applyChanged(snapshot, reduceSshWorkspace(snapshot, {
    kind: 'activate_tab', tabId: activeTabId, nowMs: nowMs + runtimeTabs.length
  }));
}

export function sshWorkspaceRuntimeProjection(
  tabId: string, hostId: string, title: string, profileId: string,
  pinned: boolean, active: boolean
): SshWorkspaceRuntimeTabProjection {
  return { tabId, hostId, title, profileId, pinned, active };
}
