/**
 * SshTerminalRendererBridge.ets — C++ SshTerminalRenderer 的 ArkTS 门面。
 *
 * 原生渲染器自带 terminal_core 句柄并通过 OH_Drawing/EGL 直接绘制到
 * XComponent surface；所有方法在原生符号缺失时安全降级（isAvailable 为
 * false），调用方据此保留 Canvas fallback 路径。
 */
import rdpnapi from 'librdpnapi.so';
import { TerminalCoreMode } from '../types/rdpnapi';

export interface SshTerminalRendererConfig {
  surfaceId: string;
  widthPx: number;
  heightPx: number;
  cols: number;
  rows: number;
  cellWidthPx: number;
  cellHeightPx: number;
  fontSizePx: number;
  foreground: number;
  background: number;
  viewportHeightPx: number;
  visibleHeightPx: number;
  bottomAlign: boolean;
}

interface SshTerminalRendererNativeModule {
  sshTerminalRendererCreate?: (surfaceId: string, widthPx: number, heightPx: number,
    cols: number, rows: number, cellWidthPx: number, cellHeightPx: number,
    fontSizePx: number, foreground: number, background: number,
    viewportHeightPx: number, visibleHeightPx: number, bottomAlign: boolean) => number;
  sshTerminalRendererDestroy?: (handle: number) => void;
  sshTerminalRendererBindSurface?: (handle: number, surfaceId: string,
    widthPx: number, heightPx: number) => boolean;
  sshTerminalRendererWriteBytes?: (handle: number, data: ArrayBuffer) => void;
  sshTerminalRendererResize?: (handle: number, cols: number, rows: number,
    cellWidthPx: number, cellHeightPx: number, fontSizePx: number) => void;
  sshTerminalRendererSetAppearance?: (handle: number, fontSizePx: number,
    foreground: number, background: number) => void;
  sshTerminalRendererSetViewport?: (handle: number, viewportHeightPx: number,
    visibleHeightPx: number, bottomAlign: boolean) => void;
  sshTerminalRendererScrollView?: (handle: number, deltaLines: number) => void;
  sshTerminalRendererScrollToBottom?: (handle: number) => void;
  sshTerminalRendererContent?: (handle: number) => string;
  sshTerminalRendererMode?: (handle: number) => TerminalCoreMode;
}

const DEFAULT_MODE: TerminalCoreMode = {
  bracketedPaste: false,
  mouseTracking: 0,
  sgrMouse: false,
  applicationCursorKeys: false,
  applicationKeypad: false,
  autoWrap: true
};

export class SshTerminalRendererBridge {
  private native: SshTerminalRendererNativeModule = rdpnapi as SshTerminalRendererNativeModule;

  isAvailable(): boolean {
    return this.native.sshTerminalRendererCreate !== undefined &&
      this.native.sshTerminalRendererDestroy !== undefined &&
      this.native.sshTerminalRendererWriteBytes !== undefined &&
      this.native.sshTerminalRendererBindSurface !== undefined;
  }

  create(config: SshTerminalRendererConfig): number {
    const fn = this.native.sshTerminalRendererCreate;
    if (fn === undefined) { return 0; }
    return fn(config.surfaceId, config.widthPx, config.heightPx,
      config.cols, config.rows, config.cellWidthPx, config.cellHeightPx,
      config.fontSizePx, config.foreground, config.background,
      config.viewportHeightPx, config.visibleHeightPx, config.bottomAlign);
  }

  destroy(handle: number): void {
    if (handle === 0) { return; }
    this.native.sshTerminalRendererDestroy?.(handle);
  }

  bindSurface(handle: number, surfaceId: string, widthPx: number, heightPx: number): boolean {
    const fn = this.native.sshTerminalRendererBindSurface;
    if (fn === undefined || handle === 0) { return false; }
    return fn(handle, surfaceId, widthPx, heightPx);
  }

  writeBytes(handle: number, data: ArrayBuffer): void {
    if (handle === 0) { return; }
    this.native.sshTerminalRendererWriteBytes?.(handle, data);
  }

  resize(handle: number, cols: number, rows: number,
    cellWidthPx: number, cellHeightPx: number, fontSizePx: number): void {
    if (handle === 0) { return; }
    this.native.sshTerminalRendererResize?.(handle, cols, rows, cellWidthPx, cellHeightPx, fontSizePx);
  }

  setAppearance(handle: number, fontSizePx: number, foreground: number, background: number): void {
    if (handle === 0) { return; }
    this.native.sshTerminalRendererSetAppearance?.(handle, fontSizePx, foreground, background);
  }

  setViewport(handle: number, viewportHeightPx: number, visibleHeightPx: number, bottomAlign: boolean): void {
    if (handle === 0) { return; }
    this.native.sshTerminalRendererSetViewport?.(handle, viewportHeightPx, visibleHeightPx, bottomAlign);
  }

  scrollView(handle: number, deltaLines: number): void {
    if (handle === 0) { return; }
    this.native.sshTerminalRendererScrollView?.(handle, deltaLines);
  }

  scrollToBottom(handle: number): void {
    if (handle === 0) { return; }
    this.native.sshTerminalRendererScrollToBottom?.(handle);
  }

  content(handle: number): string {
    const fn = this.native.sshTerminalRendererContent;
    if (fn === undefined || handle === 0) { return ''; }
    return fn(handle);
  }

  mode(handle: number): TerminalCoreMode {
    const fn = this.native.sshTerminalRendererMode;
    if (fn === undefined || handle === 0) { return DEFAULT_MODE; }
    return fn(handle);
  }
}
