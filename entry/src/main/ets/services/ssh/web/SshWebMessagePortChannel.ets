import {
  acceptSshWebMessage,
  createSshWebMessageState,
  decodeSshWebMessage,
  dequeueSshWebMessage,
  encodeSshWebMessage,
  enqueueSshWebMessage,
  markSshWebMessageClosed,
  startSshWebMessageHandshake,
  SSH_WEB_MESSAGE_MAX_IN_FLIGHT,
  SshWebMessageDequeueResultV1,
  SshWebMessageEnvelopeV1,
  SshWebMessageKind,
  SshWebMessageStateV1
} from './SshWebMessagePortPolicy';

/** Structural port contract; ArkWeb WebMessagePort satisfies this interface. */
export interface SshWebMessagePortLike {
  postMessageEvent(message: string | ArrayBuffer): void;
  onMessageEvent(callback: (message: string | ArrayBuffer) => void): void;
  close(): void;
}

export interface SshWebMessagePortChannelCallbacks {
  onReady: () => void;
  onEnvelope: (envelope: SshWebMessageEnvelopeV1) => void;
  onError: (code: string) => void;
}

export class SshWebMessagePortChannel {
  private port: SshWebMessagePortLike | null = null;
  /** Monotonic bind fence; stale WebView callbacks become no-ops. */
  private attachmentToken: number = 0;
  private state: SshWebMessageStateV1 = createSshWebMessageState('', 0);
  private callbacks: SshWebMessagePortChannelCallbacks = {
    onReady: (): void => {},
    onEnvelope: (_envelope: SshWebMessageEnvelopeV1): void => {},
    onError: (_code: string): void => {}
  };

  attach(port: SshWebMessagePortLike, sessionKey: string, generation: number,
    callbacks?: SshWebMessagePortChannelCallbacks): boolean {
    this.detach();
    const attachmentToken: number = this.attachmentToken;
    this.callbacks = callbacks ?? this.callbacks;
    this.state = createSshWebMessageState(sessionKey, generation);
    const handshake = startSshWebMessageHandshake(this.state);
    if (!handshake.accepted || handshake.envelope === null) {
      this.callbacks.onError(handshake.code);
      this.state = markSshWebMessageClosed(this.state);
      return false;
    }
    this.state = handshake.state;
    this.port = port;
    try {
      this.port.onMessageEvent((message: string | ArrayBuffer): void => {
        this.receive(message, port, attachmentToken);
      });
      const first: SshWebMessageDequeueResultV1 = dequeueSshWebMessage(this.state);
      this.state = first.state;
      if (first.envelope === null) {
        this.callbacks.onError('port_attach_failed');
        this.detach();
        return false;
      }
      this.postEnvelope(first.envelope);
      return true;
    } catch (_err) {
      this.callbacks.onError('port_attach_failed');
      this.detach();
      return false;
    }
  }

  detach(): void {
    this.attachmentToken++;
    const existing: SshWebMessagePortLike | null = this.port;
    this.port = null;
    this.state = markSshWebMessageClosed(this.state);
    if (existing !== null) {
      try { existing.close(); } catch (_err) {}
    }
  }

  isReady(): boolean {
    return this.port !== null && this.state.phase === 'ready';
  }

  snapshot(): SshWebMessageStateV1 {
    return this.state;
  }

  send(kind: SshWebMessageKind, payload: string): boolean {
    if (this.port === null) {
      this.callbacks.onError('closed');
      return false;
    }
    const queued = enqueueSshWebMessage(this.state, kind, payload);
    this.state = queued.state;
    if (!queued.accepted || queued.envelope === null) {
      this.callbacks.onError(queued.code);
      return false;
    }
    this.pump();
    return true;
  }

  private postEnvelope(envelope: SshWebMessageEnvelopeV1): void {
    if (this.port === null) { return; }
    this.port.postMessageEvent(encodeSshWebMessage(envelope));
  }

  private pump(): void {
    if (this.port === null) { return; }
    while (this.state.inFlight.length < SSH_WEB_MESSAGE_MAX_IN_FLIGHT) {
      const next = dequeueSshWebMessage(this.state);
      this.state = next.state;
      if (next.envelope === null) { break; }
      try {
        this.postEnvelope(next.envelope);
      } catch (_err) {
        this.callbacks.onError('port_post_failed');
        this.detach();
        return;
      }
    }
  }

  private receive(message: string | ArrayBuffer, expectedPort: SshWebMessagePortLike,
    expectedToken: number): void {
    // A WebView may deliver a queued callback after close(), or after a new
    // page has installed a replacement port.  Do not surface that callback to
    // the new owner and do not let a same-identity stale frame pass policy.
    if (this.port !== expectedPort || this.attachmentToken !== expectedToken) {
      return;
    }
    if (typeof message !== 'string') {
      this.callbacks.onError('unsupported_message');
      return;
    }
    const envelope: SshWebMessageEnvelopeV1 | null = decodeSshWebMessage(message);
    if (envelope === null) {
      this.callbacks.onError('invalid_message');
      return;
    }
    const received = acceptSshWebMessage(this.state, envelope);
    this.state = received.state;
    if (!received.accepted || received.envelope === null) {
      this.callbacks.onError(received.code);
      return;
    }
    if (envelope.kind === 'hello_ack') {
      this.callbacks.onReady();
      this.send('ready', '');
    } else if (envelope.kind === 'close') {
      this.detach();
      return;
    } else {
      // ACK envelopes carry the application-level batch identity in their
      // payload. They still need to reach the owner after the policy has
      // applied the transport ackSequence, otherwise a native output pump
      // cannot release its xterm frame fence.
      this.callbacks.onEnvelope(envelope);
      if (envelope.kind !== 'ack') {
        this.send('ack', '');
      }
    }
    this.pump();
  }
}
