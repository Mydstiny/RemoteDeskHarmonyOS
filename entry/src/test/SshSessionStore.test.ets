import { describe, expect, it } from '@ohos/hypium';
import {
  SshSessionHandle,
  SshSessionStore
} from '../main/ets/services/SshSessionStore';

function handle(sessionId: number, generation: number = 1): SshSessionHandle {
  return { sessionId, channelId: 'shell', generation };
}

export default function sshSessionStoreTest(): void {
  describe('SshSessionStore', (): void => {
    it('adopts an already ready native session', 0, (): void => {
      const store: SshSessionStore = new SshSessionStore();
      const adopted: SshSessionHandle = handle(41);
      expect(store.registerExisting('host-a', 'Host A', 'user@host-a', adopted, 'Ready'))
        .assertTrue();
      expect(store.accepts(adopted)).assertTrue();
      expect(store.context(adopted)?.state).assertEqual('Ready');
    });

    it('rejects old generation callbacks after rebind', 0, (): void => {
      const store: SshSessionStore = new SshSessionStore();
      const first: SshSessionHandle = handle(42, 1);
      expect(store.registerExisting('host-b', 'Host B', 'user@host-b', first, 'Ready'))
        .assertTrue();
      const next: SshSessionHandle | null = store.rebindGeneration(42, 'shell', 1, 2);
      expect(next !== null).assertTrue();
      expect(store.accepts(first)).assertFalse();
      expect(store.accepts(handle(42, 2))).assertTrue();
    });

    it('rolls back an invalid adopted transition', 0, (): void => {
      const store: SshSessionStore = new SshSessionStore();
      const invalid: SshSessionHandle = handle(43);
      expect(store.registerExisting('host-c', 'Host C', 'user@host-c', invalid,
        'ReconnectScheduled')).assertFalse();
      expect(store.handleForHost('host-c') === null).assertTrue();
    });
  });
}
