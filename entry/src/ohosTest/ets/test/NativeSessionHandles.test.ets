/**
 * NativeSessionHandles.test.ets — Native handle 生命周期测试 (T-233)
 * 验证后台脱附 vs 完全断连的调用顺序。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  NativeHandleAdapter,
  NativeSessionHandles
} from '../../../main/ets/services/NativeSessionHandles';
import { RemoteProtocol } from '../../../main/ets/services/RemoteSessionState';

// 测试 spy — 记录每次调用和参数
class SpyAdapter implements NativeHandleAdapter {
  calls: string[] = [];
  lastSurfaceId: string = '';
  lastWidth: number = 0;
  lastHeight: number = 0;

  markXComponentSurfaceDestroyed(): void {
    this.calls.push('markXComponentSurfaceDestroyed');
  }

  destroyRendererOnly(): void {
    this.calls.push('destroyRendererOnly');
  }

  disconnectProtocol(): void {
    this.calls.push('disconnectProtocol');
  }

  destroyAudio(): void {
    this.calls.push('destroyAudio');
  }

  rebindSurface(surfaceId: string, width: number, height: number): void {
    this.calls.push('rebindSurface');
    this.lastSurfaceId = surfaceId;
    this.lastWidth = width;
    this.lastHeight = height;
  }

  requestFrameRefresh(): void {
    this.calls.push('requestFrameRefresh');
  }

  reset(): void {
    this.calls = [];
  }
}

export default function nativeSessionHandlesTest(): void {
  describe('NativeSessionHandles', (): void => {

    // ----- 初始状态 -----

    it('initial_state_should_have_nothing_connected', 0, (): void => {
      const spy = new SpyAdapter();
      const handles = new NativeSessionHandles(spy);
      expect(handles.isProtocolConnected()).assertEqual(false);
      expect(handles.isRenderAttached()).assertEqual(false);
      expect(handles.isAudioActive()).assertEqual(false);
      expect(handles.getSessionId()).assertEqual(-1);
    });

    // ----- 连接 attach -----

    it('attach_connected_session_should_set_protocol_state', 0, (): void => {
      const spy = new SpyAdapter();
      const handles = new NativeSessionHandles(spy);
      handles.attachConnectedSession(42, RemoteProtocol.rdp);
      expect(handles.isProtocolConnected()).assertEqual(true);
      expect(handles.getSessionId()).assertEqual(42);
      expect(handles.getProtocol()).assertEqual(RemoteProtocol.rdp);
    });

    // ----- 渲染 attach -----

    it('mark_surface_attached_should_set_render_state', 0, (): void => {
      const spy = new SpyAdapter();
      const handles = new NativeSessionHandles(spy);
      handles.attachConnectedSession(1, RemoteProtocol.rdp);
      handles.markSurfaceAttached(100);
      expect(handles.isRenderAttached()).assertEqual(true);
    });

    // ----- 后台脱附 (核心测试 — 不误标记真实 surface 销毁) -----

    it('detach_render_for_background_should_detach_render_only_not_protocol', 0, (): void => {
      const spy = new SpyAdapter();
      const handles = new NativeSessionHandles(spy);
      handles.attachConnectedSession(7, RemoteProtocol.rustdesk);
      handles.markSurfaceAttached(200);
      handles.markAudioStarted();
      spy.reset();

      handles.detachRenderForBackground();

      // Home 后台只释放 renderer/EGL；真实 onSurfaceDestroyed / 完全断连才标记 surface destroyed。
      expect(spy.calls.length).assertEqual(1);
      expect(spy.calls[0]).assertEqual('destroyRendererOnly');
      expect(spy.calls.indexOf('markXComponentSurfaceDestroyed') < 0).assertEqual(true);

      // 验证不调用 disconnectProtocol 和 destroyAudio
      expect(spy.calls.indexOf('disconnectProtocol') < 0).assertEqual(true);
      expect(spy.calls.indexOf('destroyAudio') < 0).assertEqual(true);

      // 验证状态
      expect(handles.isRenderAttached()).assertEqual(false);
      expect(handles.isProtocolConnected()).assertEqual(true);
      expect(handles.isAudioActive()).assertEqual(true);
    });

    it('detach_render_for_background_when_not_attached_should_be_noop', 0, (): void => {
      const spy = new SpyAdapter();
      const handles = new NativeSessionHandles(spy);
      handles.attachConnectedSession(1, RemoteProtocol.rdp);
      handles.detachRenderForBackground();
      expect(spy.calls.length).assertEqual(0);
    });

    // ----- 完全断连 (核心测试 — 验证调用顺序) -----

    it('disconnect_and_release_should_follow_safe_order', 0, (): void => {
      const spy = new SpyAdapter();
      const handles = new NativeSessionHandles(spy);
      handles.attachConnectedSession(8, RemoteProtocol.rdp);
      handles.markSurfaceAttached(300);
      handles.markAudioStarted();
      spy.reset();

      handles.disconnectAndRelease('test');

      // 严格顺序: surface → renderer → audio → protocol
      // 至少有 4 个调用
      expect(spy.calls.length >= 4).assertEqual(true);
      const surfaceIdx: number = spy.calls.indexOf('markXComponentSurfaceDestroyed');
      const renderIdx: number = spy.calls.indexOf('destroyRendererOnly');
      const audioIdx: number = spy.calls.indexOf('destroyAudio');
      const protoIdx: number = spy.calls.indexOf('disconnectProtocol');

      expect(surfaceIdx >= 0).assertEqual(true);
      expect(renderIdx >= 0).assertEqual(true);
      expect(audioIdx >= 0).assertEqual(true);
      expect(protoIdx >= 0).assertEqual(true);

      // surface 必须在 renderer 之前
      expect(surfaceIdx < renderIdx).assertEqual(true);
      // audio 必须在 protocol 之前
      expect(audioIdx < protoIdx).assertEqual(true);
    });

    it('disconnect_and_release_should_clear_all_state', 0, (): void => {
      const spy = new SpyAdapter();
      const handles = new NativeSessionHandles(spy);
      handles.attachConnectedSession(9, RemoteProtocol.rustdesk);
      handles.markSurfaceAttached(400);
      handles.markAudioStarted();

      handles.disconnectAndRelease('cleanup');

      expect(handles.isProtocolConnected()).assertEqual(false);
      expect(handles.isRenderAttached()).assertEqual(false);
      expect(handles.isAudioActive()).assertEqual(false);
      expect(handles.getSessionId()).assertEqual(-1);
    });

    // ----- 前台恢复 -----

    it('reattach_render_for_foreground_should_rebind_and_request_refresh', 0, (): void => {
      const spy = new SpyAdapter();
      const handles = new NativeSessionHandles(spy);
      handles.attachConnectedSession(10, RemoteProtocol.rdp);
      spy.reset();

      handles.reattachRenderForForeground('rdpSurface', 1920, 1080);

      expect(spy.calls[0]).assertEqual('rebindSurface');
      expect(spy.calls[1]).assertEqual('requestFrameRefresh');
      expect(spy.lastSurfaceId).assertEqual('rdpSurface');
      expect(spy.lastWidth).assertEqual(1920);
      expect(spy.lastHeight).assertEqual(1080);
      expect(handles.isRenderAttached()).assertEqual(true);
    });

    it('reattach_when_already_attached_should_be_noop', 0, (): void => {
      const spy = new SpyAdapter();
      const handles = new NativeSessionHandles(spy);
      handles.attachConnectedSession(11, RemoteProtocol.rdp);
      handles.reattachRenderForForeground('s', 100, 100);
      const count: number = spy.calls.length;
      handles.reattachRenderForForeground('s2', 200, 200);
      // 不应再次调用
      expect(spy.calls.length).assertEqual(count);
    });

    // ----- 仅停止音频 -----

    it('stop_audio_only_should_destroy_audio_keep_render_and_protocol', 0, (): void => {
      const spy = new SpyAdapter();
      const handles = new NativeSessionHandles(spy);
      handles.attachConnectedSession(12, RemoteProtocol.rdp);
      handles.markSurfaceAttached(500);
      handles.markAudioStarted();
      spy.reset();

      handles.stopAudioOnly();

      expect(spy.calls.indexOf('destroyAudio') >= 0).assertEqual(true);
      expect(spy.calls.indexOf('disconnectProtocol') < 0).assertEqual(true);
      expect(spy.calls.indexOf('destroyRendererOnly') < 0).assertEqual(true);
      expect(handles.isAudioActive()).assertEqual(false);
      expect(handles.isRenderAttached()).assertEqual(true);
      expect(handles.isProtocolConnected()).assertEqual(true);
    });
  });
}
