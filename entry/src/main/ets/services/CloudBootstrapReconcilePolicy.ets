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
