import { describe, it, expect } from '@ohos/hypium';
import {
  SshWebMessagePortChannel,
  SshWebMessagePortLike
} from '../main/ets/services/ssh/web/SshWebMessagePortChannel';
import {
  decodeSshWebMessage,
  SshWebMessageEnvelopeV1
} from '../main/ets/services/ssh/web/SshWebMessagePortPolicy';

class MockWebMessagePort implements SshWebMessagePortLike {
  sent: Array<string> = [];
  closed: boolean = false;
  listener: ((message: string | ArrayBuffer) => void) | null = null;

  postMessageEvent(message: string | ArrayBuffer): void {
    if (typeof message === 'string') { this.sent.push(message); }
  }

  onMessageEvent(callback: (message: string | ArrayBuffer) => void): void {
    this.listener = callback;
  }

  close(): void { this.closed = true; }

  deliver(envelope: SshWebMessageEnvelopeV1): void {
    if (this.listener !== null) {
      this.listener(JSON.stringify(envelope));
    }
  }
}

export default function sshWebMessagePortChannelTest(): void {
  describe('SshWebMessagePortChannel', (): void => {
    it('should_handshake_then_send_through_bounded_port', 0, (): void => {
      const port = new MockWebMessagePort();
      const channel = new SshWebMessagePortChannel();
      let ready: boolean = false;
      let envelopes: number = 0;
      expect(channel.attach(port, 'host:session', 2, {
        onReady: (): void => { ready = true; },
        onEnvelope: (_envelope: SshWebMessageEnvelopeV1): void => { envelopes++; },
        onError: (_code: string): void => {}
      })).assertTrue();
      expect(port.sent.length).assertEqual(1);
      const hello: SshWebMessageEnvelopeV1 | null = decodeSshWebMessage(port.sent[0]);
      expect(hello === null).assertFalse();
      port.deliver({
        version: 1, kind: 'hello_ack', sessionKey: 'host:session', generation: 2,
        sequence: 1, ackSequence: 1, payload: ''
      });
      expect(ready).assertTrue();
      expect(channel.isReady()).assertTrue();
      expect(channel.send('output', 'hello')).assertTrue();
      expect(port.sent.length >= 3).assertTrue();
      port.deliver({
        version: 1, kind: 'ack', sessionKey: 'host:session', generation: 2,
        sequence: 2, ackSequence: 3, payload: '{"batchSequence":1}'
      });
      expect(envelopes).assertEqual(1);
    });

    it('should_close_and_fail_closed_on_stale_generation', 0, (): void => {
      const port = new MockWebMessagePort();
      const errors: Array<string> = [];
      const channel = new SshWebMessagePortChannel();
      channel.attach(port, 'host:session', 2, {
        onReady: (): void => {},
        onEnvelope: (_envelope: SshWebMessageEnvelopeV1): void => {},
        onError: (code: string): void => { errors.push(code); }
      });
      port.deliver({
        version: 1, kind: 'hello_ack', sessionKey: 'host:session', generation: 1,
        sequence: 1, ackSequence: 1, payload: ''
      });
      expect(channel.isReady()).assertFalse();
      expect(errors.length).assertEqual(1);
      channel.detach();
      expect(port.closed).assertTrue();
      expect(channel.send('input', 'late')).assertFalse();
    });
  });
}
