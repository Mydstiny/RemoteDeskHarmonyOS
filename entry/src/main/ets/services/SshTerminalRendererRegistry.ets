/**
 * SshTerminalRendererRegistry.ets — 每个 SSH 标签一个原生渲染器句柄。
 *
 * 渲染器在 native 侧自带 terminal_core，生命周期跟随 SSH 标签而不是瞬态
 * 可见页面：标签切换时 ArkUI 会销毁/重建 XComponent surface，组件用
 * bindSurface 把已有句柄重新绑到新 surface；只有用户退出全部 SSH 标签或
 * 关闭单个标签时才真正销毁 native 渲染器（及其内部 VT 核心）。
 */
import { SshTerminalRendererBridge, SshTerminalRendererConfig } from '../napi/SshTerminalRendererBridge';

interface SshTerminalRendererEntry {
  handle: number;
  surfaceId: string;
}

export class SshTerminalRendererRegistry {
  private static instance: SshTerminalRendererRegistry;
  private entries: Map<string, SshTerminalRendererEntry> = new Map<string, SshTerminalRendererEntry>();

  static getInstance(): SshTerminalRendererRegistry {
    if (!SshTerminalRendererRegistry.instance) {
      SshTerminalRendererRegistry.instance = new SshTerminalRendererRegistry();
    }
    return SshTerminalRendererRegistry.instance;
  }

  /** 获取已有句柄；没有或 surface 变化时返回 0，调用方应走 attach。 */
  handleFor(key: string): number {
    const entry: SshTerminalRendererEntry | undefined = this.entries.get(key.trim());
    return entry !== undefined ? entry.handle : 0;
  }

  /**
   * 绑定 key 到一个 surface：已有句柄则 rebind，否则创建。
   * 返回可用句柄，失败返回 0（调用方回退 Canvas 渲染器）。
   */
  attach(key: string, config: SshTerminalRendererConfig, bridge: SshTerminalRendererBridge): number {
    const normalizedKey: string = key.trim();
    const existing: SshTerminalRendererEntry | undefined =
      normalizedKey.length === 0 ? undefined : this.entries.get(normalizedKey);
    if (existing !== undefined && existing.handle > 0) {
      if (existing.surfaceId !== config.surfaceId) {
        if (!bridge.bindSurface(existing.handle, config.surfaceId, config.widthPx, config.heightPx)) {
          bridge.destroy(existing.handle);
          this.entries.delete(normalizedKey);
        } else {
          existing.surfaceId = config.surfaceId;
          return existing.handle;
        }
      } else {
        return existing.handle;
      }
    }
    const handle: number = bridge.create(config);
    if (handle > 0 && normalizedKey.length > 0) {
      this.entries.set(normalizedKey, { handle, surfaceId: config.surfaceId });
    }
    return handle;
  }

  destroy(key: string, bridge: SshTerminalRendererBridge): void {
    const normalizedKey: string = key.trim();
    if (normalizedKey.length === 0) { return; }
    const entry: SshTerminalRendererEntry | undefined = this.entries.get(normalizedKey);
    if (entry !== undefined) {
      if (entry.handle > 0) { bridge.destroy(entry.handle); }
      this.entries.delete(normalizedKey);
    }
  }

  destroyAll(bridge: SshTerminalRendererBridge): void {
    this.entries.forEach((entry: SshTerminalRendererEntry): void => {
      if (entry.handle > 0) { bridge.destroy(entry.handle); }
    });
    this.entries.clear();
  }
}
