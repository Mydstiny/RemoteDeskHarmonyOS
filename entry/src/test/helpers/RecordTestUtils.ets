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
