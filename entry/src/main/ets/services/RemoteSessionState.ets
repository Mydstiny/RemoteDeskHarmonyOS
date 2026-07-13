/**
 * RemoteSessionState.ets — 远程会话状态机 (T-232)
 *
 * 纯 ArkTS 状态模型，不依赖 native、UI 导入。所有字段显式类型，不使用 any/unknown。
 * 为远程连接保活提供统一的状态追踪和转换规则。
 */

// ====== 枚举定义 ======

export enum RemoteProtocol {
  rdp = 'rdp',
  rustdesk = 'rustdesk',
  ssh = 'ssh',
  vnc = 'vnc'
}

export enum ConnectionPhase {
  idle = 'idle',
  connecting = 'connecting',
  connected = 'connected',
  suspending = 'suspending',
  backgroundPreserved = 'backgroundPreserved',
  foregroundRestoring = 'foregroundRestoring',
  disconnecting = 'disconnecting',
  disconnected = 'disconnected',
  failed = 'failed'
}

export enum UiVisibility {
  foreground = 'foreground',
  background = 'background',
  destroyed = 'destroyed'
}

export enum ExitReason {
  homeGesture = 'homeGesture',
  systemBackground = 'systemBackground',
  explicitBack = 'explicitBack',
  explicitDisconnect = 'explicitDisconnect',
  recentTaskCleared = 'recentTaskCleared',
  abilityDestroy = 'abilityDestroy',
  error = 'error'
}

export enum RenderPhase {
  none = 'none',
  surfaceReady = 'surfaceReady',
  attached = 'attached',
  detached = 'detached',
  restoring = 'restoring',
  failed = 'failed'
}

export enum AudioPhase {
  none = 'none',
  starting = 'starting',
  playing = 'playing',
  backgroundPlaying = 'backgroundPlaying',
  stopped = 'stopped',
  failed = 'failed'
}

// ====== 状态记录 ======

export interface RemoteSessionSnapshot {
  sessionId: number;
  protocol: RemoteProtocol;
  hostId: string;
  hostAddress: string;
  connectionPhase: ConnectionPhase;
  uiVisibility: UiVisibility;
  renderPhase: RenderPhase;
  audioPhase: AudioPhase;
  preserveInBackground: boolean;
  mustDisconnectOnDestroy: boolean;
  lastErrorCode: string;
  lastErrorMessage: string;
  createdAtMs: number;
  phaseChangedAtMs: number;
}

// ====== 工厂函数 ======

export function createInitialRemoteSessionState(protocol: RemoteProtocol, hostId: string,
  hostAddress: string): RemoteSessionSnapshot {
  const now: number = Date.now();
  return {
    sessionId: -1,
    protocol: protocol,
    hostId: hostId,
    hostAddress: hostAddress,
    connectionPhase: ConnectionPhase.idle,
    uiVisibility: UiVisibility.foreground,
    renderPhase: RenderPhase.none,
    audioPhase: AudioPhase.none,
    preserveInBackground: true,
    mustDisconnectOnDestroy: false,
    lastErrorCode: '',
    lastErrorMessage: '',
    createdAtMs: now,
    phaseChangedAtMs: now
  };
}

// ====== Reducer helpers (返回新快照, 不修改原对象) ======

function withTimestamp(snapshot: RemoteSessionSnapshot, phase: ConnectionPhase): RemoteSessionSnapshot {
  return {
    sessionId: snapshot.sessionId,
    protocol: snapshot.protocol,
    hostId: snapshot.hostId,
    hostAddress: snapshot.hostAddress,
    connectionPhase: phase,
    uiVisibility: snapshot.uiVisibility,
    renderPhase: snapshot.renderPhase,
    audioPhase: snapshot.audioPhase,
    preserveInBackground: snapshot.preserveInBackground,
    mustDisconnectOnDestroy: snapshot.mustDisconnectOnDestroy,
    lastErrorCode: snapshot.lastErrorCode,
    lastErrorMessage: snapshot.lastErrorMessage,
    createdAtMs: snapshot.createdAtMs,
    phaseChangedAtMs: Date.now()
  };
}

export function markConnecting(snapshot: RemoteSessionSnapshot): RemoteSessionSnapshot {
  return withTimestamp(snapshot, ConnectionPhase.connecting);
}

export function markConnected(snapshot: RemoteSessionSnapshot, sessionId: number): RemoteSessionSnapshot {
  const next: RemoteSessionSnapshot = withTimestamp(snapshot, ConnectionPhase.connected);
  return {
    sessionId: sessionId,
    protocol: next.protocol,
    hostId: next.hostId,
    hostAddress: next.hostAddress,
    connectionPhase: next.connectionPhase,
    uiVisibility: next.uiVisibility,
    renderPhase: next.renderPhase,
    audioPhase: next.audioPhase,
    preserveInBackground: next.preserveInBackground,
    mustDisconnectOnDestroy: next.mustDisconnectOnDestroy,
    lastErrorCode: next.lastErrorCode,
    lastErrorMessage: next.lastErrorMessage,
    createdAtMs: next.createdAtMs,
    phaseChangedAtMs: next.phaseChangedAtMs
  };
}

export function markDisconnecting(snapshot: RemoteSessionSnapshot,
  reason: ExitReason): RemoteSessionSnapshot {
  const next: RemoteSessionSnapshot = withTimestamp(snapshot, ConnectionPhase.disconnecting);
  return {
    sessionId: next.sessionId,
    protocol: next.protocol,
    hostId: next.hostId,
    hostAddress: next.hostAddress,
    connectionPhase: next.connectionPhase,
    uiVisibility: next.uiVisibility,
    renderPhase: next.renderPhase,
    audioPhase: next.audioPhase,
    preserveInBackground: next.preserveInBackground,
    mustDisconnectOnDestroy: reason === ExitReason.recentTaskCleared ||
      reason === ExitReason.abilityDestroy,
    lastErrorCode: next.lastErrorCode,
    lastErrorMessage: next.lastErrorMessage,
    createdAtMs: next.createdAtMs,
    phaseChangedAtMs: next.phaseChangedAtMs
  };
}

export function markDisconnected(snapshot: RemoteSessionSnapshot,
  reason: ExitReason): RemoteSessionSnapshot {
  const next: RemoteSessionSnapshot = withTimestamp(snapshot, ConnectionPhase.disconnected);
  return {
    sessionId: -1,
    protocol: next.protocol,
    hostId: next.hostId,
    hostAddress: next.hostAddress,
    connectionPhase: next.connectionPhase,
    uiVisibility: UiVisibility.destroyed,
    renderPhase: RenderPhase.none,
    audioPhase: AudioPhase.none,
    preserveInBackground: false,
    mustDisconnectOnDestroy: false,
    lastErrorCode: next.lastErrorCode,
    lastErrorMessage: next.lastErrorMessage,
    createdAtMs: next.createdAtMs,
    phaseChangedAtMs: next.phaseChangedAtMs
  };
}

export function markFailed(snapshot: RemoteSessionSnapshot,
  errorCode: string, errorMessage: string): RemoteSessionSnapshot {
  const next: RemoteSessionSnapshot = withTimestamp(snapshot, ConnectionPhase.failed);
  return {
    sessionId: next.sessionId,
    protocol: next.protocol,
    hostId: next.hostId,
    hostAddress: next.hostAddress,
    connectionPhase: next.connectionPhase,
    uiVisibility: next.uiVisibility,
    renderPhase: next.renderPhase,
    audioPhase: next.audioPhase,
    preserveInBackground: next.preserveInBackground,
    mustDisconnectOnDestroy: next.mustDisconnectOnDestroy,
    lastErrorCode: errorCode,
    lastErrorMessage: errorMessage,
    createdAtMs: next.createdAtMs,
    phaseChangedAtMs: next.phaseChangedAtMs
  };
}

// ====== UI 可见性转换 ======

export function markUiBackground(snapshot: RemoteSessionSnapshot): RemoteSessionSnapshot {
  return {
    sessionId: snapshot.sessionId,
    protocol: snapshot.protocol,
    hostId: snapshot.hostId,
    hostAddress: snapshot.hostAddress,
    connectionPhase: snapshot.connectionPhase,
    uiVisibility: UiVisibility.background,
    renderPhase: snapshot.renderPhase,
    audioPhase: snapshot.audioPhase,
    preserveInBackground: snapshot.preserveInBackground,
    mustDisconnectOnDestroy: snapshot.mustDisconnectOnDestroy,
    lastErrorCode: snapshot.lastErrorCode,
    lastErrorMessage: snapshot.lastErrorMessage,
    createdAtMs: snapshot.createdAtMs,
    phaseChangedAtMs: Date.now()
  };
}

export function markUiForeground(snapshot: RemoteSessionSnapshot): RemoteSessionSnapshot {
  return {
    sessionId: snapshot.sessionId,
    protocol: snapshot.protocol,
    hostId: snapshot.hostId,
    hostAddress: snapshot.hostAddress,
    connectionPhase: snapshot.connectionPhase,
    uiVisibility: UiVisibility.foreground,
    renderPhase: snapshot.renderPhase,
    audioPhase: snapshot.audioPhase,
    preserveInBackground: snapshot.preserveInBackground,
    mustDisconnectOnDestroy: snapshot.mustDisconnectOnDestroy,
    lastErrorCode: snapshot.lastErrorCode,
    lastErrorMessage: snapshot.lastErrorMessage,
    createdAtMs: snapshot.createdAtMs,
    phaseChangedAtMs: Date.now()
  };
}

export function markBackgroundPreserved(snapshot: RemoteSessionSnapshot,
  reason: ExitReason): RemoteSessionSnapshot {
  const next: RemoteSessionSnapshot = withTimestamp(snapshot, ConnectionPhase.backgroundPreserved);
  return {
    sessionId: next.sessionId,
    protocol: next.protocol,
    hostId: next.hostId,
    hostAddress: next.hostAddress,
    connectionPhase: next.connectionPhase,
    uiVisibility: UiVisibility.background,
    renderPhase: RenderPhase.detached,
    audioPhase: snapshot.audioPhase === AudioPhase.playing ?
      AudioPhase.backgroundPlaying : snapshot.audioPhase,
    preserveInBackground: true,
    mustDisconnectOnDestroy: reason === ExitReason.recentTaskCleared ||
      reason === ExitReason.abilityDestroy,
    lastErrorCode: next.lastErrorCode,
    lastErrorMessage: next.lastErrorMessage,
    createdAtMs: next.createdAtMs,
    phaseChangedAtMs: next.phaseChangedAtMs
  };
}

export function markForegroundRestoring(
  snapshot: RemoteSessionSnapshot): RemoteSessionSnapshot {
  const next: RemoteSessionSnapshot = withTimestamp(snapshot, ConnectionPhase.foregroundRestoring);
  return {
    sessionId: next.sessionId,
    protocol: next.protocol,
    hostId: next.hostId,
    hostAddress: next.hostAddress,
    connectionPhase: next.connectionPhase,
    uiVisibility: UiVisibility.foreground,
    renderPhase: RenderPhase.restoring,
    audioPhase: snapshot.audioPhase === AudioPhase.backgroundPlaying ?
      AudioPhase.playing : snapshot.audioPhase,
    preserveInBackground: next.preserveInBackground,
    mustDisconnectOnDestroy: next.mustDisconnectOnDestroy,
    lastErrorCode: next.lastErrorCode,
    lastErrorMessage: next.lastErrorMessage,
    createdAtMs: next.createdAtMs,
    phaseChangedAtMs: next.phaseChangedAtMs
  };
}

// ====== 渲染阶段转换 ======

export function markSurfaceReady(snapshot: RemoteSessionSnapshot): RemoteSessionSnapshot {
  return {
    sessionId: snapshot.sessionId,
    protocol: snapshot.protocol,
    hostId: snapshot.hostId,
    hostAddress: snapshot.hostAddress,
    connectionPhase: snapshot.connectionPhase,
    uiVisibility: snapshot.uiVisibility,
    renderPhase: RenderPhase.surfaceReady,
    audioPhase: snapshot.audioPhase,
    preserveInBackground: snapshot.preserveInBackground,
    mustDisconnectOnDestroy: snapshot.mustDisconnectOnDestroy,
    lastErrorCode: snapshot.lastErrorCode,
    lastErrorMessage: snapshot.lastErrorMessage,
    createdAtMs: snapshot.createdAtMs,
    phaseChangedAtMs: Date.now()
  };
}

export function markRenderAttached(snapshot: RemoteSessionSnapshot): RemoteSessionSnapshot {
  return {
    sessionId: snapshot.sessionId,
    protocol: snapshot.protocol,
    hostId: snapshot.hostId,
    hostAddress: snapshot.hostAddress,
    connectionPhase: snapshot.connectionPhase,
    uiVisibility: snapshot.uiVisibility,
    renderPhase: RenderPhase.attached,
    audioPhase: snapshot.audioPhase,
    preserveInBackground: snapshot.preserveInBackground,
    mustDisconnectOnDestroy: snapshot.mustDisconnectOnDestroy,
    lastErrorCode: snapshot.lastErrorCode,
    lastErrorMessage: snapshot.lastErrorMessage,
    createdAtMs: snapshot.createdAtMs,
    phaseChangedAtMs: Date.now()
  };
}

export function markRenderDetached(snapshot: RemoteSessionSnapshot): RemoteSessionSnapshot {
  return {
    sessionId: snapshot.sessionId,
    protocol: snapshot.protocol,
    hostId: snapshot.hostId,
    hostAddress: snapshot.hostAddress,
    connectionPhase: snapshot.connectionPhase,
    uiVisibility: snapshot.uiVisibility,
    renderPhase: RenderPhase.detached,
    audioPhase: snapshot.audioPhase,
    preserveInBackground: snapshot.preserveInBackground,
    mustDisconnectOnDestroy: snapshot.mustDisconnectOnDestroy,
    lastErrorCode: snapshot.lastErrorCode,
    lastErrorMessage: snapshot.lastErrorMessage,
    createdAtMs: snapshot.createdAtMs,
    phaseChangedAtMs: Date.now()
  };
}

export function markRenderFailed(snapshot: RemoteSessionSnapshot,
  errorCode: string, errorMessage: string): RemoteSessionSnapshot {
  return {
    sessionId: snapshot.sessionId,
    protocol: snapshot.protocol,
    hostId: snapshot.hostId,
    hostAddress: snapshot.hostAddress,
    connectionPhase: snapshot.connectionPhase,
    uiVisibility: snapshot.uiVisibility,
    renderPhase: RenderPhase.failed,
    audioPhase: snapshot.audioPhase,
    preserveInBackground: snapshot.preserveInBackground,
    mustDisconnectOnDestroy: snapshot.mustDisconnectOnDestroy,
    lastErrorCode: errorCode,
    lastErrorMessage: errorMessage,
    createdAtMs: snapshot.createdAtMs,
    phaseChangedAtMs: Date.now()
  };
}

// ====== 音频阶段转换 ======

export function markAudioPlaying(snapshot: RemoteSessionSnapshot): RemoteSessionSnapshot {
  return {
    sessionId: snapshot.sessionId,
    protocol: snapshot.protocol,
    hostId: snapshot.hostId,
    hostAddress: snapshot.hostAddress,
    connectionPhase: snapshot.connectionPhase,
    uiVisibility: snapshot.uiVisibility,
    renderPhase: snapshot.renderPhase,
    audioPhase: snapshot.uiVisibility === UiVisibility.background ?
      AudioPhase.backgroundPlaying : AudioPhase.playing,
    preserveInBackground: snapshot.preserveInBackground,
    mustDisconnectOnDestroy: snapshot.mustDisconnectOnDestroy,
    lastErrorCode: snapshot.lastErrorCode,
    lastErrorMessage: snapshot.lastErrorMessage,
    createdAtMs: snapshot.createdAtMs,
    phaseChangedAtMs: Date.now()
  };
}

export function markAudioStopped(snapshot: RemoteSessionSnapshot): RemoteSessionSnapshot {
  return {
    sessionId: snapshot.sessionId,
    protocol: snapshot.protocol,
    hostId: snapshot.hostId,
    hostAddress: snapshot.hostAddress,
    connectionPhase: snapshot.connectionPhase,
    uiVisibility: snapshot.uiVisibility,
    renderPhase: snapshot.renderPhase,
    audioPhase: AudioPhase.stopped,
    preserveInBackground: snapshot.preserveInBackground,
    mustDisconnectOnDestroy: snapshot.mustDisconnectOnDestroy,
    lastErrorCode: snapshot.lastErrorCode,
    lastErrorMessage: snapshot.lastErrorMessage,
    createdAtMs: snapshot.createdAtMs,
    phaseChangedAtMs: Date.now()
  };
}

export function markAudioFailed(snapshot: RemoteSessionSnapshot,
  errorCode: string, errorMessage: string): RemoteSessionSnapshot {
  return {
    sessionId: snapshot.sessionId,
    protocol: snapshot.protocol,
    hostId: snapshot.hostId,
    hostAddress: snapshot.hostAddress,
    connectionPhase: snapshot.connectionPhase,
    uiVisibility: snapshot.uiVisibility,
    renderPhase: snapshot.renderPhase,
    audioPhase: AudioPhase.failed,
    preserveInBackground: snapshot.preserveInBackground,
    mustDisconnectOnDestroy: snapshot.mustDisconnectOnDestroy,
    lastErrorCode: errorCode,
    lastErrorMessage: errorMessage,
    createdAtMs: snapshot.createdAtMs,
    phaseChangedAtMs: Date.now()
  };
}

// ====== 查询辅助 ======

export function isSessionActive(snapshot: RemoteSessionSnapshot): boolean {
  return snapshot.connectionPhase === ConnectionPhase.connected ||
    snapshot.connectionPhase === ConnectionPhase.backgroundPreserved ||
    snapshot.connectionPhase === ConnectionPhase.foregroundRestoring;
}

export function isBackgroundPreserved(snapshot: RemoteSessionSnapshot): boolean {
  return snapshot.connectionPhase === ConnectionPhase.backgroundPreserved;
}

export function shouldPreserveInBackground(snapshot: RemoteSessionSnapshot): boolean {
  return snapshot.preserveInBackground && isSessionActive(snapshot) &&
    snapshot.uiVisibility === UiVisibility.foreground;
}

export function shouldDisconnectNow(snapshot: RemoteSessionSnapshot): boolean {
  return snapshot.mustDisconnectOnDestroy || !snapshot.preserveInBackground;
}

export function hasActiveAudio(snapshot: RemoteSessionSnapshot): boolean {
  return snapshot.audioPhase === AudioPhase.playing ||
    snapshot.audioPhase === AudioPhase.backgroundPlaying;
}
