export type CloudBootstrapRecordReconcileAction =
  'restore_table' | 'restore_record' |
  'delete_record' | 'invalid';

export function cloudBootstrapRecordReconcileAction(
  tableMutation: boolean,
  operation: string,
  beforeRowExists: boolean
): CloudBootstrapRecordReconcileAction {
  if (tableMutation) { return 'restore_table'; }
  if (beforeRowExists) { return 'restore_record'; }
  if (operation === 'delete' ||
    operation === 'rollback_delete') {
    return 'delete_record';
  }
  return 'invalid';
}

/**
 * A compatibility marker proves a committed table mutation but has no exact
 * record inventory. After cloud-first the only lossless reconciliation is to
 * restore the complete before-image and keep that table pending native-first.
 */
export function cloudBootstrapMustRestoreWholeTable(
  compatibilityRevision: number,
  journalRecordIds: string[]
): boolean {
  if (Number.isFinite(compatibilityRevision) &&
      compatibilityRevision > 0) {
    return true;
  }
  return journalRecordIds.indexOf('__table__') >= 0;
}
