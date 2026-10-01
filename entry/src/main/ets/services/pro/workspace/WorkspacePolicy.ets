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

export const WORKSPACE_COLORS: string[] = [
  '#007DFF', '#5856D6', '#AF52DE', '#FF2D55', '#FF9500', '#34C759', '#00C7BE', '#30B0C7'
];
export const WORKSPACE_ICONS: string[] = [
  '🖥️', '💻', '⌨️', '🧑‍💻', '🛠️', '🚀', '📊', '🧪', '🎮', '☁️', '🏢', '🏠',
  '⭐', '🌙', '☕', '📚', '🎨', '🎬', '🎧', '🔬', '🧠', '🌿', '🔐', '📡',
  '🗂️', '💡', '🪐', '🧭', '🌊', '🔥', '🍀', '🦊', '🐳', '🌸', '⚡', '🎯'
];
export const WORKSPACE_LAYOUT_PRESETS: WorkspaceLayoutPreset[] = ['split', 'columns3', 'masterDetail', 'grid4'];
/** Layout rectangles snap to an 8 × 8 grid. */
export const WORKSPACE_GRID: number = 8;

export function workspaceLayoutLabel(preset: WorkspaceLayoutPreset | undefined): string {
  if (preset === 'split') { return '左右平分'; }
  if (preset === 'columns3') { return '三栏'; }
  if (preset === 'masterDetail') { return '主副'; }
  if (preset === 'grid4') { return '四宫格'; }
  return '自定义';
}

export function newWorkspace(id: string, name: string, color: string, icon: string, order: number,
  nowMs: number = Date.now()): Workspace {
  return { schemaVersion: WORKSPACE_SCHEMA_VERSION, id, name: name.trim().slice(0, MAX_WORKSPACE_NAME_LENGTH),
    color, icon, order, entries: [], layout: 'custom', updatedAt: nowMs };
}

export function copyWorkspaceEntry(entry: WorkspaceEntry): WorkspaceEntry {
  const copied: WorkspaceEntry = {
    hostRef: entry.hostRef, protocol: entry.protocol, order: entry.order, autoConnect: entry.autoConnect,
    view: { sshPane: entry.view.sshPane, sshDirectory: entry.view.sshDirectory, monitor: entry.view.monitor,
      scale: entry.view.scale, panX: entry.view.panX, panY: entry.view.panY, inputMode: entry.view.inputMode }
  };
  if (entry.view.strictBounds !== undefined) { copied.view.strictBounds = entry.view.strictBounds; }
  if (entry.frame !== undefined) {
    copied.frame = { x: entry.frame.x, y: entry.frame.y, w: entry.frame.w, h: entry.frame.h,
      fullscreen: entry.frame.fullscreen };
  }
  return copied;
}

export function copyWorkspace(source: Workspace): Workspace {
  return { schemaVersion: source.schemaVersion, id: source.id, name: source.name, color: source.color,
    icon: source.icon, order: source.order,
    entries: source.entries.map((entry: WorkspaceEntry): WorkspaceEntry => copyWorkspaceEntry(entry)),
    layout: source.layout, updatedAt: source.updatedAt };
}

/** A new entry with the protocol's default view (RDP also carries strictBounds). */
export function newWorkspaceEntry(hostRef: string, protocol: string, order: number): WorkspaceEntry {
  const entry: WorkspaceEntry = { hostRef, protocol, order, autoConnect: true, view: defaultWorkspaceView() };
  if (protocol === 'rdp') { entry.view.strictBounds = false; }
  return entry;
}

function renumber(entries: WorkspaceEntry[]): WorkspaceEntry[] {
  return entries.map((entry: WorkspaceEntry, index: number): WorkspaceEntry => {
    const copied: WorkspaceEntry = copyWorkspaceEntry(entry);
    copied.order = index;
    return copied;
  });
}

export function sortedEntries(entries: WorkspaceEntry[]): WorkspaceEntry[] {
  return entries.slice().sort((left: WorkspaceEntry, right: WorkspaceEntry): number => left.order - right.order);
}

export function addWorkspaceEntries(entries: WorkspaceEntry[], refs: string[], protocols: string[]): WorkspaceEntry[] {
  const result: WorkspaceEntry[] = renumber(sortedEntries(entries));
  refs.forEach((hostRef: string, index: number): void => {
    if (result.length >= MAX_WORKSPACE_ENTRIES ||
        result.some((entry: WorkspaceEntry): boolean => entry.hostRef === hostRef)) { return; }
    result.push(newWorkspaceEntry(hostRef, protocols[index] || '', result.length));
  });
  return result;
}

export function removeWorkspaceEntry(entries: WorkspaceEntry[], hostRef: string): WorkspaceEntry[] {
  return renumber(sortedEntries(entries).filter((entry: WorkspaceEntry): boolean => entry.hostRef !== hostRef));
}

export function moveWorkspaceEntry(entries: WorkspaceEntry[], hostRef: string, delta: number): WorkspaceEntry[] {
  const ordered: WorkspaceEntry[] = sortedEntries(entries);
  const index: number = ordered.findIndex((entry: WorkspaceEntry): boolean => entry.hostRef === hostRef);
  const target: number = index + delta;
  if (index < 0 || target < 0 || target >= ordered.length) { return renumber(ordered); }
  const moved: WorkspaceEntry = ordered[index];
  ordered.splice(index, 1);
  ordered.splice(target, 0, moved);
  return renumber(ordered);
}

/** Entries whose host was deleted; kept until the user clears them. */
export function missingWorkspaceRefs(workspace: Workspace, liveRefs: string[]): string[] {
  return workspace.entries.filter((entry: WorkspaceEntry): boolean => liveRefs.indexOf(entry.hostRef) < 0)
    .map((entry: WorkspaceEntry): string => entry.hostRef);
}

function snap(value: number): number { return Math.round(value * WORKSPACE_GRID) / WORKSPACE_GRID; }

/** Snaps a window rectangle to the grid and keeps it fully on screen. */
export function snapWorkspaceFrame(frame: WorkspaceFrame): WorkspaceFrame {
  const minSize: number = 1 / WORKSPACE_GRID;
  const w: number = Math.min(1, Math.max(minSize, snap(frame.w)));
  const h: number = Math.min(1, Math.max(minSize, snap(frame.h)));
  const x: number = Math.min(1 - w, Math.max(0, snap(frame.x)));
  const y: number = Math.min(1 - h, Math.max(0, snap(frame.y)));
  return { x, y, w, h, fullscreen: frame.fullscreen };
}

/** The frame an entry opens with; entries without one fill the screen. */
export function workspaceEntryFrame(entry: WorkspaceEntry): WorkspaceFrame {
  return entry.frame !== undefined ? entry.frame : { x: 0, y: 0, w: 1, h: 1, fullscreen: false };
}

export type WorkspaceRunState = 'queued' | 'connecting' | 'opened' | 'failed' | 'skipped';
export interface WorkspaceRunItem {
  hostRef: string; protocol: string; label: string; state: WorkspaceRunState; message: string; autoConnect: boolean;
}
export interface WorkspaceRun { workspaceId: string; name: string; color: string; items: WorkspaceRunItem[]; startedAt: number; }

/** Builds a run from the entries in order; hosts that no longer exist are skipped up front. */
export function workspaceRunFor(workspace: Workspace, labels: Record<string, string>, nowMs: number = Date.now()): WorkspaceRun {
  const items: WorkspaceRunItem[] = sortedEntries(workspace.entries).map((entry: WorkspaceEntry): WorkspaceRunItem => {
    const label: string | undefined = labels[entry.hostRef];
    return { hostRef: entry.hostRef, protocol: entry.protocol, label: label !== undefined ? label : '已删除的主机',
      state: label !== undefined ? 'queued' : 'skipped', message: label !== undefined ? '' : '主机不存在',
      autoConnect: entry.autoConnect };
  });
  return { workspaceId: workspace.id, name: workspace.name, color: workspace.color, items, startedAt: nowMs };
}

export function nextQueuedRunIndex(run: WorkspaceRun): number {
  return run.items.findIndex((item: WorkspaceRunItem): boolean => item.state === 'queued');
}

export function connectingRunIndex(run: WorkspaceRun): number {
  return run.items.findIndex((item: WorkspaceRunItem): boolean => item.state === 'connecting');
}

export function workspaceRunFinished(run: WorkspaceRun): boolean {
  return run.items.every((item: WorkspaceRunItem): boolean => item.state !== 'queued' && item.state !== 'connecting');
}

export function workspaceRunSummary(run: WorkspaceRun): string {
  const count = (state: WorkspaceRunState): number =>
    run.items.filter((item: WorkspaceRunItem): boolean => item.state === state).length;
  const parts: string[] = [];
  if (count('opened') > 0) { parts.push(count('opened').toString() + ' 个已打开'); }
  if (count('failed') > 0) { parts.push(count('failed').toString() + ' 个未完成'); }
  if (count('skipped') > 0) { parts.push(count('skipped').toString() + ' 个已跳过'); }
  if (count('queued') + count('connecting') > 0) {
    parts.push((count('queued') + count('connecting')).toString() + ' 个待打开');
  }
  return parts.join(' · ');
}

export function setRunItemState(run: WorkspaceRun, index: number, state: WorkspaceRunState, message: string): WorkspaceRun {
  const items: WorkspaceRunItem[] = run.items.map((item: WorkspaceRunItem, at: number): WorkspaceRunItem => ({
    hostRef: item.hostRef, protocol: item.protocol, label: item.label, autoConnect: item.autoConnect,
    state: at === index ? state : item.state, message: at === index ? message : item.message }));
  return { workspaceId: run.workspaceId, name: run.name, color: run.color, items, startedAt: run.startedAt };
}

export interface WorkspaceWindowRect { left: number; top: number; width: number; height: number; }

/** Converts a saved relative frame into a pixel window rectangle on the given display, respecting minimum sizes. */
export function workspaceWindowRect(frame: WorkspaceFrame, displayWidth: number, displayHeight: number,
  minWidth: number, minHeight: number): WorkspaceWindowRect {
  const w: number = Math.max(1, displayWidth);
  const h: number = Math.max(1, displayHeight);
  if (frame.fullscreen) { return { left: 0, top: 0, width: Math.round(w), height: Math.round(h) }; }
  const width: number = Math.min(w, Math.max(minWidth, Math.round(frame.w * w)));
  const height: number = Math.min(h, Math.max(minHeight, Math.round(frame.h * h)));
  const left: number = Math.max(0, Math.min(w - width, Math.round(frame.x * w)));
  const top: number = Math.max(0, Math.min(h - height, Math.round(frame.y * h)));
  return { left, top, width, height };
}
