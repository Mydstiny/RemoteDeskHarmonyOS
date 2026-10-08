import {
  DecoderAttemptEvidence,
  NativeOrientationSelfTest,
  NativeVideoDiagnosticEvidence,
  OrientationSelfTestEvidence,
  VideoDiagnosticEvidence
} from '../types/VideoDiagnosticEvidence';
export {
  DecoderAttemptEvidence,
  NativeOrientationSelfTest,
  NativeVideoDiagnosticEvidence,
  OrientationSelfTestEvidence,
  VideoDiagnosticEvidence
};

const VIDEO_EVIDENCE_VERSION: number = 2;
const PLATFORM_TEXT: RegExp = /^[A-Za-z0-9 ._()\/-]{0,64}$/;

function platformText(value: string | undefined): string {
  return typeof value === 'string' && PLATFORM_TEXT.test(value) ? value : '';
}

function bounded(value: number | undefined, fallback: number = -1): number {
  return value !== undefined && Number.isSafeInteger(value) ? value : fallback;
}
export function videoDiagnosticEvidence(source: NativeVideoDiagnosticEvidence): VideoDiagnosticEvidence {
  return {
    evidenceVersion: VIDEO_EVIDENCE_VERSION,
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
    decoderAttempts: (source.decoderAttempts ?? []).slice(-4).map(copyDecoderAttempt),
    orientationSelfTests: (source.orientationSelfTests ?? []).slice(0, 4).map(nativeSelfTest)
  };
}

function nativeSelfTest(source: NativeOrientationSelfTest): OrientationSelfTestEvidence {
  return {
    codec: bounded(source.codec),
    mode: bounded(source.mode),
    stage: bounded(source.stage),
    platformCode: bounded(source.platformCode),
    hardware: bounded(source.hardware),
    outputPixelFormat: bounded(source.outputPixelFormat),
    outputRotation: bounded(source.outputRotation),
    outputTransformType: bounded(source.outputTransformType),
    bufferTransform: bounded(source.bufferTransform),
    v2Class: bounded(source.v2Class),
    v1Class: bounded(source.v1Class),
    identityOrientation: bounded(source.identityOrientation),
    appliedOrientation: bounded(source.appliedOrientation),
    identityCorners: [bounded(source.identityCorners0, 0), bounded(source.identityCorners1, 0),
      bounded(source.identityCorners2, 0), bounded(source.identityCorners3, 0)],
    appliedCorners: [bounded(source.appliedCorners0, 0), bounded(source.appliedCorners1, 0),
      bounded(source.appliedCorners2, 0), bounded(source.appliedCorners3, 0)],
    elapsedMs: bounded(source.elapsedMs),
    decoderName: platformText(source.decoderName),
    glVendor: platformText(source.glVendor),
    glRenderer: platformText(source.glRenderer)
  };
}

function copySelfTest(source: OrientationSelfTestEvidence): OrientationSelfTestEvidence {
  return {
    codec: source.codec, mode: source.mode, stage: source.stage, platformCode: source.platformCode,
    hardware: source.hardware, outputPixelFormat: source.outputPixelFormat, outputRotation: source.outputRotation,
    outputTransformType: source.outputTransformType, bufferTransform: source.bufferTransform,
    v2Class: source.v2Class, v1Class: source.v1Class, identityOrientation: source.identityOrientation,
    appliedOrientation: source.appliedOrientation, identityCorners: source.identityCorners.slice(),
    appliedCorners: source.appliedCorners.slice(), elapsedMs: source.elapsedMs,
    decoderName: source.decoderName, glVendor: source.glVendor, glRenderer: source.glRenderer
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
    lastAsyncError: bounded(source.lastAsyncError),
    outputStride: bounded(source.outputStride),
    outputSliceHeight: bounded(source.outputSliceHeight),
    outputCropTop: bounded(source.outputCropTop),
    outputCropBottom: bounded(source.outputCropBottom),
    outputCropLeft: bounded(source.outputCropLeft),
    outputCropRight: bounded(source.outputCropRight),
    outputRotation: bounded(source.outputRotation),
    outputTransformType: bounded(source.outputTransformType),
    bufferTransform: bounded(source.bufferTransform),
    producerV1Class: bounded(source.producerV1Class),
    orientationCorrection: bounded(source.orientationCorrection),
    streamNalMaskLow: bounded(source.streamNalMaskLow, 0),
    streamNalMaskHigh: bounded(source.streamNalMaskHigh, 0),
    streamSeiMaskLow: bounded(source.streamSeiMaskLow, 0),
    streamSeiMaskHigh: bounded(source.streamSeiMaskHigh, 0),
    streamDisplayOrientation: bounded(source.streamDisplayOrientation),
    streamInspectedFrames: bounded(source.streamInspectedFrames, 0)
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
    decoderAttempts: source.decoderAttempts.map(copyDecoderAttempt),
    orientationSelfTests: source.orientationSelfTests.map(copySelfTest)
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
  if (!exactKeys(source, fields.concat(['finalSamplingCorners', 'decoderAttempts', 'orientationSelfTests']))) {
    return null;
  }
  for (let index: number = 0; index < fields.length; index++) {
    const n: Object = source[fields[index]];
    if (typeof n !== 'number' || !Number.isSafeInteger(n as number)) { return null; }
  }
  if (source['evidenceVersion'] !== VIDEO_EVIDENCE_VERSION) { return null; }
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
  const attemptFields: string[] = ['serial', 'decoderGeneration', 'codec', 'width', 'height', 'stage', 'result',
    'platformCode', 'capabilityHardware', 'capabilitySizeSupported', 'outputWidth', 'outputHeight', 'outputPixelFormat',
    'asyncErrors', 'lastAsyncError', 'outputStride', 'outputSliceHeight', 'outputCropTop', 'outputCropBottom',
    'outputCropLeft', 'outputCropRight', 'outputRotation', 'outputTransformType', 'bufferTransform', 'producerV1Class',
    'orientationCorrection', 'streamNalMaskLow', 'streamNalMaskHigh', 'streamSeiMaskLow', 'streamSeiMaskHigh',
    'streamDisplayOrientation', 'streamInspectedFrames'];
  for (let index: number = 0; index < attempts.length; index++) {
    if (attempts[index] === null || typeof attempts[index] !== 'object') { return null; }
    const attempt: Record<string, Object> = attempts[index] as Record<string, Object>;
    if (!exactKeys(attempt, attemptFields)) { return null; }
    for (let field: number = 0; field < attemptFields.length; field++) {
      const n: Object = attempt[attemptFields[field]];
      if (typeof n !== 'number' || !Number.isSafeInteger(n as number)) { return null; }
    }
  }
  if (!selfTestsAreValid(source['orientationSelfTests'])) { return null; }
  return copyVideoDiagnosticEvidence(value as VideoDiagnosticEvidence);
}

function selfTestsAreValid(value: Object): boolean {
  if (!Array.isArray(value)) { return false; }
  const tests: Object[] = value as Object[];
  if (tests.length > 4) { return false; }
  const numberFields: string[] = ['codec', 'mode', 'stage', 'platformCode', 'hardware', 'outputPixelFormat',
    'outputRotation', 'outputTransformType', 'bufferTransform', 'v2Class', 'v1Class', 'identityOrientation',
    'appliedOrientation', 'elapsedMs'];
  const textFields: string[] = ['decoderName', 'glVendor', 'glRenderer'];
  const cornerFields: string[] = ['identityCorners', 'appliedCorners'];
  for (let index: number = 0; index < tests.length; index++) {
    if (tests[index] === null || typeof tests[index] !== 'object' || Array.isArray(tests[index])) { return false; }
    const test: Record<string, Object> = tests[index] as Record<string, Object>;
    if (!exactKeys(test, numberFields.concat(textFields, cornerFields))) { return false; }
    for (let field: number = 0; field < numberFields.length; field++) {
      const n: Object = test[numberFields[field]];
      if (typeof n !== 'number' || !Number.isSafeInteger(n as number)) { return false; }
    }
    for (let field: number = 0; field < textFields.length; field++) {
      const text: Object = test[textFields[field]];
      if (typeof text !== 'string' || !PLATFORM_TEXT.test(text as string)) { return false; }
    }
    for (let field: number = 0; field < cornerFields.length; field++) {
      const corners: Object = test[cornerFields[field]];
      if (!Array.isArray(corners) || (corners as Object[]).length !== 4) { return false; }
      const values: Object[] = corners as Object[];
      for (let corner: number = 0; corner < 4; corner++) {
        const n: Object = values[corner];
        if (typeof n !== 'number' || !Number.isSafeInteger(n as number) || (n as number) < 0 ||
          (n as number) > 0xffffffff) { return false; }
      }
    }
  }
  return true;
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
