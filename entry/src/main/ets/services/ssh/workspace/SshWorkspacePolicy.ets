export type SshWorkspaceTabKind = 'terminal' | 'sftp';
export type SshPaneDirection = 'horizontal' | 'vertical';
export type SshWorkspaceReconnectPolicy = 'never' | 'ask';

export interface SshWorkspaceTabV1 {
  tabId: string;
  kind: SshWorkspaceTabKind;
  hostId: string;
  titleOverride: string;
  profileId: string;
  pinned: boolean;
}

export interface SshPaneNodeV1 {
  nodeId: string;
  kind: 'leaf' | 'split';
  tabId: string;
  direction: SshPaneDirection;
  ratio: number;
  first: SshPaneNodeV1 | null;
  second: SshPaneNodeV1 | null;
}

export interface SshWorkspaceSnapshotV1 {
  schemaVersion: number;
  revision: number;
  workspaceId: string;
  name: string;
  tabs: Array<SshWorkspaceTabV1>;
  tabOrder: Array<string>;
  paneRoot: SshPaneNodeV1 | null;
  activeTabId: string;
  activePaneId: string;
  reconnectPolicy: SshWorkspaceReconnectPolicy;
  sidebarVisible: boolean;
  inspectorVisible: boolean;
  createdAt: number;
  updatedAt: number;
}

export type SshWorkspaceActionKind =
  | 'rename_workspace'
  | 'open_tab'
  | 'activate_tab'
  | 'close_tab'
  | 'reorder_tab'
  | 'set_tab_pinned'
  | 'rename_tab'
  | 'split_pane'
  | 'merge_pane'
  | 'move_tab'
  | 'focus_pane'
  | 'set_split_ratio'
  | 'set_reconnect_policy'
  | 'set_sidebar_visible'
  | 'set_inspector_visible';

export interface SshWorkspaceAction {
  kind: SshWorkspaceActionKind;
  nowMs?: number;
  name?: string;
  title?: string;
  tab?: SshWorkspaceTabV1;
  tabId?: string;
  beforeTabId?: string;
  pinned?: boolean;
  paneId?: string;
  splitNodeId?: string;
  newLeafId?: string;
  direction?: SshPaneDirection;
  ratio?: number;
  reconnectPolicy?: SshWorkspaceReconnectPolicy;
  visible?: boolean;
}

export type SshWorkspaceErrorCode =
  | 'invalid_action'
  | 'invalid_id'
  | 'duplicate_id'
  | 'not_found'
  | 'limit_reached'
  | 'invalid_snapshot'
  | 'unsupported_schema';

export interface SshWorkspaceError {
  code: SshWorkspaceErrorCode;
  action: SshWorkspaceActionKind;
  message: string;
}

export interface SshWorkspaceReduceResult {
  changed: boolean;
  snapshot: SshWorkspaceSnapshotV1;
  error: SshWorkspaceError | null;
}

export interface SshWorkspaceDecodeResult {
  snapshots: Array<SshWorkspaceSnapshotV1>;
  rejected: number;
  unsupported: number;
}

interface SshWorkspaceEnvelopeV1 {
  schemaVersion: number;
  items: Array<SshWorkspaceSnapshotV1>;
}

interface DecodedWorkspaceItem {
  snapshot: SshWorkspaceSnapshotV1 | null;
  unsupported: boolean;
}

export const SSH_WORKSPACE_SCHEMA_VERSION: number = 1;
export const SSH_WORKSPACE_MAX_TABS: number = 32;
export const SSH_WORKSPACE_MAX_VISIBLE_PANES: number = 4;
export const SSH_WORKSPACE_MAX_PANE_DEPTH: number = 8;
export const SSH_WORKSPACE_MAX_SERIALIZED_BYTES: number = 512 * 1024;

function validId(value: string): boolean {
  return value.length > 0 && value.length <= 96 && /^[A-Za-z0-9._:-]+$/.test(value);
}

function normalizedText(value: string, maxLength: number): string {
  return value.trim().substring(0, maxLength);
}

function cloneTab(tab: SshWorkspaceTabV1): SshWorkspaceTabV1 {
  return {
    tabId: tab.tabId,
    kind: tab.kind,
    hostId: tab.hostId,
    titleOverride: tab.titleOverride,
    profileId: tab.profileId,
    pinned: tab.pinned
  };
}

function clonePane(node: SshPaneNodeV1 | null): SshPaneNodeV1 | null {
  if (node === null) { return null; }
  return {
    nodeId: node.nodeId,
    kind: node.kind,
    tabId: node.tabId,
    direction: node.direction,
    ratio: node.ratio,
    first: clonePane(node.first),
    second: clonePane(node.second)
  };
}

export function cloneSshWorkspaceSnapshot(snapshot: SshWorkspaceSnapshotV1): SshWorkspaceSnapshotV1 {
  const tabs: Array<SshWorkspaceTabV1> = [];
  for (let index = 0; index < snapshot.tabs.length; index++) {
    tabs.push(cloneTab(snapshot.tabs[index]));
  }
  return {
    schemaVersion: snapshot.schemaVersion,
    revision: snapshot.revision,
    workspaceId: snapshot.workspaceId,
    name: snapshot.name,
    tabs,
    tabOrder: snapshot.tabOrder.slice(0),
    paneRoot: clonePane(snapshot.paneRoot),
    activeTabId: snapshot.activeTabId,
    activePaneId: snapshot.activePaneId,
    reconnectPolicy: snapshot.reconnectPolicy,
    sidebarVisible: snapshot.sidebarVisible,
    inspectorVisible: snapshot.inspectorVisible,
    createdAt: snapshot.createdAt,
    updatedAt: snapshot.updatedAt
  };
}

export function createEmptySshWorkspace(workspaceId: string, name: string,
  nowMs: number): SshWorkspaceSnapshotV1 {
  const normalizedId: string = normalizedText(workspaceId, 96);
  const normalizedName: string = normalizedText(name, 120);
  const timestamp: number = Number.isFinite(nowMs) && nowMs >= 0 ? Math.floor(nowMs) : 0;
  return {
    schemaVersion: SSH_WORKSPACE_SCHEMA_VERSION,
    revision: 0,
    workspaceId: validId(normalizedId) ? normalizedId : 'workspace-local',
    name: normalizedName.length > 0 ? normalizedName : 'SSH 工作区',
    tabs: [],
    tabOrder: [],
    paneRoot: null,
    activeTabId: '',
    activePaneId: '',
    reconnectPolicy: 'never',
    // Wide layouts start with the workspace navigator requested. LayoutPolicy
    // still suppresses it on phones, so one snapshot remains shape-neutral.
    sidebarVisible: true,
    inspectorVisible: false,
    createdAt: timestamp,
    updatedAt: timestamp
  };
}

function tabIndex(snapshot: SshWorkspaceSnapshotV1, tabId: string): number {
  for (let index = 0; index < snapshot.tabs.length; index++) {
    if (snapshot.tabs[index].tabId === tabId) { return index; }
  }
  return -1;
}

function paneById(node: SshPaneNodeV1 | null, paneId: string): SshPaneNodeV1 | null {
  if (node === null) { return null; }
  if (node.nodeId === paneId) { return node; }
  const first: SshPaneNodeV1 | null = paneById(node.first, paneId);
  return first !== null ? first : paneById(node.second, paneId);
}

function leafById(node: SshPaneNodeV1 | null, paneId: string): SshPaneNodeV1 | null {
  const pane: SshPaneNodeV1 | null = paneById(node, paneId);
  return pane !== null && pane.kind === 'leaf' ? pane : null;
}

function paneContainsTab(node: SshPaneNodeV1 | null, tabId: string): boolean {
  if (node === null) { return false; }
  if (node.kind === 'leaf') { return node.tabId === tabId; }
  return paneContainsTab(node.first, tabId) || paneContainsTab(node.second, tabId);
}

export function sshWorkspaceVisiblePaneCount(node: SshPaneNodeV1 | null): number {
  if (node === null) { return 0; }
  if (node.kind === 'leaf') { return 1; }
  return sshWorkspaceVisiblePaneCount(node.first) + sshWorkspaceVisiblePaneCount(node.second);
}

function firstLeaf(node: SshPaneNodeV1 | null): SshPaneNodeV1 | null {
  if (node === null || node.kind === 'leaf') { return node; }
  const first: SshPaneNodeV1 | null = firstLeaf(node.first);
  return first !== null ? first : firstLeaf(node.second);
}

function replaceLeafTab(node: SshPaneNodeV1 | null, paneId: string,
  tabId: string): SshPaneNodeV1 | null {
  if (node === null) { return null; }
  if (node.kind === 'leaf') {
    const copy: SshPaneNodeV1 = clonePane(node) as SshPaneNodeV1;
    if (node.nodeId === paneId) { copy.tabId = tabId; }
    return copy;
  }
  const copy: SshPaneNodeV1 = clonePane(node) as SshPaneNodeV1;
  copy.first = replaceLeafTab(node.first, paneId, tabId);
  copy.second = replaceLeafTab(node.second, paneId, tabId);
  return copy;
}

function replaceLeafWithSplit(node: SshPaneNodeV1 | null, paneId: string,
  splitNodeId: string, newLeafId: string, tabId: string,
  direction: SshPaneDirection, ratio: number): SshPaneNodeV1 | null {
  if (node === null) { return null; }
  if (node.kind === 'leaf') {
    if (node.nodeId !== paneId) { return clonePane(node); }
    return {
      nodeId: splitNodeId,
      kind: 'split',
      tabId: '',
      direction,
      ratio,
      first: clonePane(node),
      second: {
        nodeId: newLeafId,
        kind: 'leaf',
        tabId,
        direction: 'horizontal',
        ratio: 0.5,
        first: null,
        second: null
      }
    };
  }
  const copy: SshPaneNodeV1 = clonePane(node) as SshPaneNodeV1;
  copy.first = replaceLeafWithSplit(node.first, paneId, splitNodeId, newLeafId,
    tabId, direction, ratio);
  copy.second = replaceLeafWithSplit(node.second, paneId, splitNodeId, newLeafId,
    tabId, direction, ratio);
  return copy;
}

function removeLeafById(node: SshPaneNodeV1 | null, paneId: string): SshPaneNodeV1 | null {
  if (node === null) { return null; }
  if (node.kind === 'leaf') {
    return node.nodeId === paneId ? null : clonePane(node);
  }
  const first: SshPaneNodeV1 | null = removeLeafById(node.first, paneId);
  const second: SshPaneNodeV1 | null = removeLeafById(node.second, paneId);
  if (first === null) { return clonePane(second); }
  if (second === null) { return clonePane(first); }
  const copy: SshPaneNodeV1 = clonePane(node) as SshPaneNodeV1;
  copy.first = first;
  copy.second = second;
  return copy;
}

function removeLeavesByTab(node: SshPaneNodeV1 | null, tabId: string): SshPaneNodeV1 | null {
  if (node === null) { return null; }
  if (node.kind === 'leaf') {
    return node.tabId === tabId ? null : clonePane(node);
  }
  const first: SshPaneNodeV1 | null = removeLeavesByTab(node.first, tabId);
  const second: SshPaneNodeV1 | null = removeLeavesByTab(node.second, tabId);
  if (first === null) { return clonePane(second); }
  if (second === null) { return clonePane(first); }
  const copy: SshPaneNodeV1 = clonePane(node) as SshPaneNodeV1;
  copy.first = first;
  copy.second = second;
  return copy;
}

function updateSplitRatio(node: SshPaneNodeV1 | null, paneId: string,
  ratio: number): SshPaneNodeV1 | null {
  if (node === null) { return null; }
  const copy: SshPaneNodeV1 = clonePane(node) as SshPaneNodeV1;
  if (copy.nodeId === paneId && copy.kind === 'split') {
    copy.ratio = ratio;
    return copy;
  }
  copy.first = updateSplitRatio(node.first, paneId, ratio);
  copy.second = updateSplitRatio(node.second, paneId, ratio);
  return copy;
}

function stableIdToken(value: string): string {
  let hash: number = 5381;
  for (let index = 0; index < value.length; index++) {
    hash = (hash * 33 + value.charCodeAt(index)) % 2147483647;
  }
  return Math.floor(hash).toString(36);
}

function generatedPaneBaseId(workspaceId: string): string {
  return normalizedText(workspaceId, 60) + ':pane:' + stableIdToken(workspaceId);
}

function uniquePaneId(snapshot: SshWorkspaceSnapshotV1): string {
  const base: string = generatedPaneBaseId(snapshot.workspaceId);
  if (paneById(snapshot.paneRoot, base) === null) { return base; }
  let suffix: number = 2;
  while (paneById(snapshot.paneRoot, base + ':' + suffix.toString()) !== null) { suffix++; }
  return base + ':' + suffix.toString();
}

function nextTimestamp(snapshot: SshWorkspaceSnapshotV1, nowMs: number | undefined): number {
  if (nowMs !== undefined && Number.isFinite(nowMs) && nowMs >= snapshot.updatedAt) {
    return Math.floor(nowMs);
  }
  return snapshot.updatedAt + 1;
}

function errorResult(snapshot: SshWorkspaceSnapshotV1, action: SshWorkspaceAction,
  code: SshWorkspaceErrorCode, message: string): SshWorkspaceReduceResult {
  return {
    changed: false,
    snapshot,
    error: { code, action: action.kind, message }
  };
}

function successResult(snapshot: SshWorkspaceSnapshotV1, action: SshWorkspaceAction,
  next: SshWorkspaceSnapshotV1): SshWorkspaceReduceResult {
  next.revision = snapshot.revision + 1;
  next.updatedAt = nextTimestamp(snapshot, action.nowMs);
  return { changed: true, snapshot: next, error: null };
}

function normalizedTab(tab: SshWorkspaceTabV1): SshWorkspaceTabV1 | null {
  if (tab === null || tab === undefined || typeof tab.tabId !== 'string' ||
    typeof tab.hostId !== 'string' || typeof tab.kind !== 'string' ||
    typeof tab.titleOverride !== 'string' ||
    typeof tab.profileId !== 'string' || typeof tab.pinned !== 'boolean') {
    return null;
  }
  const tabId: string = normalizedText(tab.tabId, 96);
  const hostId: string = normalizedText(tab.hostId, 96);
  if (!validId(tabId) || !validId(hostId) || (tab.kind !== 'terminal' && tab.kind !== 'sftp')) {
    return null;
  }
  return {
    tabId,
    kind: tab.kind,
    hostId,
    titleOverride: normalizedText(tab.titleOverride, 160),
    profileId: normalizedText(tab.profileId, 96),
    pinned: tab.pinned
  };
}

export function reduceSshWorkspace(snapshot: SshWorkspaceSnapshotV1,
  action: SshWorkspaceAction): SshWorkspaceReduceResult {
  if (snapshot.schemaVersion !== SSH_WORKSPACE_SCHEMA_VERSION) {
    return errorResult(snapshot, action, 'unsupported_schema', '工作区版本不受支持');
  }
  if (validateSshWorkspaceSnapshot(snapshot).length > 0) {
    return errorResult(snapshot, action, 'invalid_snapshot', '工作区状态无效');
  }
  const next: SshWorkspaceSnapshotV1 = cloneSshWorkspaceSnapshot(snapshot);
  if (action.kind === 'rename_workspace') {
    const name: string = normalizedText(action.name === undefined ? '' : action.name, 120);
    if (name.length === 0) { return errorResult(snapshot, action, 'invalid_action', '工作区名称不能为空'); }
    if (name === snapshot.name) { return { changed: false, snapshot, error: null }; }
    next.name = name;
    return successResult(snapshot, action, next);
  }
  if (action.kind === 'open_tab') {
    if (action.tab === undefined) { return errorResult(snapshot, action, 'invalid_action', '缺少标签'); }
    const tab: SshWorkspaceTabV1 | null = normalizedTab(action.tab);
    if (tab === null) { return errorResult(snapshot, action, 'invalid_id', '标签字段无效'); }
    if (tabIndex(snapshot, tab.tabId) >= 0) {
      return errorResult(snapshot, action, 'duplicate_id', '标签 ID 已存在');
    }
    if (snapshot.tabs.length >= SSH_WORKSPACE_MAX_TABS) {
      return errorResult(snapshot, action, 'limit_reached', '工作区标签数量已达上限');
    }
    next.tabs.push(tab);
    next.tabOrder.push(tab.tabId);
    if (next.paneRoot === null) {
      const paneId: string = normalizedText(action.paneId === undefined ? '' : action.paneId, 96);
      if (!validId(paneId)) { return errorResult(snapshot, action, 'invalid_id', '首个 Pane ID 无效'); }
      next.paneRoot = {
        nodeId: paneId,
        kind: 'leaf',
        tabId: tab.tabId,
        direction: 'horizontal',
        ratio: 0.5,
        first: null,
        second: null
      };
      next.activePaneId = paneId;
    } else if (next.activePaneId !== '') {
      next.paneRoot = replaceLeafTab(next.paneRoot, next.activePaneId, tab.tabId);
    }
    next.activeTabId = tab.tabId;
    return successResult(snapshot, action, next);
  }
  const tabId: string = normalizedText(action.tabId === undefined ? '' : action.tabId, 96);
  if (action.kind === 'activate_tab') {
    if (tabIndex(snapshot, tabId) < 0) { return errorResult(snapshot, action, 'not_found', '标签不存在'); }
    next.activeTabId = tabId;
    if (next.activePaneId !== '') {
      next.paneRoot = replaceLeafTab(next.paneRoot, next.activePaneId, tabId);
    }
    return successResult(snapshot, action, next);
  }
  if (action.kind === 'close_tab') {
    const index: number = tabIndex(snapshot, tabId);
    if (index < 0) { return errorResult(snapshot, action, 'not_found', '标签不存在'); }
    next.tabs.splice(index, 1);
    const orderIndex: number = next.tabOrder.indexOf(tabId);
    if (orderIndex >= 0) { next.tabOrder.splice(orderIndex, 1); }
    next.paneRoot = removeLeavesByTab(next.paneRoot, tabId);
    if (next.tabs.length === 0) {
      next.activeTabId = '';
      next.activePaneId = '';
      next.paneRoot = null;
    } else {
      if (next.paneRoot === null) {
        const paneId: string = uniquePaneId(snapshot);
        next.paneRoot = {
          nodeId: paneId,
          kind: 'leaf',
          tabId: next.tabOrder[0],
          direction: 'horizontal',
          ratio: 0.5,
          first: null,
          second: null
        };
      }
      const activeLeaf: SshPaneNodeV1 | null = firstLeaf(next.paneRoot);
      next.activePaneId = activeLeaf === null ? '' : activeLeaf.nodeId;
      next.activeTabId = activeLeaf === null ? next.tabOrder[0] : activeLeaf.tabId;
    }
    return successResult(snapshot, action, next);
  }
  if (action.kind === 'reorder_tab') {
    const index: number = next.tabOrder.indexOf(tabId);
    if (index < 0) { return errorResult(snapshot, action, 'not_found', '标签不存在'); }
    const beforeTabId: string = normalizedText(action.beforeTabId === undefined ? '' : action.beforeTabId, 96);
    if (beforeTabId === tabId) { return { changed: false, snapshot, error: null }; }
    next.tabOrder.splice(index, 1);
    if (beforeTabId === '') {
      next.tabOrder.push(tabId);
    } else {
      const beforeIndex: number = next.tabOrder.indexOf(beforeTabId);
      if (beforeIndex < 0) { return errorResult(snapshot, action, 'not_found', '目标标签不存在'); }
      next.tabOrder.splice(beforeIndex, 0, tabId);
    }
    return successResult(snapshot, action, next);
  }
  if (action.kind === 'set_tab_pinned') {
    const index: number = tabIndex(snapshot, tabId);
    if (index < 0 || action.pinned === undefined) {
      return errorResult(snapshot, action, 'invalid_action', '固定标签参数无效');
    }
    if (next.tabs[index].pinned === action.pinned) { return { changed: false, snapshot, error: null }; }
    next.tabs[index].pinned = action.pinned;
    return successResult(snapshot, action, next);
  }
  if (action.kind === 'rename_tab') {
    const index: number = tabIndex(snapshot, tabId);
    if (index < 0 || action.title === undefined) {
      return errorResult(snapshot, action, 'invalid_action', '标签标题参数无效');
    }
    const title: string = normalizedText(action.title, 160);
    if (next.tabs[index].titleOverride === title) {
      return { changed: false, snapshot, error: null };
    }
    next.tabs[index].titleOverride = title;
    return successResult(snapshot, action, next);
  }
  const paneId: string = normalizedText(action.paneId === undefined ? '' : action.paneId, 96);
  if (action.kind === 'split_pane') {
    const splitNodeId: string = normalizedText(action.splitNodeId === undefined ? '' : action.splitNodeId, 96);
    const newLeafId: string = normalizedText(action.newLeafId === undefined ? '' : action.newLeafId, 96);
    if (!validId(paneId) || !validId(splitNodeId) || !validId(newLeafId) ||
      !validId(tabId) || (action.direction !== 'horizontal' && action.direction !== 'vertical') ||
      action.ratio === undefined || !Number.isFinite(action.ratio)) {
      return errorResult(snapshot, action, 'invalid_action', '分屏参数不完整');
    }
    if (leafById(snapshot.paneRoot, paneId) === null || tabIndex(snapshot, tabId) < 0) {
      return errorResult(snapshot, action, 'not_found', 'Pane 或标签不存在');
    }
    if (paneById(snapshot.paneRoot, splitNodeId) !== null || paneById(snapshot.paneRoot, newLeafId) !== null ||
      splitNodeId === newLeafId) {
      return errorResult(snapshot, action, 'duplicate_id', 'Pane ID 已存在');
    }
    if (paneContainsTab(snapshot.paneRoot, tabId)) {
      return errorResult(snapshot, action, 'duplicate_id', '同一标签不能同时显示在多个 Pane');
    }
    if (sshWorkspaceVisiblePaneCount(snapshot.paneRoot) >= SSH_WORKSPACE_MAX_VISIBLE_PANES) {
      return errorResult(snapshot, action, 'limit_reached', '可见 Pane 数量已达上限');
    }
    const ratio: number = Math.max(0.2, Math.min(0.8, action.ratio));
    next.paneRoot = replaceLeafWithSplit(next.paneRoot, paneId, splitNodeId, newLeafId,
      tabId, action.direction, ratio);
    next.activePaneId = newLeafId;
    next.activeTabId = tabId;
    return successResult(snapshot, action, next);
  }
  if (action.kind === 'merge_pane') {
    if (leafById(snapshot.paneRoot, paneId) === null) {
      return errorResult(snapshot, action, 'not_found', 'Pane 不存在');
    }
    if (sshWorkspaceVisiblePaneCount(snapshot.paneRoot) <= 1) {
      return errorResult(snapshot, action, 'invalid_action', '最后一个 Pane 不能合并');
    }
    next.paneRoot = removeLeafById(next.paneRoot, paneId);
    const activeLeaf: SshPaneNodeV1 | null = firstLeaf(next.paneRoot);
    next.activePaneId = activeLeaf === null ? '' : activeLeaf.nodeId;
    next.activeTabId = activeLeaf === null ? '' : activeLeaf.tabId;
    return successResult(snapshot, action, next);
  }
  if (action.kind === 'move_tab') {
    const target: SshPaneNodeV1 | null = leafById(snapshot.paneRoot, paneId);
    if (target === null || tabIndex(snapshot, tabId) < 0) {
      return errorResult(snapshot, action, 'not_found', 'Pane 或标签不存在');
    }
    let sourcePaneId: string = '';
    const findSource = (node: SshPaneNodeV1 | null): void => {
      if (node === null || sourcePaneId !== '') { return; }
      if (node.kind === 'leaf' && node.tabId === tabId) { sourcePaneId = node.nodeId; return; }
      findSource(node.first);
      findSource(node.second);
    };
    findSource(snapshot.paneRoot);
    if (sourcePaneId === paneId) { return { changed: false, snapshot, error: null }; }
    next.paneRoot = replaceLeafTab(next.paneRoot, paneId, tabId);
    if (sourcePaneId !== '') {
      next.paneRoot = replaceLeafTab(next.paneRoot, sourcePaneId, target.tabId);
    }
    next.activePaneId = paneId;
    next.activeTabId = tabId;
    return successResult(snapshot, action, next);
  }
  if (action.kind === 'focus_pane') {
    const target: SshPaneNodeV1 | null = leafById(snapshot.paneRoot, paneId);
    if (target === null) { return errorResult(snapshot, action, 'not_found', 'Pane 不存在'); }
    next.activePaneId = paneId;
    next.activeTabId = target.tabId;
    return successResult(snapshot, action, next);
  }
  if (action.kind === 'set_split_ratio') {
    const target: SshPaneNodeV1 | null = paneById(snapshot.paneRoot, paneId);
    if (target === null || target.kind !== 'split' || action.ratio === undefined ||
      !Number.isFinite(action.ratio)) {
      return errorResult(snapshot, action, 'invalid_action', '分屏比例参数无效');
    }
    next.paneRoot = updateSplitRatio(next.paneRoot, paneId,
      Math.max(0.2, Math.min(0.8, action.ratio)));
    return successResult(snapshot, action, next);
  }
  if (action.kind === 'set_reconnect_policy') {
    if (action.reconnectPolicy !== 'never' && action.reconnectPolicy !== 'ask') {
      return errorResult(snapshot, action, 'invalid_action', '恢复策略无效');
    }
    next.reconnectPolicy = action.reconnectPolicy;
    return successResult(snapshot, action, next);
  }
  if (action.kind === 'set_sidebar_visible' || action.kind === 'set_inspector_visible') {
    if (action.visible === undefined) {
      return errorResult(snapshot, action, 'invalid_action', '可见性参数无效');
    }
    if (action.kind === 'set_sidebar_visible') { next.sidebarVisible = action.visible; }
    else { next.inspectorVisible = action.visible; }
    return successResult(snapshot, action, next);
  }
  return errorResult(snapshot, action, 'invalid_action', '未知工作区动作');
}

function collectPaneValidation(node: SshPaneNodeV1 | null, tabIds: Set<string>,
  paneIds: Set<string>, visibleTabs: Set<string>, depth: number,
  errors: Array<string>): void {
  if (node === null) { return; }
  if (depth > SSH_WORKSPACE_MAX_PANE_DEPTH) { errors.push('pane_depth'); return; }
  if (!validId(node.nodeId) || paneIds.has(node.nodeId)) { errors.push('pane_id'); return; }
  paneIds.add(node.nodeId);
  if (node.kind === 'leaf') {
    if (!tabIds.has(node.tabId) || visibleTabs.has(node.tabId) || node.first !== null || node.second !== null) {
      errors.push('pane_leaf');
      return;
    }
    visibleTabs.add(node.tabId);
    return;
  }
  if (node.kind !== 'split' || node.first === null || node.second === null ||
    (node.direction !== 'horizontal' && node.direction !== 'vertical') ||
    !Number.isFinite(node.ratio) || node.ratio < 0.2 || node.ratio > 0.8) {
    errors.push('pane_split');
    return;
  }
  collectPaneValidation(node.first, tabIds, paneIds, visibleTabs, depth + 1, errors);
  collectPaneValidation(node.second, tabIds, paneIds, visibleTabs, depth + 1, errors);
}

export function validateSshWorkspaceSnapshot(snapshot: SshWorkspaceSnapshotV1): Array<string> {
  const errors: Array<string> = [];
  if (snapshot.schemaVersion !== SSH_WORKSPACE_SCHEMA_VERSION) { errors.push('schema'); }
  if (!validId(snapshot.workspaceId) || normalizedText(snapshot.name, 120).length === 0) {
    errors.push('identity');
  }
  if (!Number.isInteger(snapshot.revision) || snapshot.revision < 0 ||
    !Number.isFinite(snapshot.createdAt) || !Number.isFinite(snapshot.updatedAt) ||
    snapshot.updatedAt < snapshot.createdAt) { errors.push('revision'); }
  if (snapshot.tabs.length > SSH_WORKSPACE_MAX_TABS) { errors.push('tab_limit'); }
  const tabIds: Set<string> = new Set<string>();
  for (let index = 0; index < snapshot.tabs.length; index++) {
    const tab: SshWorkspaceTabV1 | null = normalizedTab(snapshot.tabs[index]);
    if (tab === null || tabIds.has(snapshot.tabs[index].tabId)) { errors.push('tab'); continue; }
    tabIds.add(tab.tabId);
  }
  const orderIds: Set<string> = new Set<string>();
  for (let index = 0; index < snapshot.tabOrder.length; index++) {
    const id: string = snapshot.tabOrder[index];
    if (!tabIds.has(id) || orderIds.has(id)) { errors.push('tab_order'); continue; }
    orderIds.add(id);
  }
  if (orderIds.size !== tabIds.size) { errors.push('tab_order_size'); }
  const paneIds: Set<string> = new Set<string>();
  const visibleTabs: Set<string> = new Set<string>();
  collectPaneValidation(snapshot.paneRoot, tabIds, paneIds, visibleTabs, 0, errors);
  if (visibleTabs.size > SSH_WORKSPACE_MAX_VISIBLE_PANES) { errors.push('pane_limit'); }
  if (snapshot.tabs.length === 0 && snapshot.paneRoot !== null) { errors.push('empty_pane'); }
  if (snapshot.tabs.length > 0 && snapshot.paneRoot === null) { errors.push('missing_pane'); }
  if (snapshot.tabs.length === 0) {
    if (snapshot.activeTabId !== '') { errors.push('active_tab'); }
    if (snapshot.activePaneId !== '') { errors.push('active_pane'); }
  } else {
    const activeLeaf: SshPaneNodeV1 | null = leafById(snapshot.paneRoot, snapshot.activePaneId);
    if (activeLeaf === null) { errors.push('active_pane'); }
    if (!tabIds.has(snapshot.activeTabId) || activeLeaf === null ||
      activeLeaf.tabId !== snapshot.activeTabId) { errors.push('active_tab'); }
  }
  if (snapshot.reconnectPolicy !== 'never' && snapshot.reconnectPolicy !== 'ask') {
    errors.push('reconnect_policy');
  }
  return errors;
}

function decodePane(source: SshPaneNodeV1 | null, validTabIds: Set<string>,
  usedPaneIds: Set<string>, usedTabIds: Set<string>, depth: number): SshPaneNodeV1 | null {
  if (source === null || source === undefined || typeof source !== 'object' ||
    depth > SSH_WORKSPACE_MAX_PANE_DEPTH || typeof source.nodeId !== 'string' ||
    typeof source.kind !== 'string') { return null; }
  const nodeId: string = normalizedText(source.nodeId, 96);
  if (!validId(nodeId) || usedPaneIds.has(nodeId)) { return null; }
  if (source.kind === 'leaf') {
    if (typeof source.tabId !== 'string') { return null; }
    const tabId: string = normalizedText(source.tabId, 96);
    if (!validTabIds.has(tabId) || usedTabIds.has(tabId)) { return null; }
    usedPaneIds.add(nodeId);
    usedTabIds.add(tabId);
    return {
      nodeId,
      kind: 'leaf',
      tabId,
      direction: 'horizontal',
      ratio: 0.5,
      first: null,
      second: null
    };
  }
  if (source.kind !== 'split' || source.first === null || source.second === null ||
    (source.direction !== 'horizontal' && source.direction !== 'vertical') ||
    typeof source.ratio !== 'number' || !Number.isFinite(source.ratio)) { return null; }
  usedPaneIds.add(nodeId);
  const first: SshPaneNodeV1 | null = decodePane(source.first, validTabIds,
    usedPaneIds, usedTabIds, depth + 1);
  const second: SshPaneNodeV1 | null = decodePane(source.second, validTabIds,
    usedPaneIds, usedTabIds, depth + 1);
  if (first === null || second === null) {
    usedPaneIds.delete(nodeId);
    return first === null ? second : first;
  }
  return {
    nodeId,
    kind: 'split',
    tabId: '',
    direction: source.direction,
    ratio: Math.max(0.2, Math.min(0.8, source.ratio)),
    first,
    second
  };
}

function decodeWorkspaceItem(source: SshWorkspaceSnapshotV1): DecodedWorkspaceItem {
  if (source === null || source === undefined || typeof source !== 'object' ||
    typeof source.schemaVersion !== 'number') {
    return { snapshot: null, unsupported: false };
  }
  if (source.schemaVersion !== SSH_WORKSPACE_SCHEMA_VERSION) {
    return { snapshot: null, unsupported: source.schemaVersion > SSH_WORKSPACE_SCHEMA_VERSION };
  }
  if (typeof source.workspaceId !== 'string' || typeof source.name !== 'string' ||
    !Array.isArray(source.tabs) || !Array.isArray(source.tabOrder)) {
    return { snapshot: null, unsupported: false };
  }
  const workspaceId: string = normalizedText(source.workspaceId, 96);
  const name: string = normalizedText(source.name, 120);
  if (!validId(workspaceId) || name.length === 0) { return { snapshot: null, unsupported: false }; }
  const tabs: Array<SshWorkspaceTabV1> = [];
  const tabIds: Set<string> = new Set<string>();
  for (let index = 0; index < source.tabs.length && tabs.length < SSH_WORKSPACE_MAX_TABS; index++) {
    const tab: SshWorkspaceTabV1 | null = normalizedTab(source.tabs[index]);
    if (tab === null || tabIds.has(tab.tabId)) { continue; }
    tabs.push(tab);
    tabIds.add(tab.tabId);
  }
  const tabOrder: Array<string> = [];
  for (let index = 0; index < source.tabOrder.length; index++) {
    const id: string = typeof source.tabOrder[index] === 'string' ?
      normalizedText(source.tabOrder[index], 96) : '';
    if (tabIds.has(id) && tabOrder.indexOf(id) < 0) { tabOrder.push(id); }
  }
  for (let index = 0; index < tabs.length; index++) {
    if (tabOrder.indexOf(tabs[index].tabId) < 0) { tabOrder.push(tabs[index].tabId); }
  }
  const usedPaneIds: Set<string> = new Set<string>();
  const usedTabIds: Set<string> = new Set<string>();
  let paneRoot: SshPaneNodeV1 | null = decodePane(source.paneRoot, tabIds,
    usedPaneIds, usedTabIds, 0);
  if (tabs.length > 0 && paneRoot === null) {
    const paneId: string = generatedPaneBaseId(workspaceId);
    paneRoot = {
      nodeId: paneId,
      kind: 'leaf',
      tabId: tabOrder[0],
      direction: 'horizontal',
      ratio: 0.5,
      first: null,
      second: null
    };
    usedPaneIds.add(paneId);
  }
  if (tabs.length === 0) { paneRoot = null; }
  const first: SshPaneNodeV1 | null = firstLeaf(paneRoot);
  const requestedActivePane: SshPaneNodeV1 | null = typeof source.activePaneId === 'string' ?
    leafById(paneRoot, source.activePaneId) : null;
  const activePaneId: string = requestedActivePane === null ?
    (first === null ? '' : first.nodeId) : requestedActivePane.nodeId;
  const activePane: SshPaneNodeV1 | null = leafById(paneRoot, activePaneId);
  const activeTabId: string = activePane === null ? '' : activePane.tabId;
  const createdAt: number = typeof source.createdAt === 'number' && Number.isFinite(source.createdAt) &&
    source.createdAt >= 0 ? Math.floor(source.createdAt) : 0;
  const updatedAt: number = typeof source.updatedAt === 'number' && Number.isFinite(source.updatedAt) &&
    source.updatedAt >= createdAt ? Math.floor(source.updatedAt) : createdAt;
  const snapshot: SshWorkspaceSnapshotV1 = {
    schemaVersion: SSH_WORKSPACE_SCHEMA_VERSION,
    revision: typeof source.revision === 'number' && Number.isInteger(source.revision) &&
      source.revision >= 0 ? source.revision : 0,
    workspaceId,
    name,
    tabs,
    tabOrder,
    paneRoot,
    activeTabId,
    activePaneId,
    reconnectPolicy: source.reconnectPolicy === 'ask' ? 'ask' : 'never',
    sidebarVisible: source.sidebarVisible === true,
    inspectorVisible: source.inspectorVisible === true,
    createdAt,
    updatedAt
  };
  return validateSshWorkspaceSnapshot(snapshot).length === 0 ?
    { snapshot, unsupported: false } : { snapshot: null, unsupported: false };
}

export function encodeSshWorkspaceSnapshots(snapshots: Array<SshWorkspaceSnapshotV1>): string {
  const clean: Array<SshWorkspaceSnapshotV1> = [];
  for (let index = 0; index < snapshots.length; index++) {
    if (validateSshWorkspaceSnapshot(snapshots[index]).length === 0) {
      clean.push(cloneSshWorkspaceSnapshot(snapshots[index]));
    }
  }
  const envelope: SshWorkspaceEnvelopeV1 = {
    schemaVersion: SSH_WORKSPACE_SCHEMA_VERSION,
    items: clean
  };
  return JSON.stringify(envelope);
}

export function decodeSshWorkspaceSnapshots(raw: string): SshWorkspaceDecodeResult {
  if (raw.trim().length === 0 || raw.length > SSH_WORKSPACE_MAX_SERIALIZED_BYTES) {
    return { snapshots: [], rejected: 0, unsupported: 0 };
  }
  try {
    const envelope: SshWorkspaceEnvelopeV1 = JSON.parse(raw) as SshWorkspaceEnvelopeV1;
    if (envelope === null || envelope === undefined || typeof envelope !== 'object' ||
      envelope.schemaVersion !== SSH_WORKSPACE_SCHEMA_VERSION || !Array.isArray(envelope.items)) {
      return { snapshots: [], rejected: 1, unsupported: 0 };
    }
    const snapshots: Array<SshWorkspaceSnapshotV1> = [];
    let rejected: number = 0;
    let unsupported: number = 0;
    const workspaceIds: Set<string> = new Set<string>();
    for (let index = 0; index < envelope.items.length; index++) {
      const decoded: DecodedWorkspaceItem = decodeWorkspaceItem(envelope.items[index]);
      if (decoded.snapshot === null) {
        if (decoded.unsupported) { unsupported++; } else { rejected++; }
        continue;
      }
      if (workspaceIds.has(decoded.snapshot.workspaceId)) { rejected++; continue; }
      workspaceIds.add(decoded.snapshot.workspaceId);
      snapshots.push(decoded.snapshot);
    }
    return { snapshots, rejected, unsupported };
  } catch (_error) {
    return { snapshots: [], rejected: 1, unsupported: 0 };
  }
}
