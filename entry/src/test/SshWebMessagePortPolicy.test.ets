import { describe, it, expect } from '@ohos/hypium';
import {
  acceptSshWebMessage,
  acknowledgeSshWebMessage,
  createSshWebMessageState,
  decodeSshWebMessage,
  dequeueSshWebMessage,
  encodeSshWebMessage,
  enqueueSshWebMessage,
  SSH_WEB_MESSAGE_MAX_QUEUE_ITEMS,
  startSshWebMessageHandshake,
  SshWebMessageEnvelopeV1,
  SshWebMessageStateV1
} from '../main/ets/services/ssh/web/SshWebMessagePortPolicy';

function readyState(): SshWebMessageStateV1 {
  let state = createSshWebMessageState('host:session', 4);
  const hello = startSshWebMessageHandshake(state);
  state = hello.state;
  const accepted = acceptSshWebMessage(state, {
    version: 1, kind: 'hello_ack', sessionKey: 'host:session', generation: 4,
    sequence: 1, ackSequence: 1, payload: ''
  });
  return accepted.state;
}

export default function sshWebMessagePortPolicyTest(): void {
  describe('SshWebMessagePortPolicy', (): void => {
    it('should_require_handshake_and_exact_generation', 0, (): void => {
      const initial = createSshWebMessageState('host:session', 4);
      const blocked = enqueueSshWebMessage(initial, 'input', 'ls');
      expect(blocked.accepted).assertFalse();
      expect(blocked.code).assertEqual('not_ready');
      const hello = startSshWebMessageHandshake(initial);
      expect(hello.accepted).assertTrue();
      const stale = acceptSshWebMessage(hello.state, {
        version: 1, kind: 'hello_ack', sessionKey: 'host:session', generation: 3,
        sequence: 1, ackSequence: 1, payload: ''
      });
      expect(stale.accepted).assertFalse();
      expect(stale.code).assertEqual('stale_generation');
    });

    it('should_round_trip_whitelisted_envelope_only', 0, (): void => {
      const envelope: SshWebMessageEnvelopeV1 = {
        version: 1, kind: 'output', sessionKey: 'host:session', generation: 4,
        sequence: 9, ackSequence: 3, payload: 'safe output'
      };
      const decoded = decodeSshWebMessage(encodeSshWebMessage(envelope));
      expect(decoded === null).assertFalse();
      expect((decoded as SshWebMessageEnvelopeV1).payload).assertEqual('safe output');
      expect(decodeSshWebMessage('{"version":1,"kind":"secret","sessionKey":"x","generation":1,"sequence":1,"ackSequence":0,"payload":"x"}') === null).assertTrue();
    });

    it('should_prioritize_control_and_bound_in_flight', 0, (): void => {
      let state = readyState();
      const first = enqueueSshWebMessage(state, 'output', 'out');
      state = first.state;
      const second = enqueueSshWebMessage(state, 'resize', '80x24');
      state = second.state;
      const next = dequeueSshWebMessage(second.state);
      expect(next.envelope === null).assertFalse();
      expect((next.envelope as SshWebMessageEnvelopeV1).kind).assertEqual('resize');
      state = next.state;
      expect(state.inFlight.length).assertEqual(1);
    });

    it('should_ack_bytes_and_reject_duplicate_sequences', 0, (): void => {
      let state = readyState();
      const queued = enqueueSshWebMessage(state, 'input', 'pwd');
      state = queued.state;
      const sent = dequeueSshWebMessage(state);
      state = sent.state;
      state = acknowledgeSshWebMessage(state, 2);
      expect(state.bufferedBytes).assertEqual(0);
      const duplicate = acceptSshWebMessage(state, {
        version: 1, kind: 'ready', sessionKey: 'host:session', generation: 4,
        sequence: 1, ackSequence: 0, payload: ''
      });
      expect(duplicate.accepted).assertFalse();
      expect(duplicate.code).assertEqual('duplicate_sequence');
    });

    it('should_cap_queue_items', 0, (): void => {
      let state = readyState();
      for (let index: number = 0; index < SSH_WEB_MESSAGE_MAX_QUEUE_ITEMS; index++) {
        state = enqueueSshWebMessage(state, 'output', 'x').state;
      }
      const overflow = enqueueSshWebMessage(state, 'output', 'x');
      expect(overflow.accepted).assertFalse();
      expect(overflow.code).assertEqual('queue_full');
    });
  });
}
