import { common } from '@kit.AbilityKit';
import { asset } from '@kit.AssetStoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';

const PREFS_NAME: string = 'RemoteDeskDiagnosticAiMetadata';
const MAX_SECRET_BYTES: number = 4096;
const SECRET_DOMAIN: string = 'RemoteDeskHarmonyOS:diagnostic-ai:v1:';

export interface DiagnosticAiSecretMetadata { secretRef: string; fingerprint: string; updatedAt: number; }

/** Device-local secret store. Preferences contain only fingerprints and refs. */
export class DiagnosticAiSecretStore {
  private static instance: DiagnosticAiSecretStore;
  private context: common.Context | null = null;
  private scope: string = 'device-local';
  private loaded: boolean = false;
  private metadata: Record<string, DiagnosticAiSecretMetadata> = {};

  static getInstance(): DiagnosticAiSecretStore {
    if (!DiagnosticAiSecretStore.instance) { DiagnosticAiSecretStore.instance = new DiagnosticAiSecretStore(); }
    return DiagnosticAiSecretStore.instance;
  }

  init(context: common.Context, scope: string): void {
    this.context = context; this.scope = scope.trim() === '' ? 'device-local' : scope.trim();
    this.loaded = false; this.metadata = {}; this.load();
  }

  private alias(ref: string): Uint8Array {
    const md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: new util.TextEncoder().encode(this.scope + '\u001f' + ref) });
    return new util.TextEncoder().encode(SECRET_DOMAIN + this.hex(md.digestSync().data));
  }

  private hex(bytes: Uint8Array): string {
    let result = ''; for (let i = 0; i < bytes.length; i++) { result += bytes[i].toString(16).padStart(2, '0'); }
    return result;
  }

  private fingerprint(secret: string): string {
    const md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: new util.TextEncoder().encode(secret) });
    return this.hex(md.digestSync().data).slice(0, 16);
  }

  private load(): void {
    if (this.loaded || this.context === null) { return; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: PREFS_NAME + '-' + this.fingerprint(this.scope) });
      const raw = prefs.getSync('metadata', '{}') as string;
      const parsed = JSON.parse(raw) as Record<string, Object>;
      Object.keys(parsed).forEach((key: string): void => {
        const value = parsed[key] as Record<string, Object>;
        if (typeof value['secretRef'] === 'string' && typeof value['fingerprint'] === 'string') {
          this.metadata[key] = { secretRef: value['secretRef'] as string, fingerprint: value['fingerprint'] as string,
            updatedAt: typeof value['updatedAt'] === 'number' ? value['updatedAt'] as number : 0 };
        }
      });
    } catch (_error) { this.metadata = {}; }
    this.loaded = true;
  }

  private persist(): void {
    if (this.context === null) { return; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: PREFS_NAME + '-' + this.fingerprint(this.scope) });
      prefs.putSync('metadata', JSON.stringify(this.metadata)); prefs.flushSync();
    } catch (_error) { /* metadata is a convenience; secret remains protected by Asset Store */ }
  }

  put(ref: string, secret: string): DiagnosticAiSecretMetadata | null {
    this.load(); const normalized = ref.trim();
    if (normalized === '' || secret === '') { return null; }
    const bytes = new util.TextEncoder().encode(secret);
    if (bytes.length > MAX_SECRET_BYTES) { return null; }
    try {
      const attributes: asset.AssetMap = new Map(); attributes.set(asset.Tag.ALIAS, this.alias(normalized));
      attributes.set(asset.Tag.SECRET, bytes); attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.THIS_DEVICE); attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
      asset.addSync(attributes);
      const result: DiagnosticAiSecretMetadata = { secretRef: normalized, fingerprint: this.fingerprint(secret), updatedAt: Date.now() };
      this.metadata[normalized] = result; this.persist(); return result;
    } catch (_error) { return null; }
  }

  get(ref: string): string {
    this.load(); const normalized = ref.trim(); if (normalized === '') { return ''; }
    try {
      const query: asset.AssetMap = new Map(); query.set(asset.Tag.ALIAS, this.alias(normalized)); query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const rows = asset.querySync(query); if (rows.length !== 1) { return ''; }
      const value = rows[0].get(asset.Tag.SECRET) as Uint8Array;
      return value && value.length <= MAX_SECRET_BYTES ? util.TextDecoder.create().decodeToString(value) : '';
    } catch (_error) { return ''; }
  }

  remove(ref: string): boolean {
    this.load(); const normalized = ref.trim(); if (normalized === '') { return true; }
    try { const query: asset.AssetMap = new Map(); query.set(asset.Tag.ALIAS, this.alias(normalized)); asset.removeSync(query); }
    catch (_error) { /* not-found is idempotent */ }
    const next: Record<string, DiagnosticAiSecretMetadata> = {};
    Object.keys(this.metadata).forEach((key: string): void => {
      if (key !== normalized) { next[key] = this.metadata[key]; }
    });
    this.metadata = next; this.persist(); return true;
  }

  clearForScopeTransition(): void {
    this.load(); Object.keys(this.metadata).forEach((ref: string): void => { this.remove(ref); });
    this.metadata = {}; this.loaded = true;
  }

  metadataFor(ref: string): DiagnosticAiSecretMetadata | null { this.load(); return this.metadata[ref.trim()] ?? null; }
}
