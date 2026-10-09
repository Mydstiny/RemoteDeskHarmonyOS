/** One saved host as the AI chat may see it: never its address, user name, password or keys. */
export class AiHostSummary {
  label: string;
  protocol: string;
  group: string;
  lastConnected: number;
  /** 0 unknown, 1 excellent … 5 bad (the last measured network). */
  health: number;
  latencyMs: number;
  /** 主机健康中心 (Pro): the last check in words — state, why, how long ago; '' without one. */
  healthCheck: string;

  constructor(label: string, protocol: string, group: string, lastConnected: number, health: number, latencyMs: number,
    healthCheck: string = '') {
    this.label = label;
    this.protocol = protocol;
    this.group = group;
    this.lastConnected = lastConnected;
    this.health = health;
    this.latencyMs = latencyMs;
    this.healthCheck = healthCheck;
  }
}

/**
 * The host page lends the AI chat a read-only view of the saved hosts (the chat lives in an overlay and cannot reach
 * the page's state itself). Nothing is read until the chat's 主机列表 tool asks.
 */
export class AiAppDataBridge {
  private static lister: (() => AiHostSummary[]) | null = null;

  static register(list: () => AiHostSummary[]): void { AiAppDataBridge.lister = list; }

  static unregister(list: () => AiHostSummary[]): void {
    if (AiAppDataBridge.lister === list) { AiAppDataBridge.lister = null; }
  }

  static hosts(): AiHostSummary[] {
    const list = AiAppDataBridge.lister;
    if (list === null) { return []; }
    try { return list(); } catch (_error) { return []; }
  }
}

const PROTOCOL_NAMES: string[][] = [['rdp', 'RDP'], ['rustdesk', 'RustDesk'], ['ssh', 'SSH'], ['vnc', 'VNC'], ['moonlight', 'Moonlight']];
const HEALTH_WORDS: string[] = ['未知', '很好', '良好', '一般', '较差', '很差'];

export function aiProtocolName(protocol: string): string {
  const pair: string[] | undefined = PROTOCOL_NAMES.find((p: string[]): boolean => p[0] === protocol);
  return pair !== undefined ? pair[1] : protocol.toUpperCase();
}

function pad(value: number): string { return (value < 10 ? '0' : '') + value.toString(); }

/** "10月2日 周五 14:20" */
export function aiTimeText(time: number): string {
  if (time <= 0) { return '从未'; }
  const date: Date = new Date(time);
  return (date.getMonth() + 1).toString() + '月' + date.getDate().toString() + '日 周' + '日一二三四五六'.charAt(date.getDay()) +
    ' ' + pad(date.getHours()) + ':' + pad(date.getMinutes());
}

/** The hosts as the list_hosts tool returns them. */
export function aiHostsText(hosts: AiHostSummary[], protocol: string): string {
  const shown: AiHostSummary[] = protocol === '' ? hosts : hosts.filter((h: AiHostSummary): boolean => h.protocol === protocol);
  if (shown.length === 0) { return protocol === '' ? '用户还没有保存任何主机。' : '没有 ' + aiProtocolName(protocol) + ' 主机。'; }
  const counts: string[] = PROTOCOL_NAMES.map((p: string[]): string => {
    const n: number = shown.filter((h: AiHostSummary): boolean => h.protocol === p[0]).length;
    return n > 0 ? p[1] + ' ' + n.toString() + ' 台' : '';
  }).filter((text: string): boolean => text !== '');
  const rows: string[] = shown.slice()
    .sort((a: AiHostSummary, b: AiHostSummary): number => b.lastConnected - a.lastConnected).slice(0, 150)
    .map((h: AiHostSummary): string => h.label + ' | ' + aiProtocolName(h.protocol) + ' | ' + (h.group !== '' ? h.group : '未分组') +
      ' | ' + aiTimeText(h.lastConnected) + ' | ' + (HEALTH_WORDS[h.health] ?? '未知') +
      (h.latencyMs > 0 ? '（' + h.latencyMs.toString() + ' ms）' : '') +
      (h.healthCheck !== '' ? ' | ' + h.healthCheck : ''));
  const checked: boolean = shown.some((h: AiHostSummary): boolean => h.healthCheck !== '');
  return '共 ' + shown.length.toString() + ' 台主机（' + counts.join('、') + '）。\n名称 | 协议 | 分组 | 最近连接 | 最近网络' +
    (checked ? ' | 健康检测（主机健康中心最近一次检测：状态、原因、时间）' : '') + '\n' + rows.join('\n');
}

/** One connection-log entry in words (time, host, protocol, result). */
export interface AiConnectionRow { at: number; label: string; protocol: string; outcome: string; detail: string; }

/** The connection log as the connection_history tool returns it: a summary first, then the entries. */
export function aiConnectionsText(rows: AiConnectionRow[], days: number, hosts: AiHostSummary[]): string {
  const since: number = Date.now() - days * 24 * 3600 * 1000;
  const recentHosts: AiHostSummary[] = hosts.filter((h: AiHostSummary): boolean => h.lastConnected >= since)
    .sort((a: AiHostSummary, b: AiHostSummary): number => b.lastConnected - a.lastConnected);
  if (rows.length === 0) {
    return '最近 ' + days.toString() + ' 天的连接记录为空（连接记录从这个版本开始保存）。' +
      (recentHosts.length > 0 ? '按主机的“最近连接时间”，这段时间连接过：' +
        recentHosts.slice(0, 40).map((h: AiHostSummary): string => h.label + '（' + aiProtocolName(h.protocol) + '，' +
          aiTimeText(h.lastConnected) + '）').join('、') + '。' : '');
  }
  const ok: AiConnectionRow[] = rows.filter((r: AiConnectionRow): boolean => r.outcome === 'connected');
  const failed: AiConnectionRow[] = rows.filter((r: AiConnectionRow): boolean => r.outcome === 'failed');
  const byHost: Map<string, number> = new Map<string, number>();
  const lastAt: Map<string, number> = new Map<string, number>();
  ok.forEach((r: AiConnectionRow): void => {
    const key: string = r.label + '（' + aiProtocolName(r.protocol) + '）';
    byHost.set(key, (byHost.get(key) ?? 0) + 1);
    lastAt.set(key, Math.max(lastAt.get(key) ?? 0, r.at));
  });
  const hostLines: string[] = [];
  byHost.forEach((count: number, key: string): void => {
    hostLines.push(key + ' ' + count.toString() + ' 次，最后一次 ' + aiTimeText(lastAt.get(key) ?? 0));
  });
  const activeDays: number = new Set<string>(ok.map((r: AiConnectionRow): string => new Date(r.at).toDateString())).size;
  return '最近 ' + days.toString() + ' 天：成功连接 ' + ok.length.toString() + ' 次（' + activeDays.toString() + ' 天有连接），失败 ' +
    failed.length.toString() + ' 次，涉及 ' + byHost.size.toString() + ' 台主机。\n按主机：\n' + hostLines.join('\n') +
    (failed.length > 0 ? '\n失败：\n' + failed.slice(-30).map((r: AiConnectionRow): string =>
      aiTimeText(r.at) + ' ' + aiProtocolName(r.protocol) + ' ' + r.detail).join('\n') : '') +
    '\n明细（最近 80 条）：\n' + rows.slice(-80).map((r: AiConnectionRow): string => aiTimeText(r.at) + ' · ' +
      (r.label !== '' ? r.label + ' · ' : '') + aiProtocolName(r.protocol) + ' · ' + (r.outcome === 'connected' ? '成功' : '失败：' + r.detail))
      .join('\n');
}
