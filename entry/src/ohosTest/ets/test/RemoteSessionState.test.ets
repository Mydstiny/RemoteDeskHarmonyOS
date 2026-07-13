/**
 * RemoteSessionState.test.ets — 远程会话状态机单元测试 (T-232)
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  RemoteProtocol,
  ConnectionPhase,
  UiVisibility,
  ExitReason,
  RenderPhase,
  AudioPhase,
  createInitialRemoteSessionState,
  markConnecting,
  markConnected,
  markDisconnecting,
  markDisconnected,
  markFailed,
  markUiBackground,
  markUiForeground,
  markBackgroundPreserved,
  markForegroundRestoring,
  markSurfaceReady,
  markRenderAttached,
  markRenderDetached,
  markRenderFailed,
  markAudioPlaying,
  markAudioStopped,
  markAudioFailed,
  isSessionActive,
  isBackgroundPreserved,
  shouldPreserveInBackground,
  shouldDisconnectNow,
  hasActiveAudio
} from '../../../main/ets/services/RemoteSessionState';

export default function remoteSessionStateTest(): void {
  describe('RemoteSessionState', (): void => {

    // ----- 初始状态 -----

    it('initial_state_should_be_idle_foreground', 0, (): void => {
      const state = createInitialRemoteSessionState(RemoteProtocol.rdp, 'host-001',
        '192.168.1.100');
      expect(state.connectionPhase).assertEqual(ConnectionPhase.idle);
      expect(state.uiVisibility).assertEqual(UiVisibility.foreground);
      expect(state.renderPhase).assertEqual(RenderPhase.none);
      expect(state.audioPhase).assertEqual(AudioPhase.none);
      expect(state.sessionId).assertEqual(-1);
      expect(state.preserveInBackground).assertEqual(true);
    });

    // ----- 连接生命周期 -----

    it('should_transition_idle_to_connecting_to_connected', 0, (): void => {
      let state = createInitialRemoteSessionState(RemoteProtocol.rustdesk, 'h2', '10.0.0.1');
      state = markConnecting(state);
      expect(state.connectionPhase).assertEqual(ConnectionPhase.connecting);
      state = markConnected(state, 42);
      expect(state.connectionPhase).assertEqual(ConnectionPhase.connected);
      expect(state.sessionId).assertEqual(42);
    });

    it('should_mark_disconnected_state', 0, (): void => {
      let state = createInitialRemoteSessionState(RemoteProtocol.rdp, 'h3', '172.16.0.1');
      state = markConnecting(state);
      state = markConnected(state, 1);
      state = markDisconnecting(state, ExitReason.explicitDisconnect);
      expect(state.connectionPhase).assertEqual(ConnectionPhase.disconnecting);
      state = markDisconnected(state, ExitReason.explicitDisconnect);
      expect(state.connectionPhase).assertEqual(ConnectionPhase.disconnected);
      expect(state.sessionId).assertEqual(-1);
      expect(state.uiVisibility).assertEqual(UiVisibility.destroyed);
    });

    it('should_mark_failed_with_error', 0, (): void => {
      let state = createInitialRemoteSessionState(RemoteProtocol.rdp, 'h4', '10.0.0.99');
      state = markConnecting(state);
      state = markFailed(state, 'ERR_TIMEOUT', '连接超时');
      expect(state.connectionPhase).assertEqual(ConnectionPhase.failed);
      expect(state.lastErrorCode).assertEqual('ERR_TIMEOUT');
      expect(state.lastErrorMessage).assertEqual('连接超时');
    });

    // ----- UI 可见性 -----

    it('should_track_ui_visibility_background_and_foreground', 0, (): void => {
      let state = createInitialRemoteSessionState(RemoteProtocol.rdp, 'h5', '10.0.0.1');
      state = markConnecting(state);
      state = markConnected(state, 1);
      state = markUiBackground(state);
      expect(state.uiVisibility).assertEqual(UiVisibility.background);
      state = markUiForeground(state);
      expect(state.uiVisibility).assertEqual(UiVisibility.foreground);
    });

    // ----- 后台保留 -----

    it('background_preserved_should_detach_render_keep_connection', 0, (): void => {
      let state = createInitialRemoteSessionState(RemoteProtocol.rustdesk, 'h6', '10.0.0.2');
      state = markConnecting(state);
      state = markConnected(state, 2);
      state = markRenderAttached(state);
      state = markAudioPlaying(state);
      expect(state.audioPhase).assertEqual(AudioPhase.playing);
      state = markBackgroundPreserved(state, ExitReason.homeGesture);
      expect(state.connectionPhase).assertEqual(ConnectionPhase.backgroundPreserved);
      expect(state.uiVisibility).assertEqual(UiVisibility.background);
      expect(state.renderPhase).assertEqual(RenderPhase.detached);
      expect(state.audioPhase).assertEqual(AudioPhase.backgroundPlaying);
      expect(state.preserveInBackground).assertEqual(true);
    });

    it('background_preserved_no_audio_should_not_set_background_playing', 0, (): void => {
      let state = createInitialRemoteSessionState(RemoteProtocol.rdp, 'h7', '10.0.0.3');
      state = markConnecting(state);
      state = markConnected(state, 3);
      state = markBackgroundPreserved(state, ExitReason.homeGesture);
      expect(state.connectionPhase).assertEqual(ConnectionPhase.backgroundPreserved);
      expect(state.audioPhase).assertEqual(AudioPhase.none);
    });

    // ----- 前台恢复 -----

    it('foreground_restoring_should_restore_render_and_audio', 0, (): void => {
      let state = createInitialRemoteSessionState(RemoteProtocol.rdp, 'h8', '10.0.0.4');
      state = markConnecting(state);
      state = markConnected(state, 4);
      state = markRenderAttached(state);
      state = markAudioPlaying(state);
      state = markBackgroundPreserved(state, ExitReason.homeGesture);
      state = markForegroundRestoring(state);
      expect(state.connectionPhase).assertEqual(ConnectionPhase.foregroundRestoring);
      expect(state.uiVisibility).assertEqual(UiVisibility.foreground);
      expect(state.renderPhase).assertEqual(RenderPhase.restoring);
      expect(state.audioPhase).assertEqual(AudioPhase.playing);
    });

    // ----- 销毁时 disconnect -----

    it('recent_task_clear_should_set_must_disconnect_on_destroy', 0, (): void => {
      let state = createInitialRemoteSessionState(RemoteProtocol.rdp, 'h9', '10.0.0.5');
      state = markConnecting(state);
      state = markConnected(state, 5);
      state = markDisconnecting(state, ExitReason.recentTaskCleared);
      expect(state.mustDisconnectOnDestroy).assertEqual(true);
    });

    it('ability_destroy_should_set_must_disconnect_on_destroy', 0, (): void => {
      let state = createInitialRemoteSessionState(RemoteProtocol.rustdesk, 'h10', '10.0.0.6');
      state = markConnecting(state);
      state = markConnected(state, 6);
      state = markDisconnecting(state, ExitReason.abilityDestroy);
      expect(state.mustDisconnectOnDestroy).assertEqual(true);
    });

    it('explicit_disconnect_should_not_set_must_disconnect_on_destroy', 0, (): void => {
      let state = createInitialRemoteSessionState(RemoteProtocol.rdp, 'h11', '10.0.0.7');
      state = markConnecting(state);
      state = markConnected(state, 7);
      state = markDisconnecting(state, ExitReason.explicitDisconnect);
      expect(state.mustDisconnectOnDestroy).assertEqual(false);
    });

    // ----- 渲染阶段 -----

    it('render_phases_should_transition_none_to_attached_to_detached', 0, (): void => {
      let state = createInitialRemoteSessionState(RemoteProtocol.rdp, 'h12', '10.0.0.8');
      expect(state.renderPhase).assertEqual(RenderPhase.none);
      state = markSurfaceReady(state);
      expect(state.renderPhase).assertEqual(RenderPhase.surfaceReady);
      state = markRenderAttached(state);
      expect(state.renderPhase).assertEqual(RenderPhase.attached);
      state = markRenderDetached(state);
      expect(state.renderPhase).assertEqual(RenderPhase.detached);
    });

    it('render_failed_should_set_error', 0, (): void => {
      let state = createInitialRemoteSessionState(RemoteProtocol.rdp, 'h13', '10.0.0.9');
      state = markRenderFailed(state, 'ERR_GL_INIT', 'EGL 初始化失败');
      expect(state.renderPhase).assertEqual(RenderPhase.failed);
      expect(state.lastErrorCode).assertEqual('ERR_GL_INIT');
    });

    // ----- 查询辅助 -----

    it('is_session_active_should_return_true_for_connected_and_preserved', 0, (): void => {
      let state = createInitialRemoteSessionState(RemoteProtocol.rdp, 'h14', '10.0.0.10');
      state = markConnecting(state);
      expect(isSessionActive(state)).assertEqual(false);
      state = markConnected(state, 8);
      expect(isSessionActive(state)).assertEqual(true);
      state = markBackgroundPreserved(state, ExitReason.homeGesture);
      expect(isSessionActive(state)).assertEqual(true);
      state = markDisconnected(state, ExitReason.explicitDisconnect);
      expect(isSessionActive(state)).assertEqual(false);
    });

    it('has_active_audio_should_return_true_only_when_playing', 0, (): void => {
      let state = createInitialRemoteSessionState(RemoteProtocol.rdp, 'h15', '10.0.0.11');
      expect(hasActiveAudio(state)).assertEqual(false);
      state = markAudioPlaying(state);
      expect(hasActiveAudio(state)).assertEqual(true);
      state = markAudioStopped(state);
      expect(hasActiveAudio(state)).assertEqual(false);
    });

    it('should_not_preserve_when_not_active', 0, (): void => {
      const state = createInitialRemoteSessionState(RemoteProtocol.rdp, 'h16', '10.0.0.12');
      expect(shouldPreserveInBackground(state)).assertEqual(false);
    });

    it('phase_changed_timestamp_should_update_on_transitions', 0, (): void => {
      const state = createInitialRemoteSessionState(RemoteProtocol.rdp, 'h17', '10.0.0.13');
      const t0: number = state.phaseChangedAtMs;
      const next = markConnecting(state);
      expect(next.phaseChangedAtMs >= t0).assertEqual(true);
    });
  });
}
