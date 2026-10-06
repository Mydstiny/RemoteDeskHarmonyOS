/**
 * Read-only aggregate contract for the third-page relay directory.
 *
 * The directory may combine entries visually, but the `kind` and `owner`
 * fields are deliberately explicit so UI actions can never accidentally send
 * a VNC Gateway mutation to HostSyncService/RustDesk storage.
 */
export type RelayDirectoryKind = 'rustdesk' | 'vnc';
export type RelayDirectoryFilter = 'all' | RelayDirectoryKind;

export interface RelayDirectoryEntry {
  kind: RelayDirectoryKind;
  id: string;
  label: string;
  endpoint: string;
  path: string;
  enabled: boolean;
  status: string;
  owner: string;
}

export function relayDirectoryMatchesFilter(kind: RelayDirectoryKind,
  filter: RelayDirectoryFilter): boolean {
  return filter === 'all' || filter === kind;
}

export function relayDirectoryOwner(kind: RelayDirectoryKind): string {
  return kind === 'vnc' ? 'VncGatewayService/vncrecordv2' : 'HostSyncService/rustdeskrelays';
}

export function relayDirectoryEntry(kind: RelayDirectoryKind, id: string, label: string,
  endpoint: string, path: string, enabled: boolean, status: string): RelayDirectoryEntry {
  return { kind, id, label, endpoint, path, enabled, status, owner: relayDirectoryOwner(kind) };
}

// ---- The 中继 tab's wording and test results: what a RustDesk relay test found on each endpoint, what a VNC
// Gateway check means in plain words, and the save stages a user sees while a relay is being saved.

export type RelayHealthStatus = 'online' | 'error' | 'offline';

/** One relay test: both endpoints are probed, so a working relay with a dead ID server is not reported online. */
export interface RelayProbeSummary {
  status: RelayHealthStatus;
  /** Shown beside 在线: the relay endpoint's latency, or the reachable one's when only one answered. */
  latency: number;
  /** ID 服务器可达，中继服务器不可达 and the like. */
  detail: string;
}

export interface RelayProbeDetail {
  idReachable: boolean;
  idLatency: number;
  relayReachable: boolean;
  relayLatency: number;
  checkedAt: number;
}

export function summarizeRustDeskRelayProbe(idReachable: boolean, idLatency: number,
  relayReachable: boolean, relayLatency: number): RelayProbeSummary {
  if (idReachable && relayReachable) {
    return {
      status: 'online', latency: relayLatency,
      detail: 'ID 服务器 ' + idLatency.toString() + 'ms · 中继服务器 ' + relayLatency.toString() + 'ms'
    };
  }
  if (idReachable) {
    return { status: 'error', latency: idLatency, detail: 'ID 服务器可达，中继服务器不可达' };
  }
  if (relayReachable) {
    return { status: 'error', latency: relayLatency, detail: 'ID 服务器不可达，中继服务器可达' };
  }
  return { status: 'offline', latency: 0, detail: 'ID 服务器和中继服务器都不可达' };
}

/** The toast after a relay test. */
export function relayProbeToast(summary: RelayProbeSummary): string {
  if (summary.status === 'online') { return '中继在线 · ' + summary.latency.toString() + 'ms'; }
  return summary.detail;
}

/** Save stages (DataMutationStage) in words. */
export function relaySaveStageLabel(stage: string): string {
  switch (stage) {
    case 'validating': return '正在检查填写内容…';
    case 'waiting_gate': return '正在等待本地数据就绪…';
    case 'committing': return '正在保存到本机…';
    case 'verifying': return '正在确认保存结果…';
    case 'completed': return '已保存';
    default: return '正在保存…';
  }
}

/** Deleting a relay unbinds the RustDesk hosts that use it. */
export function relayDeleteMessage(boundHostCount: number, accountCount: number): string {
  let message: string = '删除后无法恢复。';
  if (boundHostCount > 0) {
    message += boundHostCount.toString() + ' 台主机正在使用它，删除后这些主机需要重新选择中继服务器。';
  }
  if (accountCount > 0) {
    message += '它的 ' + accountCount.toString() + ' 个 Server Pro 账户也会一并删除。';
  }
  return message;
}

export function vncGatewayDeleteMessage(label: string, boundHostCount: number): string {
  let message: string = '确定删除“' + label + '”吗？它保存的令牌也会一并删除。';
  if (boundHostCount > 0) {
    message += boundHostCount.toString() + ' 台 VNC 主机正在使用它，删除后需要为这些主机重新选择网关。';
  }
  return message;
}

export type VncGatewayCheckState = '' | 'running' | 'ok' | 'failed' | 'cancelled';

/** A VNC Gateway check's error code in plain words; the code itself is shown smaller, for support. */
export function vncGatewayCheckCodeText(code: string): string {
  switch (code) {
    case 'E-VNC-GATEWAY-TCP': return '网关端口连不上，请检查地址、端口和网络';
    case 'E-VNC-GATEWAY-BINDING': return '账号、网关或地址刚刚发生了变化，请重新检查';
    case 'E-VNC-ENDPOINT-INVALID':
    case 'E-VNC-ENDPOINT-BINDING':
    case 'E-VNC-ENDPOINT-OWNER':
    case 'E-VNC-ENDPOINT-TRANSPORT': return '网关地址无效，请编辑后重试';
    case 'E-VNC-CERT-TRUST-REQUIRED': return '需要先确认这台网关的证书';
    case 'E-VNC-CERT-CHANGED': return '网关证书和上次确认的不一致，请核对后重新确认';
    case 'E-VNC-CERT-CANCELLED': return '检查已取消';
    case 'E-VNC-CERT-TLS-TIMEOUT':
    case 'E-VNC-CERT-CONNECT-TIMEOUT': return '连接网关超时';
    case 'E-VNC-CERT-TLS-VERSION':
    case 'E-VNC-CERT-TLS-HANDSHAKE':
    case 'E-VNC-CERT-TLS-CONTEXT':
    case 'E-VNC-CERT-TLS-SESSION': return '和网关建立加密连接失败';
    case 'E-VNC-CERT-NO-CERTIFICATE': return '网关没有提供证书';
    case 'E-VNC-REPEATER-BANNER': return '对方不是 UltraVNC 中继服务器，或版本不兼容';
    case 'E-VNC-REPEATER-TARGET': return '目标 ID 无效，或目标电脑未连到中继';
    case 'E-VNC-RFB-BANNER': return '已连到中继，但目标电脑没有返回 VNC 响应';
    case 'E-VNC-GATEWAY-DISABLED': return '这台网关已停用';
    case 'E-VNC-GATEWAY-TRANSPORT': return '这种网关类型暂不支持';
    case 'E-VNC-GATEWAY-DEEP': return '深度检查失败，请稍后重试';
    default: return code === '' ? '' : '检查失败';
  }
}

/**
 * What a check result says to the user: the native or policy message when it is already words, else the code's
 * text. Internal words (Sheet, endpoint, banner, target) are replaced.
 */
export function vncGatewayCheckMessage(code: string, message: string): string {
  const plain: string = message.trim()
    .replace(/\s*Sheet\s*/g, '弹窗')
    .replace(/\s*endpoint\s*/g, '地址')
    .replace(/RFB banner\s*/g, 'VNC 响应')
    .replace(/Repeater banner\s*/g, '中继响应')
    .replace(/\s*banner\s*/g, '响应')
    .replace(/\s*target\s*/g, '目标');
  if (plain !== '' && !/^E-VNC-/.test(plain)) { return plain; }
  return vncGatewayCheckCodeText(code);
}
