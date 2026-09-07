import { DecoderAttemptEvidence, VideoDiagnosticEvidence, NativeVideoDiagnosticEvidence } from '../types/VideoDiagnosticEvidence';
export { DecoderAttemptEvidence, VideoDiagnosticEvidence, NativeVideoDiagnosticEvidence };

function bounded(value: number | undefined, fallback: number = -1): number {
  return value !== undefined && Number.isSafeInteger(value) ? value : fallback;
}
export function videoDiagnosticEvidence(source: NativeVideoDiagnosticEvidence): VideoDiagnosticEvidence {
  return {
    evidenceVersion: 1,
    queuedCodecPreference: bounded(source.queuedCodecPreference),
    requestedVisualFlipX: bounded(source.requestedVisualFlipX),
    requestedVisualFlipY: bounded(source.requestedVisualFlipY),
    requestedTransformVersion: bounded(source.requestedTransformVersion),
    moonlightNegotiatedCodec: bounded(source.moonlightNegotiatedCodec),
    moonlightNegotiatedBitDepth: bounded(source.moonlightNegotiatedBitDepth),
    moonlightActiveStage: bounded(source.moonlightActiveStage),
    moonlightTerminalCode: bounded(source.moonlightTerminalCode),
    currentCodecPreference: bounded(source.currentCodecPreference),
    connectionCodecPreference: bounded(source.connectionCodecPreference),
    sentCodecPreference: bounded(source.sentCodecPreference),
    wireCodecPreference: bounded(source.wireCodecPreference),
    advertisedDecoderMask: bounded(source.advertisedDecoderMask),
    peerEncoderMask: bounded(source.peerEncoderMask),
    codecOptionStage: bounded(source.codecOptionStage),
    loginOptionSends: bounded(source.loginOptionSends),
    runtimeOptionSubmissions: bounded(source.runtimeOptionSubmissions),
    codecOptionSendFailures: bounded(source.codecOptionSendFailures),
    firstFrameCodec: bounded(source.firstFrameCodec),
    codecChanges: bounded(source.codecChanges),
    lastDecodeResult: bounded(source.lastDecodeResult),
    decodeRetNotReady: bounded(source.decodeRetNotReady),
    decodeRetBadCodec: bounded(source.decodeRetBadCodec),
    decodeRetMismatch: bounded(source.decodeRetMismatch),
    decodeRetOther: bounded(source.decodeRetOther),
    decodedFrames: bounded(source.decodeOk),
    presentedFrames: bounded(source.presentedFrames),
    controlFlipX: -1,
    controlFlipY: -1,
    flipSource: 0,
    observedOrientation: 0,
    finalSamplingCorners: [],
    decoderAttempts: (source.decoderAttempts ?? []).slice(-4).map(copyDecoderAttempt)
  };
}

function copyDecoderAttempt(source: DecoderAttemptEvidence): DecoderAttemptEvidence {
  return {
    serial: bounded(source.serial),
    decoderGeneration: bounded(source.decoderGeneration),
    codec: bounded(source.codec),
    width: bounded(source.width),
    height: bounded(source.height),
    stage: bounded(source.stage),
    result: bounded(source.result),
    platformCode: bounded(source.platformCode),
    capabilityHardware: bounded(source.capabilityHardware),
    capabilitySizeSupported: bounded(source.capabilitySizeSupported),
    outputWidth: bounded(source.outputWidth),
    outputHeight: bounded(source.outputHeight),
    outputPixelFormat: bounded(source.outputPixelFormat),
    asyncErrors: bounded(source.asyncErrors),
    lastAsyncError: bounded(source.lastAsyncError)
  };
}

export function copyVideoDiagnosticEvidence(source: VideoDiagnosticEvidence): VideoDiagnosticEvidence {
  return {
    evidenceVersion: source.evidenceVersion,
    queuedCodecPreference: source.queuedCodecPreference,
    requestedVisualFlipX: source.requestedVisualFlipX,
    requestedVisualFlipY: source.requestedVisualFlipY,
    requestedTransformVersion: source.requestedTransformVersion,
    moonlightNegotiatedCodec: source.moonlightNegotiatedCodec,
    moonlightNegotiatedBitDepth: source.moonlightNegotiatedBitDepth,
    moonlightActiveStage: source.moonlightActiveStage,
    moonlightTerminalCode: source.moonlightTerminalCode,
    currentCodecPreference: source.currentCodecPreference,
    connectionCodecPreference: source.connectionCodecPreference,
    sentCodecPreference: source.sentCodecPreference,
    wireCodecPreference: source.wireCodecPreference,
    advertisedDecoderMask: source.advertisedDecoderMask,
    peerEncoderMask: source.peerEncoderMask,
    codecOptionStage: source.codecOptionStage,
    loginOptionSends: source.loginOptionSends,
    runtimeOptionSubmissions: source.runtimeOptionSubmissions,
    codecOptionSendFailures: source.codecOptionSendFailures,
    firstFrameCodec: source.firstFrameCodec,
    codecChanges: source.codecChanges,
    lastDecodeResult: source.lastDecodeResult,
    decodeRetNotReady: source.decodeRetNotReady,
    decodeRetBadCodec: source.decodeRetBadCodec,
    decodeRetMismatch: source.decodeRetMismatch,
    decodeRetOther: source.decodeRetOther,
    decodedFrames: source.decodedFrames,
    presentedFrames: source.presentedFrames,
    controlFlipX: source.controlFlipX,
    controlFlipY: source.controlFlipY,
    flipSource: source.flipSource,
    observedOrientation: source.observedOrientation,
    finalSamplingCorners: source.finalSamplingCorners.slice(),
    decoderAttempts: source.decoderAttempts.map(copyDecoderAttempt)
  };
}

function exactKeys(source: Record<string, Object>, expected: string[]): boolean {
  const keys: string[] = Object.keys(source);
  return keys.length === expected.length && keys.every((key: string): boolean => expected.indexOf(key) >= 0);
}
export function parseVideoDiagnosticEvidence(value: Object): VideoDiagnosticEvidence | null {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) { return null; }
  const source: Record<string, Object> = value as Record<string, Object>;
  const fields: string[] = ['queuedCodecPreference', 'requestedVisualFlipX', 'requestedVisualFlipY', 'requestedTransformVersion', 'moonlightNegotiatedCodec', 'moonlightNegotiatedBitDepth', 'moonlightActiveStage', 'moonlightTerminalCode', 'evidenceVersion', 'currentCodecPreference', 'connectionCodecPreference', 'sentCodecPreference', 'wireCodecPreference', 'advertisedDecoderMask', 'peerEncoderMask', 'codecOptionStage', 'loginOptionSends', 'runtimeOptionSubmissions', 'codecOptionSendFailures', 'firstFrameCodec', 'codecChanges', 'lastDecodeResult', 'decodeRetNotReady', 'decodeRetBadCodec', 'decodeRetMismatch', 'decodeRetOther', 'decodedFrames', 'presentedFrames', 'controlFlipX', 'controlFlipY', 'flipSource', 'observedOrientation'];
  if (!exactKeys(source, fields.concat(['finalSamplingCorners', 'decoderAttempts']))) { return null; }
  for (let index: number = 0; index < fields.length; index++) {
    const n: Object = source[fields[index]];
    if (typeof n !== 'number' || !Number.isSafeInteger(n as number)) { return null; }
  }
  if (source['evidenceVersion'] !== 1) { return null; }
  const corners: Object = source['finalSamplingCorners'];
  if (!Array.isArray(corners)) { return null; }
  const numbers: Object[] = corners as Object[];
  if (numbers.length !== 0 && numbers.length !== 8) { return null; }
  for (let index: number = 0; index < numbers.length; index++) {
    if (typeof numbers[index] !== 'number' || !Number.isFinite(numbers[index] as number) ||
      Math.abs(numbers[index] as number) > 64) { return null; }
  }
  if (!Array.isArray(source['decoderAttempts'])) { return null; }
  const attempts: Object[] = source['decoderAttempts'] as Object[];
  if (attempts.length > 4) { return null; }
  const attemptFields: string[] = ['serial', 'decoderGeneration', 'codec', 'width', 'height', 'stage', 'result', 'platformCode', 'capabilityHardware', 'capabilitySizeSupported', 'outputWidth', 'outputHeight', 'outputPixelFormat', 'asyncErrors', 'lastAsyncError'];
  for (let index: number = 0; index < attempts.length; index++) {
    if (attempts[index] === null || typeof attempts[index] !== 'object') { return null; }
    const attempt: Record<string, Object> = attempts[index] as Record<string, Object>;
    if (!exactKeys(attempt, attemptFields)) { return null; }
    for (let field: number = 0; field < attemptFields.length; field++) {
      const n: Object = attempt[attemptFields[field]];
      if (typeof n !== 'number' || !Number.isSafeInteger(n as number)) { return null; }
    }
  }
  return copyVideoDiagnosticEvidence(value as VideoDiagnosticEvidence);
}

/** Mirror the OES shader's rotation, manual flips, then producer sampling. */
export function finalVideoSamplingCorners(matrix: number[], rotation: number,
  flipX: boolean, flipY: boolean): number[] {
  if (matrix.length !== 16) { return []; }
  const result: number[] = [];
  const input: number[] = [0, 0, 1, 0, 0, 1, 1, 1];
  for (let index: number = 0; index < 8; index += 2) {
    const x: number = input[index];
    const y: number = input[index + 1];
    let u: number = rotation === 1 ? y : (rotation === 2 ? 1 - x : (rotation === 3 ? 1 - y : x));
    let v: number = rotation === 1 ? 1 - x : (rotation === 2 ? 1 - y : (rotation === 3 ? x : y));
    if (flipX) { u = 1 - u; }
    if (flipY) { v = 1 - v; }
    result.push(Math.round((matrix[0] * u + matrix[4] * v + matrix[12]) * 1000000) / 1000000);
    result.push(Math.round((matrix[1] * u + matrix[5] * v + matrix[13]) * 1000000) / 1000000);
  }
  return result;
}
