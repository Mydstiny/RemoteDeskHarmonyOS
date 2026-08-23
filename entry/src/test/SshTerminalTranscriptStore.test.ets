/** SshTerminalTranscriptStore.test.ets - bounded per-host VT replay. */

import { describe, it, expect } from '@ohos/hypium';
import { SshTerminalTranscriptStore } from '../main/ets/services/SshTerminalTranscriptStore';

export default function sshTerminalTranscriptStoreTest(): void {
  describe('SshTerminalTranscriptStore', (): void => {
    it('should_keep_transcripts_isolated_by_host', 0, (): void => {
      const store: SshTerminalTranscriptStore = new SshTerminalTranscriptStore();
      store.append('host-a', 'A');
      store.append('host-b', 'B');

      expect(store.snapshot('host-a')).assertEqual('A');
      expect(store.snapshot('host-b')).assertEqual('B');
    });

    it('should_clear_one_host_without_affecting_another', 0, (): void => {
      const store: SshTerminalTranscriptStore = new SshTerminalTranscriptStore();
      store.append('host-a', 'A');
      store.append('host-b', 'B');
      store.clear('host-a');

      expect(store.snapshot('host-a')).assertEqual('');
      expect(store.snapshot('host-b')).assertEqual('B');
    });

    it('should_bound_each_host_by_actual_utf8_bytes', 0, (): void => {
      const store: SshTerminalTranscriptStore = new SshTerminalTranscriptStore(6);
      store.append('host-a', '密码');
      expect(store.byteLength('host-a')).assertEqual(6);
      expect(store.snapshot('host-a')).assertEqual('密码');

      store.append('host-a', 'a');
      expect(store.byteLength('host-a')).assertEqual(1);
      expect(store.snapshot('host-a')).assertEqual('a');
    });

    it('should_keep_a_bounded_suffix_without_splitting_surrogate_pairs', 0, (): void => {
      const store: SshTerminalTranscriptStore = new SshTerminalTranscriptStore(7);
      store.append('host-a', '前🙂后');

      expect(store.byteLength('host-a')).assertEqual(7);
      expect(store.snapshot('host-a')).assertEqual('🙂后');
    });
  });
}
