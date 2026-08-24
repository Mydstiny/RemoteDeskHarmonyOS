import { describe, it, expect } from '@ohos/hypium';
import {
  SSH_XTERM_RETRY_MAX_ATTEMPTS,
  sshXtermOutputBatchFitsByteBudget,
  sshXtermRetryAllowed,
  XtermOutputBuffer
} from '../main/ets/components/SshXtermSurface';

export default function xtermOutputBufferTest(): void {
  describe('XtermOutputBuffer', (): void => {
    it('wakes_live_consumers_without_observed_payload_state', 0, (): void => {
      const buffer: XtermOutputBuffer = new XtermOutputBuffer();
      let firstNotifications: number = 0;
      let secondNotifications: number = 0;
      let lifecycleToken: number = 1;
      let observedLifecycleToken: number = 0;
      const unsubscribeFirst: () => void = buffer.subscribe((): void => {
        firstNotifications++;
        // The long-lived renderer subscription must resolve the current
        // document lifecycle when output becomes readable. Capturing the
        // initial token here would silence all echo after a WebView reload.
        observedLifecycleToken = lifecycleToken;
      });
      const unsubscribeFaulty: () => void = buffer.subscribe((): void => {
        throw new Error('stale renderer');
      });
      const unsubscribeSecond: () => void = buffer.subscribe((): void => {
        secondNotifications++;
      });

      buffer.enqueue('one');
      buffer.enqueue('');
      expect(firstNotifications).assertEqual(1);
      expect(secondNotifications).assertEqual(1);
      expect(observedLifecycleToken).assertEqual(1);
      expect(buffer.size()).assertEqual(1);

      // Internal retry restoration must retain FIFO order without recursively
      // waking the same output pump.
      buffer.prepend(['zero']);
      expect(firstNotifications).assertEqual(1);
      const values: Array<string> = buffer.drain();
      expect(values.length).assertEqual(2);
      expect(values[0]).assertEqual('zero');
      expect(values[1]).assertEqual('one');

      unsubscribeFirst();
      unsubscribeFaulty();
      unsubscribeSecond();
      buffer.enqueue('two');
      expect(firstNotifications).assertEqual(1);
      expect(secondNotifications).assertEqual(1);
      expect(buffer.drain()[0]).assertEqual('two');

      const unsubscribeLifecycle: () => void = buffer.subscribe((): void => {
        observedLifecycleToken = lifecycleToken;
      });
      lifecycleToken = 2;
      buffer.enqueue('after-reload');
      expect(observedLifecycleToken).assertEqual(2);
      unsubscribeLifecycle();
      expect(buffer.drain()[0]).assertEqual('after-reload');
    });

    it('bounds_backlog_by_utf8_bytes_and_notifies_overflow_once', 0, (): void => {
      let overflows: number = 0;
      const buffer: XtermOutputBuffer = new XtermOutputBuffer((): void => {
        overflows++;
      }, 6, 4, 4);

      expect(buffer.enqueue('密码')).assertTrue();
      expect(buffer.byteLength()).assertEqual(6);
      expect(buffer.size()).assertEqual(2);
      expect(buffer.enqueue('a')).assertFalse();
      expect(buffer.enqueue('b')).assertFalse();
      expect(overflows).assertEqual(1);
      const first: Array<string> = buffer.drain(1, 4);
      expect(first.length).assertEqual(1);
      expect(first[0]).assertEqual('密');
      expect(buffer.byteLength()).assertEqual(3);

      buffer.clear();
      expect(buffer.byteLength()).assertEqual(0);
      expect(buffer.enqueue('🙂a')).assertTrue();
      expect(buffer.size()).assertEqual(2);
      const scalar: Array<string> = buffer.drain(1, 4);
      expect(scalar[0]).assertEqual('🙂');
      expect(buffer.byteLength()).assertEqual(1);
    });

    it('rechecks_backlog_limits_when_restoring_an_unacked_frame', 0, (): void => {
      let overflows: number = 0;
      const buffer: XtermOutputBuffer = new XtermOutputBuffer((): void => {
        overflows++;
      }, 6, 3, 4);

      expect(buffer.enqueue('abcd')).assertTrue();
      const inFlight: Array<string> = buffer.drain();
      expect(inFlight.length).assertEqual(1);
      // Output received while the first frame is awaiting ACK consumes all
      // capacity that drain() temporarily released.
      expect(buffer.enqueue('密码')).assertTrue();
      expect(buffer.byteLength()).assertEqual(6);
      expect(buffer.size()).assertEqual(2);

      expect(buffer.prepend(inFlight)).assertFalse();
      expect(overflows).assertEqual(1);
      expect(buffer.byteLength()).assertEqual(6);
      expect(buffer.size()).assertEqual(2);
      expect(buffer.drain().join('')).assertEqual('密码');
    });

    it('bounds_proxy_batches_by_utf8_bytes', 0, (): void => {
      const emojiChunk: string = '🙂'.repeat(8192);
      const cjkChunk: string = '中'.repeat(21846);
      expect(sshXtermOutputBatchFitsByteBudget(32768, emojiChunk)).assertTrue();
      expect(sshXtermOutputBatchFitsByteBudget(32768, cjkChunk)).assertFalse();
      expect(sshXtermOutputBatchFitsByteBudget(65536, 'a')).assertFalse();
    });

    it('bounds_webview_retry_loops_per_lifecycle', 0, (): void => {
      expect(SSH_XTERM_RETRY_MAX_ATTEMPTS).assertEqual(240);
      expect(sshXtermRetryAllowed(0)).assertTrue();
      expect(sshXtermRetryAllowed(239)).assertTrue();
      expect(sshXtermRetryAllowed(240)).assertFalse();
      expect(sshXtermRetryAllowed(1.5)).assertFalse();
      expect(sshXtermRetryAllowed(Number.POSITIVE_INFINITY)).assertFalse();
    });
  });
}
