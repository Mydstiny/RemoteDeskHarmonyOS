// The validity check is adjacent to the side effect, after asynchronous preflight.
export async function runCurrentProPurchase(preflight: () => Promise<void>,
  isCurrent: () => boolean, checkout: () => Promise<void>): Promise<void> {
  await preflight();
  if (!isCurrent()) { return; }
  await checkout();
}

export class ProPurchaseLifecycle {
  private static epoch: number = 0;
  static capture(): number { return ProPurchaseLifecycle.epoch; }
  static current(epoch: number): boolean { return epoch === ProPurchaseLifecycle.epoch; }
  static dismiss(): void { ProPurchaseLifecycle.epoch++; }
}
