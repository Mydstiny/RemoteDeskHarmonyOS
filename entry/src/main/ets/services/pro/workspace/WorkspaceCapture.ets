import {
  Workspace, WorkspaceEntry, WorkspaceFrame, WorkspaceLayoutPreset, WorkspaceView,
  WORKSPACE_SCHEMA_VERSION, MAX_WORKSPACE_ENTRIES, defaultWorkspaceView, validateWorkspace
} from './WorkspacePolicy';

/** Minimal view of an active session accepted by the capture boundary. */
export interface WorkspaceCaptureSession {
  hostRef: string;
  protocol: string;
  view?: WorkspaceView;
  frame?: WorkspaceFrame;
  autoConnect?: boolean;
}

function copyView(view: WorkspaceView | undefined): WorkspaceView {
  const source: WorkspaceView = view ?? defaultWorkspaceView();
  const copied: WorkspaceView = {
    sshPane: source.sshPane, sshDirectory: source.sshDirectory, monitor: source.monitor,
    scale: source.scale, panX: source.panX, panY: source.panY, inputMode: source.inputMode
  };
  if (source.strictBounds !== undefined) { copied.strictBounds = source.strictBounds; }
  return copied;
}

function copyFrame(frame: WorkspaceFrame | undefined): WorkspaceFrame | undefined {
  if (frame === undefined) { return undefined; }
  return { x: frame.x, y: frame.y, w: frame.w, h: frame.h, fullscreen: frame.fullscreen };
}

/** Capture only safe session references and view/layout fields into a draft. */
export function captureWorkspace(id: string, name: string, color: string, icon: string,
  sessions: WorkspaceCaptureSession[], layout: WorkspaceLayoutPreset = 'custom',
  updatedAt: number = Date.now()): Workspace {
  const entries: WorkspaceEntry[] = [];
  sessions.slice(0, MAX_WORKSPACE_ENTRIES).forEach((session: WorkspaceCaptureSession): void => {
    const hostRef: string = session.hostRef.trim();
    const protocol: string = session.protocol.trim();
    if (hostRef === '' || protocol === '') { return; }
    const entry: WorkspaceEntry = {
      hostRef, protocol, order: entries.length, autoConnect: session.autoConnect !== false,
      view: copyView(session.view)
    };
    if (protocol === 'rdp' && entry.view.strictBounds === undefined) { entry.view.strictBounds = false; }
    const frame: WorkspaceFrame | undefined = copyFrame(session.frame);
    if (frame !== undefined) { entry.frame = frame; }
    entries.push(entry);
  });
  const workspace: Workspace = {
    schemaVersion: WORKSPACE_SCHEMA_VERSION, id: id.trim(), name: name.trim(), color, icon,
    order: 0, entries, layout, updatedAt
  };
  const errors: string[] = validateWorkspace(workspace);
  if (errors.length > 0) { throw new Error('invalid_workspace_capture:' + errors.join(',')); }
  return workspace;
}
