/**
 * NativeSessionHandles.ets — Native handle 生命周期统一封装 (T-233)
 *
 * 集中管理 native handle 的 attach/detach/disconnect 生命周期，
 * 区分"后台脱附"与"完全断连+释放"两种路径。
 * 通过可注入的适配器接口支持测试中的调用顺序断言。
 */

import { RemoteProtocol } from './RemoteSessionState';

// ====== 适配器接口 (注入以支持测试) ======

export interface NativeHandleAdapter {
  /** 标记 XComponent surface 已销毁 (仅真实销毁/完全断连路径在 renderer destroy 之前调用) */
  markXComponentSurfaceDestroyed(): void;

  /** 仅销毁渲染器, 不触碰协议连接和音频 */
  destroyRendererOnly(): void;

  /** 断开协议连接 */
  disconnectProtocol(): void;

  /** 销毁音频 */
  destroyAudio(): void;

  /** 重新绑定 surface (前台恢复时) */
  rebindSurface(surfaceId: string, width: number, height: number): void;

  /** 请求关键帧刷新 (前台恢复后) */
  requestFrameRefresh(): void;
}

// ====== 默认的生产适配器 (连接 ExtensionLoader) ======

export class ProductionNativeHandleAdapter implements NativeHandleAdapter {
  private loaderGet: () => ExtensionLoaderLike;

  constructor(loaderGet: () => ExtensionLoaderLike) {
    this.loaderGet = loaderGet;
  }

  markXComponentSurfaceDestroyed(): void {
    this.loaderGet().markXComponentSurfaceDestroyed();
  }

  destroyRendererOnly(): void {
    this.loaderGet().destroyRenderer();
  }

  disconnectProtocol(): void {
    this.loaderGet().disconnect();
  }

  destroyAudio(): void {
    this.loaderGet().destroyAudioPlayer();
  }

  rebindSurface(surfaceId: string, width: number, height: number): void {
    this.loaderGet().initRenderer(surfaceId, width, height);
  }

  requestFrameRefresh(): void {
    this.loaderGet().requestFrameRefresh();
  }
}

// ====== ExtensionLoader 所需的最小接口 (避免循环导入) ======

export interface ExtensionLoaderLike {
  disconnect(): void;
  destroyRenderer(): void;
  destroyAudioPlayer(): void;
  initRenderer(surfaceId: string, width: number, height: number): number;
  markXComponentSurfaceDestroyed(): void;
  requestFrameRefresh(): void;
}

// ====== NativeSessionHandles ======

export class NativeSessionHandles {
  private sessionId: number = -1;
  private protocol: RemoteProtocol = RemoteProtocol.rdp;
  private protocolConnected: boolean = false;
  private renderAttached: boolean = false;
  private audioActive: boolean = false;
  private rendererHandle: number = -1;
  private adapter: NativeHandleAdapter;

  constructor(adapter: NativeHandleAdapter) {
    this.adapter = adapter;
  }

  // ---- 生命周期操作 ----

  attachConnectedSession(sessionId: number, protocol: RemoteProtocol): void {
    this.sessionId = sessionId;
    this.protocol = protocol;
    this.protocolConnected = true;
  }

  markSurfaceAttached(rendererHandle: number): void {
    this.rendererHandle = rendererHandle;
    this.renderAttached = true;
  }

  /**
   * 后台脱附: 只销毁渲染器, 保留协议连接、音频和 XComponent surface。
   * Home 后台不等同于 XComponent surface destroyed；误标记会跳过 EGL surface teardown。
   */
  detachRenderForBackground(): void {
    if (!this.renderAttached) {
      return;
    }
    this.adapter.destroyRendererOnly();
    this.renderAttached = false;
    this.rendererHandle = -1;
  }

  /**
   * 前台恢复: 重新绑定 surface → 初始化渲染器 → 请求关键帧。
   */
  reattachRenderForForeground(surfaceId: string, width: number, height: number): void {
    if (this.renderAttached) {
      return;
    }
    this.adapter.rebindSurface(surfaceId, width, height);
    this.renderAttached = true;
    this.adapter.requestFrameRefresh();
  }

  /**
   * 仅停止音频, 不影响渲染和协议。
   */
  stopAudioOnly(): void {
    if (!this.audioActive) {
      return;
    }
    this.adapter.destroyAudio();
    this.audioActive = false;
  }

  /**
   * 完全断连+释放: 先 mark surface destroyed → 渲染清理 → 音频清理 → 协议断连。
   * 严格顺序: surface → renderer → audio → protocol。
   */
  disconnectAndRelease(reason: string): void {
    // 1. 标记 surface destroyed (如果渲染仍然 attached)
    if (this.renderAttached) {
      this.adapter.markXComponentSurfaceDestroyed();
      this.adapter.destroyRendererOnly();
      this.renderAttached = false;
      this.rendererHandle = -1;
    }

    // 2. 销毁音频
    if (this.audioActive) {
      this.adapter.destroyAudio();
      this.audioActive = false;
    }

    // 3. 断开协议
    if (this.protocolConnected) {
      this.adapter.disconnectProtocol();
      this.protocolConnected = false;
    }

    this.sessionId = -1;
  }

  // ---- 标记方法 (用于外部状态同步) ----

  markAudioStarted(): void {
    this.audioActive = true;
  }

  markAudioStopped(): void {
    this.audioActive = false;
  }

  markProtocolDisconnected(): void {
    this.protocolConnected = false;
    this.sessionId = -1;
  }

  // ---- 查询方法 ----

  isProtocolConnected(): boolean {
    return this.protocolConnected;
  }

  isRenderAttached(): boolean {
    return this.renderAttached;
  }

  isAudioActive(): boolean {
    return this.audioActive;
  }

  getSessionId(): number {
    return this.sessionId;
  }

  getProtocol(): RemoteProtocol {
    return this.protocol;
  }
}
