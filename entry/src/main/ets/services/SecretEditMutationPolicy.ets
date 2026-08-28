export type SecretEditMutationKind = 'keep' | 'replace' | 'clear';

export interface SecretEditMutation {
  kind: SecretEditMutationKind;
  value: string;
}

export function secretConfigured(value: string): boolean {
  return value.length > 0;
}

/** Hidden values stay outside the editor state; visible values remain masked by InputType.Password. */
export function secretEditDraftValue(existing: string, hidden: boolean): string {
  return hidden ? '' : existing;
}

export function secretEditMutationForDraft(draft: string, hidden: boolean,
  existingConfigured: boolean, preserveAllowed: boolean = true): SecretEditMutation {
  if (hidden && existingConfigured && preserveAllowed && draft.length === 0) {
    return { kind: 'keep', value: '' };
  }
  return { kind: 'replace', value: draft };
}

export function clearSecretEditMutation(): SecretEditMutation {
  return { kind: 'clear', value: '' };
}

export function applySecretEditMutation(existing: string,
  mutation: SecretEditMutation): string {
  if (mutation.kind === 'keep') { return existing; }
  if (mutation.kind === 'clear') { return ''; }
  return mutation.value;
}

export function resolveSecretEditValue(existing: string, draft: string,
  hidden: boolean, preserveAllowed: boolean = true): string {
  return applySecretEditMutation(existing,
    secretEditMutationForDraft(draft, hidden, existing.length > 0, preserveAllowed));
}

export function secretEditPlaceholder(existingConfigured: boolean,
  hidden: boolean, emptyPlaceholder: string): string {
  if (existingConfigured && hidden) { return '已保存（不回显；输入新值以替换）'; }
  return emptyPlaceholder;
}
