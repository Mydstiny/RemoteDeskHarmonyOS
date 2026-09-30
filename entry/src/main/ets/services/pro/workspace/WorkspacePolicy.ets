/** Pure validation and device-shape planning for Pro workspaces. */
export const WORKSPACE_SCHEMA_VERSION: number = 1;
export const MAX_WORKSPACES: number = 30;
export const MAX_WORKSPACE_ENTRIES: number = 16;
export const MAX_WORKSPACE_NAME_LENGTH: number = 48;
export type WorkspaceDevice = 'phone' | 'tablet' | 'pc';
export type WorkspaceProtocol = 'rdp' | 'rustdesk' | 'ssh' | 'vnc' | 'moonlight' | 'ai' | string;
export type WorkspaceLayoutPreset = 'split' | 'columns3' | 'masterDetail' | 'grid4' | 'custom';

export interface WorkspaceView {
  sshPane: string; sshDirectory: string; monitor: number; scale: number; panX: number; panY: number; inputMode: string; strictBounds?: boolean;
}
export interface WorkspaceFrame { x: number; y: number; w: number; h: number; fullscreen: boolean; }
export interface WorkspaceEntry { hostRef: string; protocol: WorkspaceProtocol; order: number; autoConnect: boolean; view: WorkspaceView; frame?: WorkspaceFrame; }
export interface Workspace { schemaVersion: number; id: string; name: string; color: string; icon: string; order: number; entries: WorkspaceEntry[]; layout?: WorkspaceLayoutPreset; updatedAt: number; }
export interface WorkspaceOpenItem { hostRef: string; protocol: string; mode: 'window' | 'tab' | 'split' | 'queued'; order: number; frame?: WorkspaceFrame; }
export interface WorkspaceOpenPlan { device: WorkspaceDevice; items: WorkspaceOpenItem[]; maxConcurrent: number; fallback: string; }

function finite(value: number, min: number, max: number): boolean { return Number.isFinite(value) && value >= min && value <= max; }
function text(value: string, max: number, empty: boolean = false): boolean {
  return typeof value === 'string' && value.length <= max && (empty || value.trim().length > 0) && !/[\u0000-\u001f\u007f]/.test(value);
}
function exactView(view: WorkspaceView, protocol: string): boolean {
  if (!view || typeof view !== 'object') { return false; }
  const expected: string[] = ['sshPane', 'sshDirectory', 'monitor', 'scale', 'panX', 'panY', 'inputMode'];
  if (protocol === 'rdp') { expected.push('strictBounds'); }
  const keys: string[] = Object.keys(view);
  if (keys.length !== expected.length || keys.some((key: string): boolean => expected.indexOf(key) < 0)) { return false; }
  return (view.sshPane === 'terminal' || view.sshPane === 'files') && text(view.sshDirectory, 4096, true) &&
    (view.sshDirectory === '' || view.sshDirectory.startsWith('/')) && finite(view.monitor, 0, 15) && Number.isInteger(view.monitor) &&
    finite(view.scale, 0.1, protocol === 'rdp' ? 12 : 8) && finite(view.panX, -100000, 100000) && finite(view.panY, -100000, 100000) &&
    ['direct', 'touchpad', 'keyboardMouse'].indexOf(view.inputMode) >= 0 &&
    (protocol !== 'rdp' ? view.sshPane === 'terminal' || protocol === 'ssh' : typeof view.strictBounds === 'boolean');
}
export function defaultWorkspaceView(): WorkspaceView {
  return { sshPane: 'terminal', sshDirectory: '', monitor: 0, scale: 1, panX: 0, panY: 0, inputMode: 'direct' };
}
export function validateWorkspaceEntry(entry: WorkspaceEntry): string[] {
  const errors: string[] = [];
  if (!text(entry.hostRef, 160) || /[\u0000-\u001f]/.test(entry.hostRef)) { errors.push('invalid_host_ref'); }
  if (!text(entry.protocol, 32)) { errors.push('invalid_protocol'); }
  if (!Number.isInteger(entry.order) || entry.order < 0 || entry.order >= MAX_WORKSPACE_ENTRIES) { errors.push('invalid_order'); }
  if (typeof entry.autoConnect !== 'boolean' || !exactView(entry.view, entry.protocol)) { errors.push('invalid_view'); }
  if (entry.frame !== undefined && (!finite(entry.frame.x, 0, 1) || !finite(entry.frame.y, 0, 1) || !finite(entry.frame.w, 0.01, 1) ||
      !finite(entry.frame.h, 0.01, 1) || entry.frame.x + entry.frame.w > 1.001 || entry.frame.y + entry.frame.h > 1.001 ||
      typeof entry.frame.fullscreen !== 'boolean')) { errors.push('invalid_frame'); }
  return errors;
}
export function validateWorkspace(workspace: Workspace): string[] {
  const errors: string[] = [];
  if (workspace.schemaVersion !== WORKSPACE_SCHEMA_VERSION || !text(workspace.id, 96) || !text(workspace.name, MAX_WORKSPACE_NAME_LENGTH) ||
      !text(workspace.color, 32) || !text(workspace.icon, 64) || !Number.isInteger(workspace.order) || workspace.order < 0 ||
      workspace.entries.length > MAX_WORKSPACE_ENTRIES || !finite(workspace.updatedAt, 0, Number.MAX_SAFE_INTEGER)) { errors.push('invalid_workspace'); }
  if (!Array.isArray(workspace.entries)) { return ['invalid_entries']; }
  const refs: string[] = [];
  workspace.entries.forEach((entry: WorkspaceEntry): void => {
    validateWorkspaceEntry(entry).forEach((error: string): void => { if (errors.indexOf(error) < 0) { errors.push(error); } });
    if (refs.indexOf(entry.hostRef) >= 0) { errors.push('duplicate_host_ref'); }
    refs.push(entry.hostRef);
  });
  if (workspace.layout !== undefined && ['split', 'columns3', 'masterDetail', 'grid4', 'custom'].indexOf(workspace.layout) < 0) { errors.push('invalid_layout'); }
  return Array.from(new Set<string>(errors));
}
export function applyLayoutPreset(entries: WorkspaceEntry[], preset: WorkspaceLayoutPreset): WorkspaceEntry[] {
  const result: WorkspaceEntry[] = entries.slice(0, MAX_WORKSPACE_ENTRIES);
  const count: number = result.length;
  result.forEach((entry: WorkspaceEntry, index: number): void => {
    let frame: WorkspaceFrame = { x: 0, y: 0, w: 1, h: 1, fullscreen: false };
    if (preset === 'split') { frame = { x: index % 2 * 0.5, y: 0, w: 0.5, h: 1, fullscreen: false }; }
    else if (preset === 'columns3') { frame = { x: (index % 3) / 3, y: 0, w: 1 / 3, h: 1, fullscreen: false }; }
    else if (preset === 'masterDetail') { frame = index === 0 ? { x: 0, y: 0, w: 0.65, h: 1, fullscreen: false } : { x: 0.65, y: (index - 1) * 0.5, w: 0.35, h: 0.5, fullscreen: false }; }
    else if (preset === 'grid4') { frame = { x: (index % 2) * 0.5, y: Math.floor(index / 2) * 0.5, w: 0.5, h: 0.5, fullscreen: false }; }
    entry.frame = frame;
    entry.order = index;
  });
  return result;
}
export function workspaceOpenPlan(workspace: Workspace, device: WorkspaceDevice): WorkspaceOpenPlan {
  const entries: WorkspaceEntry[] = workspace.entries.slice().sort((left: WorkspaceEntry, right: WorkspaceEntry): number => left.order - right.order);
  const items: WorkspaceOpenItem[] = entries.map((entry: WorkspaceEntry, index: number): WorkspaceOpenItem => ({
    hostRef: entry.hostRef, protocol: entry.protocol, order: index,
    mode: device === 'pc' ? (entry.protocol === 'ssh' ? 'tab' : 'window') :
      device === 'tablet' ? (index < 2 ? 'split' : 'tab') : (index === 0 ? 'window' : 'queued'),
    frame: entry.frame
  }));
  return { device, items, maxConcurrent: device === 'phone' ? 3 : device === 'tablet' ? 2 : Math.max(1, items.length),
    fallback: device === 'tablet' ? 'session_switcher' : device === 'phone' ? 'session_switcher' : 'visible_bounds' };
}
