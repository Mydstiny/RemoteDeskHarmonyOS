import {
  sshTerminalInputBufferStateCountForTest,
  TerminalInputBuffer
} from '../main/ets/components/SshTerminalSurface';

export default function terminalInputBufferTest(): void {
  const baselineStates: number = sshTerminalInputBufferStateCountForTest();
  const queue: TerminalInputBuffer = new TerminalInputBuffer();
  expect(sshTerminalInputBufferStateCountForTest()).assertEqual(baselineStates);
  const first: ArrayBuffer = new ArrayBuffer(2);
  const second: ArrayBuffer = new ArrayBuffer(3);

  queue.enqueue(first);
  queue.enqueue(new ArrayBuffer(0));
  queue.enqueue(second);
  const otherQueue: TerminalInputBuffer = new TerminalInputBuffer();
  const other: ArrayBuffer = new ArrayBuffer(4);
  otherQueue.enqueue(other);
  expect(sshTerminalInputBufferStateCountForTest()).assertEqual(baselineStates + 2);
  expect(queue.size()).assertEqual(2);
  expect(queue.byteLength()).assertEqual(5);
  expect(otherQueue.size()).assertEqual(1);
  expect(otherQueue.byteLength()).assertEqual(4);

  const drained: ArrayBuffer[] = queue.drain();
  expect(drained.length).assertEqual(2);
  expect(drained[0]).assertEqual(first);
  expect(drained[1]).assertEqual(second);
  expect(queue.size()).assertEqual(0);
  expect(queue.byteLength()).assertEqual(0);
  expect(otherQueue.drain()[0]).assertEqual(other);
  expect(otherQueue.byteLength()).assertEqual(0);

  queue.enqueue(first);
  queue.clear();
  expect(sshTerminalInputBufferStateCountForTest()).assertEqual(baselineStates + 1);
  expect(queue.size()).assertEqual(0);
  expect(queue.byteLength()).assertEqual(0);
  expect(sshTerminalInputBufferStateCountForTest()).assertEqual(baselineStates + 2);

  queue.enqueue(first);
  queue.enqueue(second);
  const firstBatch: ArrayBuffer[] = queue.drain(3);
  expect(firstBatch.length).assertEqual(1);
  expect(firstBatch[0]).assertEqual(first);
  expect(queue.size()).assertEqual(1);
  expect(queue.byteLength()).assertEqual(3);
  const secondBatch: ArrayBuffer[] = queue.drain(3);
  expect(secondBatch.length).assertEqual(1);
  expect(secondBatch[0]).assertEqual(second);
  expect(queue.size()).assertEqual(0);
  expect(queue.byteLength()).assertEqual(0);

  const oversized: ArrayBuffer = new ArrayBuffer(5);
  const oversizedView: Uint8Array = new Uint8Array(oversized);
  oversizedView[0] = 11;
  oversizedView[1] = 22;
  oversizedView[2] = 33;
  oversizedView[3] = 44;
  oversizedView[4] = 55;
  queue.enqueue(oversized);
  const prefix: ArrayBuffer[] = queue.drain(3);
  expect(prefix.length).assertEqual(1);
  expect(prefix[0].byteLength).assertEqual(3);
  const prefixView: Uint8Array = new Uint8Array(prefix[0]);
  expect(prefixView[0]).assertEqual(11);
  expect(prefixView[1]).assertEqual(22);
  expect(prefixView[2]).assertEqual(33);
  expect(queue.size()).assertEqual(1);
  expect(queue.byteLength()).assertEqual(2);
  const remainder: ArrayBuffer[] = queue.drain(0);
  expect(remainder.length).assertEqual(1);
  expect(remainder[0].byteLength).assertEqual(2);
  const remainderView: Uint8Array = new Uint8Array(remainder[0]);
  expect(remainderView[0]).assertEqual(44);
  expect(remainderView[1]).assertEqual(55);
  expect(queue.size()).assertEqual(0);
  expect(queue.byteLength()).assertEqual(0);

  queue.clear();
  otherQueue.clear();
  expect(sshTerminalInputBufferStateCountForTest()).assertEqual(baselineStates);
}
