import { describe, it, expect } from '@ohos/hypium';
import { XtermOutputBuffer } from '../main/ets/components/SshXtermSurface';

export default function xtermOutputBufferTest(): void {
  describe('XtermOutputBuffer', (): void => {
    it('wakes_live_consumers_without_observed_payload_state', 0, (): void => {
      const buffer: XtermOutputBuffer = new XtermOutputBuffer();
      let firstNotifications: number = 0;
      let secondNotifications: number = 0;
      const unsubscribeFirst: () => void = buffer.subscribe((): void => {
        firstNotifications++;
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
  });
}
