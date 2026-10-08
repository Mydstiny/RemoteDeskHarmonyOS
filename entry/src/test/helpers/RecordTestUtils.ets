/**
 * Strict ArkTS has no `delete`; tests that need a record with one key
 * missing build a copy without it.
 */
export function withoutKey<T>(record: Record<string, T>, key: string): Record<string, T> {
  const result: Record<string, T> = {};
  const keys: string[] = Object.keys(record);
  for (let i = 0; i < keys.length; i++) {
    if (keys[i] !== key) {
      result[keys[i]] = record[keys[i]];
    }
  }
  return result;
}

/**
 * Strict ArkTS has no object spread; `withOverrides(base, { 'a': 1 })` builds
 * the same shallow copy as `{ ...base, a: 1 }`.
 */
export function withOverrides<T>(base: T, overrides: Record<string, Object | null | undefined>): T {
  const source: ESObject = base as ESObject;
  const copy: ESObject = new Object() as ESObject;
  const baseKeys: string[] = Object.keys(source);
  for (let i = 0; i < baseKeys.length; i++) {
    copy[baseKeys[i]] = source[baseKeys[i]];
  }
  const overrideKeys: string[] = Object.keys(overrides);
  for (let i = 0; i < overrideKeys.length; i++) {
    copy[overrideKeys[i]] = overrides[overrideKeys[i]];
  }
  return copy as T;
}

/** Plain-record view of a serialized model, for asserting on its keys. */
export function jsonRecord<T>(value: T): Record<string, Object> {
  return JSON.parse(JSON.stringify(value)) as Record<string, Object>;
}
