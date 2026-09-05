import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { DataCrypto } from '../../DataCrypto';
import { AccountSessionCoordinator } from '../../AccountSessionCoordinator';
import {
  appendSshHistory,
  decodeSshProductivityDocument,
  emptySshProductivityDocument,
  encodeSshProductivityDocument,
  normalizeSshSnippet,
  SSH_PRODUCTIVITY_MAX_SNIPPETS,
  SshCommandHistoryV1,
  SshProductivityDocumentV1,
  SshSnippetV1,
  SshStartupCommandV1,
  sshSnippetAllowedAsStartup
} from './SshProductivityPolicy';

export const SSH_PRODUCTIVITY_PREFERENCES_NAME: string = 'RemoteDesktopSshProductivityPrefs';
export const SSH_PRODUCTIVITY_PREFERENCES_KEY: string = 'ssh.productivity.encrypted.v1';
export const SSH_PRODUCTIVITY_LEGACY_CLAIM_KEY: string =
  'ssh.productivity.legacy.claim.v1';

export interface SshProductivityPersistencePort {
  read(context: common.Context, key: string): string | null;
  write(context: common.Context, key: string, value: string): boolean;
}

export interface SshProductivityCryptoPort {
  ready(): boolean;
  generation(): number;
  isProtected(value: string): boolean;
  encrypt(value: string): string;
  decrypt(value: string): string;
}

export interface SshProductivityScopeFence {
  ownerScopeId: string;
  generation: number;
}

export interface SshProductivityScopePort {
  current(): SshProductivityScopeFence;
}

export type SshProductivitySettingKind =
  'history' | 'completion' | 'notification' | 'shell';

class HarmonySshProductivityPersistence implements SshProductivityPersistencePort {
  read(context: common.Context, key: string): string | null {
    try {
      const prefs = preferences.getPreferencesSync(context, {
        name: SSH_PRODUCTIVITY_PREFERENCES_NAME
      });
      const value: Object = prefs.getSync(key, '') as Object;
      return typeof value === 'string' ? value as string : null;
    } catch (_err) { return null; }
  }

  write(context: common.Context, key: string, value: string): boolean {
    try {
      const prefs = preferences.getPreferencesSync(context, {
        name: SSH_PRODUCTIVITY_PREFERENCES_NAME
      });
      prefs.putSync(key, value);
      prefs.flushSync();
      return true;
    } catch (_err) { return false; }
  }
}

class DataCryptoSshProductivityPort implements SshProductivityCryptoPort {
  ready(): boolean { return DataCrypto.getInstance().isReady(); }
  generation(): number { return DataCrypto.getInstance().stateGeneration(); }
  isProtected(value: string): boolean { return DataCrypto.getInstance().isEncrypted(value); }
  encrypt(value: string): string { return DataCrypto.getInstance().encrypt(value); }
  decrypt(value: string): string { return DataCrypto.getInstance().decrypt(value); }
}

class AccountSshProductivityScopePort implements SshProductivityScopePort {
  current(): SshProductivityScopeFence {
    const scope = AccountSessionCoordinator.getInstance().currentScope();
    return { ownerScopeId: scope.ownerScopeId, generation: scope.generation };
  }
}

export class SshProductivityStore {
  private context: common.Context | null = null;
  private persistence: SshProductivityPersistencePort;
  private crypto: SshProductivityCryptoPort;
  private scope: SshProductivityScopePort;
  private document: SshProductivityDocumentV1 = emptySshProductivityDocument();
  private initialized: boolean = false;
  private persistedCiphertext: string = '';
  private storageKey: string = '';
  private boundOwnerScopeId: string = '';
  private boundScopeGeneration: number = 0;
  private boundCryptoGeneration: number = -1;

  constructor(persistence: SshProductivityPersistencePort = new HarmonySshProductivityPersistence(),
    crypto: SshProductivityCryptoPort = new DataCryptoSshProductivityPort(),
    scope: SshProductivityScopePort = new AccountSshProductivityScopePort()) {
    this.persistence = persistence;
    this.crypto = crypto;
    this.scope = scope;
  }

  init(context: common.Context): boolean {
    this.clearSensitiveState();
    const currentScope: SshProductivityScopeFence = this.scope.current();
    if (currentScope.ownerScopeId.trim().length === 0 || currentScope.generation <= 0 ||
      !this.crypto.ready()) { return false; }
    this.context = context;
    this.boundOwnerScopeId = currentScope.ownerScopeId.trim();
    this.boundScopeGeneration = currentScope.generation;
    this.boundCryptoGeneration = this.crypto.generation();
    this.storageKey = this.storageKeyForOwner(this.boundOwnerScopeId);
    let stored: string | null = this.persistence.read(context, this.storageKey);
    if (stored === null) { return false; }
    const rawLegacyClaim: string | null = this.persistence.read(
      context, SSH_PRODUCTIVITY_LEGACY_CLAIM_KEY);
    if (rawLegacyClaim === null) { return false; }
    let legacyClaim: string = this.normalizeLegacyClaim(rawLegacyClaim);
    if (stored.length === 0) {
      // One-time compatibility migration. A protected legacy payload can be
      // claimed only when the current account DEK authenticates it. Once
      // claimed, other accounts must initialize their own empty encrypted slot.
      const legacy: string | null = this.persistence.read(
        context, SSH_PRODUCTIVITY_PREFERENCES_KEY);
      if (legacy === null) { return false; }
      if (legacy.length > 0 && this.crypto.isProtected(legacy) &&
        (legacyClaim.length === 0 || legacyClaim === this.boundOwnerScopeId)) {
        try {
          const migrated: SshProductivityDocumentV1 | null =
            decodeSshProductivityDocument(this.crypto.decrypt(legacy));
          if (migrated === null) { return false; }
          const migratedCiphertext: string = this.crypto.encrypt(
            encodeSshProductivityDocument(migrated));
          if (migratedCiphertext.length === 0 || !this.crypto.isProtected(migratedCiphertext) ||
            !this.persistence.write(context, this.storageKey, migratedCiphertext)) {
            return false;
          }
          if (legacyClaim !== this.boundOwnerScopeId &&
            !this.persistence.write(context, SSH_PRODUCTIVITY_LEGACY_CLAIM_KEY,
              this.boundOwnerScopeId)) {
            // The scoped ciphertext is already durable. Leave initialization
            // closed so the same owner retries the claim before another owner
            // can consider the unclaimed legacy payload.
            return false;
          }
          legacyClaim = this.boundOwnerScopeId;
          stored = migratedCiphertext;
        } catch (_err) {
          // Never create an empty owner slot over a recoverable legacy value.
          return false;
        }
      }
    }
    if (stored.length === 0) {
      try {
        const encrypted: string = this.crypto.encrypt(
          encodeSshProductivityDocument(this.document));
        if (encrypted.length === 0 || !this.crypto.isProtected(encrypted) ||
          !this.persistence.write(context, this.storageKey, encrypted)) {
          return false;
        }
        this.persistedCiphertext = encrypted;
        this.initialized = true;
        return true;
      } catch (_err) { return false; }
    }
    if (!this.crypto.isProtected(stored)) { return false; }
    try {
      const decoded: SshProductivityDocumentV1 | null =
        decodeSshProductivityDocument(this.crypto.decrypt(stored));
      if (decoded === null) { return false; }
      this.document = decoded;
      this.persistedCiphertext = stored;
      if (legacyClaim.length === 0 && !this.repairLegacyClaim(context)) {
        return false;
      }
      this.initialized = true;
      return true;
    } catch (_err) { return false; }
  }

  isReady(): boolean {
    if (!this.initialized || this.context === null || !this.crypto.ready() ||
      this.crypto.generation() !== this.boundCryptoGeneration) { return false; }
    const currentScope: SshProductivityScopeFence = this.scope.current();
    return currentScope.ownerScopeId.trim() === this.boundOwnerScopeId &&
      currentScope.generation === this.boundScopeGeneration;
  }

  snapshot(): SshProductivityDocumentV1 {
    if (!this.isReady()) { return emptySshProductivityDocument(); }
    return decodeSshProductivityDocument(encodeSshProductivityDocument(this.document)) ??
      emptySshProductivityDocument();
  }

  /** Explicit cold-path refresh used when a Sheet opens in another window.
   * Keystroke and shell-output hot paths must keep snapshot() memory-only. */
  refreshLatest(): boolean {
    return this.readLatestDocument() !== null;
  }

  clearSensitiveState(): void {
    this.context = null;
    this.document = emptySshProductivityDocument();
    this.initialized = false;
    this.persistedCiphertext = '';
    this.storageKey = '';
    this.boundOwnerScopeId = '';
    this.boundScopeGeneration = 0;
    this.boundCryptoGeneration = -1;
  }

  upsertSnippet(snippet: SshSnippetV1): boolean {
    const normalized: SshSnippetV1 | null = normalizeSshSnippet(snippet);
    if (!this.isReady() || normalized === null) { return false; }
    const next: SshProductivityDocumentV1 | null = this.readLatestDocument();
    if (next === null) { return false; }
    const index: number = next.snippets.findIndex(
      (item: SshSnippetV1): boolean => item.id === normalized.id);
    if (index >= 0) { next.snippets[index] = normalized; }
    else {
      if (next.snippets.length >= SSH_PRODUCTIVITY_MAX_SNIPPETS) { return false; }
      next.snippets.push(normalized);
    }
    return this.commit(next);
  }

  removeSnippet(snippetId: string): boolean {
    if (!this.isReady()) { return false; }
    const next: SshProductivityDocumentV1 | null = this.readLatestDocument();
    if (next === null) { return false; }
    next.snippets = next.snippets.filter(
      (item: SshSnippetV1): boolean => item.id !== snippetId.trim());
    next.startupCommands = next.startupCommands.filter(
      (item: SshStartupCommandV1): boolean => item.snippetId !== snippetId.trim());
    return this.commit(next);
  }

  appendHistory(record: SshCommandHistoryV1): boolean {
    if (!this.isReady()) { return false; }
    const next: SshProductivityDocumentV1 | null = this.readLatestDocument();
    return next !== null && this.commit(appendSshHistory(next, record));
  }

  updateHistoryExitCode(historyId: string, exitCode: number | null): boolean {
    if (!this.isReady()) { return false; }
    const next: SshProductivityDocumentV1 | null = this.readLatestDocument();
    if (next === null) { return false; }
    const index: number = next.history.findIndex(
      (item: SshCommandHistoryV1): boolean => item.id === historyId.trim());
    if (index < 0) { return false; }
    next.history[index].exitCode = exitCode === null || !Number.isFinite(exitCode) ? null :
      Math.floor(exitCode);
    return this.commit(next);
  }

  setSetting(kind: SshProductivitySettingKind, enabled: boolean): boolean {
    if (!this.isReady()) { return false; }
    const next: SshProductivityDocumentV1 | null = this.readLatestDocument();
    if (next === null) { return false; }
    if (kind === 'history') { next.settings.historyEnabled = enabled; }
    else if (kind === 'completion') { next.settings.completionEnabled = enabled; }
    else if (kind === 'notification') {
      next.settings.completionNotificationEnabled = enabled;
    } else { next.settings.shellIntegrationEnabled = enabled; }
    return this.commit(next);
  }

  setStartupCommand(command: SshStartupCommandV1): boolean {
    if (!this.isReady() || command.hostId.trim().length === 0 ||
      command.snippetId.trim().length === 0) { return false; }
    const next: SshProductivityDocumentV1 | null = this.readLatestDocument();
    if (next === null) { return false; }
    const snippet: SshSnippetV1 | undefined = next.snippets.find(
      (item: SshSnippetV1): boolean => item.id === command.snippetId.trim());
    if (command.enabled && !sshSnippetAllowedAsStartup(snippet)) { return false; }
    next.startupCommands = next.startupCommands.filter(
      (item: SshStartupCommandV1): boolean => item.hostId !== command.hostId.trim());
    if (command.enabled) {
      next.startupCommands.push({
        hostId: command.hostId.trim(),
        snippetId: command.snippetId.trim(),
        enabled: true
      });
    }
    return this.commit(next);
  }

  /** Every mutation rebases on the latest encrypted document. Preference I/O
   * and mutation are synchronous on ArkUI's JS thread, so two open terminal
   * windows cannot overwrite each other's older in-memory snapshot. */
  private readLatestDocument(): SshProductivityDocumentV1 | null {
    if (!this.isReady() || this.context === null) { return null; }
    try {
      const stored: string | null = this.persistence.read(this.context, this.storageKey);
      if (stored === null || stored.length === 0 || !this.crypto.isProtected(stored)) {
        this.clearSensitiveState();
        return null;
      }
      const decoded: SshProductivityDocumentV1 | null =
        decodeSshProductivityDocument(this.crypto.decrypt(stored));
      if (decoded === null) {
        this.clearSensitiveState();
        return null;
      }
      this.document = decoded;
      this.persistedCiphertext = stored;
      return decodeSshProductivityDocument(encodeSshProductivityDocument(decoded));
    } catch (_err) {
      this.clearSensitiveState();
      return null;
    }
  }

  private commit(next: SshProductivityDocumentV1): boolean {
    if (!this.isReady()) { return false; }
    const normalized: SshProductivityDocumentV1 | null =
      decodeSshProductivityDocument(encodeSshProductivityDocument(next));
    if (normalized === null) { return false; }
    try {
      const encrypted: string = this.crypto.encrypt(encodeSshProductivityDocument(normalized));
      if (encrypted.length === 0 || !this.crypto.isProtected(encrypted) ||
        !this.persistence.write(this.context as common.Context, this.storageKey, encrypted)) {
        if (this.persistedCiphertext.length > 0) {
          this.persistence.write(this.context as common.Context, this.storageKey,
            this.persistedCiphertext);
        }
        return false;
      }
      this.document = normalized;
      this.persistedCiphertext = encrypted;
      return true;
    } catch (_err) { return false; }
  }

  private storageKeyForOwner(ownerScopeId: string): string {
    const suffix: string = ownerScopeId.trim().replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 96);
    return suffix.length === 0 ? '' : SSH_PRODUCTIVITY_PREFERENCES_KEY + '.' + suffix;
  }

  private normalizeLegacyClaim(value: string): string {
    const normalized: string = value.trim();
    if (normalized.length === 0) { return ''; }
    if (normalized.length > 96 || !/^[A-Za-z0-9._-]+$/.test(normalized)) {
      // A malformed local marker is treated as already claimed. It may skip
      // legacy recovery, but can never disclose the legacy document.
      return '!invalid-legacy-claim!';
    }
    return normalized;
  }

  private repairLegacyClaim(context: common.Context): boolean {
    const legacy: string | null = this.persistence.read(
      context, SSH_PRODUCTIVITY_PREFERENCES_KEY);
    if (legacy === null) { return false; }
    if (legacy.length === 0 || !this.crypto.isProtected(legacy)) { return true; }
    try {
      const decoded: SshProductivityDocumentV1 | null =
        decodeSshProductivityDocument(this.crypto.decrypt(legacy));
      if (decoded === null) { return true; }
      return this.persistence.write(context, SSH_PRODUCTIVITY_LEGACY_CLAIM_KEY,
        this.boundOwnerScopeId);
    } catch (_err) {
      // An existing scoped slot remains usable when an unrelated account's
      // legacy ciphertext cannot be authenticated with the current DEK.
      return true;
    }
  }
}
