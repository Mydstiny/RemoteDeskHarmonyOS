/**
 * RustDeskDiagnosticsPolicy — 诊断开关、生命周期和数值显示的纯规则。
 *
 * 这里不读取 Preferences，也不调用 native；这样基础开关和 Pro 子开关的
 * 依赖关系可以在没有连接、没有设备资源接口的情况下独立测试。
 */

export function shouldShowRustDeskDiagnostics(showDiagnostics: boolean,
  connected: boolean, protocol: string, sessionId: number): boolean {
  return showDiagnostics && connected && protocol === 'rustdesk' && sessionId > 0;
}

export function shouldEnableRustDeskPro(showDiagnostics: boolean, proEnabled: boolean): boolean {
  return showDiagnostics && proEnabled;
}

export interface RustDeskDiagnosticsPreferenceState {
  showDiagnostics: boolean;
  showProDiagnostics: boolean;
}

/**
 * Pro is a direct user choice, not a disabled child control. Enabling it
 * promotes the base monitor in the same preference update; disabling it leaves
 * the base monitor unchanged. Turning the base monitor off deliberately keeps
 * the Pro preference for the next session.
 */
export function resolveRustDeskProDiagnosticsToggle(showDiagnostics: boolean,
  _showProDiagnostics: boolean, nextProEnabled: boolean): RustDeskDiagnosticsPreferenceState {
  return {
    showDiagnostics: nextProEnabled ? true : showDiagnostics,
    showProDiagnostics: nextProEnabled
  };
}

export function isFiniteDiagnosticNumber(value: number): boolean {
  return value === value && value !== Infinity && value !== -Infinity;
}

export function formatDiagnosticRate(value: number): string {
  return isFiniteDiagnosticNumber(value) && value > 0 ? value.toFixed(1) : '—';
}

/** Keep sampling, idle, and unavailable states distinct from a measured zero. */
export function formatDiagnosticFrameRate(value: number, rateAvailable: boolean,
  videoSeen: boolean, stale: boolean): string {
  if (!videoSeen) {
    return '等待视频流';
  }
  if (stale) {
    return '已停滞';
  }
  if (!rateAvailable) {
    return '采样中';
  }
  return isFiniteDiagnosticNumber(value) && value >= 0 ? value.toFixed(1) : '—';
}

export function rustDeskDiagnosticsStreamState(videoSeen: boolean, lastFrameAgeMs: number): string {
  if (!videoSeen) {
    return '等待视频流';
  }
  if (isFiniteDiagnosticNumber(lastFrameAgeMs) && lastFrameAgeMs >= 3000) {
    return '已停滞';
  }
  return '正在接收';
}

export function formatDiagnosticLatency(value: number): string {
  return isFiniteDiagnosticNumber(value) && value >= 0 ? Math.round(value).toString() + ' ms' : '—';
}

export function formatDiagnosticBitrate(kbps: number): string {
  if (!isFiniteDiagnosticNumber(kbps) || kbps <= 0) {
    return '—';
  }
  return kbps >= 1000 ? (kbps / 1000).toFixed(1) + ' Mbps' : kbps.toFixed(0) + ' Kbps';
}

export function formatDiagnosticBytes(bytes: number): string {
  if (!isFiniteDiagnosticNumber(bytes) || bytes <= 0) {
    return '—';
  }
  if (bytes >= 1024 * 1024) {
    return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  }
  if (bytes >= 1024) {
    return (bytes / 1024).toFixed(1) + ' KB';
  }
  return Math.round(bytes).toString() + ' B';
}

export function formatDiagnosticDurationUs(value: number): string {
  if (!isFiniteDiagnosticNumber(value) || value <= 0) {
    return '—';
  }
  return value >= 1000 ? (value / 1000).toFixed(1) + ' ms' : Math.round(value).toString() + ' μs';
}

export function rustDeskCodecLabel(codec: number): string {
  if (codec === 0) { return 'H264'; }
  if (codec === 1) { return 'H265'; }
  if (codec === 2) { return 'VP8'; }
  if (codec === 3) { return 'VP9'; }
  if (codec === 4) { return 'AV1'; }
  return '—';
}
