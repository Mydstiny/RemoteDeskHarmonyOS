/**
 * RustDeskDiagnosticsPolicy — 诊断开关、生命周期和数值显示的纯规则。
 *
 * 这里不读取 Preferences，也不调用 native；这样基础开关和 Pro 子开关的
 * 依赖关系可以在没有连接、没有设备资源接口的情况下独立测试。
 */

export function shouldShowSessionDiagnostics(showDiagnostics: boolean,
  connected: boolean, protocol: string, sessionId: number): boolean {
  return showDiagnostics && connected &&
    (protocol === 'rustdesk' || protocol === 'vnc') && sessionId > 0;
}

export function shouldShowRustDeskDiagnostics(showDiagnostics: boolean,
  connected: boolean, protocol: string, sessionId: number): boolean {
  return shouldShowSessionDiagnostics(showDiagnostics, connected, protocol, sessionId) &&
    protocol === 'rustdesk';
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
    return '静止 / 待更新';
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
    return '画面静止或停滞';
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

export function rustDeskCodecPreferenceLabel(preference: number): string {
  if (preference === 1) { return 'VP8'; }
  if (preference === 2) { return 'VP9'; }
  if (preference === 3) { return 'AV1'; }
  if (preference === 4) { return 'H264'; }
  if (preference === 5) { return 'H265'; }
  return '自动';
}

export function rustDeskCodecForPreference(preference: number): number {
  if (preference === 1) { return 2; }
  if (preference === 2) { return 3; }
  if (preference === 3) { return 4; }
  if (preference === 4) { return 0; }
  if (preference === 5) { return 1; }
  return -1;
}

export interface RustDeskCodecAlignment {
  preference: string;
  actual: string;
  state: string;
  aligned: boolean;
}

/** Keep the reconnect-scoped preference distinct from the codec observed on real frames. */
export function rustDeskCodecAlignment(
  preference: number, actualCodec: number, videoSeen: boolean): RustDeskCodecAlignment {
  const requested: string = rustDeskCodecPreferenceLabel(preference);
  const actual: string = rustDeskCodecLabel(actualCodec);
  if (!videoSeen || actualCodec < 0 || actualCodec > 4) {
    return { preference: requested, actual: '等待视频流', state: '等待实际编码', aligned: false };
  }
  const expected: number = rustDeskCodecForPreference(preference);
  if (expected < 0) {
    return { preference: requested, actual, state: '自动协商', aligned: true };
  }
  if (expected === actualCodec) {
    return { preference: requested, actual, state: '偏好与实际流已对齐', aligned: true };
  }
  return { preference: requested, actual, state: '待重连重新协商', aligned: false };
}
