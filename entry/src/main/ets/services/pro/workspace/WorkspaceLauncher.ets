import { ProEntries } from '../ProEntries';
import { Workspace, WorkspaceOpenItem, WorkspaceOpenPlan, WorkspaceDevice, workspaceOpenPlan } from './WorkspacePolicy';

export type WorkspaceLaunchState = 'queued' | 'connecting' | 'connected' | 'failed' | 'skipped';
export interface WorkspaceLaunchResult { item: WorkspaceOpenItem; state: WorkspaceLaunchState; message: string; }
export interface WorkspaceLaunchAdapter { open(item: WorkspaceOpenItem): Promise<void>; }

/** Executes a validated plan without letting one protocol failure cancel others. */
export class WorkspaceLauncher {
  async launch(workspace: Workspace, device: WorkspaceDevice, adapter: WorkspaceLaunchAdapter): Promise<WorkspaceLaunchResult[]> {
    if (!ProEntries.visible('pro.workspaces')) { return []; }
    const plan: WorkspaceOpenPlan = workspaceOpenPlan(workspace, device);
    const results: WorkspaceLaunchResult[] = plan.items.map((item: WorkspaceOpenItem): WorkspaceLaunchResult => ({ item, state: 'queued', message: '' }));
    const limit: number = Math.max(1, plan.maxConcurrent);
    for (let start: number = 0; start < results.length; start += limit) {
      const batch: WorkspaceLaunchResult[] = results.slice(start, start + limit);
      await Promise.all(batch.map(async (result: WorkspaceLaunchResult): Promise<void> => {
        result.state = 'connecting';
        try { await adapter.open(result.item); result.state = 'connected'; result.message = '已连接'; }
        catch (error) { result.state = 'failed'; result.message = error instanceof Error ? error.message : '连接失败'; }
      }));
    }
    return results;
  }
}
