/** API23 insertSync succeeds with a rowId; -1 is its documented failure sentinel. */
export function rdbInsertSucceeded(rowId: number): boolean {
  return rowId !== -1;
}

/** Every id-addressed update/delete must modify exactly one local row. */
export function rdbSingleRowAffected(rows: number): boolean {
  return rows === 1;
}

/** Only known Huawei Cloud Space/service-disabled errors warrant the setup guidance. */
export function cloudServiceGuidanceRequiredForMessage(message: string): boolean {
  const normalized: string = message.toLowerCase();
  return normalized.indexOf('cloud space') >= 0 || normalized.indexOf('cloud service') >= 0 ||
    normalized.indexOf('cloud sync') >= 0 || normalized.indexOf('not enabled') >= 0 ||
    normalized.indexOf('未开通') >= 0 || normalized.indexOf('未开启') >= 0;
}
