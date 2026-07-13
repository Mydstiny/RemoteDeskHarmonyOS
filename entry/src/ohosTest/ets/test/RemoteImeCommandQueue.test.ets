/**
 * RemoteImeCommandQueue.test.ets - remote IME command ordering.
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  RemoteImeCommandKind,
  RemoteImeCommandQueue
} from '../../../main/ets/services/RemoteImeCommandQueue';

export default function remoteImeCommandQueueTest(): void {
  describe('RemoteImeCommandQueue', (): void => {
    it('keeps_text_cursor_text_order', 0, (): void => {
      const queue = new RemoteImeCommandQueue();
      queue.enqueueText('alpha', 4, 'didInsert');
      queue.enqueueKeyTaps(2014, 300, 4, 'selection');
      queue.enqueueText('omega', 4, 'didInsert');

      expect(queue.shift()!.kind).assertEqual(RemoteImeCommandKind.TEXT);
      const movement = queue.shift()!;
      expect(movement.tapCount).assertEqual(300);
      movement.tapCount = 268;
      queue.pushFront(movement);
      expect(queue.shift()!.tapCount).assertEqual(268);
      expect(queue.shift()!.text).assertEqual('omega');
    });

    it('clear_discards_old_generation_commands', 0, (): void => {
      const queue = new RemoteImeCommandQueue();
      queue.enqueueKeyTaps(2015, 10, 2, 'selection');
      queue.clear();
      expect(queue.size()).assertEqual(0);
    });
  });
}
