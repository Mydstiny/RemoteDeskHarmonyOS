import { recordDiagnosticEvent } from './DiagnosticCaptureRuntime';

export interface VncUpdateFailureFacts {
  reason: number;
  advertised: number;
  processed: number;
  encoding: number;
}

// Parse only the native numeric suffix. Never export the surrounding message,
// endpoint, credentials, pixel data, or server-supplied strings.
export function parseVncUpdateFailure(message: string): VncUpdateFailureFacts | null {
  const match: RegExpExecArray | null =
    /\[VNC-FBU reason=([1-4]) advertised=([0-9]{1,5}) processed=([0-9]{1,4}) encoding=(-?[0-9]{1,10})\]$/.exec(message);
  if (match === null) { return null; }
  const advertised: number = Number(match[2]);
  const processed: number = Number(match[3]);
  const encoding: number = Number(match[4]);
  if (advertised > 65535 || processed > 4096 || processed > advertised ||
    encoding < -2147483648 || encoding > 2147483647) { return null; }
  return { reason: Number(match[1]), advertised, processed, encoding };
}

export function recordVncUpdateFailure(sessionId: number, message: string): void {
  try {
    const facts: VncUpdateFailureFacts | null = parseVncUpdateFailure(message);
    if (facts === null) { return; }
    // Header event: code = failure stage, count = advertised rectangle count.
    // Progress event: code = failing encoding (0 if header incomplete),
    // count = fully processed non-LastRect rectangles. Both share sessionRef.
    recordDiagnosticEvent('connection.vnc', 'vnc_update_rejected', 'failed',
      sessionId, 0, facts.reason, 0, facts.advertised);
    recordDiagnosticEvent('connection.vnc', 'vnc_update_progress', 'failed',
      sessionId, 0, facts.encoding, 0, facts.processed);
  } catch (_err) {
    // Diagnosis must not change connection polling or teardown.
  }
}
