import { SshPaneNodeV1, SshWorkspaceSnapshotV1 } from './SshWorkspacePolicy';

export interface SshWorkspacePaneFrame {
  paneId: string;
  tabId: string;
  xVp: number;
  yVp: number;
  widthVp: number;
  heightVp: number;
  active: boolean;
}

export interface SshWorkspacePaneLayoutResult {
  frames: Array<SshWorkspacePaneFrame>;
  hiddenPaneCount: number;
  focused: boolean;
}

export interface SshWorkspaceParentSplit {
  splitNodeId: string;
  ratio: number;
  paneIsSecond: boolean;
}

function finiteSize(value: number, fallback: number): number {
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

function collectLeaves(node: SshPaneNodeV1 | null, result: Array<SshPaneNodeV1>): void {
  if (node === null) { return; }
  if (node.kind === 'leaf') {
    result.push(node);
    return;
  }
  collectLeaves(node.first, result);
  collectLeaves(node.second, result);
}

function leafById(node: SshPaneNodeV1 | null, paneId: string): SshPaneNodeV1 | null {
  if (node === null) { return null; }
  if (node.kind === 'leaf') { return node.nodeId === paneId ? node : null; }
  const first: SshPaneNodeV1 | null = leafById(node.first, paneId);
  return first === null ? leafById(node.second, paneId) : first;
}

function layoutTree(node: SshPaneNodeV1 | null, activePaneId: string,
  x: number, y: number, width: number, height: number,
  result: Array<SshWorkspacePaneFrame>): void {
  if (node === null) { return; }
  if (node.kind === 'leaf') {
    result.push({
      paneId: node.nodeId,
      tabId: node.tabId,
      xVp: x,
      yVp: y,
      widthVp: width,
      heightVp: height,
      active: node.nodeId === activePaneId
    });
    return;
  }
  if (node.direction === 'horizontal') {
    const firstWidth: number = Math.floor(width * node.ratio);
    layoutTree(node.first, activePaneId, x, y, firstWidth, height, result);
    layoutTree(node.second, activePaneId, x + firstWidth, y,
      Math.max(0, width - firstWidth), height, result);
    return;
  }
  const firstHeight: number = Math.floor(height * node.ratio);
  layoutTree(node.first, activePaneId, x, y, width, firstHeight, result);
  layoutTree(node.second, activePaneId, x, y + firstHeight, width,
    Math.max(0, height - firstHeight), result);
}

function selectedLeaves(leaves: Array<SshPaneNodeV1>, activePaneId: string,
  maxPaneCount: number): Array<SshPaneNodeV1> {
  const result: Array<SshPaneNodeV1> = [];
  const active: SshPaneNodeV1 | undefined = leaves.find(
    (leaf: SshPaneNodeV1): boolean => leaf.nodeId === activePaneId);
  if (active !== undefined) { result.push(active); }
  for (let index: number = 0; index < leaves.length && result.length < maxPaneCount; index++) {
    if (result.find((leaf: SshPaneNodeV1): boolean => leaf.nodeId === leaves[index].nodeId) ===
      undefined) {
      result.push(leaves[index]);
    }
  }
  return result;
}

function layoutSelected(leaves: Array<SshPaneNodeV1>, activePaneId: string,
  width: number, height: number): Array<SshWorkspacePaneFrame> {
  const result: Array<SshWorkspacePaneFrame> = [];
  if (leaves.length === 0) { return result; }
  const columns: number = leaves.length === 1 ? 1 : 2;
  const rows: number = leaves.length <= 2 ? 1 : 2;
  const cellWidth: number = Math.floor(width / columns);
  const cellHeight: number = Math.floor(height / rows);
  for (let index: number = 0; index < leaves.length; index++) {
    const column: number = index % columns;
    const row: number = Math.floor(index / columns);
    result.push({
      paneId: leaves[index].nodeId,
      tabId: leaves[index].tabId,
      xVp: column * cellWidth,
      yVp: row * cellHeight,
      widthVp: column === columns - 1 ? width - column * cellWidth : cellWidth,
      heightVp: row === rows - 1 ? height - row * cellHeight : cellHeight,
      active: leaves[index].nodeId === activePaneId
    });
  }
  return result;
}

function paneFramesRespectMinimumWidth(frames: Array<SshWorkspacePaneFrame>,
  minimumPaneWidthVp: number): boolean {
  if (minimumPaneWidthVp <= 0) { return true; }
  for (let index: number = 0; index < frames.length; index++) {
    if (frames[index].widthVp < minimumPaneWidthVp) { return false; }
  }
  return true;
}

/** Keeps the pane tree stable while projecting only the capacity of the current container. */
export function resolveSshWorkspacePaneLayout(snapshot: SshWorkspaceSnapshotV1,
  focusedPaneId: string, maxPaneCount: number, widthVp: number,
  heightVp: number, minimumPaneWidthVp: number = 0): SshWorkspacePaneLayoutResult {
  const width: number = finiteSize(widthVp, 360);
  const height: number = finiteSize(heightVp, 480);
  const leaves: Array<SshPaneNodeV1> = [];
  collectLeaves(snapshot.paneRoot, leaves);
  const focus: SshPaneNodeV1 | null = leafById(snapshot.paneRoot, focusedPaneId.trim());
  if (focus !== null) {
    return {
      frames: [{
        paneId: focus.nodeId, tabId: focus.tabId, xVp: 0, yVp: 0,
        widthVp: width, heightVp: height, active: focus.nodeId === snapshot.activePaneId
      }],
      hiddenPaneCount: Math.max(0, leaves.length - 1),
      focused: true
    };
  }
  const capacity: number = Math.max(1, Math.min(4,
    Number.isFinite(maxPaneCount) ? Math.floor(maxPaneCount) : 1));
  if (leaves.length <= capacity) {
    const frames: Array<SshWorkspacePaneFrame> = [];
    layoutTree(snapshot.paneRoot, snapshot.activePaneId, 0, 0, width, height, frames);
    // Preserve the user's tree whenever it fits. At a constrained wide
    // breakpoint, temporarily balance only the projection instead of
    // squeezing a nested leaf below the readable terminal width. Persisted
    // split directions and ratios remain unchanged.
    if (!paneFramesRespectMinimumWidth(frames, minimumPaneWidthVp) &&
      leaves.length > 1 && width >= minimumPaneWidthVp * 2) {
      return {
        frames: layoutSelected(leaves, snapshot.activePaneId, width, height),
        hiddenPaneCount: 0,
        focused: false
      };
    }
    return { frames, hiddenPaneCount: 0, focused: false };
  }
  const selected: Array<SshPaneNodeV1> = selectedLeaves(leaves, snapshot.activePaneId, capacity);
  return {
    frames: layoutSelected(selected, snapshot.activePaneId, width, height),
    hiddenPaneCount: leaves.length - selected.length,
    focused: false
  };
}

export function sshWorkspaceParentSplit(node: SshPaneNodeV1 | null,
  paneId: string): SshWorkspaceParentSplit | null {
  if (node === null || node.kind === 'leaf') { return null; }
  if (leafById(node.first, paneId) !== null) {
    if (node.first !== null && node.first.nodeId === paneId) {
      return { splitNodeId: node.nodeId, ratio: node.ratio, paneIsSecond: false };
    }
    const nested: SshWorkspaceParentSplit | null = sshWorkspaceParentSplit(node.first, paneId);
    return nested === null ?
      { splitNodeId: node.nodeId, ratio: node.ratio, paneIsSecond: false } : nested;
  }
  if (leafById(node.second, paneId) !== null) {
    if (node.second !== null && node.second.nodeId === paneId) {
      return { splitNodeId: node.nodeId, ratio: node.ratio, paneIsSecond: true };
    }
    const nested: SshWorkspaceParentSplit | null = sshWorkspaceParentSplit(node.second, paneId);
    return nested === null ?
      { splitNodeId: node.nodeId, ratio: node.ratio, paneIsSecond: true } : nested;
  }
  return null;
}

export function sshWorkspaceHiddenTabIds(snapshot: SshWorkspaceSnapshotV1): Array<string> {
  const leaves: Array<SshPaneNodeV1> = [];
  collectLeaves(snapshot.paneRoot, leaves);
  const result: Array<string> = [];
  for (let index: number = 0; index < snapshot.tabOrder.length; index++) {
    const tabId: string = snapshot.tabOrder[index];
    if (leaves.find((leaf: SshPaneNodeV1): boolean => leaf.tabId === tabId) === undefined) {
      result.push(tabId);
    }
  }
  return result;
}
