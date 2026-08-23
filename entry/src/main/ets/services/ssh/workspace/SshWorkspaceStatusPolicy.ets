import { SshTerminalTabState } from '../../SshTerminalTabStore';

export type SshWorkspaceStatusTone = 'normal' | 'positive' | 'warning' | 'danger';

export interface SshWorkspaceStatusItem {
  id: string;
  label: string;
  tone: SshWorkspaceStatusTone;
}

export interface SshWorkspaceStatusInput {
  mode: 'sm' | 'md' | 'lg' | 'xl';
  connectionState: SshTerminalTabState;
  latencyMs: number;
  cols: number;
  rows: number;
  activePaneIndex: number;
  visiblePaneCount: number;
  tabCount: number;
  transferAttentionCount: number;
  forwardingCount: number;
  persistenceError: boolean;
}

export interface SshWorkspaceStatusView {
  visible: boolean;
  compact: boolean;
  items: Array<SshWorkspaceStatusItem>;
}

function connectionStatus(input: SshWorkspaceStatusInput): SshWorkspaceStatusItem {
  if (input.connectionState === 'connected') {
    const latency: string = input.latencyMs >= 0 ? ' · ' + input.latencyMs.toString() + ' ms' : '';
    return { id: 'connection', label: '已连接' + latency, tone: 'positive' };
  }
  if (input.connectionState === 'connecting') {
    return { id: 'connection', label: '连接中', tone: 'warning' };
  }
  if (input.connectionState === 'reconnecting') {
    return { id: 'connection', label: '正在恢复', tone: 'warning' };
  }
  if (input.connectionState === 'error') {
    return { id: 'connection', label: '连接异常', tone: 'danger' };
  }
  return { id: 'connection', label: '未连接', tone: 'normal' };
}

function append(items: Array<SshWorkspaceStatusItem>, id: string, label: string,
  tone: SshWorkspaceStatusTone = 'normal'): void {
  items.push({ id, label, tone });
}

/**
 * Keeps the bottom chrome quiet and bounded. Phone retains a terminal-first
 * surface; wider layouts receive only non-sensitive operational metadata.
 */
export function resolveSshWorkspaceStatus(input: SshWorkspaceStatusInput): SshWorkspaceStatusView {
  if (input.mode === 'sm') { return { visible: false, compact: true, items: [] }; }

  const items: Array<SshWorkspaceStatusItem> = [connectionStatus(input)];
  if (input.persistenceError) {
    append(items, 'persistence', '工作区未保存', 'danger');
  }
  if (input.transferAttentionCount > 0) {
    append(items, 'transfer', '传输 ' + input.transferAttentionCount.toString(), 'warning');
  }
  if (input.forwardingCount > 0) {
    append(items, 'forwarding', '隧道 ' + input.forwardingCount.toString(), 'positive');
  }
  if (input.cols > 0 && input.rows > 0) {
    append(items, 'grid', input.cols.toString() + '×' + input.rows.toString());
  }
  if (input.activePaneIndex >= 0 && input.visiblePaneCount > 0) {
    append(items, 'pane', 'Pane ' + (input.activePaneIndex + 1).toString() + '/' +
      input.visiblePaneCount.toString());
  }
  if (input.tabCount > 0) {
    append(items, 'tabs', input.tabCount.toString() + ' 个标签');
  }
  append(items, 'encoding', 'UTF-8');

  const maxItems: number = input.mode === 'md' ? 4 : (input.mode === 'lg' ? 6 : 8);
  return { visible: true, compact: input.mode === 'md', items: items.slice(0, maxItems) };
}
