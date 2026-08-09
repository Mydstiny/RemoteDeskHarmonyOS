/**
 * Keeps one VT core alive per SSH tab while the visible ArkUI page is replaced.
 * The registry is SSH-terminal scoped and owns no network/session state.
 */
import { TerminalCoreBridge } from '../napi/TerminalCoreBridge';

interface TerminalCoreEntry {
  handle: number;
  cols: number;
  rows: number;
}

export class TerminalCoreRegistry {
  private static instance: TerminalCoreRegistry;
  private entries: Map<string, TerminalCoreEntry> = new Map<string, TerminalCoreEntry>();

  static getInstance(): TerminalCoreRegistry {
    if (!TerminalCoreRegistry.instance) {
      TerminalCoreRegistry.instance = new TerminalCoreRegistry();
    }
    return TerminalCoreRegistry.instance;
  }

  acquire(key: string, cols: number, rows: number, bridge: TerminalCoreBridge): number {
    const normalizedKey: string = key.trim();
    if (normalizedKey.length === 0) {
      return bridge.create(cols, rows);
    }
    const existing: TerminalCoreEntry | undefined = this.entries.get(normalizedKey);
    if (existing !== undefined && existing.handle > 0) {
      if (existing.cols !== cols || existing.rows !== rows) {
        bridge.resize(existing.handle, cols, rows);
      }
      existing.cols = cols;
      existing.rows = rows;
      return existing.handle;
    }
    const handle: number = bridge.create(cols, rows);
    if (handle > 0) {
      this.entries.set(normalizedKey, { handle, cols, rows });
    }
    return handle;
  }

  destroy(key: string, bridge: TerminalCoreBridge): void {
    const normalizedKey: string = key.trim();
    if (normalizedKey.length === 0) { return; }
    const entry: TerminalCoreEntry | undefined = this.entries.get(normalizedKey);
    if (entry !== undefined) {
      if (entry.handle > 0) { bridge.destroy(entry.handle); }
      this.entries.delete(normalizedKey);
    }
  }

  destroyAll(bridge: TerminalCoreBridge): void {
    this.entries.forEach((entry: TerminalCoreEntry): void => {
      if (entry.handle > 0) { bridge.destroy(entry.handle); }
    });
    this.entries.clear();
  }
}
