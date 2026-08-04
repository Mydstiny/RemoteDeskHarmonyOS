import { TerminalInputBuffer } from '../main/ets/components/NativeTerminalRenderer';

export default function terminalInputBufferTest(): void {
  const queue: TerminalInputBuffer = new TerminalInputBuffer();
  const first: ArrayBuffer = new ArrayBuffer(2);
  const second: ArrayBuffer = new ArrayBuffer(3);

  queue.enqueue(first);
  queue.enqueue(new ArrayBuffer(0));
  queue.enqueue(second);
  expect(queue.size()).assertEqual(2);
  expect(queue.byteLength()).assertEqual(5);

  const drained: ArrayBuffer[] = queue.drain();
  expect(drained.length).assertEqual(2);
  expect(drained[0]).assertEqual(first);
  expect(drained[1]).assertEqual(second);
  expect(queue.size()).assertEqual(0);
  expect(queue.byteLength()).assertEqual(0);

  queue.enqueue(first);
  queue.clear();
  expect(queue.size()).assertEqual(0);
  expect(queue.byteLength()).assertEqual(0);
}
