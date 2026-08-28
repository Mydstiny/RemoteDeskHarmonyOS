import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export const SECRET_PRESENTATION_PREFERENCE_KEY: string =
  'secretPresentationPolicyV1';
export const SECRET_PRESENTATION_SCHEMA_VERSION: number = 1;

export type EditableSecretKind =
  'rdp_host_password' |
  'rdp_saved_credential' |
  'rustdesk_device_password' |
  'ssh_host_password' |
  'ssh_key_passphrase' |
  'vnc_host_password';

export interface SecretPresentationPolicy {
  version: number;
  hiddenKinds: EditableSecretKind[];
}

const EDITABLE_SECRET_KINDS: EditableSecretKind[] = [
  'rdp_host_password',
  'rdp_saved_credential',
  'rustdesk_device_password',
  'ssh_host_password',
  'ssh_key_passphrase',
  'vnc_host_password'
];

export function editableSecretKinds(): EditableSecretKind[] {
  return EDITABLE_SECRET_KINDS.slice();
}

export function isEditableSecretKind(value: string): boolean {
  return EDITABLE_SECRET_KINDS.indexOf(value as EditableSecretKind) >= 0;
}

/** Existing installations retain VNC's historical write-only editor default. */
export function defaultSecretPresentationPolicy(): SecretPresentationPolicy {
  return { version: SECRET_PRESENTATION_SCHEMA_VERSION, hiddenKinds: ['vnc_host_password'] };
}

export function allHiddenSecretPresentationPolicy(): SecretPresentationPolicy {
  return {
    version: SECRET_PRESENTATION_SCHEMA_VERSION,
    hiddenKinds: editableSecretKinds()
  };
}

function normalizedHiddenKinds(values: Object[]): EditableSecretKind[] {
  const result: EditableSecretKind[] = [];
  for (let i = 0; i < values.length; i++) {
    if (typeof values[i] !== 'string') { continue; }
    const value: string = values[i] as string;
    if (!isEditableSecretKind(value)) { continue; }
    const kind: EditableSecretKind = value as EditableSecretKind;
    if (result.indexOf(kind) < 0) { result.push(kind); }
  }
  return result;
}

export function normalizeSecretPresentationPolicy(value: Object): SecretPresentationPolicy {
  if (!value || Array.isArray(value) || typeof value !== 'object') {
    return defaultSecretPresentationPolicy();
  }
  const record: Record<string, Object> = value as Record<string, Object>;
  if (record['version'] !== SECRET_PRESENTATION_SCHEMA_VERSION ||
    !Array.isArray(record['hiddenKinds'])) {
    return defaultSecretPresentationPolicy();
  }
  return {
    version: SECRET_PRESENTATION_SCHEMA_VERSION,
    hiddenKinds: normalizedHiddenKinds(record['hiddenKinds'] as Object[])
  };
}

export function parseSecretPresentationPolicy(payload: string): SecretPresentationPolicy {
  if (payload.length === 0 || payload.length > 2048) {
    return defaultSecretPresentationPolicy();
  }
  try {
    return normalizeSecretPresentationPolicy(JSON.parse(payload) as Object);
  } catch (_e) {
    return defaultSecretPresentationPolicy();
  }
}

export function serializeSecretPresentationPolicy(policy: SecretPresentationPolicy): string {
  return JSON.stringify(normalizeSecretPresentationPolicy(policy as Object));
}

export function secretPresentationHidden(policy: SecretPresentationPolicy,
  kind: EditableSecretKind, securityOverride: boolean = false): boolean {
  return securityOverride || policy.hiddenKinds.indexOf(kind) >= 0;
}

export function withSecretPresentationHidden(policy: SecretPresentationPolicy,
  kind: EditableSecretKind, hidden: boolean): SecretPresentationPolicy {
  const next: EditableSecretKind[] = policy.hiddenKinds.filter(
    (candidate: EditableSecretKind): boolean => candidate !== kind);
  if (hidden) { next.push(kind); }
  const candidate: SecretPresentationPolicy = {
    version: SECRET_PRESENTATION_SCHEMA_VERSION,
    hiddenKinds: next
  };
  return normalizeSecretPresentationPolicy(candidate as Object);
}

export function secretPresentationSummary(policy: SecretPresentationPolicy): string {
  const count: number = normalizeSecretPresentationPolicy(policy as Object).hiddenKinds.length;
  if (count === 0) { return '未隐藏可编辑密码 · 仅本机'; }
  if (count === EDITABLE_SECRET_KINDS.length) { return '全部可编辑密码已隐藏 · 仅本机'; }
  return '已隐藏 ' + count.toString() + ' 类 · 仅本机';
}

/** Device-global store. This path never calls CloudStore or portable backup. */
export class SecretPresentationStore {
  private static instance: SecretPresentationStore;
  private context: common.Context | null = null;
  private policy: SecretPresentationPolicy = defaultSecretPresentationPolicy();
  private changeListeners: Array<() => void> = [];

  static getInstance(): SecretPresentationStore {
    if (!SecretPresentationStore.instance) {
      SecretPresentationStore.instance = new SecretPresentationStore();
    }
    return SecretPresentationStore.instance;
  }

  init(context: common.Context): void {
    this.context = context;
    try {
      const prefs = preferences.getPreferencesSync(
        context, { name: 'RemoteDesktopAppPrefs' });
      const payload: string = prefs.getSync(
        SECRET_PRESENTATION_PREFERENCE_KEY,
        serializeSecretPresentationPolicy(defaultSecretPresentationPolicy())) as string;
      this.policy = parseSecretPresentationPolicy(payload);
    } catch (_e) {
      this.policy = defaultSecretPresentationPolicy();
    }
  }

  get(): SecretPresentationPolicy {
    return normalizeSecretPresentationPolicy(this.policy as Object);
  }

  getJson(): string {
    return serializeSecretPresentationPolicy(this.policy);
  }

  isHidden(kind: EditableSecretKind, securityOverride: boolean = false): boolean {
    return secretPresentationHidden(this.policy, kind, securityOverride);
  }

  onChange(listener: () => void): () => void {
    this.changeListeners.push(listener);
    return (): void => {
      const index: number = this.changeListeners.indexOf(listener);
      if (index >= 0) { this.changeListeners.splice(index, 1); }
    };
  }

  private notifyChange(): void {
    const listeners: Array<() => void> = this.changeListeners.slice();
    for (let i = 0; i < listeners.length; i++) {
      try { listeners[i](); } catch (_e) { /* presentation listeners are isolated */ }
    }
  }

  save(policy: SecretPresentationPolicy): boolean {
    if (this.context === null) { return false; }
    const normalized: SecretPresentationPolicy =
      normalizeSecretPresentationPolicy(policy as Object);
    try {
      const prefs = preferences.getPreferencesSync(
        this.context, { name: 'RemoteDesktopAppPrefs' });
      prefs.putSync(SECRET_PRESENTATION_PREFERENCE_KEY,
        serializeSecretPresentationPolicy(normalized));
      prefs.flushSync();
      this.policy = normalized;
      this.notifyChange();
      return true;
    } catch (_e) {
      return false;
    }
  }
}
