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
  });
}
