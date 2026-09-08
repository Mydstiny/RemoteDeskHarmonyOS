/** In-process ownership for window/host/account invalidation; holds no secrets. */
export class AiLifecycle {
  private static epoch: number = 0;
  private static restoreCount: number = 0;
  static generation(): number { return AiLifecycle.epoch; }
  static restoring(): boolean { return AiLifecycle.restoreCount > 0; }
  static beginRestore(): () => void {
    AiLifecycle.restoreCount++; AiLifecycle.invalidateAll();
    let ended = false;
    return (): void => { if (!ended) { ended = true; AiLifecycle.restoreCount--; } };
  }
  private static closers: Map<string, () => void> = new Map();
  private static hosts: Map<string, string> = new Map();
  private static writers: Map<string, string> = new Map();
  static register(id: string, hostId: string, close: () => void): () => void {
    AiLifecycle.closers.set(id, close);
    AiLifecycle.hosts.set(id, hostId);
    return (): void => {
      AiLifecycle.closers.delete(id); AiLifecycle.hosts.delete(id);
      AiLifecycle.writers.forEach((owner: string, key: string): void => {
        if (owner === id) { AiLifecycle.writers.delete(key); }
      });
    };
  }
  static claim(key: string, owner: string): boolean {
    const current = AiLifecycle.writers.get(key);
    if (current !== undefined && current !== owner) { return false; }
    AiLifecycle.writers.set(key, owner); return true;
  }
  static release(key: string, owner: string): void {
    if (AiLifecycle.writers.get(key) === owner) { AiLifecycle.writers.delete(key); }
  }
  static closeHost(hostId: string): void {
    AiLifecycle.hosts.forEach((id: string, owner: string): void => {
      if (id === hostId) { AiLifecycle.closers.get(owner)?.(); }
    });
  }
  static invalidateAll(): void {
    AiLifecycle.epoch++;
    const callbacks = Array.from(AiLifecycle.closers.values());
    AiLifecycle.closers.clear(); AiLifecycle.hosts.clear(); AiLifecycle.writers.clear();
    callbacks.forEach((close: () => void): void => { try { close(); } catch (_error) {} });
  }
}
