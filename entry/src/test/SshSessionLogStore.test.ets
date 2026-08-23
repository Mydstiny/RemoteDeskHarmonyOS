import { describe, it, expect } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import {
  SshSessionLogCryptoPort,
  SshSessionLogPersistencePort,
  SshSessionLogStore
} from '../main/ets/services/ssh/log/SshSessionLogStore';
import {
  SshSessionLogRecordV1,
  SshSessionLogSettingsV1
} from '../main/ets/services/ssh/log/SshSessionLogPolicy';

class MemoryLogPersistence implements SshSessionLogPersistencePort {
  index: string | null = null;
  chunks: Map<string, string> = new Map<string, string>();
  failIndexWrite: boolean = false;
  failChunkWrite: boolean = false;
  async prepare(_context: common.Context): Promise<boolean> { return true; }
  readIndex(_context: common.Context): string | null { return this.index; }
  writeIndex(_context: common.Context, value: string): boolean {
    if (this.failIndexWrite) { return false; }
    this.index = value;
    return true;
  }
  readChunk(_context: common.Context, chunkId: string): string | null {
    return this.chunks.get(chunkId) ?? null;
  }
  listChunkIds(_context: common.Context): Array<string> | null {
    return Array.from(this.chunks.keys());
  }
  writeChunk(_context: common.Context, chunkId: string, value: string): boolean {
    if (this.failChunkWrite) { return false; }
    this.chunks.set(chunkId, value);
    return true;
  }
  removeChunk(_context: common.Context, chunkId: string): boolean {
    this.chunks.delete(chunkId);
    return true;
  }
}

class FakeLogCrypto implements SshSessionLogCryptoPort {
  available: boolean = true;
  failEncrypt: boolean = false;
  ready(): boolean { return this.available; }
  encrypt(value: string): string {
    if (this.failEncrypt) { throw new Error('encrypt failed'); }
    return 'cipher<' + value.split('').reverse().join('') + '>';
  }
  decrypt(value: string): string {
    if (!value.startsWith('cipher<') || !value.endsWith('>')) { throw new Error('bad cipher'); }
    return value.slice(7, -1).split('').reverse().join('');
  }
}

function logRecord(id: string, text: string): SshSessionLogRecordV1 {
  return {
    id, hostId: 'host-one', sessionId: 9, generation: 1, timestamp: 100,
    direction: 'output', kind: 'data', text, searchText: '', byteSize: text.length
  };
}

export default function sshSessionLogStoreTest(): void {
  describe('SshSessionLogStore', (): void => {
    it('should_initialize_an_encrypted_empty_index_and_restore_chunks', 0, (): void => {
      const persistence = new MemoryLogPersistence();
      const crypto = new FakeLogCrypto();
      const store = new SshSessionLogStore(persistence, crypto);
      const context: common.Context = undefined as common.Context;
      expect(store.init(context)).assertTrue();
      const settings: SshSessionLogSettingsV1 = store.snapshot().settings;
      settings.enabled = true;
      expect(store.setSettings(settings)).assertTrue();
      expect(store.append(logRecord('one', 'safe output'))).assertTrue();
      expect(persistence.index?.indexOf('safe output') ?? -1).assertEqual(-1);
      expect(persistence.chunks.size).assertEqual(1);
      const restored = new SshSessionLogStore(persistence, crypto);
      expect(restored.init(context)).assertTrue();
      expect(restored.search('safe', 'host-one').length).assertEqual(1);
    });

    it('should_keep_previous_snapshot_when_index_write_fails', 0, (): void => {
      const persistence = new MemoryLogPersistence();
      const crypto = new FakeLogCrypto();
      const store = new SshSessionLogStore(persistence, crypto);
      const context: common.Context = undefined as common.Context;
      expect(store.init(context)).assertTrue();
      const settings = store.snapshot().settings;
      settings.enabled = true;
      expect(store.setSettings(settings)).assertTrue();
      expect(store.append(logRecord('one', 'before'))).assertTrue();
      persistence.failIndexWrite = true;
      expect(store.append(logRecord('two', 'after'))).assertFalse();
      expect(persistence.chunks.size).assertEqual(1);
      expect(store.search('before', 'host-one').length).assertEqual(1);
      expect(store.search('after', 'host-one').length).assertEqual(0);
      persistence.failIndexWrite = false;
      const restored = new SshSessionLogStore(persistence, crypto);
      expect(restored.init(context)).assertTrue();
      expect(restored.search('before', 'host-one').length).assertEqual(1);
      expect(restored.search('after', 'host-one').length).assertEqual(0);
    });

    it('should_remove_orphan_chunks_after_process_restart', 0, (): void => {
      const persistence = new MemoryLogPersistence();
      const crypto = new FakeLogCrypto();
      const context: common.Context = undefined as common.Context;
      const store = new SshSessionLogStore(persistence, crypto);
      expect(store.init(context)).assertTrue();
      const settings: SshSessionLogSettingsV1 = store.settingsSnapshot();
      settings.enabled = true;
      expect(store.setSettings(settings)).assertTrue();
      expect(store.append(logRecord('one', 'committed'))).assertTrue();
      persistence.chunks.set('power-loss-orphan', 'cipher<unreferenced>');

      const restored = new SshSessionLogStore(persistence, crypto);
      expect(restored.init(context)).assertTrue();
      expect(restored.search('committed', 'host-one').length).assertEqual(1);
      expect(persistence.chunks.has('power-loss-orphan')).assertFalse();
      expect(persistence.chunks.size).assertEqual(1);
    });

    it('should_not_replace_a_missing_index_when_chunk_rows_still_exist', 0, (): void => {
      const persistence = new MemoryLogPersistence();
      const crypto = new FakeLogCrypto();
      persistence.chunks.set('preserve-for-recovery', 'cipher<unreferenced>');
      const restored = new SshSessionLogStore(persistence, crypto);

      expect(restored.init(undefined as common.Context)).assertFalse();
      expect(persistence.index === null).assertTrue();
      expect(persistence.chunks.has('preserve-for-recovery')).assertTrue();
    });

    it('should_fail_closed_when_a_repaired_index_cannot_be_committed', 0, (): void => {
      const persistence = new MemoryLogPersistence();
      const crypto = new FakeLogCrypto();
      const context: common.Context = undefined as common.Context;
      const store = new SshSessionLogStore(persistence, crypto);
      expect(store.init(context)).assertTrue();
      const settings: SshSessionLogSettingsV1 = store.settingsSnapshot();
      settings.enabled = true;
      expect(store.setSettings(settings)).assertTrue();
      expect(store.append(logRecord('one', 'missing after power loss'))).assertTrue();
      const committedId: string = Array.from(persistence.chunks.keys())[0];
      persistence.chunks.delete(committedId);
      persistence.failIndexWrite = true;

      const restored = new SshSessionLogStore(persistence, crypto);
      expect(restored.init(context)).assertFalse();
      expect(restored.isReady()).assertFalse();
    });

    it('should_keep_record_payloads_out_of_page_snapshots', 0, (): void => {
      const persistence = new MemoryLogPersistence();
      const crypto = new FakeLogCrypto();
      const store = new SshSessionLogStore(persistence, crypto);
      const context: common.Context = undefined as common.Context;
      expect(store.init(context)).assertTrue();
      const settings: SshSessionLogSettingsV1 = store.settingsSnapshot();
      settings.enabled = true;
      expect(store.setSettings(settings)).assertTrue();
      expect(store.append(logRecord('one', 'payload stays in the store'))).assertTrue();

      const page = store.pageSnapshot();
      expect(page.settings.enabled).assertTrue();
      expect(page.chunks.length).assertEqual(1);
      expect(page.chunks[0].byteSize > 0).assertTrue();
      expect(page.chunks[0].records.length).assertEqual(0);
      expect(store.snapshot().chunks[0].records.length).assertEqual(1);
      expect(store.search('payload', 'host-one').length).assertEqual(1);
    });

    it('should_yield_and_honor_cancellation_between_search_slices', 0,
      async (): Promise<void> => {
        const persistence = new MemoryLogPersistence();
        const crypto = new FakeLogCrypto();
        const store = new SshSessionLogStore(persistence, crypto);
        const context: common.Context = undefined as common.Context;
        expect(store.init(context)).assertTrue();
        const settings: SshSessionLogSettingsV1 = store.settingsSnapshot();
        settings.enabled = true;
        expect(store.setSettings(settings)).assertTrue();
        for (let index: number = 0; index < 513; index++) {
          const item: SshSessionLogRecordV1 = logRecord(
            'yield-' + index.toString(), 'search-miss-' + index.toString());
          item.timestamp = 100 + index;
          expect(store.append(item, item.timestamp)).assertTrue();
        }
        let continuationChecks: number = 0;
        const results = await store.searchAsync(
          'not-present', 'host-one', undefined, (): boolean => {
            continuationChecks++;
            return continuationChecks < 2;
          });

        expect(continuationChecks).assertEqual(2);
        expect(results.length).assertEqual(0);
      });

    it('should_fail_closed_when_crypto_is_unavailable', 0, (): void => {
      const persistence = new MemoryLogPersistence();
      const crypto = new FakeLogCrypto();
      crypto.available = false;
      const store = new SshSessionLogStore(persistence, crypto);
      expect(store.init(undefined as common.Context)).assertFalse();
      expect(store.append(logRecord('one', 'never'))).assertFalse();
    });
  });
}
