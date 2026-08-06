/**
 * SshTerminalRendererRegistry.ets — 每个 SSH 标签一个原生渲染器句柄。
 *
 * 渲染器在 native 侧自带 terminal_core，生命周期跟随 SSH 标签而不是瞬态
 * 可见页面：标签切换时 ArkUI 会销毁/重建 XComponent surface，组件用
 * bindSurface 把已有句柄重新绑到新 surface；只有用户退出全部 SSH 标签或
 * 关闭单个标签时才真正销毁 native 渲染器（及其内部 VT 核心）。
 */
import { SshTerminalRendererBridge, SshTerminalRendererConfig } from '../napi/SshTerminalRendererBridge';
import { shouldRebindSshTerminalSurface } from './SshTerminalSurfaceBindingPolicy';

interface SshTerminalRendererEntry {
  handle: number;
  surfaceId: string;
  /** Binding identity of the component that currently owns the surface. */
  ownerId: string;
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
   * 返回可用句柄；普通 surface 失败返回 0，GPU flush 失败返回负值，
   * 调用方据此立即回退到 xterm/transcript 渲染器。
   */
  attach(key: string, config: SshTerminalRendererConfig, bridge: SshTerminalRendererBridge,
    ownerId: string = ''): number {
    const normalizedKey: string = key.trim();
    const normalizedOwnerId: string = ownerId.trim();
    const existing: SshTerminalRendererEntry | undefined =
      normalizedKey.length === 0 ? undefined : this.entries.get(normalizedKey);
    if (existing !== undefined && existing.handle > 0) {
      if (shouldRebindSshTerminalSurface(existing.surfaceId, config.surfaceId,
        existing.ownerId, normalizedOwnerId)) {
        const bindStatus: number = bridge.bindSurface(existing.handle, config.surfaceId,
          config.widthPx, config.heightPx);
        if (bindStatus !== 0) {
          // Rebinding can race XComponent surface destruction or be required
          // for a reused platform surface ID. Keep the VT core and mark it
          // detached so the next surface callback can retry; destroying here
          // would lose the hidden tab's scrollback.
          existing.surfaceId = '';
          // The new component owns the recovery attempt. Prevent an old
          // component from detaching this handle while the new surface is
          // between destruction and recreation.
          existing.ownerId = normalizedOwnerId;
          return bindStatus < 0 || bridge.hasSurfaceFlushFailure(existing.handle) ? -1 : 0;
        } else {
          existing.surfaceId = config.surfaceId;
          existing.ownerId = normalizedOwnerId;
          return existing.handle;
        }
      } else {
        existing.ownerId = normalizedOwnerId;
        return existing.handle;
      }
    }
    const handle: number = bridge.create(config);
    if (handle > 0 && normalizedKey.length > 0) {
      this.entries.set(normalizedKey, {
        handle,
        surfaceId: config.surfaceId,
        ownerId: normalizedOwnerId
      });
    }
    return handle;
  }

  /** Release the current XComponent surface while retaining the per-tab VT core. */
  detach(key: string, bridge: SshTerminalRendererBridge, ownerId: string = ''): void {
    const normalizedKey: string = key.trim();
    if (normalizedKey.length === 0) { return; }
    const entry: SshTerminalRendererEntry | undefined = this.entries.get(normalizedKey);
    if (entry !== undefined && entry.handle > 0) {
      const normalizedOwnerId: string = ownerId.trim();
      if (normalizedOwnerId.length > 0 && entry.ownerId !== normalizedOwnerId) {
        return;
      }
      bridge.detachSurface(entry.handle);
      entry.surfaceId = '';
      entry.ownerId = normalizedOwnerId;
    }
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
