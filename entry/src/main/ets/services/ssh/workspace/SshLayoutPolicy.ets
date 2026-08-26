import { SshWorkspaceLayoutEngine } from './SshWorkspaceCapabilityPolicy';

export type SshLayoutMode = 'sm' | 'md' | 'lg' | 'xl';
export type SshContainerClass = 'compact' | 'regular' | 'wide';
export type SshWorkspaceTopology = 'single' | 'rail' | 'dual' | 'triple';
export type SshWorkspaceFocusRegion =
  'title_actions' | 'sidebar' | 'tab_strip' | 'pane_host' | 'inspector' | 'status_bar';

export interface SshLayoutInput {
  widthVp: number;
  heightVp: number;
  containerWidthVp: number;
  desktop: boolean;
  pad: boolean;
  sidebarRequested: boolean;
  inspectorRequested: boolean;
  requestedPaneCount: number;
  minimumTerminalPaneWidthVp: number;
  engine: SshWorkspaceLayoutEngine;
}

export interface SshLayoutResult {
  mode: SshLayoutMode;
  containerClass: SshContainerClass;
  topology: SshWorkspaceTopology;
  engine: SshWorkspaceLayoutEngine;
  sidebarVisible: boolean;
  sidebarWidthVp: number;
  inspectorVisible: boolean;
  inspectorWidthVp: number;
  mainWidthVp: number;
  visiblePaneCount: number;
  maxPaneCount: number;
  titleHeightVp: number;
  statusHeightVp: number;
  controlVisualSizeVp: number;
  controlHitSizeVp: number;
  paneDividerVisualWidthVp: number;
  paneDividerHitWidthVp: number;
  semanticRegions: Array<string>;
}

function finiteSize(value: number, fallback: number): number {
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

export function sshLayoutMode(widthVp: number): SshLayoutMode {
  const width: number = finiteSize(widthVp, 360);
  if (width < 600) { return 'sm'; }
  if (width < 840) { return 'md'; }
  if (width < 1440) { return 'lg'; }
  return 'xl';
}

export function sshContainerClass(widthVp: number): SshContainerClass {
  const width: number = finiteSize(widthVp, 360);
  if (width < 480) { return 'compact'; }
  if (width < 840) { return 'regular'; }
  return 'wide';
}

export function sshWorkspaceFocusOrder(sidebarVisible: boolean,
  inspectorVisible: boolean): Array<SshWorkspaceFocusRegion> {
  const result: Array<SshWorkspaceFocusRegion> = ['title_actions'];
  if (sidebarVisible) { result.push('sidebar'); }
  result.push('tab_strip');
  result.push('pane_host');
  if (inspectorVisible) { result.push('inspector'); }
  result.push('status_bar');
  return result;
}

/** Cycle only through regions that are actually mounted in the current layout. */
export function nextSshWorkspaceFocusRegion(regions: Array<SshWorkspaceFocusRegion>,
  current: string, reverse: boolean = false): SshWorkspaceFocusRegion | null {
  if (regions.length === 0) { return null; }
  const currentIndex: number = regions.indexOf(current as SshWorkspaceFocusRegion);
  if (currentIndex < 0) { return reverse ? regions[regions.length - 1] : regions[0]; }
  const delta: number = reverse ? -1 : 1;
  return regions[(currentIndex + delta + regions.length) % regions.length];
}

export function resolveSshLayout(input: SshLayoutInput): SshLayoutResult {
  const width: number = finiteSize(input.widthVp, 360);
  const mode: SshLayoutMode = sshLayoutMode(width);
  const localWidth: number = finiteSize(input.containerWidthVp, width);
  let sidebarVisible: boolean = input.sidebarRequested && mode !== 'sm';
  let sidebarWidth: number = 0;
  if (sidebarVisible) {
    if (mode === 'md') {
      sidebarWidth = 72;
    } else {
      sidebarWidth = Math.max(240, Math.min(320, width * 0.22));
      sidebarWidth = Math.min(sidebarWidth, width * 0.4);
    }
  }
  const terminalMin: number = Math.max(280,
    finiteSize(input.minimumTerminalPaneWidthVp, 360));
  let inspectorVisible: boolean = input.inspectorRequested && (mode === 'lg' || mode === 'xl');
  let inspectorWidth: number = inspectorVisible ? (mode === 'xl' ? 320 : 300) : 0;
  let mainWidth: number = width - sidebarWidth - inspectorWidth;
  if (inspectorVisible && (mainWidth < width * 0.6 || mainWidth < terminalMin)) {
    inspectorVisible = false;
    inspectorWidth = 0;
    mainWidth = width - sidebarWidth;
  }
  if (sidebarVisible && mainWidth < terminalMin) {
    sidebarVisible = false;
    sidebarWidth = 0;
    mainWidth = width - inspectorWidth;
  }
  let maxPaneCount: number = 1;
  if (mode === 'lg') { maxPaneCount = Math.min(2, Math.max(1, Math.floor(mainWidth / terminalMin))); }
  if (mode === 'xl') {
    // Four panes are projected as a two-column grid. Counting every pane as a
    // horizontal slot incorrectly reduced a valid 2x2 workspace to 3 panes
    // whenever the wide sidebar was open.
    maxPaneCount = mainWidth >= terminalMin * 2 ? 4 : 1;
  }
  const requestedPaneCount: number = Number.isFinite(input.requestedPaneCount) ?
    Math.max(1, Math.floor(input.requestedPaneCount)) : 1;
  const visiblePaneCount: number = Math.min(requestedPaneCount, maxPaneCount);
  let topology: SshWorkspaceTopology = 'single';
  if (mode === 'md') { topology = sidebarVisible ? 'rail' : 'single'; }
  if (mode === 'lg') { topology = sidebarVisible ? 'dual' : 'single'; }
  if (mode === 'xl') {
    topology = sidebarVisible && inspectorVisible ? 'triple' :
      (sidebarVisible || inspectorVisible ? 'dual' : 'single');
  }
  const compactDesktop: boolean = input.desktop && mode !== 'xl';
  const visualSize: number = compactDesktop ? 36 : (input.desktop ? 40 : 44);
  return {
    mode,
    containerClass: sshContainerClass(localWidth),
    topology,
    engine: input.engine,
    sidebarVisible,
    sidebarWidthVp: Math.floor(sidebarWidth),
    inspectorVisible,
    inspectorWidthVp: inspectorWidth,
    mainWidthVp: Math.max(0, Math.floor(mainWidth)),
    visiblePaneCount,
    maxPaneCount,
    titleHeightVp: input.desktop ? 52 : 56,
    statusHeightVp: input.desktop ? 26 : 28,
    controlVisualSizeVp: visualSize,
    controlHitSizeVp: 48,
    paneDividerVisualWidthVp: 2,
    paneDividerHitWidthVp: input.desktop ? 10 : 12,
    semanticRegions: sshWorkspaceFocusOrder(sidebarVisible, inspectorVisible)
  };
}

/** DynamicLayout and static fallback must differ only in rendering mechanism. */
export function sameSshLayoutSemantics(left: SshLayoutResult,
  right: SshLayoutResult): boolean {
  if (left.mode !== right.mode || left.containerClass !== right.containerClass ||
    left.topology !== right.topology || left.sidebarVisible !== right.sidebarVisible ||
    left.sidebarWidthVp !== right.sidebarWidthVp ||
    left.inspectorVisible !== right.inspectorVisible ||
    left.inspectorWidthVp !== right.inspectorWidthVp ||
    left.mainWidthVp !== right.mainWidthVp ||
    left.visiblePaneCount !== right.visiblePaneCount ||
    left.maxPaneCount !== right.maxPaneCount ||
    left.titleHeightVp !== right.titleHeightVp ||
    left.statusHeightVp !== right.statusHeightVp ||
    left.controlVisualSizeVp !== right.controlVisualSizeVp ||
    left.controlHitSizeVp !== right.controlHitSizeVp ||
    left.paneDividerVisualWidthVp !== right.paneDividerVisualWidthVp ||
    left.paneDividerHitWidthVp !== right.paneDividerHitWidthVp ||
    left.semanticRegions.length !== right.semanticRegions.length) { return false; }
  for (let index = 0; index < left.semanticRegions.length; index++) {
    if (left.semanticRegions[index] !== right.semanticRegions[index]) { return false; }
  }
  return true;
}
