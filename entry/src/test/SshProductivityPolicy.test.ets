import { describe, it, expect } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import {
  appendSshHistory,
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
  sshStartupExecutionKey,
  startupCommandMayRun
} from '../main/ets/services/ssh/productivity/SshProductivityPolicy';
import {
  SshProductivityCryptoPort,
  SshProductivityPersistencePort,
  SshProductivityStore
} from '../main/ets/services/ssh/productivity/SshProductivityStore';

class MemoryProductivityPersistence implements SshProductivityPersistencePort {
  value: string | null = '';
  failWrite: boolean = false;
  read(_context: common.Context): string | null { return this.value; }
  write(_context: common.Context, value: string): boolean {
    if (this.failWrite) { return false; }
    this.value = value;
    return true;
  }
}

class FakeProductivityCrypto implements SshProductivityCryptoPort {
  available: boolean = true;
  failEncrypt: boolean = false;
  emptyEncrypt: boolean = false;
  ready(): boolean { return this.available; }
  encrypt(value: string): string {
    if (this.failEncrypt) { throw new Error('encrypt failed'); }
    if (this.emptyEncrypt) { return ''; }
    return 'cipher<' + value.split('').reverse().join('') + '>';
  }
  decrypt(value: string): string {
    if (!value.startsWith('cipher<') || !value.endsWith('>')) { throw new Error('bad cipher'); }
    return value.slice(7, -1).split('').reverse().join('');
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
        const contaminated: SshProductivityDocumentV1 = emptySshProductivityDocument();
        contaminated.startupCommands.push({
          hostId: 'host-one', snippetId: 'snippet-one', enabled: true,
          command: 'top-secret-value'
        } as SshStartupCommandV1);
        const encoded: string = encodeSshProductivityDocument(contaminated);
        expect(encoded.indexOf('top-secret-value')).assertEqual(-1);
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
