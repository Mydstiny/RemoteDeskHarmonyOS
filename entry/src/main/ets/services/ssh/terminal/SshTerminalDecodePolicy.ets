/**
 * Decode-buffer ownership rules for SSH terminal output.
 *
 * UTF-8 remainders may span native callback chunks, but they must never span
 * a session identity boundary. A reconnect can reuse the host id while
 * changing the native session id or generation, so the page must drop the
 * old suffix before decoding output from the new owner.
 */

export function sshTerminalDecodeStateNeedsReset(
  previousSessionId: number, previousGeneration: number,
  nextSessionId: number, nextGeneration: number): boolean {
  const previousKnown: boolean = Number.isFinite(previousSessionId) &&
    Number.isInteger(previousSessionId) && previousSessionId > 0 &&
    Number.isFinite(previousGeneration) && Number.isInteger(previousGeneration) &&
    previousGeneration > 0;
  if (!previousKnown) { return false; }
  const nextKnown: boolean = Number.isFinite(nextSessionId) &&
    Number.isInteger(nextSessionId) && nextSessionId > 0 &&
    Number.isFinite(nextGeneration) && Number.isInteger(nextGeneration) &&
    nextGeneration > 0;
  // Clearing before a new identity is published is the reconnect/close path.
  if (!nextKnown) { return true; }
  return previousSessionId !== nextSessionId || previousGeneration !== nextGeneration;
}
