/**
 * TerminalCoreBridge.ets — Rust terminal_core 的 ArkTS 门面。
 *
 * 当前文件只定义类型和延迟调用包装, 不切换现有 SSH UI。
 * 后续 C++ NAPI 注册 terminalCore* 方法后, NativeTerminalRenderer 可直接复用此门面。
 */
import rdpnapi from 'librdpnapi.so';
import { TerminalCoreSnapshot } from '../types/rdpnapi';
export { TerminalCoreCell, TerminalCoreSnapshot } from '../types/rdpnapi';

interface TerminalCoreNativeModule {
  terminalCoreCreate?: (cols: number, rows: number) => number;
  terminalCoreDestroy?: (handle: number) => void;
  terminalCoreWrite?: (handle: number, data: string) => void;
  terminalCoreResize?: (handle: number, cols: number, rows: number) => void;
  terminalCoreScrollView?: (handle: number, deltaLines: number) => void;
  terminalCoreScrollToBottom?: (handle: number) => void;
  terminalCoreSnapshot?: (handle: number) => TerminalCoreSnapshot;
  terminalCoreDirtySnapshot?: (handle: number) => TerminalCoreSnapshot;
}

export class TerminalCoreBridge {
  private native: TerminalCoreNativeModule = rdpnapi as TerminalCoreNativeModule;

  isAvailable(): boolean {
    return this.native.terminalCoreCreate !== undefined &&
      this.native.terminalCoreDestroy !== undefined &&
      this.native.terminalCoreWrite !== undefined &&
      this.native.terminalCoreSnapshot !== undefined;
  }

  create(cols: number, rows: number): number {
    const fn = this.native.terminalCoreCreate;
    if (fn === undefined) { throw new Error('terminalCoreCreate is not registered'); }
    return fn(cols, rows);
  }

  destroy(handle: number): void {
    const fn = this.native.terminalCoreDestroy;
    if (fn === undefined) { throw new Error('terminalCoreDestroy is not registered'); }
    fn(handle);
  }

  write(handle: number, data: string): void {
    const fn = this.native.terminalCoreWrite;
    if (fn === undefined) { throw new Error('terminalCoreWrite is not registered'); }
    fn(handle, data);
  }

  resize(handle: number, cols: number, rows: number): void {
    const fn = this.native.terminalCoreResize;
    if (fn === undefined) { throw new Error('terminalCoreResize is not registered'); }
    fn(handle, cols, rows);
  }

  scrollView(handle: number, deltaLines: number): void {
    const fn = this.native.terminalCoreScrollView;
    if (fn === undefined) { throw new Error('terminalCoreScrollView is not registered'); }
    fn(handle, deltaLines);
  }

  scrollToBottom(handle: number): void {
    const fn = this.native.terminalCoreScrollToBottom;
    if (fn === undefined) { throw new Error('terminalCoreScrollToBottom is not registered'); }
    fn(handle);
  }

  snapshot(handle: number): TerminalCoreSnapshot {
    const fn = this.native.terminalCoreSnapshot;
    if (fn === undefined) { throw new Error('terminalCoreSnapshot is not registered'); }
    return fn(handle);
  }

  dirtySnapshot(handle: number): TerminalCoreSnapshot {
    const fn = this.native.terminalCoreDirtySnapshot;
    if (fn === undefined) { throw new Error('terminalCoreDirtySnapshot is not registered'); }
    return fn(handle);
  }
}
