import { describe, it, expect } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import {
  appendSshHistory,
  buildSshSnippetInsertSubmission,
  buildSshQuickCommandSnippet,
  captureSshHistory,
  decodeSshProductivityDocument,
  emptySshProductivityDocument,
  encodeSshProductivityDocument,
  renderSshSnippet,
  searchSshProductivity,
  SshLocalCommandTracker,
  SshProductivityDocumentV1,
  SshShellIntegrationParser,
  SshSnippetV1,
  SshStartupCommandV1,
  sshSnippetEditableAsQuickCommand,
  sshStartupExecutionKey,
  startupCommandMayRun
} from '../main/ets/services/ssh/productivity/SshProductivityPolicy';
import {
  SSH_PRODUCTIVITY_LEGACY_CLAIM_KEY,
  SSH_PRODUCTIVITY_PREFERENCES_KEY,
  SshProductivityCryptoPort,
  SshProductivityPersistencePort,
  SshProductivityScopeFence,
  SshProductivityScopePort,
  SshProductivityStore
} from '../main/ets/services/ssh/productivity/SshProductivityStore';

class MemoryProductivityPersistence implements SshProductivityPersistencePort {
  value: string | null = '';
  failWrite: boolean = false;
  failWritesRemaining: number = 0;
  failWriteKeyOnce: string = '';
  writeAttempts: number = 0;
  readAttempts: number = 0;
  values: Map<string, string> = new Map<string, string>();
  read(_context: common.Context, key: string): string | null {
    this.readAttempts++;
    return this.values.get(key) ?? '';
  }
  write(_context: common.Context, key: string, value: string): boolean {
    this.writeAttempts++;
    if (this.failWrite) { return false; }
    if (this.failWriteKeyOnce === key) {
      this.failWriteKeyOnce = '';
      return false;
    }
    if (this.failWritesRemaining > 0) {
      this.failWritesRemaining--;
      return false;
    }
    this.value = value;
    this.values.set(key, value);
    return true;
  }
}

class FakeProductivityCrypto implements SshProductivityCryptoPort {
  available: boolean = true;
  failEncrypt: boolean = false;
  failDecrypt: boolean = false;
  emptyEncrypt: boolean = false;
  generationValue: number = 1;
  ready(): boolean { return this.available; }
  generation(): number { return this.generationValue; }
  isProtected(value: string): boolean {
    return value.startsWith('cipher<') && value.endsWith('>');
  }
  encrypt(value: string): string {
    if (this.failEncrypt) { throw new Error('encrypt failed'); }
    if (this.emptyEncrypt) { return ''; }
    return 'cipher<' + value.split('').reverse().join('') + '>';
  }
  decrypt(value: string): string {
    if (this.failDecrypt) { throw new Error('decrypt failed'); }
    if (!value.startsWith('cipher<') || !value.endsWith('>')) { throw new Error('bad cipher'); }
    return value.slice(7, -1).split('').reverse().join('');
  }
}

class FakeProductivityScope implements SshProductivityScopePort {
  fence: SshProductivityScopeFence = { ownerScopeId: 'device-local', generation: 1 };
  current(): SshProductivityScopeFence {
    return { ownerScopeId: this.fence.ownerScopeId, generation: this.fence.generation };
  }
}

function snippet(): SshSnippetV1 {
  return {
    id: 'snippet-one', title: 'Deploy', description: 'deploy service',
    template: 'deploy --env ${ENV} --token ${TOKEN}', scope: 'global', scopeId: '',
    variables: [
      { name: 'ENV', label: 'Environment', defaultValue: 'prod', secretRef: '' },
      { name: 'TOKEN', label: 'Token', defaultValue: 'must-not-persist', secretRef: 'vault-token' }
    ],
    insertOnly: true, updatedAt: 100
  };
}

function executableSnippet(id: string = 'startup-one'): SshSnippetV1 {
  return {
    id, title: 'Startup', description: 'explicit startup command',
    template: 'tmux attach', scope: 'host', scopeId: 'host-one',
    variables: [], insertOnly: false, updatedAt: 101
  };
}

export default function sshProductivityPolicyTest(): void {
  describe('SshProductivityPolicy', (): void => {
    it('snippet_preview_should_mask_secret_and_default_to_insert_only', 0, (): void => {
      const rendered = renderSshSnippet(snippet(), [
        { name: 'ENV', value: 'staging', secret: false },
        { name: 'TOKEN', value: 'top-secret-value', secret: true }
      ]);
      expect(rendered.ok).assertTrue();
      expect(rendered.insertion.indexOf('top-secret-value') >= 0).assertTrue();
      expect(rendered.preview.indexOf('top-secret-value')).assertEqual(-1);
      expect(rendered.containsSecret).assertTrue();
      expect(snippet().insertOnly).assertTrue();
    });

    it('quick_commands_should_be_bounded_insert_only_and_scope_aware', 0, (): void => {
      const global = buildSshQuickCommandSnippet({
        id: '', title: '查看磁盘', command: 'df -h', scope: 'global', hostId: 'ignored'
      }, 1000, 2);
      expect(global?.id).assertEqual('quick-rs-2');
      expect(global?.scope).assertEqual('global');
      expect(global?.scopeId).assertEqual('');
      expect(global?.insertOnly).assertTrue();
      expect(global?.variables.length).assertEqual(0);
      expect(renderSshSnippet(global as SshSnippetV1, []).insertion).assertEqual('df -h');
      const submission = buildSshSnippetInsertSubmission(global as SshSnippetV1, []);
      expect(submission?.data).assertEqual('df -h');
      expect(submission?.control).assertFalse();
      expect(submission?.data.indexOf('\r')).assertEqual(-1);
      expect(submission?.data.indexOf('\n')).assertEqual(-1);
      expect(sshSnippetEditableAsQuickCommand(global as SshSnippetV1)).assertTrue();

      const host = buildSshQuickCommandSnippet({
        id: 'existing', title: '查看日志', command: 'journalctl -n 100',
        scope: 'host', hostId: 'host-one'
      }, 1001, 3);
      expect(host?.id).assertEqual('existing');
      expect(host?.scopeId).assertEqual('host-one');
      expect(buildSshQuickCommandSnippet({
        id: '', title: '非法多行', command: 'echo one\necho two',
        scope: 'global', hostId: ''
      }, 1002, 4)).assertNull();
      expect(buildSshQuickCommandSnippet({
        id: '', title: '', command: 'pwd', scope: 'global', hostId: ''
      }, 1003, 5)).assertNull();
      expect(sshSnippetEditableAsQuickCommand(snippet())).assertFalse();
    });

    it('decoder_should_whitelist_fields_and_drop_plaintext_secret_defaults', 0, (): void => {
      const document: SshProductivityDocumentV1 = emptySshProductivityDocument();
      document.snippets.push(snippet());
      const raw: string = encodeSshProductivityDocument(document);
      expect(raw.indexOf('must-not-persist')).assertEqual(-1);
      const contaminated: string = raw.replace('"schemaVersion":1',
        '"schemaVersion":1,"password":"never","terminalOutput":"never"');
      const decoded: SshProductivityDocumentV1 | null =
        decodeSshProductivityDocument(contaminated);
      expect((decoded as SshProductivityDocumentV1).settings
        .completionNotificationEnabled).assertFalse();
      const encodedAgain: string = encodeSshProductivityDocument(
        decoded as SshProductivityDocumentV1);
      expect(encodedAgain.indexOf('password')).assertEqual(-1);
      expect(encodedAgain.indexOf('terminalOutput')).assertEqual(-1);
    });

    it('history_should_fail_closed_in_sensitive_terminal_modes', 0, (): void => {
      const base = {
        hostId: 'host-one', command: 'echo safe', nowMs: 100, enabled: true,
        hostDisabled: false, passwordPrompt: false, rawMode: false,
        fullscreenMode: false, secretExpansion: false
      };
      expect(captureSshHistory(base, 1)?.command).assertEqual('echo safe');
      expect(captureSshHistory({ ...base, passwordPrompt: true }, 2)).assertNull();
      expect(captureSshHistory({ ...base, rawMode: true }, 3)).assertNull();
      expect(captureSshHistory({ ...base, fullscreenMode: true }, 4)).assertNull();
      expect(captureSshHistory({ ...base, secretExpansion: true }, 5)).assertNull();
    });

    it('local_tracker_should_only_submit_locally_admitted_printable_commands', 0,
      (): void => {
        const tracker: SshLocalCommandTracker = new SshLocalCommandTracker();
        expect(tracker.push('echo hel', true).length).assertEqual(0);
        const submitted = tracker.push('lo\r', true);
        expect(submitted.length).assertEqual(1);
        expect(submitted[0].command).assertEqual('echo hello');
        tracker.push('password', false);
        expect(tracker.push('\r', true).length).assertEqual(0);
      });

    it('shell_parser_should_handle_every_split_tmux_and_bound_malicious_output', 0,
      (): void => {
        const markers: Array<string> = [
          '\u001B]133;A\u0007',
          '\u001B]633;D;0\u001B\\'
        ];
        for (let markerIndex: number = 0; markerIndex < markers.length; markerIndex++) {
          const marker: string = markers[markerIndex];
          for (let split: number = 1; split < marker.length; split++) {
            const fragmented: SshShellIntegrationParser = new SshShellIntegrationParser();
            const firstCount: number = fragmented.push(marker.slice(0, split)).events.length;
            const secondCount: number = fragmented.push(marker.slice(split)).events.length;
            expect(firstCount + secondCount).assertEqual(1);
          }
        }
        const parser: SshShellIntegrationParser = new SshShellIntegrationParser();
        const tmux: string = '\u001BPtmux;\u001B\u001B]133;A\u001B\u001B\\\u001B\\';
        expect(parser.push(tmux.slice(0, 6)).events.length).assertEqual(0);
        expect(parser.push(tmux.slice(6)).events.length).assertEqual(1);
        const malicious: string = '\u001B]133;' + 'x'.repeat(700) + '\u0007';
        expect(parser.push(malicious).malformed).assertEqual(1);
      });

    it('startup_should_run_once_only_after_authentication_and_host_key', 0, (): void => {
      const fence = { hostId: 'host-one', sessionId: 7, generation: 3,
        authenticated: true, hostKeyVerified: true };
      expect(startupCommandMayRun(fence, '')).assertTrue();
      const key: string = sshStartupExecutionKey(fence);
      expect(startupCommandMayRun(fence, key)).assertFalse();
      expect(startupCommandMayRun({ ...fence, authenticated: false }, '')).assertFalse();
      expect(startupCommandMayRun({ ...fence, hostKeyVerified: false }, '')).assertFalse();
    });

    it('history_search_should_stay_host_scoped_and_keep_pinned_records', 0, (): void => {
      let document: SshProductivityDocumentV1 = emptySshProductivityDocument();
      const first = captureSshHistory({ hostId: 'host-one', command: 'kubectl get pods',
        nowMs: 100, enabled: true, hostDisabled: false, passwordPrompt: false,
        rawMode: false, fullscreenMode: false, secretExpansion: false }, 1);
      document = appendSshHistory(document, first!);
      const second = captureSshHistory({ hostId: 'host-two', command: 'kubectl get nodes',
        nowMs: 101, enabled: true, hostDisabled: false, passwordPrompt: false,
        rawMode: false, fullscreenMode: false, secretExpansion: false }, 2);
      document = appendSshHistory(document, second!);
      expect(searchSshProductivity(document, 'kubectl', 'host-one', '').length).assertEqual(1);
    });

    it('encrypted_store_should_fail_closed_and_restore_last_ciphertext_on_write_failure', 0,
      (): void => {
        const persistence: MemoryProductivityPersistence = new MemoryProductivityPersistence();
        const crypto: FakeProductivityCrypto = new FakeProductivityCrypto();
        const store: SshProductivityStore = new SshProductivityStore(persistence, crypto);
        const context: common.Context = undefined as common.Context;
        expect(store.init(context)).assertTrue();
        expect((persistence.value as string).indexOf('schemaVersion')).assertEqual(-1);
        const before: string = persistence.value as string;
        persistence.failWrite = true;
        expect(store.upsertSnippet(snippet())).assertFalse();
        expect(persistence.value).assertEqual(before);
        crypto.available = false;
      expect(store.isReady()).assertFalse();
    });

    it('encrypted_store_should_persist_update_and_remove_quick_commands', 0, (): void => {
      const persistence: MemoryProductivityPersistence = new MemoryProductivityPersistence();
      const crypto: FakeProductivityCrypto = new FakeProductivityCrypto();
      const context: common.Context = undefined as common.Context;
      const store: SshProductivityStore = new SshProductivityStore(persistence, crypto);
      expect(store.init(context)).assertTrue();
      const created = buildSshQuickCommandSnippet({
        id: '', title: 'Pods', command: 'kubectl get pods',
        scope: 'host', hostId: 'host-one'
      }, 2000, 1) as SshSnippetV1;
      expect(store.upsertSnippet(created)).assertTrue();
      const restored: SshProductivityStore = new SshProductivityStore(persistence, crypto);
      expect(restored.init(context)).assertTrue();
      expect(restored.snapshot().snippets.length).assertEqual(1);
      const updated = buildSshQuickCommandSnippet({
        id: created.id, title: 'Pods wide', command: 'kubectl get pods -o wide',
        scope: 'host', hostId: 'host-one'
      }, 2001, 2) as SshSnippetV1;
      expect(restored.upsertSnippet(updated)).assertTrue();
      expect(restored.snapshot().snippets.length).assertEqual(1);
      expect(restored.snapshot().snippets[0].template).assertEqual('kubectl get pods -o wide');
      expect(restored.setStartupCommand({
        hostId: 'host-one', snippetId: created.id, enabled: true
      })).assertFalse();
      expect(restored.removeSnippet(created.id)).assertTrue();
      expect(restored.snapshot().snippets.length).assertEqual(0);
      expect(restored.snapshot().startupCommands.length).assertEqual(0);
    });

    it('startup_store_should_persist_reference_only_and_reject_secret_snippet', 0,
      (): void => {
        const persistence: MemoryProductivityPersistence = new MemoryProductivityPersistence();
        const crypto: FakeProductivityCrypto = new FakeProductivityCrypto();
        const store: SshProductivityStore = new SshProductivityStore(persistence, crypto);
        const context: common.Context = undefined as common.Context;
        expect(store.init(context)).assertTrue();
        expect(store.upsertSnippet(snippet())).assertTrue();
        expect(store.setStartupCommand({
          hostId: 'host-one', snippetId: 'snippet-one', enabled: true
        })).assertFalse();
        expect(store.upsertSnippet(executableSnippet())).assertTrue();
        expect(store.setStartupCommand({
          hostId: 'host-one', snippetId: 'startup-one', enabled: true
        })).assertTrue();
        expect(store.snapshot().startupCommands[0].snippetId).assertEqual('startup-one');
        const contaminated: SshProductivityDocumentV1 = emptySshProductivityDocument();
        contaminated.startupCommands.push({
          hostId: 'host-one', snippetId: 'snippet-one', enabled: true,
          command: 'top-secret-value'
        } as SshStartupCommandV1);
      const encoded: string = encodeSshProductivityDocument(contaminated);
      expect(encoded.indexOf('top-secret-value')).assertEqual(-1);
      expect((decodeSshProductivityDocument(encoded) as SshProductivityDocumentV1)
        .startupCommands.length).assertEqual(0);
    });

    it('startup_should_drop_insert_only_legacy_references', 0, (): void => {
      const document: SshProductivityDocumentV1 = emptySshProductivityDocument();
      const quick = buildSshQuickCommandSnippet({
        id: 'quick-one', title: 'Disk', command: 'df -h', scope: 'global', hostId: ''
      }, 3000, 1) as SshSnippetV1;
      document.snippets.push(quick);
      document.startupCommands.push({
        hostId: 'host-one', snippetId: quick.id, enabled: true
      });
      const decoded = decodeSshProductivityDocument(encodeSshProductivityDocument(document));
      expect(decoded?.startupCommands.length).assertEqual(0);
    });

    it('stores_should_rebase_interleaved_writes_on_latest_scoped_ciphertext', 0,
      (): void => {
        const persistence: MemoryProductivityPersistence = new MemoryProductivityPersistence();
        const crypto: FakeProductivityCrypto = new FakeProductivityCrypto();
        const scope: FakeProductivityScope = new FakeProductivityScope();
        const context: common.Context = undefined as common.Context;
        const first: SshProductivityStore = new SshProductivityStore(persistence, crypto, scope);
        const second: SshProductivityStore = new SshProductivityStore(persistence, crypto, scope);
        expect(first.init(context)).assertTrue();
        expect(second.init(context)).assertTrue();
        const readsBeforeSnapshot: number = persistence.readAttempts;
        expect(second.snapshot().snippets.length).assertEqual(0);
        expect(persistence.readAttempts).assertEqual(readsBeforeSnapshot);
        expect(first.upsertSnippet(executableSnippet('from-first'))).assertTrue();
        expect(second.upsertSnippet(executableSnippet('from-second'))).assertTrue();
        expect(first.setSetting('history', true)).assertTrue();
        expect(second.setSetting('completion', true)).assertTrue();
        const ids: Array<string> = first.snapshot().snippets.map(
          (item: SshSnippetV1): string => item.id).sort();
        expect(ids.length).assertEqual(2);
        expect(ids[0]).assertEqual('from-first');
        expect(ids[1]).assertEqual('from-second');
        expect(first.refreshLatest()).assertTrue();
        expect(first.snapshot().settings.historyEnabled).assertTrue();
        expect(first.snapshot().settings.completionEnabled).assertTrue();
      });

    it('store_should_fail_closed_at_capacity_without_dropping_existing_snippets', 0,
      (): void => {
        const persistence: MemoryProductivityPersistence = new MemoryProductivityPersistence();
        const crypto: FakeProductivityCrypto = new FakeProductivityCrypto();
        const scope: FakeProductivityScope = new FakeProductivityScope();
        const context: common.Context = undefined as common.Context;
        const store: SshProductivityStore = new SshProductivityStore(persistence, crypto, scope);
        expect(store.init(context)).assertTrue();
        for (let index: number = 0; index < 200; index++) {
          expect(store.upsertSnippet(executableSnippet('capacity-' + index.toString())))
            .assertTrue();
        }
        expect(store.upsertSnippet(executableSnippet('capacity-overflow'))).assertFalse();
        const snapshot: SshProductivityDocumentV1 = store.snapshot();
        expect(snapshot.snippets.length).assertEqual(200);
        expect(snapshot.snippets.some((item: SshSnippetV1): boolean =>
          item.id === 'capacity-overflow')).assertFalse();
      });

    it('store_should_fence_crypto_generation_and_account_scope', 0, (): void => {
      const persistence: MemoryProductivityPersistence = new MemoryProductivityPersistence();
      const crypto: FakeProductivityCrypto = new FakeProductivityCrypto();
      const scope: FakeProductivityScope = new FakeProductivityScope();
      const context: common.Context = undefined as common.Context;
      const store: SshProductivityStore = new SshProductivityStore(persistence, crypto, scope);
      expect(store.init(context)).assertTrue();
      expect(store.upsertSnippet(executableSnippet('owner-a'))).assertTrue();
      crypto.available = false;
      expect(store.isReady()).assertFalse();
      crypto.generationValue++;
      crypto.available = true;
      expect(store.isReady()).assertFalse();
      expect(store.snapshot().snippets.length).assertEqual(0);
      expect(store.init(context)).assertTrue();
      expect(store.snapshot().snippets.length).assertEqual(1);
      scope.fence = { ownerScopeId: 'owner-b', generation: 2 };
      expect(store.isReady()).assertFalse();
      expect(store.init(context)).assertTrue();
      expect(store.snapshot().snippets.length).assertEqual(0);
      expect(store.upsertSnippet(executableSnippet('owner-b'))).assertTrue();
      scope.fence = { ownerScopeId: 'device-local', generation: 3 };
      expect(store.isReady()).assertFalse();
      expect(store.init(context)).assertTrue();
      expect(store.snapshot().snippets[0].id).assertEqual('owner-a');
    });

    it('store_should_never_accept_or_copy_plaintext_persistence', 0, (): void => {
      const context: common.Context = undefined as common.Context;
      const crypto: FakeProductivityCrypto = new FakeProductivityCrypto();
      const scope: FakeProductivityScope = new FakeProductivityScope();
      const legacyPersistence: MemoryProductivityPersistence =
        new MemoryProductivityPersistence();
      const legacyDocument: SshProductivityDocumentV1 = emptySshProductivityDocument();
      legacyDocument.snippets.push(executableSnippet('plaintext-legacy'));
      legacyPersistence.values.set(SSH_PRODUCTIVITY_PREFERENCES_KEY,
        encodeSshProductivityDocument(legacyDocument));
      const migrated: SshProductivityStore = new SshProductivityStore(
        legacyPersistence, crypto, scope);
      expect(migrated.init(context)).assertTrue();
      expect(migrated.snapshot().snippets.length).assertEqual(0);
      expect(crypto.isProtected(legacyPersistence.values.get(
        SSH_PRODUCTIVITY_PREFERENCES_KEY + '.device-local') ?? '')).assertTrue();

      const scopedPersistence: MemoryProductivityPersistence =
        new MemoryProductivityPersistence();
      scopedPersistence.values.set(SSH_PRODUCTIVITY_PREFERENCES_KEY + '.device-local',
        encodeSshProductivityDocument(legacyDocument));
      const rejected: SshProductivityStore = new SshProductivityStore(
        scopedPersistence, crypto, scope);
      expect(rejected.init(context)).assertFalse();
      expect(rejected.snapshot().snippets.length).assertEqual(0);
    });

    it('legacy_migration_failure_should_not_create_an_empty_owner_slot', 0,
      (): void => {
        const context: common.Context = undefined as common.Context;
        const crypto: FakeProductivityCrypto = new FakeProductivityCrypto();
        const scope: FakeProductivityScope = new FakeProductivityScope();
        const persistence: MemoryProductivityPersistence = new MemoryProductivityPersistence();
        const legacyDocument: SshProductivityDocumentV1 = emptySshProductivityDocument();
        legacyDocument.snippets.push(executableSnippet('recoverable-legacy'));
        persistence.values.set(SSH_PRODUCTIVITY_PREFERENCES_KEY,
          crypto.encrypt(encodeSshProductivityDocument(legacyDocument)));
        persistence.failWritesRemaining = 1;
        const store: SshProductivityStore = new SshProductivityStore(
          persistence, crypto, scope);
        expect(store.init(context)).assertFalse();
        expect(persistence.writeAttempts).assertEqual(1);
        expect(persistence.values.has(
          SSH_PRODUCTIVITY_PREFERENCES_KEY + '.device-local')).assertFalse();

        const future: MemoryProductivityPersistence = new MemoryProductivityPersistence();
        future.values.set(SSH_PRODUCTIVITY_PREFERENCES_KEY, crypto.encrypt('{"schemaVersion":2}'));
        expect(new SshProductivityStore(future, crypto, scope).init(context)).assertFalse();
        expect(future.values.has(
          SSH_PRODUCTIVITY_PREFERENCES_KEY + '.device-local')).assertFalse();
      });

    it('legacy_claim_write_should_retry_from_the_durable_owner_slot', 0,
      (): void => {
        const context: common.Context = undefined as common.Context;
        const crypto: FakeProductivityCrypto = new FakeProductivityCrypto();
        const scope: FakeProductivityScope = new FakeProductivityScope();
        const persistence: MemoryProductivityPersistence = new MemoryProductivityPersistence();
        const legacyDocument: SshProductivityDocumentV1 = emptySshProductivityDocument();
        legacyDocument.snippets.push(executableSnippet('claim-retry'));
        persistence.values.set(SSH_PRODUCTIVITY_PREFERENCES_KEY,
          crypto.encrypt(encodeSshProductivityDocument(legacyDocument)));
        persistence.failWriteKeyOnce = SSH_PRODUCTIVITY_LEGACY_CLAIM_KEY;

        const first: SshProductivityStore = new SshProductivityStore(
          persistence, crypto, scope);
        expect(first.init(context)).assertFalse();
        expect(crypto.isProtected(persistence.values.get(
          SSH_PRODUCTIVITY_PREFERENCES_KEY + '.device-local') ?? '')).assertTrue();
        expect(persistence.values.has(SSH_PRODUCTIVITY_LEGACY_CLAIM_KEY)).assertFalse();

        const retried: SshProductivityStore = new SshProductivityStore(
          persistence, crypto, scope);
        expect(retried.init(context)).assertTrue();
        expect(retried.snapshot().snippets[0].id).assertEqual('claim-retry');
        expect(persistence.values.get(SSH_PRODUCTIVITY_LEGACY_CLAIM_KEY))
          .assertEqual('device-local');
      });

    it('protected_legacy_should_migrate_only_for_the_authenticating_account', 0,
      (): void => {
        const context: common.Context = undefined as common.Context;
        const crypto: FakeProductivityCrypto = new FakeProductivityCrypto();
        const scope: FakeProductivityScope = new FakeProductivityScope();
        scope.fence = { ownerScopeId: 'owner-a', generation: 2 };
        const persistence: MemoryProductivityPersistence = new MemoryProductivityPersistence();
        const legacyDocument: SshProductivityDocumentV1 = emptySshProductivityDocument();
        legacyDocument.snippets.push(executableSnippet('account-legacy'));
        persistence.values.set(SSH_PRODUCTIVITY_PREFERENCES_KEY,
          crypto.encrypt(encodeSshProductivityDocument(legacyDocument)));
        const migrated: SshProductivityStore = new SshProductivityStore(
          persistence, crypto, scope);
        expect(migrated.init(context)).assertTrue();
        expect(migrated.snapshot().snippets[0].id).assertEqual('account-legacy');
        expect(crypto.isProtected(persistence.values.get(
          SSH_PRODUCTIVITY_PREFERENCES_KEY + '.owner-a') ?? '')).assertTrue();
        expect(persistence.values.get(SSH_PRODUCTIVITY_LEGACY_CLAIM_KEY))
          .assertEqual('owner-a');

        scope.fence = { ownerScopeId: 'owner-b', generation: 3 };
        const isolated: SshProductivityStore = new SshProductivityStore(
          persistence, crypto, scope);
        expect(isolated.init(context)).assertTrue();
        expect(isolated.snapshot().snippets.length).assertEqual(0);
        expect(crypto.isProtected(persistence.values.get(
          SSH_PRODUCTIVITY_PREFERENCES_KEY + '.owner-b') ?? '')).assertTrue();

        scope.fence = { ownerScopeId: 'owner-a', generation: 4 };
        const restored: SshProductivityStore = new SshProductivityStore(
          persistence, crypto, scope);
        expect(restored.init(context)).assertTrue();
        expect(restored.snapshot().snippets[0].id).assertEqual('account-legacy');

        const mismatchPersistence: MemoryProductivityPersistence =
          new MemoryProductivityPersistence();
        mismatchPersistence.values.set(SSH_PRODUCTIVITY_PREFERENCES_KEY,
          crypto.encrypt(encodeSshProductivityDocument(legacyDocument)));
        const mismatchCrypto: FakeProductivityCrypto = new FakeProductivityCrypto();
        mismatchCrypto.failDecrypt = true;
        scope.fence = { ownerScopeId: 'owner-b', generation: 5 };
        const rejected: SshProductivityStore = new SshProductivityStore(
          mismatchPersistence, mismatchCrypto, scope);
        expect(rejected.init(context)).assertFalse();
        expect(mismatchPersistence.values.has(
          SSH_PRODUCTIVITY_PREFERENCES_KEY + '.owner-b')).assertFalse();
      });

    it('fresh_store_should_fail_closed_when_encrypt_throws_or_returns_empty', 0,
      (): void => {
        const context: common.Context = undefined as common.Context;
        const throwingCrypto: FakeProductivityCrypto = new FakeProductivityCrypto();
        throwingCrypto.failEncrypt = true;
        expect(new SshProductivityStore(new MemoryProductivityPersistence(), throwingCrypto)
          .init(context)).assertFalse();
        const emptyCrypto: FakeProductivityCrypto = new FakeProductivityCrypto();
        emptyCrypto.emptyEncrypt = true;
        expect(new SshProductivityStore(new MemoryProductivityPersistence(), emptyCrypto)
          .init(context)).assertFalse();
      });
  });
}
