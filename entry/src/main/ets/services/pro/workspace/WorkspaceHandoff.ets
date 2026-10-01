import { WorkspaceFrame, WorkspaceView } from './WorkspacePolicy';

const WORKSPACE_HANDOFF_TTL_MS: number = 3 * 60 * 1000;

interface StagedView { hostId: string; view: WorkspaceView; expiresAt: number; }
interface StagedFrame { hostId: string; frame: WorkspaceFrame; expiresAt: number; }
/** Pad workspaces open their two sessions side by side. */
export type WorkspaceSplitSide = 'primary' | 'secondary';
interface StagedSplit { hostId: string; side: WorkspaceSplitSide; expiresAt: number; }

/**
 * One-shot, host-bound hints for a session opened from a workspace: the SSH pane/directory to restore and the PC
 * window rectangle. They carry no credentials and expire after three minutes.
 */
export class WorkspaceHandoff {
  private static instance: WorkspaceHandoff | null = null;
  private views: StagedView[] = [];
  private frames: StagedFrame[] = [];
  private splits: StagedSplit[] = [];

  static getInstance(): WorkspaceHandoff {
    if (WorkspaceHandoff.instance === null) { WorkspaceHandoff.instance = new WorkspaceHandoff(); }
    return WorkspaceHandoff.instance;
  }

  stage(hostId: string, view: WorkspaceView | null, frame: WorkspaceFrame | null, nowMs: number = Date.now()): void {
    this.clear(hostId);
    if (hostId.trim() === '') { return; }
    if (view !== null) { this.views.push({ hostId, view, expiresAt: nowMs + WORKSPACE_HANDOFF_TTL_MS }); }
    if (frame !== null) { this.frames.push({ hostId, frame, expiresAt: nowMs + WORKSPACE_HANDOFF_TTL_MS }); }
  }

  takeView(hostId: string, nowMs: number = Date.now()): WorkspaceView | null {
    const found: StagedView | undefined = this.views.find((item: StagedView): boolean =>
      item.hostId === hostId && item.expiresAt > nowMs);
    this.views = this.views.filter((item: StagedView): boolean => item.hostId !== hostId && item.expiresAt > nowMs);
    return found === undefined ? null : found.view;
  }

  takeFrame(hostId: string, nowMs: number = Date.now()): WorkspaceFrame | null {
    const found: StagedFrame | undefined = this.frames.find((item: StagedFrame): boolean =>
      item.hostId === hostId && item.expiresAt > nowMs);
    this.frames = this.frames.filter((item: StagedFrame): boolean => item.hostId !== hostId && item.expiresAt > nowMs);
    return found === undefined ? null : found.frame;
  }

  /** Marks the next session window of this host to open in split screen (Pad workspaces only). */
  stageSplit(hostId: string, side: WorkspaceSplitSide, nowMs: number = Date.now()): void {
    this.splits = this.splits.filter((item: StagedSplit): boolean => item.hostId !== hostId && item.expiresAt > nowMs);
    if (hostId.trim() !== '') { this.splits.push({ hostId, side, expiresAt: nowMs + WORKSPACE_HANDOFF_TTL_MS }); }
  }

  /** Whether a split window is staged for this host, without consuming it (used to pick the window route). */
  hasSplit(hostId: string, nowMs: number = Date.now()): boolean {
    return this.splits.some((item: StagedSplit): boolean => item.hostId === hostId && item.expiresAt > nowMs);
  }

  takeSplit(hostId: string, nowMs: number = Date.now()): WorkspaceSplitSide | null {
    const found: StagedSplit | undefined = this.splits.find((item: StagedSplit): boolean =>
      item.hostId === hostId && item.expiresAt > nowMs);
    this.splits = this.splits.filter((item: StagedSplit): boolean => item.hostId !== hostId && item.expiresAt > nowMs);
    return found === undefined ? null : found.side;
  }

  clear(hostId: string): void {
    this.splits = this.splits.filter((item: StagedSplit): boolean => item.hostId !== hostId);
    this.views = this.views.filter((item: StagedView): boolean => item.hostId !== hostId);
    this.frames = this.frames.filter((item: StagedFrame): boolean => item.hostId !== hostId);
  }
}
