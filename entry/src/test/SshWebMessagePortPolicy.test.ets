import { describe, it, expect } from '@ohos/hypium';
import {
  acceptSshWebMessage,
  acknowledgeSshWebMessage,
  createSshWebMessageState,
  decodeSshWebMessage,
  dequeueSshWebMessage,
  encodeSshWebMessage,
  enqueueSshWebMessage,
  SSH_WEB_MESSAGE_MAX_FRAME_BYTES,
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
        sequence: 9, ackSequence: 3, payload: 'safe output · 终端🛰️'
      };
      const decoded = decodeSshWebMessage(encodeSshWebMessage(envelope));
      expect(decoded === null).assertFalse();
      expect((decoded as SshWebMessageEnvelopeV1).payload).assertEqual('safe output · 终端🛰️');
      expect(decodeSshWebMessage('{"version":1,"kind":"secret","sessionKey":"x","generation":1,"sequence":1,"ackSequence":0,"payload":"x"}') === null).assertTrue();
    });

    it('should_reject_coerced_fields_and_ack_future_sequences', 0, (): void => {
      expect(decodeSshWebMessage('{"version":"1","kind":"output","sessionKey":"host:session","generation":4,"sequence":1,"ackSequence":0,"payload":"x"}') === null).assertTrue();
      expect(decodeSshWebMessage('{"version":1,"kind":"output","sessionKey":"host:session","generation":4,"sequence":1,"ackSequence":0,"payload":7}') === null).assertTrue();
      expect(decodeSshWebMessage('{"version":1,"kind":"output","sessionKey":"host:session","generation":"4","sequence":1,"ackSequence":0,"payload":"x"}') === null).assertTrue();

      const state = readyState();
      const futureAck = acceptSshWebMessage(state, {
        version: 1, kind: 'ack', sessionKey: 'host:session', generation: 4,
        sequence: 2, ackSequence: 99, payload: ''
      });
      expect(futureAck.accepted).assertFalse();
      expect(futureAck.code).assertEqual('invalid_message');
      expect(futureAck.state.lastReceivedSequence).assertEqual(1);
    });

    it('should_reject_fractional_and_forward_gap_counters', 0, (): void => {
      expect(decodeSshWebMessage('{"version":1,"kind":"output","sessionKey":"host:session","generation":4,"sequence":1.5,"ackSequence":0,"payload":"x"}') === null).assertTrue();
      expect(decodeSshWebMessage('{"version":1,"kind":"output","sessionKey":"host:session","generation":4,"sequence":2,"ackSequence":0.5,"payload":"x"}') === null).assertTrue();
      expect(decodeSshWebMessage('{"version":1,"kind":"output","sessionKey":"host:session","generation":4.5,"sequence":2,"ackSequence":0,"payload":"x"}') === null).assertTrue();
      const fractionalIdentity = startSshWebMessageHandshake(
        createSshWebMessageState('host:session', 4.5));
      expect(fractionalIdentity.accepted).assertFalse();
      expect(fractionalIdentity.code).assertEqual('invalid_identity');

      const gap = acceptSshWebMessage(readyState(), {
        version: 1, kind: 'input', sessionKey: 'host:session', generation: 4,
        sequence: 3, ackSequence: 1, payload: 'late-after-gap'
      });
      expect(gap.accepted).assertFalse();
      expect(gap.code).assertEqual('out_of_order_sequence');
      expect(gap.state.lastReceivedSequence).assertEqual(1);
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
      expect((next.envelope as SshWebMessageEnvelopeV1).sequence).assertEqual(2);
      state = next.state;
      expect(state.inFlight.length).assertEqual(1);
      state = acknowledgeSshWebMessage(state, 2);
      expect(state.queue.length).assertEqual(1);
      const output = dequeueSshWebMessage(state);
      expect(output.envelope === null).assertFalse();
      expect((output.envelope as SshWebMessageEnvelopeV1).kind).assertEqual('output');
      expect((output.envelope as SshWebMessageEnvelopeV1).sequence).assertEqual(3);
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

    it('should_count_utf8_bytes_when_bounding_burst_queue', 0, (): void => {
      let state = readyState();
      const unicodeChunk: string = '🙂'.repeat(16384);
      expect(unicodeChunk.length).assertEqual(32768);
      for (let index: number = 0; index < 16; index++) {
        const queued = enqueueSshWebMessage(state, 'output', unicodeChunk);
        expect(queued.accepted).assertTrue();
        state = queued.state;
      }
      const overflow = enqueueSshWebMessage(state, 'output', unicodeChunk);
      expect(overflow.accepted).assertFalse();
      expect(overflow.code).assertEqual('queue_full');
    });

    it('should_reject_single_frame_above_character_limit', 0, (): void => {
      const state = readyState();
      const oversized = enqueueSshWebMessage(state, 'output', 'x'.repeat(65537));
      expect(oversized.accepted).assertFalse();
      expect(oversized.code).assertEqual('frame_too_large');
    });

    it('should_reject_single_frame_above_utf8_byte_limit', 0, (): void => {
      const state = readyState();
      const exact: string = '🙂'.repeat(SSH_WEB_MESSAGE_MAX_FRAME_BYTES / 4);
      expect(exact.length < 65536).assertTrue();
      expect(enqueueSshWebMessage(state, 'output', exact).accepted).assertTrue();

      const oversized: string = exact + '🙂';
      expect(oversized.length < 65536).assertTrue();
      const queued = enqueueSshWebMessage(state, 'output', oversized);
      expect(queued.accepted).assertFalse();
      expect(queued.code).assertEqual('frame_too_large');
      expect(decodeSshWebMessage(JSON.stringify({
        version: 1, kind: 'input', sessionKey: 'host:session', generation: 4,
        sequence: 2, ackSequence: 1, payload: oversized
      })) === null).assertTrue();
      const received = acceptSshWebMessage(state, {
        version: 1, kind: 'input', sessionKey: 'host:session', generation: 4,
        sequence: 2, ackSequence: 1, payload: oversized
      });
      expect(received.accepted).assertFalse();
      expect(received.code).assertEqual('frame_too_large');
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
