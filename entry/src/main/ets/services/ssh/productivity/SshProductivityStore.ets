import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { DataCrypto } from '../../DataCrypto';
import {
  appendSshHistory,
  decodeSshProductivityDocument,
  emptySshProductivityDocument,
  encodeSshProductivityDocument,
  normalizeSshSnippet,
  SshCommandHistoryV1,
  SshProductivityDocumentV1,
  SshProductivitySettingsV1,
  SshSnippetV1,
  SshSnippetVariableV1,
  SshStartupCommandV1
} from './SshProductivityPolicy';

export const SSH_PRODUCTIVITY_PREFERENCES_NAME: string = 'RemoteDesktopSshProductivityPrefs';
export const SSH_PRODUCTIVITY_PREFERENCES_KEY: string = 'ssh.productivity.encrypted.v1';

export interface SshProductivityPersistencePort {
  read(context: common.Context): string | null;
  write(context: common.Context, value: string): boolean;
}

export interface SshProductivityCryptoPort {
  ready(): boolean;
  encrypt(value: string): string;
  decrypt(value: string): string;
}

class HarmonySshProductivityPersistence implements SshProductivityPersistencePort {
  read(context: common.Context): string | null {
    try {
      const prefs = preferences.getPreferencesSync(context, {
        name: SSH_PRODUCTIVITY_PREFERENCES_NAME
      });
      const value: Object = prefs.getSync(SSH_PRODUCTIVITY_PREFERENCES_KEY, '') as Object;
      return typeof value === 'string' ? value as string : null;
    } catch (_err) { return null; }
  }

  write(context: common.Context, value: string): boolean {
    try {
      const prefs = preferences.getPreferencesSync(context, {
        name: SSH_PRODUCTIVITY_PREFERENCES_NAME
      });
      prefs.putSync(SSH_PRODUCTIVITY_PREFERENCES_KEY, value);
      prefs.flushSync();
      return true;
    } catch (_err) { return false; }
  }
}

class DataCryptoSshProductivityPort implements SshProductivityCryptoPort {
  ready(): boolean { return DataCrypto.getInstance().isReady(); }
  encrypt(value: string): string { return DataCrypto.getInstance().encrypt(value); }
  decrypt(value: string): string { return DataCrypto.getInstance().decrypt(value); }
}

export class SshProductivityStore {
  private context: common.Context | null = null;
  private persistence: SshProductivityPersistencePort;
  private crypto: SshProductivityCryptoPort;
  private document: SshProductivityDocumentV1 = emptySshProductivityDocument();
  private initialized: boolean = false;
  private persistedCiphertext: string = '';

  constructor(persistence: SshProductivityPersistencePort = new HarmonySshProductivityPersistence(),
    crypto: SshProductivityCryptoPort = new DataCryptoSshProductivityPort()) {
    this.persistence = persistence;
    this.crypto = crypto;
  }

  init(context: common.Context): boolean {
    this.context = context;
    this.initialized = false;
    this.document = emptySshProductivityDocument();
    this.persistedCiphertext = '';
    if (!this.crypto.ready()) { return false; }
    const stored: string | null = this.persistence.read(context);
    if (stored === null) { return false; }
    if (stored.length === 0) {
      try {
        const encrypted: string = this.crypto.encrypt(
          encodeSshProductivityDocument(this.document));
        if (encrypted.length === 0 || !this.persistence.write(context, encrypted)) {
          return false;
        }
        this.persistedCiphertext = encrypted;
        this.initialized = true;
        return true;
      } catch (_err) { return false; }
    }
    try {
      const decoded: SshProductivityDocumentV1 | null =
        decodeSshProductivityDocument(this.crypto.decrypt(stored));
      if (decoded === null) { return false; }
      this.document = decoded;
      this.persistedCiphertext = stored;
      this.initialized = true;
      return true;
    } catch (_err) { return false; }
  }

  isReady(): boolean { return this.initialized && this.context !== null && this.crypto.ready(); }

  snapshot(): SshProductivityDocumentV1 {
    return decodeSshProductivityDocument(encodeSshProductivityDocument(this.document)) ??
      emptySshProductivityDocument();
  }

  upsertSnippet(snippet: SshSnippetV1): boolean {
    const normalized: SshSnippetV1 | null = normalizeSshSnippet(snippet);
    if (!this.isReady() || normalized === null) { return false; }
    const next: SshProductivityDocumentV1 = this.snapshot();
    const index: number = next.snippets.findIndex(
      (item: SshSnippetV1): boolean => item.id === normalized.id);
    if (index >= 0) { next.snippets[index] = normalized; }
    else { next.snippets.push(normalized); }
    return this.commit(next);
  }

  removeSnippet(snippetId: string): boolean {
    if (!this.isReady()) { return false; }
    const next: SshProductivityDocumentV1 = this.snapshot();
    next.snippets = next.snippets.filter(
      (item: SshSnippetV1): boolean => item.id !== snippetId.trim());
    next.startupCommands = next.startupCommands.filter(
      (item: SshStartupCommandV1): boolean => item.snippetId !== snippetId.trim());
    return this.commit(next);
  }

  appendHistory(record: SshCommandHistoryV1): boolean {
    if (!this.isReady()) { return false; }
    return this.commit(appendSshHistory(this.document, record));
  }

  updateHistoryExitCode(historyId: string, exitCode: number | null): boolean {
    if (!this.isReady()) { return false; }
    const next: SshProductivityDocumentV1 = this.snapshot();
    const index: number = next.history.findIndex(
      (item: SshCommandHistoryV1): boolean => item.id === historyId.trim());
    if (index < 0) { return false; }
    next.history[index].exitCode = exitCode === null || !Number.isFinite(exitCode) ? null :
      Math.floor(exitCode);
    return this.commit(next);
  }

  setSettings(settings: SshProductivitySettingsV1): boolean {
    if (!this.isReady()) { return false; }
    const next: SshProductivityDocumentV1 = this.snapshot();
    next.settings = settings;
    return this.commit(next);
  }

  setStartupCommand(command: SshStartupCommandV1): boolean {
    if (!this.isReady() || command.hostId.trim().length === 0 ||
      command.snippetId.trim().length === 0) { return false; }
    const next: SshProductivityDocumentV1 = this.snapshot();
    const snippet: SshSnippetV1 | undefined = next.snippets.find(
      (item: SshSnippetV1): boolean => item.id === command.snippetId.trim());
    if (command.enabled && (snippet === undefined || snippet.variables.some(
      (item: SshSnippetVariableV1): boolean => item.secretRef.length > 0))) { return false; }
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

  private commit(next: SshProductivityDocumentV1): boolean {
    if (!this.isReady()) { return false; }
    const normalized: SshProductivityDocumentV1 | null =
      decodeSshProductivityDocument(encodeSshProductivityDocument(next));
    if (normalized === null) { return false; }
    try {
      const encrypted: string = this.crypto.encrypt(encodeSshProductivityDocument(normalized));
      if (encrypted.length === 0 ||
        !this.persistence.write(this.context as common.Context, encrypted)) {
        if (this.persistedCiphertext.length > 0) {
          this.persistence.write(this.context as common.Context, this.persistedCiphertext);
        }
        return false;
      }
      this.document = normalized;
      this.persistedCiphertext = encrypted;
      return true;
    } catch (_err) { return false; }
  }
}
