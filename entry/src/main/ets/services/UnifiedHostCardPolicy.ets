export type UnifiedHostCardKind = 'remote' | 'moonlight';

export interface UnifiedHostCardRef {
  key: string;
  kind: UnifiedHostCardKind;
  hostId: string;
}

const REMOTE_HOST_KEY_PREFIX: string = 'remote:';
const MOONLIGHT_HOST_KEY_PREFIX: string = 'moonlight:';

export function remoteHostCardKey(hostId: string): string {
  return REMOTE_HOST_KEY_PREFIX + hostId;
}

export function moonlightHostCardKey(hostId: string): string {
  return MOONLIGHT_HOST_KEY_PREFIX + hostId;
}

export function remoteHostIdFromCardKey(key: string): string {
  return key.startsWith(REMOTE_HOST_KEY_PREFIX)
    ? key.substring(REMOTE_HOST_KEY_PREFIX.length) : '';
}

export function moonlightHostIdFromCardKey(key: string): string {
  return key.startsWith(MOONLIGHT_HOST_KEY_PREFIX)
    ? key.substring(MOONLIGHT_HOST_KEY_PREFIX.length) : '';
}

function manualOrderIndex(order: string[], ref: UnifiedHostCardRef): number {
  const namespacedIndex: number = order.indexOf(ref.key);
  if (namespacedIndex >= 0) { return namespacedIndex; }
  // Versions before the unified Moonlight list stored bare RemoteHost IDs.
  // Accept those values without rewriting Preferences until the user saves a
  // new order.
  return ref.kind === 'remote' ? order.indexOf(ref.hostId) : -1;
}

export function buildUnifiedHostCardRefs(
  remoteHostIds: string[],
  moonlightHostIds: string[],
  manualOrder: string[]
): UnifiedHostCardRef[] {
  const result: UnifiedHostCardRef[] = [];
  for (let index: number = 0; index < remoteHostIds.length; index++) {
    const hostId: string = remoteHostIds[index];
    result.push({ key: remoteHostCardKey(hostId), kind: 'remote', hostId: hostId });
  }
  for (let index: number = 0; index < moonlightHostIds.length; index++) {
    const hostId: string = moonlightHostIds[index];
    result.push({ key: moonlightHostCardKey(hostId), kind: 'moonlight', hostId: hostId });
  }
  if (manualOrder.length === 0) { return result; }
  result.sort((left: UnifiedHostCardRef, right: UnifiedHostCardRef): number => {
    const leftIndex: number = manualOrderIndex(manualOrder, left);
    const rightIndex: number = manualOrderIndex(manualOrder, right);
    if (leftIndex < 0 && rightIndex < 0) { return 0; }
    if (leftIndex < 0) { return 1; }
    if (rightIndex < 0) { return -1; }
    return leftIndex - rightIndex;
  });
  return result;
}

export function moveUnifiedHostCard(
  visibleOrder: string[],
  draggingKey: string,
  targetKey: string
): string[] {
  const result: string[] = visibleOrder.slice();
  const from: number = result.indexOf(draggingKey);
  const to: number = result.indexOf(targetKey);
  if (from < 0 || to < 0 || from === to) { return result; }
  const moved: string = result.splice(from, 1)[0];
  result.splice(to, 0, moved);
  return result;
}

export function mergeVisibleHostOrder(
  previousOrder: string[],
  previousVisibleKeys: string[],
  nextVisibleKeys: string[]
): string[] {
  const visible: Set<string> = new Set<string>(previousVisibleKeys);
  const result: string[] = [];
  let nextVisibleIndex: number = 0;
  for (let index: number = 0; index < previousOrder.length; index++) {
    const storedKey: string = previousOrder[index];
    const legacyRemoteKey: string = remoteHostCardKey(storedKey);
    const key: string = !visible.has(storedKey) && visible.has(legacyRemoteKey)
      ? legacyRemoteKey : storedKey;
    if (visible.has(key)) {
      // Keep hidden cards in their original slots. Each slot occupied by a
      // visible card receives the next card from the reordered visible list.
      while (nextVisibleIndex < nextVisibleKeys.length &&
          result.indexOf(nextVisibleKeys[nextVisibleIndex]) >= 0) {
        nextVisibleIndex++;
      }
      if (nextVisibleIndex < nextVisibleKeys.length) {
        result.push(nextVisibleKeys[nextVisibleIndex]);
        nextVisibleIndex++;
      }
    } else if (result.indexOf(key) < 0) {
      result.push(key);
    }
  }
  while (nextVisibleIndex < nextVisibleKeys.length) {
    if (result.indexOf(nextVisibleKeys[nextVisibleIndex]) < 0) {
      result.push(nextVisibleKeys[nextVisibleIndex]);
    }
    nextVisibleIndex++;
  }
  return result;
}
