import { MAX_WORKSPACES, missingWorkspaceRefs, newWorkspace, sortedEntries, Workspace, WORKSPACE_COLORS,
  WORKSPACE_ICONS, WorkspaceEntry, workspaceLayoutLabel } from '../../../services/pro/workspace/WorkspacePolicy';
import { WorkspaceStore } from '../../../services/pro/workspace/WorkspaceStore';
import { captureWorkspace, WorkspaceCaptureSession } from '../../../services/pro/workspace/WorkspaceCapture';
import { orgProtocolLabel, OrgHostRow } from '../../../services/pro/org/HostOrganizationDirectory';
import { currentWorkspaceDeviceKind, workspaceEntryLimit } from '../../../services/pro/workspace/WorkspaceDevicePolicy';

/** Shared actions of the home workspace entries (flat strip and category card). */
export function workspaceTint(color: string, alpha: string): string {
  return /^#[0-9A-Fa-f]{6}$/.test(color) ? '#' + alpha + color.substring(1) : color;
}

export function workspaceProtocols(workspace: Workspace): string[] {
  const result: string[] = [];
  sortedEntries(workspace.entries).forEach((entry: WorkspaceEntry): void => {
    const label: string = orgProtocolLabel(entry.protocol);
    if (result.indexOf(label) < 0) { result.push(label); }
  });
  return result.slice(0, 4);
}

export function workspaceSubtitle(workspace: Workspace, rows: OrgHostRow[]): string {
  const missing: number = missingWorkspaceRefs(workspace, rows.map((row: OrgHostRow): string => row.ref)).length;
  return workspace.entries.length.toString() + ' 个会话 · ' + workspaceLayoutLabel(workspace.layout) +
    (missing > 0 ? ' · ' + missing.toString() + ' 台已删除' : '');
}

/** First "<base> N" that no workspace uses yet (two devices can create 工作区 1 before they sync). */
function freeName(base: string): string {
  const names: string[] = WorkspaceStore.getInstance().list().map((item: Workspace): string => item.name);
  for (let index: number = 1; index <= MAX_WORKSPACES + 1; index++) {
    const name: string = base + ' ' + index.toString();
    if (names.indexOf(name) < 0) { return name; }
  }
  return base;
}

function toast(ui: UIContext, message: string): void { ui.getPromptAction().showToast({ message, duration: 1800 }); }

/** Creates an empty workspace; returns it so the caller can open the editor. */
export function createWorkspace(ui: UIContext): Workspace | null {
  const store: WorkspaceStore = WorkspaceStore.getInstance();
  if (!store.canAdd()) { toast(ui, '最多 ' + MAX_WORKSPACES.toString() + ' 个工作区'); return null; }
  const count: number = store.list().length;
  const workspace: Workspace = newWorkspace('workspace-' + Date.now().toString(36), freeName('工作区'),
    WORKSPACE_COLORS[count % WORKSPACE_COLORS.length], WORKSPACE_ICONS[count % WORKSPACE_ICONS.length], count);
  if (store.save(workspace)) { return workspace; }
  toast(ui, '工作区未保存，请稍后重试');
  return null;
}

/** Saves the live sessions as a new workspace. */
export function saveCurrentWorkspace(ui: UIContext, rows: OrgHostRow[], activeRefs: string[]): Workspace | null {
  const store: WorkspaceStore = WorkspaceStore.getInstance();
  if (!store.canAdd()) { toast(ui, '最多 ' + MAX_WORKSPACES.toString() + ' 个工作区'); return null; }
  const sessions: WorkspaceCaptureSession[] = [];
  activeRefs.forEach((ref: string): void => {
    const row: OrgHostRow | undefined = rows.find((item: OrgHostRow): boolean => item.ref === ref);
    if (row !== undefined) { sessions.push({ hostRef: ref, protocol: row.protocol }); }
  });
  if (sessions.length === 0) { toast(ui, '当前没有已连接的会话'); return null; }
  const limit: number = workspaceEntryLimit(currentWorkspaceDeviceKind());
  if (sessions.length > limit) {
    toast(ui, '平板上每个工作区最多 ' + limit.toString() + ' 台主机，已保存前 ' + limit.toString() + ' 个会话');
    sessions.splice(limit, sessions.length - limit);
  }
  const count: number = store.list().length;
  try {
    const workspace: Workspace = captureWorkspace('workspace-' + Date.now().toString(36), freeName('当前会话'),
      WORKSPACE_COLORS[count % WORKSPACE_COLORS.length], WORKSPACE_ICONS[0], sessions, 'custom');
    workspace.order = count;
    if (store.save(workspace)) { return workspace; }
    toast(ui, '工作区未保存，请稍后重试');
  } catch (_error) {
    toast(ui, '当前会话无法保存为工作区');
  }
  return null;
}

/** 编辑 / 前移 / 后移 / 删除 for one workspace. */
export function showWorkspaceMenu(ui: UIContext, workspace: Workspace, textColor: string, dangerColor: string,
  onEdit: (workspace: Workspace) => void): void {
  ui.getPromptAction().showActionMenu({
    title: workspace.name,
    buttons: [{ text: '编辑', color: textColor }, { text: '前移', color: textColor },
      { text: '后移', color: textColor }, { text: '删除', color: dangerColor }]
  }).then((result): void => {
    if (result.index === 0) { onEdit(workspace); }
    if (result.index === 1) { WorkspaceStore.getInstance().move(workspace.id, -1); }
    if (result.index === 2) { WorkspaceStore.getInstance().move(workspace.id, 1); }
    if (result.index === 3) {
      ui.getPromptAction().showDialog({
        title: '删除工作区', message: '删除「' + workspace.name + '」？主机和正在进行的会话不受影响。',
        buttons: [{ text: '取消', color: textColor }, { text: '删除', color: dangerColor }]
      }).then((answer): void => {
        if (answer.index === 1) { WorkspaceStore.getInstance().remove(workspace.id); }
      }).catch((): void => {});
    }
  }).catch((): void => {});
}
