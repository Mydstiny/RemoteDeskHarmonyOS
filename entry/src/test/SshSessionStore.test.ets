import { describe, expect, it } from '@ohos/hypium';
import {
  SshSessionHandle,
  SshSessionStore
} from '../main/ets/services/SshSessionStore';
import {
  DiagnosticCaptureEvent,
  DiagnosticCaptureRuntime,
  FrozenDiagnosticCapture
} from '../main/ets/services/DiagnosticCaptureRuntime';

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

    it('records_the_target_state_for_an_adopted_ready_session', 0, (): void => {
      const runtime: DiagnosticCaptureRuntime = DiagnosticCaptureRuntime.getInstance();
      if (runtime.status().phase === 'saving') { runtime.finishSaving(false); }
      if (runtime.status().phase !== 'idle') { runtime.discard(); }
      try {
        expect(runtime.start(1, ['connection.ssh_sftp'])).assertEqual('ok');
        const store: SshSessionStore = new SshSessionStore();
        expect(store.registerExisting('host-d', 'Host D', 'user@host-d',
          handle(44), 'Ready')).assertTrue();
        expect(runtime.stop()).assertEqual('ok');
        const frozen: FrozenDiagnosticCapture =
          runtime.frozenCapture() as FrozenDiagnosticCapture;
        const sshEvents: DiagnosticCaptureEvent[] = frozen.events.filter(
          (event: DiagnosticCaptureEvent): boolean =>
            event.moduleId === 'connection.ssh_sftp');
        expect(sshEvents.length).assertEqual(2);
        expect(sshEvents[sshEvents.length - 1].code).assertEqual(4);
        expect(sshEvents[sshEvents.length - 1].outcome).assertEqual('state');
      } finally {
        if (runtime.status().phase === 'saving') { runtime.finishSaving(false); }
        if (runtime.status().phase !== 'idle') { runtime.discard(); }
      }
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

    it('reclaims a terminal owner before enforcing capacity', 0, (): void => {
      const store: SshSessionStore = new SshSessionStore(1);
      const first: SshSessionHandle = handle(45);
      expect(store.registerExisting('host-capacity', 'Host capacity', 'user@host-capacity',
        first, 'Ready')).assertTrue();
      expect(store.transition(first, 'Failed', 'connect.failed')).assertTrue();

      const replacement: SshSessionHandle = handle(46);
      expect(store.registerExisting('host-capacity', 'Host capacity', 'user@host-capacity',
        replacement, 'Ready')).assertTrue();
      expect(store.handleForHost('host-capacity')?.sessionId).assertEqual(46);
      expect(store.context(first) === null).assertTrue();
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
